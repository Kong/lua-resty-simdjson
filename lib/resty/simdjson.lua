-- Copyright 2023 Datong Sun (dndx@idndx.com)
-- Dual licensed under the MIT License and Apache License Version 2.0
-- See LICENSE-MIT and LICENSE-APACHE for more information


local _M = {}
local _MT = { __index = _M, }


local ffi = require("ffi")
local table_new = require("table.new")
local string_buffer = require("string.buffer")


local type = type
local assert = assert
local error = error
local setmetatable = setmetatable
local ffi_string = ffi.string
local ffi_gc = ffi.gc
local ngx_null = ngx.null
local ngx_sleep = ngx.sleep


-- From: https://github.com/openresty/lua-resty-signal/blob/master/lib/resty/signal.lua
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


local lib_name = ffi.os == "OSX" and "libsimdjson_ffi.dylib" or "libsimdjson_ffi.so"


local C, tried_paths = load_shared_lib(lib_name)
if not C then
    error(("could not load %s shared library from the following paths:\n"):format(lib_name) ..
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
    uint32_t                   size;

    union {
        const char            *str;
        double                 number;
        uint32_t               boolean;
    }                          val;
} simdjson_ffi_op_t;

typedef struct simdjson_ffi_state_t simdjson_ffi_state;

simdjson_ffi_state *simdjson_ffi_state_new();
simdjson_ffi_op_t *simdjson_ffi_state_get_ops(simdjson_ffi_state *state);
void simdjson_ffi_state_free(simdjson_ffi_state *state);
int simdjson_ffi_is_eof(simdjson_ffi_state *state);
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


local DEFAULT_TABLE_SLOTS = 4
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
        decoding = false,
        number_precision = "%.16g",  -- up to 16 decimals
    }

    return setmetatable(self, _MT)
end


function _M:destroy()
    if not self.state then
        error("already destroyed", 2)
    end

    if self.yieldable and self.decoding then
        error("decoding, can not be destroyed", 2)
    end

    C.simdjson_ffi_state_free(ffi_gc(self.state, nil))
    self.state = nil
    self.ops = nil
end


function _M:_build(op)
    local opcode = op.opcode

    if opcode == SIMDJSON_FFI_OPCODE_ARRAY then
        return self:_build_array(DEFAULT_TABLE_SLOTS)

    elseif opcode == SIMDJSON_FFI_OPCODE_OBJECT then
        return self:_build_object(DEFAULT_TABLE_SLOTS)

    elseif opcode == SIMDJSON_FFI_OPCODE_NUMBER then
        return op.val.number

    elseif opcode == SIMDJSON_FFI_OPCODE_STRING then
        return ffi_string(op.val.str, op.size)

    elseif opcode == SIMDJSON_FFI_OPCODE_BOOLEAN then
        return op.val.boolean == 1

    elseif opcode == SIMDJSON_FFI_OPCODE_NULL then
        return ngx_null

    else
        assert(false) -- never reach here
    end
end


function _M:_build_array(count)
    if not self.state then
        error("already destroyed", 2)
    end

    local n = 1
    local tbl = table_new(count, 0)
    local ops = self.ops
    local yieldable = self.yieldable

    repeat
        while self.ops_index < self.ops_size do
            local ops_index = self.ops_index
            local op = ops[ops_index]
            local opcode = op.opcode

            self.ops_index = ops_index + 1

            if opcode == SIMDJSON_FFI_OPCODE_RETURN then
                return tbl
            end

            tbl[n] = self:_build(op)

            n = n + 1
        end

        yielding(yieldable)

        self.ops_size = C.simdjson_ffi_next(self.state, errmsg)
        if self.ops_size == SIMDJSON_FFI_ERROR then
            return nil, "simdjson: error: " .. ffi_string(errmsg[0])
        end

        self.ops_index = 0
    until self.ops_size == 0

    assert(false, "array close did not seen")
end


function _M:_build_object(count)
    if not self.state then
        error("already destroyed", 2)
    end

    local tbl = table_new(0, count)
    local key
    local ops = self.ops
    local yieldable = self.yieldable

    repeat
        while self.ops_index < self.ops_size do
            local ops_index = self.ops_index
            local op = ops[ops_index]
            local opcode = op.opcode

            self.ops_index = ops_index + 1

            if opcode == SIMDJSON_FFI_OPCODE_RETURN then
                assert(key == nil)

                return tbl
            end

            if not key then
                -- object key must be string
                assert(opcode == SIMDJSON_FFI_OPCODE_STRING)
                key = ffi_string(op.val.str, op.size)

            else
                -- value
                tbl[key] = self:_build(op)

                key = nil
            end
        end

        yielding(yieldable)

        self.ops_size = C.simdjson_ffi_next(self.state, errmsg)
        if self.ops_size == SIMDJSON_FFI_ERROR then
            return nil, "simdjson: error: " .. ffi_string(errmsg[0])
        end

        self.ops_index = 0
    until self.ops_size == 0

    assert(false, "object close did not seen")
end


function _M:decode(json)
    assert(type(json) == "string")

    if not self.state then
        error("already destroyed", 2)
    end

    if self.yieldable and self.decoding then
        error("decode is not reentrant", 2)
    end

    self.decoding = true

    local res = C.simdjson_ffi_parse(self.state, json, #json, errmsg)
    if res == SIMDJSON_FFI_ERROR then
        self.decoding = false
        return nil, "simdjson: error: " .. ffi_string(errmsg[0])
    end

    local op = self.ops[0]

    local res = self:_build(op)
    if res and res ~= ngx_null and C.simdjson_ffi_is_eof(self.state) ~= 1 then
        self.decoding = false
        return nil, "simdjson: error: trailing content found"
    end

    self.decoding = false

    return res
end


local encode_helper
do
    local pairs = pairs
    local tostring = tostring
    local string_byte = string.byte
    local string_char = string.char
    local tb_isarray = require("table.isarray")
    local tb_nkeys = require("table.nkeys")

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

    local function table_isarray(tbl)
        local is_array = tb_isarray(tbl)
        if not is_array then
            return false
        end

        local count = #tbl
        local nkeys = tb_nkeys(tbl)

        -- table is a normal array
        if count == nkeys then
            return true, count
        end

        -- table may have negative/zero index or hole

        local max = 1
        for k in pairs(tbl) do
            -- negative or zero index
            if k <= 0 then
                return false
            end

            if k > max then
                max = k
            end
        end

        return true, max
    end

    function encode_helper(self, item, cb)
        local typ = type(item)
        if typ == "table" then
            local comma = false

            local is_array, count = table_isarray(item)

            if is_array then
                cb("[")
                for i = 1, count do
                    local v = item[i] or ngx_null

                    if comma then
                        cb(",")
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
                    local kt = type(k)
                    if kt ~= "string" and kt ~= "number" then
                        return nil, "object key must be a number or string"
                    end
                    k = tostring(k)

                    if comma then
                        cb(",")
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

        elseif typ == "number" then
            cb(self.number_precision:format(item))

        elseif typ == "boolean" then
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
    local yieldable = self.yieldable

    local res, err = encode_helper(self, item, function(s)
        buf:put(s)

        if not yieldable then
            return
        end

        iterations = iterations - 1
        if iterations > 0 then
            return
        end

        -- iterations <= 0, should reset iterations then yield
        iterations = MAX_ITERATIONS
        yielding(true)
    end)
    if not res then
        return nil, err
    end

    return buf:tostring()
end


function _M:encode_number_precision(precision)
    assert(type(precision) == "number")
    assert(math.floor(precision) == precision)
    assert(precision >= 1 and precision <= 16)

    self.number_precision = "%." .. precision .. "g"
end


-- we will never encode sparse array to object
function _M:encode_sparse_array(convert)
    assert(not convert)
end


return _M
