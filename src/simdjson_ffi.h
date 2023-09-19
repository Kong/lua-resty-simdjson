#ifndef SIMDJSON_FFI_H
#define SIMDJSON_FFI_H


#include <stack>
#include <limits>


#define SIMDJSON_FFI_BATCH_SIZE 2048
#define SIMDJSON_FFI_ERROR      -1


extern "C" {
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
}


static_assert(sizeof(uintptr_t) == 8,
              "uintptr_t should be 8 bytes");

// We assume this enum takes 4 bytes,
// so we could utilize the alignment rules to save 4 bytes for `simdjson_ffi_op_t`.
static_assert(sizeof(simdjson_ffi_opcode_e) <= 4,
              "simdjson_ffi_opcode_e should be less than 4 bytes");

// This struct was designed carefully for minimal memory usage,
// asserting it here to avoid breaking this design unintentionally.
static_assert(sizeof(simdjson_ffi_op_t) == 16,
              "simdjson_ffi_op_t should be 16 bytes");

// If the `SIMDJSON_FFI_BATCH_SIZE` is larger than 2^32,
// we might get a float number in LuaJIT.
// The design goal of this library doesn't need such a large batch,
// so this assertion is just in case.
static_assert(SIMDJSON_FFI_BATCH_SIZE <= std::numeric_limits<uint32_t>::max(),
              "SIMDJSON_FFI_BATCH_SIZE should be less than 2^32");


enum class simdjson_ffi_resume_state : unsigned char {
    array,
    object
};


struct simdjson_ffi_stack_frame {
    simdjson_ffi_resume_state       state;
    bool                            processing = false;

    union it {
        template<typename Iter>
        struct range {
            Iter current;
            Iter end;

            range(Iter current, Iter end) : current(current), end(end) {}
        };

        range<simdjson::ondemand::array_iterator>  array;
        range<simdjson::ondemand::object_iterator> object;

        it(simdjson::ondemand::array &v): array(v.begin(), v.end()) {}
        it(simdjson::ondemand::object &v): object(v.begin(), v.end()) {}
    } it;

    simdjson_ffi_stack_frame(simdjson::ondemand::array &v):
        state(simdjson_ffi_resume_state::array), it(v) {}

    simdjson_ffi_stack_frame(simdjson::ondemand::object &v):
        state(simdjson_ffi_resume_state::object), it(v) {}
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


#endif /* !SIMDJSON_FFI_H */
