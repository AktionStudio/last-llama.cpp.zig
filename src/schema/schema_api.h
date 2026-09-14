#ifndef LAB_SCHEMA_API_H
#define LAB_SCHEMA_API_H
#include <stddef.h>
#include <stdint.h>
#ifdef _WIN32
#ifdef LAB_SCHEMA_EXPORTS
#define LAB_SCHEMA_API __declspec(dllexport)
#else
#define LAB_SCHEMA_API __declspec(dllimport)
#endif
#else
#define LAB_SCHEMA_API
#endif
#ifdef __cplusplus
extern "C" {
#endif
// Caller initializes both fields to zero. One successful compile owns exactly one
// result allocation. Clear it before reuse; clear is safe on an already empty result.
typedef struct lab_schema_result { char * data; size_t size; } lab_schema_result;
enum lab_schema_status { LAB_SCHEMA_OK=0, LAB_SCHEMA_INVALID_ARGUMENT=1,
    LAB_SCHEMA_UNSUPPORTED=2, LAB_SCHEMA_INVALID_JSON=3, LAB_SCHEMA_CONVERSION_FAILED=4,
    LAB_SCHEMA_OUT_OF_MEMORY=5 };
LAB_SCHEMA_API int lab_schema_compile(const uint8_t * input, size_t input_size,
    lab_schema_result * result, char * error, size_t error_capacity);
LAB_SCHEMA_API void lab_schema_result_clear(lab_schema_result * result);
#ifdef __cplusplus
}
#endif
#endif
