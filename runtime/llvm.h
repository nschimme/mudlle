/* Runtime interface shared by LLVM-generated code and the loader. */
#ifndef RUNTIME_LLVM_H
#define RUNTIME_LLVM_H

#include <stdint.h>
#include "../alloc.h"

value system_cmd(struct string *cmd);
void llvm_init(void);
void llvm_raise_error(int64_t error_code, int64_t argument);
void llvm_loop_check(void);
void llvm_check_type(int64_t value, int64_t type);
void llvm_check_typeset(int64_t value, int64_t typeset, int64_t argnum);
void llvm_check_mutable(int64_t value);
int32_t llvm_type_matches(int64_t value, int64_t type);
int64_t llvm_object_length(int64_t value, int64_t is_string);
int32_t llvm_predicate(int64_t value, int64_t predicate);
int32_t llvm_vector_find(int64_t needle, int64_t haystack);
int64_t llvm_pair_car(int64_t pair);
int64_t llvm_pair_cdr(int64_t pair);
int32_t llvm_equal(int64_t lhs, int64_t rhs);
value llvm_build_vector(value *arguments, int64_t nargs, int64_t readonly,
                        int64_t immutable);
value llvm_concat_strings(value *arguments, int64_t nargs);
void llvm_check_arity(int64_t nargs, int64_t minimum, int64_t maximum);
int64_t llvm_argument_get(value *arguments, int64_t nargs, int64_t index);
int64_t llvm_make_varargs(value *arguments, int64_t nargs, int64_t start);
value llvm_global_read(int64_t offset);
void llvm_global_write(int64_t offset, int64_t value);
struct gcpro *llvm_gc_roots_enter(value **slots, int64_t nslots,
                                  struct gcpro *roots);
void llvm_gc_roots_leave(struct gcpro *old_gcpro);
value llvm_call_value(value function, value *arguments, size_t nargs,
                      int64_t secure_call);
int64_t llvm_call_global(int64_t name, value *arguments, int64_t nargs);
int64_t llvm_variable_new(int64_t value);
int64_t llvm_variable_get(int64_t variable);
void llvm_variable_set(int64_t variable, int64_t value);
value llvm_make_function_closure(int64_t address, int64_t nargs,
                                 value *captures, int64_t ncaptures,
                                 int64_t self_capture, int64_t parent_env);
value llvm_constant_get(int64_t menv, int64_t index);
value llvm_closure_capture_get(int64_t menv, int64_t index);
void llvm_closure_capture_set(int64_t menv, int64_t index, int64_t value);

#endif
