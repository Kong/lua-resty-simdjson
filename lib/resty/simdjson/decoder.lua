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
local co_running = coroutine.running
local co_status = coroutine.status


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
        ops = nil,  -- reserved for decode
        yieldable = yieldable,
        decoding = false,
        decoding_co = nil,  -- reserved for a yieldable decode
    }

    return setmetatable(self, _MT)
end


-- A yieldable decode marks the decoder while it runs, so that a second decode
-- on the same object is refused. The marker can outlive the decode that set
-- it: pcall catches a raise, but a light thread killed while parked in
-- yielding() unwinds nothing. Give the marker back once the coroutine that
-- set it can no longer resume.
--
-- A suspended owner is left alone on purpose. It may still be resumed, and
-- reclaiming there would run two decodes over one C++ state.
local function reclaim_abandoned(self)
    local owner = self.decoding_co

    if not owner or owner == co_running() or co_status(owner) ~= "dead" then
        return false
    end

    self.decoding = false
    self.decoding_co = nil

    return true
end


function _M:destroy()
    local state = self.state

    if not state then
        error("already destroyed", 2)
    end

    if self.decoding and not reclaim_abandoned(self) then
        error("decoding, can not be destroyed", 2)
    end

    C.simdjson_ffi_state_free(ffi_gc(state, nil))
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
    local state = self.state

    if not state then
        error("already destroyed", 2)
    end

    local err
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

            tbl[n], err = self:_build(op)
            if err then
              return nil, err
            end

            n = n + 1
        end

        yielding(yieldable)

        self.ops_size = C.simdjson_ffi_next(state, errmsg)
        if self.ops_size == SIMDJSON_FFI_ERROR then
            return nil, "simdjson: error: " .. ffi_string(errmsg[0])
        end

        self.ops_index = 0
    until self.ops_size == 0

    assert(false, "array close did not seen")
end


function _M:_build_object(count)
    local state = self.state

    if not state then
        error("already destroyed", 2)
    end

    local err
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
                tbl[key], err = self:_build(op)
                if err then
                  return nil, err
                end

                key = nil
            end
        end

        yielding(yieldable)

        self.ops_size = C.simdjson_ffi_next(state, errmsg)
        if self.ops_size == SIMDJSON_FFI_ERROR then
            return nil, "simdjson: error: " .. ffi_string(errmsg[0])
        end

        self.ops_index = 0
    until self.ops_size == 0

    assert(false, "object close did not seen")
end


local function do_process(self, json, state)
    local res = C.simdjson_ffi_parse(state, json, #json, errmsg)
    if res == SIMDJSON_FFI_ERROR then
        return nil, "simdjson: error: " .. ffi_string(errmsg[0])
    end

    local res, err = self:_build(self.ops[0])
    if err then
        return nil, err
    end

    if res and res ~= ngx_null and C.simdjson_ffi_is_eof(state) ~= 1 then
        return nil, "simdjson: error: trailing content found"
    end

    return res
end


function _M:process(json)
    assert(type(json) == "string")

    local state = self.state

    if not state then
        error("already destroyed", 2)
    end

    if self.yieldable and self.decoding and not reclaim_abandoned(self) then
        error("decode is not reentrant", 2)
    end

    -- a previous decode may have been abandoned part way through, so start
    -- from a known position instead of where that decode stopped
    self.ops_index = 0
    self.ops_size = 0

    -- allocate array memory on-demand
    self.ops = assert(C.simdjson_ffi_state_get_ops(state))

    local res, err

    if self.yieldable then
        -- Only a yieldable decode can be seen part way through, so only it
        -- needs the marker. The builders raise when the opcode stream is not
        -- what they expect, and that would leave the marker set: the guard
        -- above would refuse every later decode, and destroy() would refuse
        -- too. Clear it before the error travels on.
        self.decoding = true
        self.decoding_co = co_running()

        local ok
        ok, res, err = pcall(do_process, self, json, state)

        self.decoding = false
        self.decoding_co = nil

        if not ok then
            -- res holds the error, which already carries its own position
            error(res, 0)
        end

    else
        -- No marker is set here, so a raise leaves nothing for destroy() to
        -- trip over, and this path stays free of the pcall.
        res, err = do_process(self, json, state)
    end

    if err then
        return nil, err
    end

    return res
end


return _M
