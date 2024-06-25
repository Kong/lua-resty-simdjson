/*
 * Copyright 2023 Datong Sun (dndx@idndx.com)
 * Dual licensed under the MIT License and Apache License Version 2.0
 * See LICENSE-MIT and LICENSE-APACHE for more information
 */

#ifndef SIMDJSON_FFI_H
#define SIMDJSON_FFI_H

#include <stack>


#define SIMDJSON_FFI_BATCH_SIZE 2048
#define SIMDJSON_FFI_ERROR      -1


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
    const char                *str;
    uint32_t                   size;
    double                     number;
} simdjson_ffi_op_t;


enum class simdjson_ffi_resume_state {
    array,
    object
};


struct simdjson_ffi_stack_frame {
    simdjson_ffi_resume_state       state;
    bool                            processing;

    union it {
        struct array {

            simdjson::ondemand::array_iterator current;
            simdjson::ondemand::array_iterator end;

            array(simdjson::ondemand::array_iterator current, simdjson::ondemand::array_iterator end): current(current), end(end) {}
        } array;

        struct object {

            simdjson::ondemand::object_iterator current;
            simdjson::ondemand::object_iterator end;

            object(simdjson::ondemand::object_iterator current, simdjson::ondemand::object_iterator end): current(current), end(end) {}
        } object;

        it(simdjson::ondemand::array_iterator current, simdjson::ondemand::array_iterator end): array(current, end) {}
        it(simdjson::ondemand::object_iterator current, simdjson::ondemand::object_iterator end): object(current, end) {}
    } it;

    simdjson_ffi_stack_frame(simdjson_ffi_resume_state state, simdjson::ondemand::array_iterator current, simdjson::ondemand::array_iterator end): state(state), processing(false), it(current, end) {}

    simdjson_ffi_stack_frame(simdjson_ffi_resume_state state, simdjson::ondemand::object_iterator current, simdjson::ondemand::object_iterator end): state(state), processing(false), it(current, end) {}
};


struct simdjson_ffi_state_t {
    simdjson::ondemand::parser            parser;
    simdjson::ondemand::document          document;
    simdjson_ffi_op_t                     ops[SIMDJSON_FFI_BATCH_SIZE];
    size_t                                ops_n;
    std::stack<simdjson_ffi_stack_frame>  frames;
    simdjson::padded_string               json;
};


typedef struct simdjson_ffi_state_t simdjson_ffi_state;


extern "C" {
    simdjson_ffi_state *simdjson_ffi_state_new();
    simdjson_ffi_op_t *simdjson_ffi_state_get_ops(simdjson_ffi_state *state);
    void simdjson_ffi_state_free(simdjson_ffi_state *state);
    int simdjson_ffi_parse(simdjson_ffi_state *state, const char *json, size_t len, const char **errmsg);
    int simdjson_ffi_next(simdjson_ffi_state *state, const char **errmsg);
}


#endif /* !SIMDJSON_FFI_H */
