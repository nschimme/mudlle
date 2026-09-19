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

#ifndef CODE_H
#define CODE_H

#include "env.h"

/* Definition of generated code */

/* A bytecode style representation is used:
   Code to be interpreted is an array of bytes.
   Each instruction is stored in 1 byte, followed by an optional 1 or 2 byte
   argument.

   arg0 means no argument.
   arg1 means a byte argument.
   arg2 means a 2 byte argument (big-endian format). */

#define DEF_VCLASS_OP(prefix, name)				\
  op_ ## prefix ## _ ## name = op_ ## prefix + vclass_ ## name
#define VCLASS_OPS(prefix) op_ ## prefix, FOR_VCLASS(DEF_VCLASS_OP, prefix)

union typecheck_arg {
  struct {
    bool is_arg : 1;
    uint8_t argnum : 7;
  } s;
  uint8_t u;
};
CASSERT_SIZEOF(union typecheck_arg, 1);

enum operator {
  /* Simple operations */
  op_return,			/* arg0 */
  op_null,			/* arg0 */
  op_constant1,			/* arg1 is offset in code's constants */
  op_constant2,			/* arg2 is offset in code's constants */
  op_integer1,			/* arg1 is signed integer */
  op_integer2,			/* arg2 is signed integer */
  op_closure,			/* arg1 is # of closure variables */
  op_closure_code1,		/* arg1 is code's offset in constants */
  op_closure_code2,		/* arg2 is code's offset in constants */
  op_execute,			/* arg1 is # of parameters passed */
  op_execute2,                  /* arg2 is # of parameters passed */
  op_execute_secure,		/* arg1 is # of parameters passed */
  op_execute_secure2,           /* arg2 is # of parameters passed */
  op_execute_varargs,		/* arg1 is # of parameters passed */
  op_execute_varargs2,          /* arg2 is # of parameters passed */
  op_execute_primitive,		/* arg1 is # of parameters passed */
  op_execute_primitive2,        /* arg2 is # of parameters passed */
  op_execute_primitive_1arg,	/* arg2 is global offset */
  op_execute_primitive_2arg,	/* arg2 is global offset */
  op_execute_global_1arg,       /* arg2 is global offset */
  op_execute_global_2arg,       /* arg2 is global offset */
  op_args_fixed,                /* arg1 is # of parameters expected */
  op_args_range,                /* arg0; stack holds min/max # arguments */
  op_args_vararg,               /* arg0; stack holds min/optional #
                                   arguments */
  op_pop_args,			/* arg0. Pop function args off stack */
  op_discard,			/* arg0. Pop top of stack (discard result) */
  op_exit_discard_n,		/* arg1. Pop n entries */
  op_exit_n,			/* arg1. Pop top of stack, pop n
                                   entries, push old top of stack */
  /* All branch instructions must be consecutive, with the 1 byte version
     immediately preceding the 2 byte one.
     op_branch1 must be the first branch */
  op_branch1,			/* arg1 is signed offset from next instr */
  op_branch2,			/* arg2 is signed offset from next instr */
  op_loop1,			/* arg1 is signed offset from next instr */
  op_loop2,			/* arg2 is signed offset from next instr */
  op_branch_nz1,		/* arg1 is signed offset from next instr */
  op_branch_nz2,		/* arg2 is signed offset from next instr */
  op_branch_z1,			/* arg1 is signed offset from next instr */
  op_branch_z2,			/* arg2 is signed offset from next instr */

  op_clear_local,		/* arg1 is # of local var to set to null */
  /* variable operations, which come in vclass_local, vclass_closure,
     vclass_global flavours, and take an arg1 (local, closure) or arg2
     (global) indicating the offset in the corresponding variable
     list */
  VCLASS_OPS(recall),
  VCLASS_OPS(assign),

  VCLASS_OPS(closure_var),  /* n.b., closure_var have no globals */

  op_define,
  op_c_callback,             /* calls arg1's mcallback with arg2 as argument */

  /* Builtin operations (very common) */
  op_builtin_eq,
  op_builtin_neq,
  op_builtin_gt,
  op_builtin_lt,
  op_builtin_le,
  op_builtin_ge,
  op_builtin_ref,
  op_builtin_set,
  op_builtin_add,
  op_builtin_sub,
  op_builtin_bitand,
  op_builtin_bitor,
  op_builtin_bitnot,
  op_builtin_not,
  op_builtin_car,
  op_builtin_cdr,

  /* arg1 (a union typecheck_arg) is stack offset. Pop top of stack (an
     integer) and make sure variable indicated by arg1 is of a type therein. */
  op_typeset_check,

  /* typecheck i: op_typecheck + i. arg1 (a union typecheck_arg) is the stack
     offset. */
  op_typecheck,

#define DEF_TYPECHECK_OP(name) op_typecheck_ ## name = op_typecheck + name
  FOR_MUDLLE_TYPES(DEF_TYPECHECK_OP, SEP_COMMA)
#undef DEF_TYPECHECK_OP
};

#endif
