#include "simdjson.h"
#include "simdjson_ffi.h"
#include <iostream>
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

    case ondemand::json_type::number:
        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_NUMBER;
        state.ops[state.ops_n++].number = double(value);
        return false;

    case ondemand::json_type::string: {
        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_STRING;
        std::string_view str = value;

        state.ops[state.ops_n].str = str.data();
        state.ops[state.ops_n++].size = str.size();
        return false;
    }

    case ondemand::json_type::boolean:
        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_BOOLEAN;
        state.ops[state.ops_n++].size = bool(value);
        return false;

    case ondemand::json_type::null:
        value.is_null();

        state.ops[state.ops_n++].opcode = SIMDJSON_FFI_OPCODE_NULL;
        return false;

    default:
        __builtin_unreachable();
    }
}

extern "C" {
    void *simdjson_ffi_state_new() {
        return reinterpret_cast<void *>(new simdjson_ffi_state());
    }

    simdjson_ffi_op_t *simdjson_ffi_state_get_ops(void *state) {
        return reinterpret_cast<simdjson_ffi_state *>(state)->ops;
    }

    void simdjson_ffi_state_free(void *state) {
        delete reinterpret_cast<simdjson_ffi_state *>(state);
    }


    int simdjson_ffi_parse(void *state, const char *json, size_t len, size_t capacity) {
        simdjson_ffi_state *s = reinterpret_cast<simdjson_ffi_state *>(state);
        s->document = s->parser.iterate(json, len, capacity);
        s->ops_n = 0;

        switch (s->document.type()) {
        case ondemand::json_type::array: {
            simdjson::ondemand::array a = s->document;
            s->frames.emplace(simdjson_ffi_resume_state::array, a.begin(), a.end());

            s->ops[s->ops_n].opcode = SIMDJSON_FFI_OPCODE_ARRAY;

            break;
        }

        case ondemand::json_type::object: {
            simdjson::ondemand::object o = s->document;
            s->frames.emplace(simdjson_ffi_resume_state::object, o.begin(), o.end());

            s->ops[s->ops_n].opcode = SIMDJSON_FFI_OPCODE_OBJECT;

            break;
        }

        case ondemand::json_type::number:
            s->ops[s->ops_n].opcode = SIMDJSON_FFI_OPCODE_NUMBER;
            s->ops[s->ops_n].number = double(s->document);
            break;

        case ondemand::json_type::string: {
            s->ops[s->ops_n].opcode = SIMDJSON_FFI_OPCODE_STRING;
            std::string_view str = s->document;

            s->ops[s->ops_n].str = str.data();
            s->ops[s->ops_n].size = str.size();
            break;
        }

        case ondemand::json_type::boolean:
            s->ops[s->ops_n].opcode = SIMDJSON_FFI_OPCODE_BOOLEAN;
            s->ops[s->ops_n].size = bool(s->document);
            break;

        case ondemand::json_type::null:
            s->document.is_null();

            s->ops[s->ops_n].opcode = SIMDJSON_FFI_OPCODE_NULL;
            break;

        default:
            __builtin_unreachable();
        }

        return ++s->ops_n;
    }

    int simdjson_ffi_next(void *state) {
        simdjson_ffi_state *s = reinterpret_cast<simdjson_ffi_state *>(state);
        s->ops_n = 0;

        while (!s->frames.empty()) {

            if (s->ops_n >= SIMDJSON_FFI_BATCH_SIZE - 1) {
                // -1 for key value pair which requires 2 ops
                return s->ops_n;
            }

            auto &frame = s->frames.top();

            switch (frame.state) {
                case simdjson_ffi_resume_state::array:
                    if (frame.processing) {
                        ++frame.it.array.current;
                        frame.processing = false;
                    }

                    // resume array iteration
                    for (auto it = frame.it.array.current; it != frame.it.array.end; ++it) {
                        simdjson::ondemand::value value = *it;

                        if (simdjson_ffi_process_value(*s, value)) {
                            // save state, go deeper
                            frame.it.array.current = it;
                            frame.processing = true;

                            break;
                        }

                        if (s->ops_n >= SIMDJSON_FFI_BATCH_SIZE) {
                            // array can use the last of the slots, no need to
                            // reserve two slots like object below
                            frame.it.array.current = it;
                            frame.processing = true;

                            return s->ops_n;
                        }
                    }

                    if (!frame.processing) {
                        s->frames.pop();

                        s->ops[s->ops_n++].opcode = SIMDJSON_FFI_OPCODE_RETURN;
                    }

                    break;

                case simdjson_ffi_resume_state::object:
                    // resume object iteration

                    if (frame.processing) {
                        ++frame.it.object.current;
                        frame.processing = false;
                    }

                    for (auto it = frame.it.object.current; it != frame.it.object.end; ++it) {
                        auto field = *it;
                        std::string_view key = field.unescaped_key();

                        s->ops[s->ops_n].opcode = SIMDJSON_FFI_OPCODE_STRING;
                        s->ops[s->ops_n].str = key.data();
                        s->ops[s->ops_n++].size = key.size();

                        // this can not overflow, because we checked to make sure
                        // ops has at least 2 empty slots above

                        if (simdjson_ffi_process_value(*s, field.value())) {
                            // save state, go deeper
                            frame.it.object.current = it;
                            frame.processing = true;

                            break;
                        }

                        if (s->ops_n >= SIMDJSON_FFI_BATCH_SIZE - 1) {
                            frame.it.object.current = it;
                            frame.processing = true;

                            return s->ops_n;
                        }
                    }

                    if (!frame.processing) {
                        s->frames.pop();

                        s->ops[s->ops_n++].opcode = SIMDJSON_FFI_OPCODE_RETURN;
                    }

                    break;

                default:
                    __builtin_unreachable();
            }
        }

        return s->ops_n;
    }
}
