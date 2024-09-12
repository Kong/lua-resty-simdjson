local ffi = require("ffi")
local table_new = require("table.new")


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
simdjson_ffi_op_t *simdjson_ffi_state_get_ops(simdjson_ffi_state *state, size_t json_len);
void simdjson_ffi_state_free(simdjson_ffi_state *state);
int simdjson_ffi_is_eof(simdjson_ffi_state *state);
int simdjson_ffi_parse(simdjson_ffi_state *state, const char *json, size_t len, char **errmsg);
int simdjson_ffi_next(simdjson_ffi_state *state, char **errmsg);
]])


return C
