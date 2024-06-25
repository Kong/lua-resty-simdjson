-- Copyright 2023 Datong Sun (dndx@idndx.com)
-- Dual licensed under the MIT License and Apache License Version 2.0
-- See LICENSE-MIT and LICENSE-APACHE for more information


local _M = {}
local _MT = { __index = _M, }


local ffi = require("ffi")
local table_new = require("table.new")
local table_isarray = require("table.isarray")
local string_buffer = require("string.buffer")


local assert = assert
local error = error
local setmetatable = setmetatable
local ffi_string = ffi.string
local ffi_gc = ffi.gc
local ngx_null = ngx.null
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
typedef enum {
    SIMDJSON_FFI_OPCODE_ARRAY = 0,
    SIMDJSON_FFI_OPCODE_OBJECT,
    SIMDJSON_FFI_OPCODE_NUMBER,
    SIMDJSON_FFI_OPCODE_STRING,
    SIMDJSON_FFI_OPCODE_BOOLEAN,
    SIMDJSON_FFI_OPCODE_NULL,
    SIMDJSON_FFI_OPCODE_RETURN
} simdjson_ffi_opcode_e;


typedef struct {
    simdjson_ffi_opcode_e      opcode;
    const char                *str;
    uint32_t                   size;
    double                     number;
} simdjson_ffi_op_t;


typedef struct simdjson_ffi_state_t simdjson_ffi_state;


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


local errmsg = require("resty.core.base").get_errmsg_ptr()


local function yielding(enable)
    if enable then
        ngx_sleep(0)
    end
end


function _M.new(yieldable)
    local state = C.simdjson_ffi_state_new()
    if state == nil then
        return nil, "no memory"
    end


    local self = {
        ops_index = 0,
        ops_size = 0,
        state = ffi_gc(state, C.simdjson_ffi_state_free),
        ops = C.simdjson_ffi_state_get_ops(state),
        yieldable = yieldable,
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
                tbl[n] = ngx_null

            else
                assert(false)
            end
        end

        yielding(self.yieldable)

        self.ops_size = C.simdjson_ffi_next(self.state, errmsg)
        if self.ops_size == SIMDJSON_FFI_ERROR then
            return nil, "simdjson: error: " .. ffi_string(errmsg[0])
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
                    tbl[key] = ngx_null

                else
                    assert(false)
                end

                key = nil
            end
        end

        yielding(self.yieldable)

        self.ops_size = C.simdjson_ffi_next(self.state, errmsg)
        if self.ops_size == SIMDJSON_FFI_ERROR then
            return nil, "simdjson: error: " .. ffi_string(errmsg[0])
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
        return nil, "simdjson: error: " .. ffi_string(errmsg[0])
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
        return ngx_null

    else
        assert(false)
    end
end


local encode_helper
do
    local type = type
    local pairs = pairs
    local ipairs = ipairs
    local tostring = tostring
    local string_byte = string.byte
    local string_char = string.char

    local ESCAPE_TABLE = {
        "\\u0001", "\\u0002", "\\u0003",
        "\\u0004", "\\u0005", "\\u0006", "\\u0007",
        "\\b", "\\t", "\\n", "\\u000b",
        "\\f", "\\r", "\\u000e", "\\u000f",
        "\\u0010", "\\u0011", "\\u0012", "\\u0013",
        "\\u0014", "\\u0015", "\\u0016", "\\u0017",
        "\\u0018", "\\u0019", "\\u001a", "\\u001b",
        "\\u001c", "\\u001d", "\\u001e", "\\u001f",
        nil, nil, "\\\"", nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, "\\/",
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, "\\\\", nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, "\\u007f",
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, nil, nil, nil,
    }

    ESCAPE_TABLE[0] = "\\u0000"

    for i = 0, 255 do
        if not ESCAPE_TABLE[i] then
            ESCAPE_TABLE[i] = string_char(i)
        end
    end

    function encode_helper(self, item, cb)
        local typ = type(item)
        if typ == "table" then
            local comma = false

            local is_array = table_isarray(item)

            if is_array then
                cb("[")
                for _, v in ipairs(item) do
                    if comma then
                        cb(", ")
                    end

                    comma = true

                    local res, err = encode_helper(self, v, cb)
                    if not res then
                        return nil, err
                    end
                end
                cb("]")

            else
                cb("{")
                for k, v in pairs(item) do
                    if type(k) ~= "string" then
                        return nil, "object keys must be strings"
                    end

                    if comma then
                        cb(", ")
                    end

                    comma = true

                    assert(encode_helper(self, k, cb))

                    cb(":")

                    local res, err = encode_helper(self, v, cb)
                    if not res then
                        return nil, err
                    end
                end
                cb("}")
            end

        elseif typ == "string" then
            cb("\"")
            for i = 1, #item do
                cb(ESCAPE_TABLE[string_byte(item, i)])
            end
            cb("\"")

        elseif typ == "number" or typ == "boolean" then
            -- TODO: number's precision
            cb(tostring(item))

        elseif item == ngx_null then
            cb("null")

        else
            return nil, "unsupported data type: " .. typ
        end

        return true
    end
end
_M.encode_helper = encode_helper


local MAX_ITERATIONS = 2048


function _M:encode(item)
    local buf = string_buffer.new()
    local iterations = MAX_ITERATIONS

    local res, err = encode_helper(self, item, function(s)
        buf:put(s)

        if self.yieldable then
            iterations = iterations - 1
            if iterations <= 0 then
                iterations = MAX_ITERATIONS
                yielding(true)
            end
        end
    end)
    if not res then
        return nil, err
    end

    return buf:tostring()
end


return _M
