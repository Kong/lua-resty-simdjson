-- Copyright 2023 Datong Sun (dndx@idndx.com)
-- Dual licensed under the MIT License and Apache License Version 2.0
-- See LICENSE-MIT and LICENSE-APACHE for more information


local _M = {}


local ffi = require("ffi")
local ffi_string = ffi.string
local ffi_gc = ffi.gc
local table_new = require("table.new")
local assert = assert
local error = error
local setmetatable = setmetatable
local null = ngx.null
local ngx_sleep = ngx.sleep


local load_shared_lib
do
    local string_gmatch = string.gmatch
    local string_match = string.match
    local io_open = io.open
    local io_close = io.close

    local cpath = package.cpath

    function load_shared_lib(so_name)
        local tried_paths = table_new(32, 0)
        local i = 1

        for k, _ in string_gmatch(cpath, "[^;]+") do
            local fpath = string_match(k, "(.*/)")
            fpath = fpath .. so_name
            -- Don't get me wrong, the only way to know if a file exist is
            -- trying to open it.
            local f = io_open(fpath)
            if f ~= nil then
                io_close(f)
                return ffi.load(fpath)
            end

            tried_paths[i] = fpath
            i = i + 1
        end

        return nil, tried_paths
    end  -- function
end  -- do


local C, tried_paths = load_shared_lib("libsimdjson_ffi.so")
if not C then
    error("could not load libsimdjson.so from the following paths:\n" ..
          table.concat(tried_paths, "\n"), 2)
end

ffi.cdef([[
enum simdjson_ffi_opcode_t {
    SIMDJSON_FFI_OPCODE_ARRAY = 0,
    SIMDJSON_FFI_OPCODE_OBJECT,
    SIMDJSON_FFI_OPCODE_NUMBER,
    SIMDJSON_FFI_OPCODE_STRING,
    SIMDJSON_FFI_OPCODE_BOOLEAN,
    SIMDJSON_FFI_OPCODE_NULL,
    SIMDJSON_FFI_OPCODE_RETURN,
};

typedef struct {
    enum simdjson_ffi_opcode_t opcode;
    const char                *str;
    uint32_t                   size;
    double                     number;
} simdjson_ffi_op_t;


typedef struct simdjson_ffi_state simdjson_ffi_state;


simdjson_ffi_state *simdjson_ffi_state_new();
simdjson_ffi_op_t *simdjson_ffi_state_get_ops(simdjson_ffi_state *state);
void simdjson_ffi_state_free(simdjson_ffi_state *state);
int simdjson_ffi_parse(simdjson_ffi_state *state, const char *json, size_t len, char **errmsg);
int simdjson_ffi_next(simdjson_ffi_state *state, char **errmsg);
]])


local SIMDJSON_FFI_OPCODE_ARRAY = C.SIMDJSON_FFI_OPCODE_ARRAY
local SIMDJSON_FFI_OPCODE_OBJECT = C.SIMDJSON_FFI_OPCODE_OBJECT
local SIMDJSON_FFI_OPCODE_NUMBER = C.SIMDJSON_FFI_OPCODE_NUMBER
local SIMDJSON_FFI_OPCODE_STRING = C.SIMDJSON_FFI_OPCODE_STRING
local SIMDJSON_FFI_OPCODE_BOOLEAN = C.SIMDJSON_FFI_OPCODE_BOOLEAN
local SIMDJSON_FFI_OPCODE_NULL = C.SIMDJSON_FFI_OPCODE_NULL
local SIMDJSON_FFI_OPCODE_RETURN = C.SIMDJSON_FFI_OPCODE_RETURN
local SIMDJSON_FFI_ERROR = -1
local _MT = { __index = _M, }


local errmsg = require("resty.core.base").get_errmsg_ptr()


function _M.new(yield)
    local state = C.simdjson_ffi_state_new()
    if state == nil then
        return nil, "no memory"
    end


    local self = {
        ops_index = 0,
        ops_size = 0,
        state = ffi_gc(state, C.simdjson_ffi_state_free),
        ops = C.simdjson_ffi_state_get_ops(state),
        yield = yield,
    }

    return setmetatable(self, _MT)
end


function _M:destroy()
    if not self.state then
        error("already destroyed", 2)
    end

    C.simdjson_ffi_state_free(ffi_gc(self.state, nil))
    self.state = nil
    self.ops = nil
end


function _M:_build_array()
    if not self.state then
        error("already destroyed", 2)
    end

    local n = 0
    local tbl = table_new(4, 0)
    local ops = self.ops

    repeat
        while self.ops_index < self.ops_size do
            local opcode = ops[self.ops_index].opcode
            self.ops_index = self.ops_index + 1

            if opcode == SIMDJSON_FFI_OPCODE_RETURN then
                return tbl
            end

            if opcode == SIMDJSON_FFI_OPCODE_ARRAY then
                n = n + 1
                tbl[n] = self:_build_array()

            elseif opcode == SIMDJSON_FFI_OPCODE_OBJECT then
                n = n + 1
                tbl[n] = self:_build_object()

            elseif opcode == SIMDJSON_FFI_OPCODE_NUMBER then
                n = n + 1
                tbl[n] = ops[self.ops_index - 1].number

            elseif opcode == SIMDJSON_FFI_OPCODE_STRING then
                n = n + 1
                tbl[n] = ffi_string(ops[self.ops_index - 1].str, ops[self.ops_index - 1].size)

            elseif opcode == SIMDJSON_FFI_OPCODE_BOOLEAN then
                n = n + 1
                tbl[n] = ops[self.ops_index - 1].size == 1

            elseif opcode == SIMDJSON_FFI_OPCODE_NULL then
                n = n + 1
                tbl[n] = null

            else
                assert(false)
            end
        end

        if self.yield then
            ngx_sleep(0)
        end

        self.ops_size = C.simdjson_ffi_next(self.state, errmsg)
        if self.ops_size == SIMDJSON_FFI_ERROR then
            return nil, "simdjson: error: ", ffi_string(errmsg[0])
        end

        self.ops_index = 0
    until self.ops_size == 0

    assert(false, "array close did not seen")
end


function _M:_build_object()
    if not self.state then
        error("already destroyed", 2)
    end

    local tbl = table_new(0, 4)
    local key
    local ops = self.ops

    repeat
        while self.ops_index < self.ops_size do
            local opcode = ops[self.ops_index].opcode
            self.ops_index = self.ops_index + 1

            if opcode == SIMDJSON_FFI_OPCODE_RETURN then
                assert(key == nil)

                return tbl
            end


            if not key then
                -- object key must be string
                assert(opcode == SIMDJSON_FFI_OPCODE_STRING)
                key = ffi_string(ops[self.ops_index - 1].str, ops[self.ops_index - 1].size)

            else
                -- value
                if opcode == SIMDJSON_FFI_OPCODE_ARRAY then
                    tbl[key] = self:_build_array()

                elseif opcode == SIMDJSON_FFI_OPCODE_OBJECT then
                    tbl[key] = self:_build_object()

                elseif opcode == SIMDJSON_FFI_OPCODE_NUMBER then
                    tbl[key] = ops[self.ops_index - 1].number

                elseif opcode == SIMDJSON_FFI_OPCODE_STRING then
                    tbl[key] = ffi_string(ops[self.ops_index - 1].str, ops[self.ops_index - 1].size)

                elseif opcode == SIMDJSON_FFI_OPCODE_BOOLEAN then
                    tbl[key] = ops[self.ops_index - 1].size == 1

                elseif opcode == SIMDJSON_FFI_OPCODE_NULL then
                    tbl[key] = null

                else
                    assert(false)
                end

                key = nil
            end
        end

        if self.yield then
            ngx_sleep(0)
        end

        self.ops_size = C.simdjson_ffi_next(self.state, errmsg)
        if self.ops_size == SIMDJSON_FFI_ERROR then
            return nil, "simdjson: error: ", ffi_string(errmsg[0])
        end

        self.ops_index = 0
    until self.ops_size == 0

    assert(false, "object close did not seen")
end


function _M:decode(json)
    if not self.state then
        error("already destroyed", 2)
    end

    local res = C.simdjson_ffi_parse(self.state, json, #json, errmsg)
    if res == SIMDJSON_FFI_ERROR then
        return nil, "simdjson: error: ", ffi_string(errmsg[0])
    end

    local op = self.ops[0]

    if op.opcode == SIMDJSON_FFI_OPCODE_ARRAY then
        return self:_build_array(self.state)

    elseif op.opcode == SIMDJSON_FFI_OPCODE_OBJECT then
        return self:_build_object(self.state)

    elseif op.opcode == SIMDJSON_FFI_OPCODE_NUMBER then
        return op.number

    elseif op.opcode == SIMDJSON_FFI_OPCODE_STRING then
        return ffi_string(op.str, op.size)

    elseif op.opcode == SIMDJSON_FFI_OPCODE_BOOLEAN then
        return op.size == 1

    elseif op.opcode == SIMDJSON_FFI_OPCODE_NULL then
        return null

    else
        assert(false)
    end
end


return _M
