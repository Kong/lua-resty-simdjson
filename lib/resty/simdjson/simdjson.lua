-- Copyright 2023 Datong Sun (dndx@idndx.com)
-- Dual licensed under the MIT License and Apache License Version 2.0
-- See LICENSE-MIT and LICENSE-APACHE for more information


local _M = {}
local _MT = { __index = _M, }


local ffi = require("ffi")
local table_new = require("table.new")
local string_buffer = require("string.buffer")
local C = require("resty.simdjson.cdefs")


local type = type
local assert = assert
local error = error
local setmetatable = setmetatable
local ffi_string = ffi.string
local ffi_gc = ffi.gc
local ngx_null = ngx.null
local ngx_sleep = ngx.sleep


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

    if self.decoding then
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

    local res, err = self:_build(op)

    self.decoding = false

    if err then
        return nil, err
    end

    if res and res ~= ngx_null and C.simdjson_ffi_is_eof(self.state) ~= 1 then
        return nil, "simdjson: error: trailing content found"
    end

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

    function encode_helper(self, item, cb, ctx)
        local typ = type(item)
        if typ == "table" then
            local comma = false

            local is_array, count = table_isarray(item)

            if is_array then
                cb("[", ctx)
                for i = 1, count do
                    local v = item[i] or ngx_null

                    if comma then
                        cb(",", ctx)
                    end

                    comma = true

                    local res, err = encode_helper(self, v, cb, ctx)
                    if not res then
                        return nil, err
                    end
                end
                cb("]", ctx)

            else
                cb("{", ctx)
                for k, v in pairs(item) do
                    local kt = type(k)
                    if kt ~= "string" and kt ~= "number" then
                        return nil, "object key must be a number or string"
                    end
                    k = tostring(k)

                    if comma then
                        cb(",", ctx)
                    end

                    comma = true

                    assert(encode_helper(self, k, cb, ctx))

                    cb(":", ctx)

                    local res, err = encode_helper(self, v, cb, ctx)
                    if not res then
                        return nil, err
                    end
                end
                cb("}", ctx)
            end

        elseif typ == "string" then
            cb("\"", ctx)
            for i = 1, #item do
                cb(ESCAPE_TABLE[string_byte(item, i)], ctx)
            end
            cb("\"", ctx)

        elseif typ == "number" then
            cb(self.number_precision:format(item), ctx)

        elseif typ == "boolean" then
            cb(tostring(item), ctx)

        elseif item == ngx_null then
            cb("null", ctx)

        else
            return nil, "unsupported data type: " .. typ
        end

        return true
    end
end
_M.encode_helper = encode_helper


local MAX_ITERATIONS = 2048


local function encode_callback(s, ctx)
    ctx.buf:put(s)

    if not ctx.yieldable then
        return
    end

    local iterations = ctx.iterations

    iterations = iterations - 1

    if iterations > 0 then
        ctx.iterations = iterations
        return
    end

    -- iterations <= 0, should reset iterations then yield
    ctx.iterations = MAX_ITERATIONS
    yielding(true)
end


function _M:encode(item)
    local ctx = {
        buf = string_buffer.new(),
        iterations = MAX_ITERATIONS,
        yieldable = self.yieldable,
    }

    local res, err = encode_helper(self, item, encode_callback, ctx)
    if not res then
        return nil, err
    end

    return ctx.buf:tostring()
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
