/*
 * Copyright 2023 Datong Sun (dndx@idndx.com)
 * Dual licensed under the MIT License and Apache License Version 2.0
 * See LICENSE-MIT and LICENSE-APACHE for more information
 */

#include "simdjson.h"
#include "simdjson_ffi.h"
using namespace simdjson;
using namespace std;


static bool simdjson_ffi_process_value(simdjson_ffi_state &state, simdjson::ondemand::value value) {
    switch (value.type()) {
    case ondemand::json_type::array: {
        simdjson::ondemand::array a = value;
        state.frames.emplace(simdjson_ffi_resume_state::array, a.begin(), a.end());

        state.ops[state.ops_n++].opcode = SIMDJSON_FFI_OPCODE_ARRAY;

        return true;
    }

    case ondemand::json_type::object: {
        simdjson::ondemand::object o = value;
        state.frames.emplace(simdjson_ffi_resume_state::object, o.begin(), o.end());

        state.ops[state.ops_n++].opcode = SIMDJSON_FFI_OPCODE_OBJECT;

        return true;
    }

    case ondemand::json_type::number: {
        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_NUMBER;
        state.ops[state.ops_n++].number = double(value);
        return false;
    }

    case ondemand::json_type::string: {
        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_STRING;
        std::string_view str = value;

        state.ops[state.ops_n].str = str.data();
        state.ops[state.ops_n++].size = str.size();
        return false;
    }

    case ondemand::json_type::boolean: {
        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_BOOLEAN;
        state.ops[state.ops_n++].size = bool(value);
        return false;
    }

    case ondemand::json_type::null: {
        value.is_null();

        state.ops[state.ops_n++].opcode = SIMDJSON_FFI_OPCODE_NULL;
        return false;
    }

    default:
        SIMDJSON_UNREACHABLE();
    }
}

extern "C" {
    simdjson_ffi_state *simdjson_ffi_state_new() {
        return new(nothrow) simdjson_ffi_state();
    }

    simdjson_ffi_op_t *simdjson_ffi_state_get_ops(simdjson_ffi_state *state) {
        return state->ops;
    }

    void simdjson_ffi_state_free(simdjson_ffi_state *state) {
        delete state;
    }


    int simdjson_ffi_parse(simdjson_ffi_state *state, const char *json, size_t len, const char **errmsg) {
        try {
            state->json = simdjson::padded_string(json, len);

            state->document = state->parser.iterate(state->json);
            state->ops_n = 0;

            switch (state->document.type()) {
            case ondemand::json_type::array: {
                simdjson::ondemand::array a = state->document;
                state->frames.emplace(simdjson_ffi_resume_state::array, a.begin(), a.end());

                state->ops[state->ops_n].opcode = SIMDJSON_FFI_OPCODE_ARRAY;

                break;
            }

            case ondemand::json_type::object: {
                simdjson::ondemand::object o = state->document;
                state->frames.emplace(simdjson_ffi_resume_state::object, o.begin(), o.end());

                state->ops[state->ops_n].opcode = SIMDJSON_FFI_OPCODE_OBJECT;

                break;
            }

            case ondemand::json_type::number: {
                state->ops[state->ops_n].opcode = SIMDJSON_FFI_OPCODE_NUMBER;
                state->ops[state->ops_n].number = double(state->document);
                break;
            }

            case ondemand::json_type::string: {
                state->ops[state->ops_n].opcode = SIMDJSON_FFI_OPCODE_STRING;
                std::string_view str = state->document;

                state->ops[state->ops_n].str = str.data();
                state->ops[state->ops_n].size = str.size();
                break;
            }

            case ondemand::json_type::boolean: {
                state->ops[state->ops_n].opcode = SIMDJSON_FFI_OPCODE_BOOLEAN;
                state->ops[state->ops_n].size = bool(state->document);
                break;
            }

            case ondemand::json_type::null: {
                state->document.is_null();

                state->ops[state->ops_n].opcode = SIMDJSON_FFI_OPCODE_NULL;
                break;
            }

            default:
                SIMDJSON_UNREACHABLE();
            }

        } catch (simdjson_error &e) {
            *errmsg = e.what();

            return SIMDJSON_FFI_ERROR;
        }

        return ++state->ops_n;
    }

    int simdjson_ffi_next(simdjson_ffi_state *state, const char **errmsg) {
        try {
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
                            simdjson::ondemand::value value = *it;

                            if (simdjson_ffi_process_value(*state, value)) {
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

                        if (!frame.processing) {
                            state->frames.pop();

                            state->ops[state->ops_n++].opcode = SIMDJSON_FFI_OPCODE_RETURN;
                        }

                        break;
                    }

                    case simdjson_ffi_resume_state::object: {
                        // resume object iteration

                        if (frame.processing) {
                            ++frame.it.object.current;
                            frame.processing = false;
                        }

                        for (auto it = frame.it.object.current; it != frame.it.object.end; ++it) {
                            auto field = *it;
                            std::string_view key = field.unescaped_key();

                            state->ops[state->ops_n].opcode = SIMDJSON_FFI_OPCODE_STRING;
                            state->ops[state->ops_n].str = key.data();
                            state->ops[state->ops_n++].size = key.size();

                            // this can not overflow, because we checked to make sure
                            // ops has at least 2 empty slots above

                            if (simdjson_ffi_process_value(*state, field.value())) {
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

                        if (!frame.processing) {
                            state->frames.pop();

                            state->ops[state->ops_n++].opcode = SIMDJSON_FFI_OPCODE_RETURN;
                        }

                        break;
                    }

                    default:
                        SIMDJSON_UNREACHABLE();
                }
            }

        } catch (simdjson_error &e) {
            *errmsg = e.what();

            return SIMDJSON_FFI_ERROR;
        }

        // we are done! clean up the tmp string to save memory
        state->json = simdjson::padded_string();

        return state->ops_n;
    }
}
