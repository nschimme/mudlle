/*
 * Copyright (c) 1993-2012 David Gay and Gustav Hållberg
 * All rights reserved.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose, without fee, and without written agreement is hereby granted,
 * provided that the above copyright notice and the following two paragraphs
 * appear in all copies of this software.
 *
 * IN NO EVENT SHALL DAVID GAY OR GUSTAV HALLBERG BE LIABLE TO ANY PARTY FOR
 * DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT
 * OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF DAVID GAY OR
 * GUSTAV HALLBERG HAVE BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * DAVID GAY AND GUSTAV HALLBERG SPECIFICALLY DISCLAIM ANY WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
 * FITNESS FOR A PARTICULAR PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS ON AN
 * "AS IS" BASIS, AND DAVID GAY AND GUSTAV HALLBERG HAVE NO OBLIGATION TO
 * PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.
 */

#ifndef ERROR_H
#define ERROR_H

#include "types.h"

enum runtime_error {
/* end mudlle const */
  error_none = -1,
/* start mudlle const */
  error_bad_function,
  error_stack_underflow,
  error_bad_type,
  error_divide_by_zero,
  error_bad_index,
  error_bad_value,
  error_variable_read_only,
  error_loop,
  error_recurse,
  error_wrong_parameters,
  error_security_violation,
  error_value_read_only,
  error_user_interrupt,
  error_no_match,
  error_compile,
  error_abort,
  last_runtime_error
};

/* end mudlle const */
enum mudlle_signal {
  SIGNAL_NONE,
  SIGNAL_ERROR,
  SIGNAL_LONGJMP
};

extern const char *const mudlle_errors[];
extern int suppress_extra_calltrace;

#define __ERRFN noreturn __attribute__((cold)) void

__ERRFN interpreted_early_runtime_error(
  enum runtime_error error, const char *msg);
/* Effects: Runtime error 'error' has occured. Dump the call_stack to
     mudout & throw back to the exception handler with SIGNAL_ERROR
     and the error code in exception_error.
     Call this function instead of runtime_error if the arguments of the
     function at the top of call_stack are still on the stack.
   Note: Never returns
*/
__ERRFN compiled_early_runtime_error(enum runtime_error error, int nargs);
/* As above, but there are nargs arguments on the native stack. */

__ERRFN runtime_error_message(enum runtime_error error, const char *msg);
__ERRFN runtime_error_message_hide_tos(
  enum runtime_error error, const char *msg, const struct prim_op *hide_tos);
__ERRFN runtime_error(enum runtime_error error);
/* Effects: Runtime error 'error' has occured in a primitive operation.
     Dump the call_stack (plus the primitive operation call) to
     mudout & throw back to the exception handler with SIGNAL_ERROR
     and the error code in exception_error.
*/

void runtime_warning(const char *msg, const struct prim_op *hide_tos)
  __attribute__((cold));

/* these functions all return a pointer to a string that can be used in mudlle
   runtime error messages */
const char *fmt_error_message(const char *fmt, ...) FMT_PRINTF(1, 2);
const char *bad_nargs_message(unsigned nargs, unsigned min, unsigned max);
const char *out_of_range_message(long v, long minval, long maxval);
const char *not_callable_message(long nargs);
const char *bad_typeset_message(value v, typeset_t expected);
const char *bad_type_message(value v, enum mudlle_type expected);
const char *errno_message(int eno, const char *prefix);
const char *bad_value_message(value v, const char *prefix, const char *suffix);

/* adds "when returning" to 'head' and returns the new string */
const char *message_when_returning(const char *head);

/* Using these functions with a vararg prim_op and an argument vector, use
   nargs = NARGSPLUS(<N>) and pass the argument vector last.
   'argnum' should be -1 or a zero-based argument number */
__ERRFN primitive_runtime_error(
  enum runtime_error error, const struct prim_op *op, int nargs, ...);
__ERRFN primitive_runtime_error_msg(
  enum runtime_error error, const char *msg, const struct prim_op *op,
  int argnum, int nargs, ...);
__ERRFN primitive_bad_typeset_error(
  value v, typeset_t expected, const struct prim_op *op,
  int argnum, int nargs, ...);
__ERRFN primitive_bad_type_error(
  value v, enum mudlle_type expected, const struct prim_op *op,
  int nargs, ...);

void primitive_runtime_warning(
  const char *msg, const struct prim_op *op, int nargs, ...);

__ERRFN bad_call_error(
  enum runtime_error error, value callee, int nargs, value *argp);
__ERRFN bad_call_error_1plus(
  enum runtime_error error, const char *errmsg, value callee,
  value arg, struct vector *argv);
__ERRFN bad_type_error(value v, enum mudlle_type expected, int argnum);
__ERRFN bad_typeset_error(value v, typeset_t expected, int argnum);
__ERRFN out_of_range_error(long v, long minval, long maxval);
__ERRFN no_match_error(value v);
__ERRFN bad_vector_len_error(value v, size_t vlen);

#undef __ERRFN

typedef void (*call_trace_callback_fn)(value dst, void *cbdata);

void remove_call_trace(value dst);
void add_call_trace(value dst, bool unhandled_only, bool use_markup,
                    call_trace_callback_fn callback, void *cbdata);

struct c_call_trace_entry {
  enum { ct_mudlle, ct_prim, ct_string } class;
  union {
    value mudlle;
    const struct prim_op *primop;
    const char *string;
    void *ptr;
  } u;
};

static inline bool c_call_trace_entries_equal(
  const struct c_call_trace_entry *a,
  const struct c_call_trace_entry *b)
{
  return a->u.ptr == b->u.ptr;
}

struct c_call_trace {
  size_t used, size;
  struct c_call_trace_entry *data;
};

struct call_stack_c_header;
void get_c_call_trace(struct c_call_trace *dst,
                      struct call_stack_c_header *limit);

struct vector *get_mudlle_call_trace(size_t maxdepth, bool lines);

#endif /* ERROR_H */
