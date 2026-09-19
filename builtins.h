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

#ifndef BUILTINS_H
#define BUILTINS_H

#include <stdint.h>

#include "mudlle-macro.h"

/* machine code primitives */

void interpreter_invoke(void);
/* Enter the interpreter from a machine code function */

/* Compiler support builtins (machine specific) */
#define BUILTINS_FOREACH(v, sep)                \
  v(badd)                          sep()        \
  v(balloc_closure)                sep()        \
  v(balloc_variable)               sep()        \
  v(balloc_vector)                 sep()        \
  v(bapply_varargs)                sep()        \
  v(bbitref)                       sep()        \
  v(bcall)                         sep()        \
  v(bcall_prim)                    sep()        \
  v(bcall_prim_noalloc)            sep()        \
  v(bcall_secure)                  sep()        \
  v(bcall_varargs)                 sep()        \
  v(bcheck_xcount)                 sep()        \
  v(bcleargc)                      sep()        \
  v(bcleargc0)                     sep()        \
  v(bcleargc1)                     sep()        \
  v(bcleargc2)                     sep()        \
  v(bcleargc3)                     sep()        \
  v(bcleargc4)                     sep()        \
  v(bconcat)                       sep()        \
  v(bcons)                         sep()        \
  v(bdivide)                       sep()        \
  v(bearly_error_wrong_parameters) sep()        \
  v(berror_abort)                  sep()        \
  v(berror_bad_function)           sep()        \
  v(berror_bad_index)              sep()        \
  v(berror_bad_type)               sep()        \
  v(berror_bad_value)              sep()        \
  v(berror_compile)                sep()        \
  v(berror_divide_by_zero)         sep()        \
  v(berror_loop)                   sep()        \
  v(berror_no_match)               sep()        \
  v(berror_recurse)                sep()        \
  v(berror_security_violation)     sep()        \
  v(berror_stack_underflow)        sep()        \
  v(berror_user_interrupt)         sep()        \
  v(berror_value_read_only)        sep()        \
  v(berror_variable_read_only)     sep()        \
  v(berror_wrong_parameters)       sep()        \
  v(bmultiply)                     sep()        \
  v(bno_match_error)               sep()        \
  v(bpcons)                        sep()        \
  v(bref)                          sep()        \
  v(bref_end)                      sep()        \
  v(bremainder)                    sep()        \
  v(brglobal)                      sep()        \
  v(bset)                          sep()        \
  v(bshift_left)                   sep()        \
  v(bshift_right)                  sep()        \
  v(bsref)                         sep()        \
  v(btype_error)                   sep()        \
  v(bvarargs)                      sep()        \
  v(bvcopy)                        sep()        \
  v(bvector_bitor)                 sep()        \
  v(bvequalp)                      sep()        \
  v(bvfindp)                       sep()        \
  v(bvref)                         sep()        \
  v(bwglobal)

#define DECL_PROTO(name) extern void name()
BUILTINS_FOREACH(DECL_PROTO, SEP_SEMI);
#undef DECL_PROTO

/* these aren't accessible via builtin_find() */
extern void bcall_primitive_tail();
extern void builtin_start(), builtin_end(), bref_end(), bset_end();

extern const uint8_t valid_segvs[];

#endif  /* BUILTINS_H */
