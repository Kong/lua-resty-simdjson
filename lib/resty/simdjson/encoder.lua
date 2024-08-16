local string_buffer = require("string.buffer")


local _M = {}
local _MT = { __index = _M, }


local type = type
local assert = assert
local setmetatable = setmetatable
local ngx_null = ngx.null
local ngx_sleep = ngx.sleep


function _M.new(yieldable)
    local self = {
        yieldable = yieldable,
        number_precision = "%.16g",  -- up to 16 decimals
    }

    return setmetatable(self, _MT)
end


local encode_helper
do
    local cjson = assert(require("cjson"))
    local cjson_array_mt = cjson.array_mt
    local cjson_empty_array = cjson.empty_array
    local cjson_empty_array_mt = cjson.empty_array_mt

    local pairs = pairs
    local tostring = tostring
    local getmetatable = getmetatable
    local string_byte = string.byte
    local string_char = string.char
    local tb_isempty = require("table.isempty")
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
        -- empty table will be encoded to json object
        -- unless empty_array_mt is set
        if tb_isempty(tbl) then
            local mt = getmetatable(tbl)
            if mt == cjson_empty_array_mt or mt == cjson_array_mt then
                return true, 0
            end

            return false
        end

        -- pure array or has cjson.array_mt
        local is_array = tb_isarray(tbl) or
                         getmetatable(tbl) == cjson_array_mt
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

        local max = 0
        for k in pairs(tbl) do
            -- skip non-numeric keys
            if type(k) ~= "number" then
                goto continue
            end

            -- negative or zero index
            if k <= 0 then
                return false
            end

            if k > max then
                max = k
            end

            ::continue::
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

        elseif item == cjson_empty_array then
            cb("[]", ctx)

        else
            return nil, "unsupported data type: " .. typ
        end

        return true
    end
end
_M.encode_helper = encode_helper


local MAX_ITERATIONS = 2048


local function yielding()
    ngx_sleep(0)
end


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

    yielding()
end


function _M:process(item)
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
