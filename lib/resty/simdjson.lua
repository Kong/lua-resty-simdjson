local _M = {}


local ffi = require("ffi")
local ffi_string = ffi.string
local table_new = require("table.new")
local assert = assert

local C = ffi.load("/home/datong/code/dndx/lua-resty-simdjson/libsimdjson_ffi.so")
local errmsg = require("resty.core.base").get_errmsg_ptr()

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


local SIMDJSON_PADDING = 64
local SIMDJSON_FFI_OPCODE_ARRAY = C.SIMDJSON_FFI_OPCODE_ARRAY
local SIMDJSON_FFI_OPCODE_OBJECT = C.SIMDJSON_FFI_OPCODE_OBJECT
local SIMDJSON_FFI_OPCODE_NUMBER = C.SIMDJSON_FFI_OPCODE_NUMBER
local SIMDJSON_FFI_OPCODE_STRING = C.SIMDJSON_FFI_OPCODE_STRING
local SIMDJSON_FFI_OPCODE_BOOLEAN = C.SIMDJSON_FFI_OPCODE_BOOLEAN
local SIMDJSON_FFI_OPCODE_NULL = C.SIMDJSON_FFI_OPCODE_NULL
local SIMDJSON_FFI_OPCODE_RETURN = C.SIMDJSON_FFI_OPCODE_RETURN
local SIMDJSON_FFI_ERROR = -1



local function deep_compare(tbl1, tbl2)
	if tbl1 == tbl2 then
		return true
	elseif type(tbl1) == "table" and type(tbl2) == "table" then
		for key1, value1 in pairs(tbl1) do
			local value2 = tbl2[key1]

			if value2 == nil then
				-- avoid the type call for missing keys in tbl2 by directly comparing with nil
				return false
			elseif value1 ~= value2 then
				if type(value1) == "table" and type(value2) == "table" then
					if not deep_compare(value1, value2) then
						return false
					end
				else
					return false
				end
			end
		end

		-- check for missing keys in tbl1
		for key2, _ in pairs(tbl2) do
			if tbl1[key2] == nil then
				return false
			end
		end

		return true
	end

	return false
end



local json = io.open("100mb.json", "rb"):read("*a")

local state = C.simdjson_ffi_state_new()
print("state = ", state)
local ops = C.simdjson_ffi_state_get_ops(state)
print("ops = ", ops)


for i = 1, 10 do
ngx.update_time()
local now = ngx.now()

local res = C.simdjson_ffi_parse(state, json, #json, errmsg)
if res == SIMDJSON_FFI_ERROR then
    print("simdjson_ffi_parse: error: ", ffi_string(errmsg[0]))
end
ngx.update_time()
print("simdjson_ffi_parse: ", res, ", time = ", ngx.now() - now)


local ops_index = 0
local ops_size = 0

local build_object

local function build_array(state)
    local n = 0
    local tbl = table_new(4, 0)

    repeat
        while ops_index < ops_size do
            local opcode = ops[ops_index].opcode
            ops_index = ops_index + 1

            if opcode == SIMDJSON_FFI_OPCODE_RETURN then
                return tbl
            end

            if opcode == SIMDJSON_FFI_OPCODE_ARRAY then
                n = n + 1
                tbl[n] = build_array(state)

            elseif opcode == SIMDJSON_FFI_OPCODE_OBJECT then
                n = n + 1
                tbl[n] = build_object(state)

            elseif opcode == SIMDJSON_FFI_OPCODE_NUMBER then
                n = n + 1
                tbl[n] = ops[ops_index - 1].number

            elseif opcode == SIMDJSON_FFI_OPCODE_STRING then
                n = n + 1
                tbl[n] = ffi_string(ops[ops_index - 1].str, ops[ops_index - 1].size)

            elseif opcode == SIMDJSON_FFI_OPCODE_BOOLEAN then
                n = n + 1
                tbl[n] = ops[ops_index - 1].size == 1

            elseif opcode == SIMDJSON_FFI_OPCODE_NULL then
                n = n + 1
                tbl[n] = ngx.null

            else
                assert(false)
            end
        end

        ops_size = C.simdjson_ffi_next(state, errmsg)
        if ops_size == SIMDJSON_FFI_ERROR then
            return nil, ffi_string(errmsg[0])
        end

        ops_index = 0
    until ops_size == 0

    assert(false, "array close did not seen")
end

function build_object(state)
    local tbl = table_new(0, 4)
    local key

    repeat
        while ops_index < ops_size do
            local opcode = ops[ops_index].opcode
            ops_index = ops_index + 1

            if opcode == SIMDJSON_FFI_OPCODE_RETURN then
                assert(key == nil)

                return tbl
            end


            if not key then
                -- object key must be string
                assert(opcode == SIMDJSON_FFI_OPCODE_STRING)
                key = ffi_string(ops[ops_index - 1].str, ops[ops_index - 1].size)

            else
                -- value
                if opcode == SIMDJSON_FFI_OPCODE_ARRAY then
                    tbl[key] = build_array(state)

                elseif opcode == SIMDJSON_FFI_OPCODE_OBJECT then
                    tbl[key] = build_object(state)

                elseif opcode == SIMDJSON_FFI_OPCODE_NUMBER then
                    tbl[key] = ops[ops_index - 1].number

                elseif opcode == SIMDJSON_FFI_OPCODE_STRING then
                    tbl[key] = ffi_string(ops[ops_index - 1].str, ops[ops_index - 1].size)

                elseif opcode == SIMDJSON_FFI_OPCODE_BOOLEAN then
                    tbl[key] = ops[ops_index - 1].size == 1

                elseif opcode == SIMDJSON_FFI_OPCODE_NULL then
                    tbl[key] = ngx.null

                else
                    assert(false)
                end

                key = nil
            end
        end

        ops_size = C.simdjson_ffi_next(state, errmsg)
        if ops_size == SIMDJSON_FFI_ERROR then
            return nil, ffi_string(errmsg[0])
        end
        ops_index = 0
    until ops_size == 0

    assert(false, "object close did not seen")
end





local op = ops[0]

local res

ngx.update_time()
now = ngx.now()

if op.opcode == SIMDJSON_FFI_OPCODE_ARRAY then
    res = build_array(state)

elseif op.opcode == SIMDJSON_FFI_OPCODE_OBJECT then
    res = build_object(state)

elseif op.opcode == SIMDJSON_FFI_OPCODE_NUMBER then
    res = op.number

elseif op.opcode == SIMDJSON_FFI_OPCODE_STRING then
    res = ffi_string(op.str, op.size)

elseif op.opcode == SIMDJSON_FFI_OPCODE_BOOLEAN then
    res = op.size == 1

elseif op.opcode == SIMDJSON_FFI_OPCODE_NULL then
    res = ngx.null

else
    assert(false)

end

ngx.update_time()
print("simdjson took: ", ngx.now() - now)


end

C.simdjson_ffi_state_free(state)



for i = 1, 10 do
ngx.update_time()
local now = ngx.now()
local cj = require("cjson.safe").decode(json)
ngx.update_time()
print("cjson took: ", ngx.now() - now)
end

print("results are equal? ", deep_compare(cj, res))

return _M
