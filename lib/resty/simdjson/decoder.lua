-- Copyright 2023 Datong Sun (dndx@idndx.com)
-- Dual licensed under the MIT License and Apache License Version 2.0
-- See LICENSE-MIT and LICENSE-APACHE for more information


local _M = {}
local _MT = { __index = _M, }


local ffi = require("ffi")
local table_new = require("table.new")
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


return _M
