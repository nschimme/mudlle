/*
 * Copyright (c) 2026 Nils Schimmelmann
 * All rights reserved.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose, without fee, and without written agreement is hereby granted,
 * provided that the above copyright notice and the following two paragraphs
 * appear in all copies of this software.
 *
 * IN NO EVENT SHALL NILS SCHIMMELMANN BE LIABLE TO ANY PARTY FOR DIRECT,
 * INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE
 * USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF NILS SCHIMMELMANN HAS
 * BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * NILS SCHIMMELMANN SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 * PARTICULAR PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS"
 * BASIS, AND NILS SCHIMMELMANN HAS NO OBLIGATION TO PROVIDE MAINTENANCE,
 * SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.
 */

/* Runtime interface shared by LLVM-generated code and the loader. */
#ifndef RUNTIME_LLVM_H
#define RUNTIME_LLVM_H

#include <stdint.h>
#include "../alloc.h"

#ifndef LLVM_HELPER
#  if defined(__GNUC__) || defined(__clang__)
#    define LLVM_HELPER __attribute__((visibility("hidden")))
#  else
#    define LLVM_HELPER
#  endif
#endif

LLVM_HELPER void llvm_init(void);
LLVM_HELPER void llvm_raise_error(int64_t error_code, int64_t argument);
LLVM_HELPER void llvm_loop_check(void);
LLVM_HELPER void llvm_loop_slow_path(void);
LLVM_HELPER void llvm_check_type(int64_t value, int64_t type);
LLVM_HELPER void llvm_check_integer_pair(int64_t first, int64_t second);
LLVM_HELPER void llvm_check_typeset(int64_t value, int64_t typeset, int64_t argnum);
LLVM_HELPER void llvm_check_mutable(int64_t value);
LLVM_HELPER int32_t llvm_type_matches(int64_t value, int64_t type);
LLVM_HELPER int64_t llvm_object_length(int64_t value, int64_t is_string);
LLVM_HELPER int32_t llvm_predicate(int64_t value, int64_t predicate);
LLVM_HELPER bool llvm_stable_closure(value fn);
LLVM_HELPER int32_t llvm_vector_find(int64_t needle, int64_t haystack);
LLVM_HELPER int64_t llvm_pair_car(int64_t pair);
LLVM_HELPER int64_t llvm_pair_cdr(int64_t pair);
LLVM_HELPER int32_t llvm_equal(int64_t lhs, int64_t rhs);
LLVM_HELPER value llvm_build_vector(value *arguments, int64_t nargs, int64_t readonly,
                                    int64_t immutable);
LLVM_HELPER value llvm_concat_strings(value *arguments, int64_t nargs);
LLVM_HELPER void llvm_check_arity(int64_t nargs, int64_t minimum, int64_t maximum);
LLVM_HELPER int64_t llvm_argument_get(value *arguments, int64_t nargs, int64_t index);
LLVM_HELPER int64_t llvm_make_varargs(value *arguments, int64_t nargs, int64_t start);
LLVM_HELPER value llvm_global_read(int64_t offset);
LLVM_HELPER void llvm_check_global_read(int64_t offset);
LLVM_HELPER void llvm_global_write(int64_t offset, int64_t value);
LLVM_HELPER void llvm_check_global_write(int64_t offset, int64_t value);
LLVM_HELPER struct gcpro *llvm_gc_roots_enter(value **slots, int64_t nslots,
                                              struct gcpro *roots);
LLVM_HELPER void llvm_gc_roots_leave(struct gcpro *old_gcpro);
LLVM_HELPER value llvm_call_value(value caller, value function, value *arguments,
                                  size_t nargs, int64_t secure_call);
LLVM_HELPER value llvm_call_global_constant(int64_t offset, value caller,
                                          value *arguments, int64_t nargs);
LLVM_HELPER int64_t llvm_call_global(int64_t caller, int64_t name, value *arguments,
                                     int64_t nargs);
LLVM_HELPER int64_t llvm_variable_new(int64_t value);
LLVM_HELPER int64_t llvm_variable_get(int64_t variable);
LLVM_HELPER void llvm_variable_set(int64_t variable, int64_t value);
LLVM_HELPER value llvm_make_function_closure(int64_t address, int64_t nargs,
                                             value *captures, int64_t ncaptures,
                                             int64_t self_capture, int64_t parent_env,
                                             int64_t arguments, int64_t return_typeset);
LLVM_HELPER value llvm_constant_get(int64_t menv, int64_t index);
LLVM_HELPER value llvm_closure_capture_get(int64_t menv, int64_t index);
LLVM_HELPER void llvm_closure_capture_set(int64_t menv, int64_t index, int64_t value);

#endif
