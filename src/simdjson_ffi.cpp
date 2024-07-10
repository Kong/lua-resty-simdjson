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
        state.frames.emplace(a.begin(), a.end());

        state.ops[state.ops_n].size = a.count_elements();

        go_deeper = true;

        break;
    }

    case ondemand::json_type::object: {
        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_OBJECT;

        ondemand::object o = value;
        state.frames.emplace(o.begin(), o.end());

        state.ops[state.ops_n].size = o.count_fields();

        go_deeper = true;

        break;
    }

    case ondemand::json_type::number: {
        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_NUMBER;
        state.vals[state.ops_n].number = double(value);

        break;
    }

    case ondemand::json_type::string: {
        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_STRING;
        std::string_view str = value;

        state.ops[state.ops_n].size = str.size();
        state.vals[state.ops_n].str = str.data();

        break;
    }

    case ondemand::json_type::boolean: {
        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_BOOLEAN;
        state.vals[state.ops_n].boolean = bool(value);

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


extern "C"
simdjson_ffi_state *simdjson_ffi_state_new() {
    return new(std::nothrow) simdjson_ffi_state();
}


extern "C"
simdjson_ffi_op_t *simdjson_ffi_state_get_ops(simdjson_ffi_state *state) {
    return state->ops;
}


extern "C"
simdjson_ffi_val_t *simdjson_ffi_state_get_vals(simdjson_ffi_state *state) {
    return state->vals;
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
                if (frame.processing) {
                    ++frame.it.array.current;
                    frame.processing = false;
                }

                // resume array iteration
                for (auto it = frame.it.array.current; it != frame.it.array.end; ++it) {
                    ondemand::value value = *it;

                    if (simdjson_process_value(*state, value)) {
                        // save state, go deeper
                        frame.it.array.current = it;
                        frame.processing = true;

                        break;
                    }

                    if (state->ops_n >= SIMDJSON_FFI_BATCH_SIZE) {
                        // array can use the last of the slots, no need to
                        // reserve two slots like object below
                        frame.it.array.current = it;
                        frame.processing = true;

                        return state->ops_n;
                    }
                }

                break;
            }

            case simdjson_ffi_resume_state::object: {
                if (frame.processing) {
                    ++frame.it.object.current;
                    frame.processing = false;
                }

                // resume object iteration
                for (auto it = frame.it.object.current; it != frame.it.object.end; ++it) {
                    auto field = *it;
                    std::string_view key = field.unescaped_key();

                    state->ops[state->ops_n].opcode = SIMDJSON_FFI_OPCODE_STRING;
                    state->ops[state->ops_n].size = key.size();
                    state->vals[state->ops_n++].str = key.data();

                    // this can not overflow, because we checked to make sure
                    // ops has at least 2 empty slots above

                    if (simdjson_process_value(*state, field.value())) {
                        // save state, go deeper
                        frame.it.object.current = it;
                        frame.processing = true;

                        break;
                    }

                    if (state->ops_n >= SIMDJSON_FFI_BATCH_SIZE - 1) {
                        frame.it.object.current = it;
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
