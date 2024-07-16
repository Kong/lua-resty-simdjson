/*
 * Copyright 2023 Datong Sun (dndx@idndx.com)
 * Dual licensed under the MIT License and Apache License Version 2.0
 * See LICENSE-MIT and LICENSE-APACHE for more information
 */

#include "simdjson.h"
#include "simdjson_ffi.h"


using namespace simdjson;


// T may be ondemand::value or state->document
template<typename T>
static bool simdjson_process_value(simdjson_ffi_state &state, T&& value) {
    bool go_deeper = false;

    switch (value.type()) {
    case ondemand::json_type::array: {
        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_ARRAY;

        ondemand::array a = value;
        state.frames.emplace(a);

        go_deeper = true;

        break;
    }

    case ondemand::json_type::object: {
        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_OBJECT;

        ondemand::object o = value;
        state.frames.emplace(o);

        go_deeper = true;

        break;
    }

    case ondemand::json_type::number: {
        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_NUMBER;
        state.ops[state.ops_n].val.number = double(value);

        break;
    }

    case ondemand::json_type::string: {
        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_STRING;
        std::string_view str = value;

        state.ops[state.ops_n].size = str.size();
        state.ops[state.ops_n].val.str = str.data();

        break;
    }

    case ondemand::json_type::boolean: {
        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_BOOLEAN;
        state.ops[state.ops_n].val.boolean = bool(value);

        break;
    }

    case ondemand::json_type::null: {
        SIMDJSON_DEVELOPMENT_ASSERT(value.is_null());

        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_NULL;

        break;
    }

    default:
        SIMDJSON_UNREACHABLE();
    }

    state.ops_n++;

    return go_deeper;
}


template<>
bool simdjson_process_value(simdjson_ffi_state &state, simdjson_result<std::string_view>&& key) {
    state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_STRING;
    std::string_view str = key.value();

    state.ops[state.ops_n].size = str.size();
    state.ops[state.ops_n].val.str = str.data();

    state.ops_n++;

    return false;
}


extern "C"
simdjson_ffi_state *simdjson_ffi_state_new() {
    return new(std::nothrow) simdjson_ffi_state();
}


extern "C"
simdjson_ffi_op_t *simdjson_ffi_state_get_ops(simdjson_ffi_state *state) {
    return state->ops;
}


extern "C"
void simdjson_ffi_state_free(simdjson_ffi_state *state) {
    delete state;
}


extern "C"
int simdjson_ffi_parse(simdjson_ffi_state *state,
    const char *json, size_t len, const char **errmsg) try {

    state->json = padded_string(json, len);

    state->document = state->parser.iterate(state->json);
    state->ops_n = 0;

    simdjson_process_value(*state, state->document);

    return state->ops_n;

} catch (simdjson_error &e) {
    *errmsg = e.what();

    return SIMDJSON_FFI_ERROR;
}


extern "C"
int simdjson_ffi_is_eof(simdjson_ffi_state *state) {
    return state->document.at_end();
}


extern "C"
int simdjson_ffi_next(simdjson_ffi_state *state, const char **errmsg) try {
    state->ops_n = 0;

    while (!state->frames.empty()) {

        if (state->ops_n >= SIMDJSON_FFI_BATCH_SIZE - 1) {
            // -1 for key value pair which requires 2 ops
            return state->ops_n;
        }

        auto &frame = state->frames.top();

        switch (frame.state) {
            case simdjson_ffi_resume_state::array: {
                auto &it = frame.it.array.current;

                if (frame.processing) {
                    ++it;
                    frame.processing = false;
                }

                // resume array iteration
                for (; it != frame.it.array.end; ++it) {
                    auto value = *it;

                    if (simdjson_process_value(*state, value)) {
                        // save state, go deeper
                        frame.processing = true;

                        break;
                    }

                    if (state->ops_n >= SIMDJSON_FFI_BATCH_SIZE) {
                        // array can use the last of the slots, no need to
                        // reserve two slots like object below
                        frame.processing = true;

                        return state->ops_n;
                    }
                }

                break;
            }

            case simdjson_ffi_resume_state::object: {
                auto &it = frame.it.object.current;

                if (frame.processing) {
                    ++it;
                    frame.processing = false;
                }

                // resume object iteration
                for (; it != frame.it.object.end; ++it) {
                    auto field = *it;

                    simdjson_process_value(*state, field.unescaped_key());

                    // this can not overflow, because we checked to make sure
                    // ops has at least 2 empty slots above

                    if (simdjson_process_value(*state, field.value())) {
                        // save state, go deeper
                        frame.processing = true;

                        break;
                    }

                    if (state->ops_n >= SIMDJSON_FFI_BATCH_SIZE - 1) {
                        frame.processing = true;

                        return state->ops_n;
                    }
                }

                break;
            }

            default:
                SIMDJSON_UNREACHABLE();
        }

        if (!frame.processing) {
            state->frames.pop();

            state->ops[state->ops_n++].opcode = SIMDJSON_FFI_OPCODE_RETURN;
        }
    }

    // we are done! clean up the tmp string to save memory
    state->json = padded_string();

    return state->ops_n;

} catch (simdjson_error &e) {
    *errmsg = e.what();

    return SIMDJSON_FFI_ERROR;
}
