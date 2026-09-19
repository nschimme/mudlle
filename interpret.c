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

#include "mudlle-config.h"

#include "global.h"
#include "ins.h"
#include "interpret.h"
#include "profile.h"
#include "stack.h"

#include "runtime/arith.h"
#include "runtime/basic.h"
#include "runtime/list.h"
#include "runtime/mudlle-string.h"
#include "runtime/runtime.h"
#include "runtime/vector.h"

/* As good a place as any other */
extern const char COPYRIGHT[];
const char COPYRIGHT[] = "\
Copyright (c) 1993-2012 David Gay and Gustav H\xe5llberg\n\
All rights reserved.\n\
\n\
Permission to use, copy, modify, and distribute this software for any\n\
purpose, without fee, and without written agreement is hereby granted,\n\
provided that the above copyright notice and the following two paragraphs\n\
appear in all copies of this software.\n\
\n\
IN NO EVENT SHALL DAVID GAY OR GUSTAV HALLBERG BE LIABLE TO ANY PARTY FOR\n\
DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT\n\
OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF DAVID GAY OR\n\
GUSTAV HALLBERG HAVE BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.\n\
\n\
DAVID GAY AND GUSTAV HALLBERG SPECIFICALLY DISCLAIM ANY WARRANTIES,\n\
INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND\n\
FITNESS FOR A PARTICULAR PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS ON AN\n\
\"AS IS\" BASIS, AND DAVID GAY AND GUSTAV HALLBERG HAVE NO OBLIGATION TO\n\
PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.\n\
";

static value invoke_stack(struct closure *c, int nargs);

struct primop_header {
  struct call_stack_c_header c;
  value args[MAX_C_ARGS];
};

static noreturn void cearly_error(struct primop_header *primop,
                                  enum runtime_error error, const char *msg);

/* Macros for fast access to the GC'ed stack & code structures.
   RESTORE_INS & RESTORE_STACK must be called after anything that may
   have caused a GC
*/

struct stack_cache {
  value *used;                  /* cached address of stack->used */
  value *pos;                   /* next stack slot to be pushed to */
};

#define RESTORE_STACK() do {                                            \
  stack_cache.used = &stack->used;                                      \
  stack_cache.pos = stack->values->data + intval(*stack_cache.used);    \
} while (0)

#define _FAST_POPN(n)                                           \
  (*stack_cache.used = mudlle_iadd(*stack_cache.used, -(n)),    \
   *(stack_cache.pos -= (n)))
#define FAST_POP() (_FAST_POPN(1))
#define FAST_POPN(n) do {                                       \
  ulong __n = (n);                                              \
  (void)_FAST_POPN(__n);                                        \
} while (0)
#define FAST_PUSH(v) do {                                       \
  *stack_cache.used = mudlle_iadd(*stack_cache.used, 1);        \
  *stack_cache.pos++ = (v);                                     \
} while (0)
#define FAST_GET(n)    (CASSERT_TYPE((n) | 0L, long),           \
                        stack_cache.pos[-((n) + 1)])
#define FAST_SET(n, v) (CASSERT_TYPE((n) | 0L, long),           \
                        stack_cache.pos[-((n) + 1)] = (v))

#define RESTORE_INS() ((void)(ins = (uint8_t *)me.code + ins_index))
#define INSUINT8()  (ins_index++, *ins++)
#define INSINT8()   ((int8_t)INSUINT8())
#define INSOPER()   ((enum operator)INSUINT8())
#define INSUINT16() (ins_index += 2, ins += 2, (ins[-2] << 8) | ins[-1])
#define INSINT16()  ((int16_t)INSUINT16())

#define SAVE_OFFSET() ((void)(me.offset = ins_index))

#define CONST(n) (me.code->constants[n])

#define IERROR(n) do {				\
  SAVE_OFFSET();				\
  runtime_error(n);				\
} while (0)

#define IERROR_TYPE(arg, type, argnum) do {     \
  SAVE_OFFSET();				\
  bad_type_error(arg, type, argnum);            \
} while (0)

/* Early error with the arguments still on the interpreter stack. */
#define IEARLY_ERROR(n, msg) do {               \
  SAVE_OFFSET();				\
  interpreted_early_runtime_error((n), (msg));  \
} while (0)

/* Use after C_START_CALL() has been called. */
#define CEARLY_ERROR(n, msg) do {               \
  SAVE_OFFSET();                                \
  cearly_error(&primop, (n), (msg));            \
} while (0)

static inline bool check_loop(void)
{
  maybe_profile_tick();
  return false;
}

void do_interpret(struct closure *fn, int my_nargs)
{
  uint8_t *ins;

  struct stack_cache stack_cache;

  if (check_loop()) runtime_error(error_loop);

  if (get_stack_pointer() < mudlle_stack_limit)
    runtime_error(error_recurse);

  if (my_nargs > MAX_FUNCTION_ARGS)
    runtime_error(error_wrong_parameters);

  check_interrupt();

  assert(TYPE(fn->code, icode));

  struct call_stack_mudlle me = {
    .s = {
      .next = call_stack,
      .type = call_bytecode
    },
    .fn     = fn,
    .code   = (struct icode *)fn->code,
    .locals = NULL,
    .nargs  = my_nargs,
    .offset = -1,
  };
  call_stack = &me.s;

#ifdef PROFILE_CALL_COUNT
  ++me.code->code.call_count;
#endif

  /* make local variables */
  if (me.code->nb_locals > 0)
    me.locals = allocate_locals(me.code->nb_locals);

#define LOCAL_VAR(n) ((struct variable *)me.locals->data[n])
#define LOCAL        LOCAL_VAR(INSUINT8())
#define CLOSURE      ((struct variable *)me.fn->variables[INSUINT8()])

  /* Pre-initialise call stack entry for calls to C primitives */
  struct primop_header primop;
  primop.c.s = (struct call_stack){
    .next = &me.s,
    .type = call_c
  };

  static ulong instruction_number;
  ulong start_ins = instruction_number;

  seclev_t seclev = me.code->code.seclevel;
  if (seclev < minlevel)
    interpreted_early_runtime_error(error_security_violation, NULL);

  seclev_t this_seclev = intval(seclevel_to_maxseclevel(seclev));
  seclev_t old_maxseclevel = c_maxseclevel();
  seclev_t old_trace_seclevel = trace_seclevel();
  if (this_seclev < old_maxseclevel)
    set_c_maxseclevel(this_seclev);
  if (this_seclev < old_trace_seclevel)
    set_trace_seclevel(this_seclev);

  stack_reserve(me.code->stkdepth); /* Ensure enough space on stack */
  RESTORE_STACK();

  /* Loop over instructions, executing each one */
  /* As code may move with gc, we can't have a pointer into it.
     So we base ourselves on code (which is protected) and pretend
     that is an array of instructions. */
  ulong ins_index = ((uint8_t *)(&me.code->constants[me.code->nb_constants])
                     - (uint8_t *)me.code);
  RESTORE_INS();

  int call_nargs;

  for (;;) {
    struct obj *called;
    const struct prim_op *op;
    value c_result;

    ++instruction_number;
    enum operator byteop = INSOPER();
    switch (byteop)
      {
      case op_return: goto done;

      case op_null:
	FAST_PUSH(NULL);
	break;
      case op_constant1:
	FAST_PUSH(CONST(INSUINT8()));
	GCCHECK(FAST_GET(0));
	break;
      case op_constant2:
        FAST_PUSH(CONST(INSUINT16()));
        GCCHECK(FAST_GET(0));
        break;
      case op_integer1:
	FAST_PUSH(makeint(INSINT8()));
	break;
      case op_integer2:
	FAST_PUSH(makeint(INSINT16()));
	break;

	/* Note: Semantics of closure, closure_code & vclass_closure could be
	   a bit different (simpler):
	     - closure creates an empty closure and pushes it on the stack
	     - vclass_closure & closure_code modify the closure at the top of
	       the stack.
	   This removes restrictions on the use of these instructions, but
	   makes the code a bit more complicated (and slower).
	   New restriction: No instructions but op_closure_var may appear
	   between op_closure and op_closure_code. The closure is in an
	   unsafe state for GC.
	   As the restrictions are not a problem for compile.c, the simpler
	   implementation is chosen. */
      case op_closure:
        {
	  struct closure *new_closure = alloc_closure_noinit(INSUINT8());
          /* No GC allowed after this point till op_closure_code is executed */
          RESTORE_STACK();
          RESTORE_INS();
          FAST_PUSH(new_closure);

          for (struct variable **next_var = new_closure->variables;;)
            {
              enum operator cop = INSOPER();
              if (cop == op_closure_var_local)
                {
                  *next_var++ = LOCAL;
                  continue;
                }
              if (cop == op_closure_var_closure)
                {
                  *next_var++ = CLOSURE;
                  continue;
                }

              if (cop == op_closure_code1)
                new_closure->code = CONST(INSUINT8());
              else if (cop == op_closure_code2)
                new_closure->code = CONST(INSUINT16());
              else
                abort();
              GCCHECK(new_closure->code);
              break;
            }
          break;
        }

#define C_ARG(n) primop.args[n]
#define C_SETARG(n, arg) do {                   \
        C_ARG(n) = arg;                         \
        GCCHECK(C_ARG(n));                      \
      } while (0)

#define C_START_CALL(n, pop) do {               \
          SAVE_OFFSET();                        \
          struct primitive *__pop = (pop);      \
          primop.c.u.prim = __pop;              \
          op = __pop->op;                       \
          primop.c.nargs = n;			\
          call_stack = &primop.c.s;             \
        } while (0)

#define C_END_CALL(result) do {                 \
          c_result = (result);                  \
          call_stack = &me.s;			\
          goto c_end_call;                      \
        } while (0)

      case op_execute_primitive_1arg:
	C_START_CALL(1, GVAR(INSUINT16()));
	C_SETARG(0, FAST_POP());
	set_seclevel(seclev);
	C_END_CALL(((op1_fn)op->op)(C_ARG(0)));

      c_end_call:
        RESTORE_STACK();
        RESTORE_INS();
        FAST_PUSH(c_result);
	break;

      case op_execute_primitive_2arg:
	C_START_CALL(2, GVAR(INSUINT16()));
	C_SETARG(0, FAST_POP());
	C_SETARG(1, FAST_POP());
	set_seclevel(seclev);
	C_END_CALL(((op2_fn)op->op)(C_ARG(0), C_ARG(1)));

      case op_execute_global_1arg:
	called = GVAR(INSUINT16());
	call_nargs = 1;
	goto execute_fn;
      case op_execute_global_2arg:
	called = GVAR(INSUINT16());
	call_nargs = 2;
	goto execute_fn;

      case op_execute2:
        call_nargs = INSUINT16();
        goto do_op_execute;
      case op_execute:
	call_nargs = INSUINT8();
      do_op_execute:
	called = FAST_POP();

      execute_fn:
	set_seclevel(DEFAULT_SECLEVEL);
	switch (TYPEOF(called))
	  {
	  case type_varargs:
            goto execute_vararg;

	  case type_secure:
	    C_START_CALL(call_nargs, (struct primitive *)called);
	    if (DEFAULT_SECLEVEL < op->seclevel
                || c_maxseclevel() < op->seclevel)
              CEARLY_ERROR(error_security_violation, NULL);
	    goto execute_primitive;

	  case type_primitive:
	    C_START_CALL(call_nargs, (struct primitive *)called);

	  execute_primitive:
	    if (call_nargs != op->nargs)
              CEARLY_ERROR(
                error_wrong_parameters,
                bad_nargs_message(call_nargs, op->nargs, op->nargs));

            for (int arg = 0; arg < call_nargs; ++arg)
              C_SETARG(arg, FAST_POP());

            {
              value result;
              switch (primop.c.nargs)
                {
                case 0:
                  result = ((op0_fn)op->op)();
                  break;

#define __CPRIMARG(N) C_ARG(DEC(N))
#define __CALL_PRIM(N)                                                  \
                  case N:                                               \
                    result = ((PRIMOPTYPE(N))op->op)(                   \
                      CONCATCOMMA(N, __CPRIMARG));                      \
                    break
                  DOPRIMARGS(__CALL_PRIM, SEP_SEMI);
#undef __CALL_PRIM
#undef __CPRIMARG
                default:
                  abort();
                }
              C_END_CALL(result);
            }

	  case type_closure:
	    {
	      struct closure *c = (struct closure *)called;

	      SAVE_OFFSET();
	      if (c->code->o.type == type_mcode)
		{
		  value result = invoke_stack(c, call_nargs);
		  RESTORE_STACK();
		  FAST_PUSH(result);
		}
	      else
		{
		  do_interpret(c, call_nargs);
		  RESTORE_STACK();
		}
	      RESTORE_INS();
	      break;
	    }
	  default:
            {
              SAVE_OFFSET();
              primop.c.s.type = call_invalid;
              primop.c.u.value = called;
              primop.c.nargs = call_nargs;
              call_stack = &primop.c.s;
              CEARLY_ERROR(error_bad_function, NULL);
            }
	  }
	break;

      case op_execute_secure2:
        call_nargs = INSUINT16();
        goto do_op_execute_secure;
      case op_execute_secure:
	call_nargs = INSUINT8();
      do_op_execute_secure:
	called = FAST_POP();

	/* Compiler only generates this for secure primitives in
	   protected modules (normally system) */
	assert(pointerp(called) && called->type == type_secure);

	C_START_CALL(call_nargs, (struct primitive *)called);
	set_seclevel(seclev);
	if (seclev < op->seclevel || c_maxseclevel() < op->seclevel)
	  CEARLY_ERROR(error_security_violation, NULL);
	goto execute_primitive;

      case op_execute_primitive2:
        call_nargs = INSUINT16();
        goto do_op_execute_primitive;
      case op_execute_primitive:
	call_nargs = INSUINT8();
      do_op_execute_primitive:
	called = FAST_POP();

	/* Compiler only generates this for primitives in
	   protected modules (normally system) */
	assert(pointerp(called) && called->type == type_primitive);

	C_START_CALL(call_nargs, (struct primitive *)called);
	goto execute_primitive;

      case op_execute_varargs2:
        call_nargs = INSUINT16();
        goto do_op_execute_varargs;
      case op_execute_varargs:
	{
          call_nargs = INSUINT8();
        do_op_execute_varargs:
	  called = FAST_POP();

	  /* Compiler only generates this for varargs primitives in
	     protected modules (normally system) */
	  assert(pointerp(called) && called->type == type_varargs);

	  set_seclevel(seclev);

        execute_vararg: ;
          struct primitive *pop = (struct primitive *)called;

          C_START_CALL(call_nargs, pop);

          int nfixed = varop_nfixed(op);
          if (nfixed > call_nargs)
            CEARLY_ERROR(error_wrong_parameters,
                         bad_nargs_message(call_nargs, nfixed, UINT_MAX));
          int nvec   = call_nargs - nfixed;

          primop.c.nargs = 0;   /* in case of GC */
          struct vector *argv = (nvec == 0
                                 ? empty_vector
                                 : ALLOC_RECORD_NOINIT(vector, nvec));
          RESTORE_STACK();

          for (int i = 0; i < nfixed; ++i)
            C_SETARG(i, FAST_POP());
          for (int i = 0; i < nvec; ++i)
            argv->data[i] = FAST_POP();
          C_SETARG(nfixed, argv);
          primop.c.nargs = nfixed + 1;

          value result = call_vararg(op, nfixed, primop.args, argv);
          C_END_CALL(result);
        }

      case op_c_callback:
        {
          struct mcallback *cb = FAST_POP();
          SAVE_OFFSET();
          c_result = call_mcallback(cb);
          goto c_end_call;
        }

      case op_args_fixed:       /* A CISCy instruction :-) */
        {
          uint8_t nfixed = INSUINT8();
          if (my_nargs != nfixed)
            IEARLY_ERROR(error_wrong_parameters,
                         bad_nargs_message(my_nargs, nfixed, nfixed));
          for (int i = 0; i < my_nargs; ++i)
            LOCAL_VAR(i)->vvalue = FAST_GET(i);
          break;
        }
      case op_args_range:       /* Another CISCy instruction... */
        {
          long maxargs = intval(FAST_POP());
          long minargs = intval(FAST_POP());
          assert(minargs >= 0);
          if (my_nargs < minargs || my_nargs > maxargs)
            IEARLY_ERROR(error_wrong_parameters,
                         bad_nargs_message(my_nargs, minargs, maxargs));
          for (int i = 0; i < my_nargs; ++i)
            LOCAL_VAR(i)->vvalue = FAST_GET(i);
          LOCAL_VAR(maxargs)->vvalue = makeint(my_nargs);
          break;
        }
      case op_args_vararg:      /* Another CISCy instruction... */
	{
          long optargs = intval(FAST_POP());
          long minargs = intval(FAST_POP());

          if (my_nargs < minargs)
            IEARLY_ERROR(error_wrong_parameters,
                         bad_nargs_message(my_nargs, minargs, UINT_MAX));

	  struct vector *args = empty_vector;
          int nvarargs = 0;
          int nregular = my_nargs;
          if (my_nargs > minargs + optargs)
            {
              nvarargs = my_nargs - minargs - optargs;
              nregular -= nvarargs;
              me.nargs = nregular + 1;

              args = ALLOC_RECORD_NOINIT(vector, nvarargs);
              RESTORE_STACK();
              RESTORE_INS();
              for (int i = 0; i < nvarargs; ++i)
                args->data[i] = FAST_GET(i + minargs + optargs);
            }

          LOCAL_VAR(minargs + optargs)->vvalue = args;
          LOCAL_VAR(minargs + optargs + 1)->vvalue = makeint(my_nargs);
          for (int i = 0; i < nregular; ++i)
            LOCAL_VAR(i)->vvalue = FAST_GET(i);
	  break;
	}
      case op_discard:
	FAST_POPN(1);
	break;
      case op_exit_n:
        {
          value result = FAST_POP();
          FAST_POPN(INSUINT8());
          FAST_PUSH(result);
          break;
        }
      case op_exit_discard_n:
        FAST_POPN(INSUINT8());
        break;
      case op_pop_args:
	FAST_POPN(my_nargs);
	break;
      case op_branch_z1:
	if (isfalse(FAST_POP())) goto branch1;
	(void)INSINT8();
	break;
      case op_branch_z2:
	if (isfalse(FAST_POP())) goto branch2;
	(void)INSINT16();
	break;
      case op_branch_nz1:
	if (istrue(FAST_POP())) goto branch1;
	(void)INSINT8();
	break;
      case op_branch_nz2:
	if (istrue(FAST_POP())) goto branch2;
	(void)INSINT16();
	break;
      case op_loop1:
        if (check_loop()) IERROR(error_loop);
	check_interrupt();
        FALLTHROUGH;
      case op_branch1:
      branch1:
	{
	  int8_t offset = INSINT8();

	  ins_index += offset;
	  ins += offset;
	  break;
	}

      case op_loop2:
        if (check_loop()) IERROR(error_loop);
	check_interrupt();
        FALLTHROUGH;
      case op_branch2:
      branch2:
	{
	  int16_t offset = INSINT16();

	  ins_index += offset;
	  ins += offset;
	  break;
	}

#define RECALL(access) FAST_PUSH((access)->vvalue)
#define ASSIGN(access) do {                     \
          struct variable *_var = (access);     \
          _var->vvalue = FAST_GET(0);           \
        } while (0)

      case op_clear_local: LOCAL->vvalue = NULL; break;

      case op_recall_local:   RECALL(LOCAL);   break;
      case op_recall_closure: RECALL(CLOSURE); break;
      case op_recall_global:
        {
          ulong goffset = INSUINT16();

          SAVE_OFFSET();
          check_global_read(goffset);

          FAST_PUSH(GVAR(goffset));
          break;
        }
      case op_assign_local:   ASSIGN(LOCAL);   break;
      case op_assign_closure: ASSIGN(CLOSURE); break;
      case op_assign_global:
	{
	  ulong goffset = INSUINT16();

	  SAVE_OFFSET();
          value val = FAST_GET(0);
	  check_global_write(goffset, val);
	  GVAR(goffset) = val;
	  break;
	}
      case op_define:
        /* like op_assign global, but no error checking */
	GVAR(INSUINT16()) = FAST_GET(0);
	break;

	/* The builtin operations */
      case op_builtin_eq:
        {
          value arg1 = FAST_POP();
          FAST_SET(0, makebool(FAST_GET(0) == arg1));
          break;
        }
      case op_builtin_neq:
        {
          value arg1 = FAST_POP();
          FAST_SET(0, makebool(FAST_GET(0) != arg1));
          break;
        }

#define INTEGER_OP(op, opname) do {		\
	  value arg1 = FAST_POP();              \
	  value arg2 = FAST_GET(0);             \
	  if ((long)arg1 & (long)arg2 & 1)	\
	    FAST_SET(0, op);			\
	  else					\
            {                                   \
              SAVE_OFFSET();                    \
              code_ ## opname(arg1, arg2);      \
              abort();                          \
            }                                   \
	} while (0)

      case op_builtin_lt:
	INTEGER_OP(makebool((long)arg1 < (long)arg2), smaller);
	break;
      case op_builtin_le:
	INTEGER_OP(makebool((long)arg1 <= (long)arg2), smaller_equal);
	break;
      case op_builtin_gt:
	INTEGER_OP(makebool((long)arg1 > (long)arg2), greater);
	break;
      case op_builtin_ge:
	INTEGER_OP(makebool((long)arg1 >= (long)arg2), greater_equal);
	break;

      case op_builtin_add:
        {
          value arg1 = FAST_POP();
          value arg2 = FAST_GET(0);
          if ((long)arg1 & (long)arg2 & 1)
            FAST_SET(0, (value)((long)arg1 + (long)arg2 - 1));
          else if (TYPE(arg1, string) && TYPE(arg2, string))
            {
              SAVE_OFFSET();    /* in case string_plus() causes error */
              arg1 = string_plus(arg1, arg2);
              RESTORE_INS();
              RESTORE_STACK();
              FAST_SET(0, arg1);
            }
          else
            {
              SAVE_OFFSET();
              code_plus(arg1, arg2);
              abort();
            }
          break;
        }

      case op_builtin_sub:
	INTEGER_OP((value)((long)arg1 - (long)arg2 + 1), subtract);
	break;

      case op_builtin_bitand:
	INTEGER_OP((value)((long)arg1 & (long)arg2), bitand);
	break;
      case op_builtin_bitor:
	INTEGER_OP((value)((long)arg1 | (long)arg2), bitor);
	break;
      case op_builtin_bitnot:
        {
          value arg = FAST_GET(0);
          if (!integerp(arg))
            {
              SAVE_OFFSET();
              code_bitnot(arg);
              abort();
            }
          FAST_SET(0, (value)((long)arg ^ -2));
        }
	break;

      case op_builtin_not:
	FAST_SET(0, makebool(isfalse(FAST_GET(0))));
	break;

      case op_builtin_car:
      case op_builtin_cdr:
        {
          struct list *arg = FAST_GET(0);
          if (!TYPE(arg, pair))
            {
              SAVE_OFFSET();
              (byteop == op_builtin_car ? code_car : code_cdr)(arg);
              abort();
            }
          FAST_SET(0, byteop == op_builtin_car ? arg->car : arg->cdr);
          break;
        }

	/* These could be optimised */
      case op_builtin_ref:
        {
          SAVE_OFFSET();
          value arg1 = FAST_POP();
          value arg2 = FAST_GET(0);
          value result = code_ref(arg1, arg2);
          GCCHECK(result);
          RESTORE_STACK();
          RESTORE_INS();
          FAST_SET(0, result);
          break;
        }

      case op_builtin_set:
        {
          SAVE_OFFSET();
          value arg0 = FAST_POP();
          value arg1 = FAST_POP();
          value arg2 = FAST_GET(0);
          value result = code_setb(arg0, arg1, arg2);
          GCCHECK(result);
          RESTORE_STACK();
          RESTORE_INS();
          FAST_SET(0, result);
          break;
        }

      case op_typeset_check:
        {
          value arg2 = FAST_POP();
          assert(integerp(arg2));
          long typeset = intval(arg2);
          union typecheck_arg arg = { .u = INSUINT8() };
          value arg1 = FAST_GET(arg.s.argnum);
          if (!is_typeset(arg1, typeset))
            {
              SAVE_OFFSET();
              bad_typeset_error(arg1, typeset,
                                arg.s.is_arg ? arg.s.argnum : -1);
            }
          break;
        }

        /* type checks follow */
#define _SIMPLE_TYPECHECK(cbarg, type) {                        \
          union typecheck_arg arg = { .u = INSUINT8() };        \
          value arg1 = FAST_GET(arg.s.argnum);                  \
          if (!TYPE(arg1, type))                                \
            IERROR_TYPE(arg1, type_ ## type, arg.s.argnum);     \
        }                                                       \
        break
#define _OP_TYPECHECK(simple, arg, type) IF(simple)(    \
          _SIMPLE_TYPECHECK(arg, type),                 \
          goto pointer_typecheck)
#define OP_TYPECHECK(type, arg)                         \
        case op_typecheck_type_ ## type:                \
          _OP_TYPECHECK(                                \
            IF(IS_MARK(_TYPE_IS_NULL_ ## type))(        \
              1,                                        \
              IF(IS_MARK(_TYPE_IS_INT_ ## type))(       \
                1, 0)),                                 \
            arg, type)

        FOR_PLAIN_TYPES(OP_TYPECHECK, , SEP_SEMI);

        {
        pointer_typecheck: ;
          union typecheck_arg arg = { .u = INSUINT8() };
          struct obj *arg1 = FAST_GET(arg.s.argnum);
          enum mudlle_type type = byteop - op_typecheck;
          if (!pointerp(arg1) || arg1->type != type)
            IERROR_TYPE(arg1, type, arg.s.is_arg ? arg.s.argnum : -1);
          break;
        }

      case op_typecheck_stype_none:
	IERROR(error_bad_type);

      case op_typecheck_stype_any:
        break;

      case op_typecheck_stype_function:
	{
          union typecheck_arg arg = { .u = INSUINT8() };
	  value arg1 = FAST_GET(arg.s.argnum);
	  if (!is_function(arg1))
            IERROR_TYPE(arg1, stype_function,
                        arg.s.is_arg ? arg.s.argnum : -1);
	  break;
	}

      case op_typecheck_stype_false:
        {
          union typecheck_arg arg = { .u = INSUINT8() };
          value arg1 = FAST_GET(arg.s.argnum);
          if (arg1 != makebool(false))
            IERROR_TYPE(arg1, stype_false,
                        arg.s.is_arg ? arg.s.argnum : -1);
          break;
        }

      case op_typecheck_stype_bigint_like:
        {
          union typecheck_arg arg = { .u = INSUINT8() };
          value arg1 = FAST_GET(arg.s.argnum);
          if (!is_const_typeset(arg1, TYPESET_BIGINT_LIKE))
            IERROR_TYPE(arg1, stype_bigint_like,
                        arg.s.is_arg ? arg.s.argnum : -1);
          break;
        }

      case op_typecheck_stype_float_like:
        {
          union typecheck_arg arg = { .u = INSUINT8() };
          value arg1 = FAST_GET(arg.s.argnum);
          if (!is_const_typeset(arg1, TYPESET_FLOAT_LIKE))
            IERROR_TYPE(arg1, stype_float_like,
                        arg.s.is_arg ? arg.s.argnum : -1);
          break;
        }

      case op_typecheck_stype_list:
        {
          CASSERT(mudlle_synthetic_types - mudlle_types == 7);
          union typecheck_arg arg = { .u = INSUINT8() };
	  value arg1 = FAST_GET(arg.s.argnum);
          if (arg1 && !TYPE(arg1, pair))
            IERROR_TYPE(arg1, stype_list,
                        arg.s.is_arg ? arg.s.argnum : -1);
          break;
        }

      default: abort();
      }
  }
 done:
  set_c_maxseclevel(old_maxseclevel);
  set_trace_seclevel(old_trace_seclevel);

  if (me.locals != NULL)
    gc_free(&me.locals->o);

  call_stack = me.s.next;

  me.code->instruction_count += instruction_number - start_ins;
}

/* Interface to machine code. */

static value invoke_stack(struct closure *c, int nargs)
/* Requires: c be a closure whose code is in machine code, i.e.
     TYPEIS(c->code, mcode);
     The stack must contain at least nargs entries.
   Effects: Executes c(nargs arguments taken from the stack)
   Returns: c's result
*/
{
  if (nargs == 0)
    return invoke0(c);

  if (nargs > MAX_PRIMITIVE_ARGS)
    {
      GCPRO(c);
      struct vector *extra = ALLOC_RECORD_NOINIT(vector, nargs);
      UNGCPRO();
      struct stack_cache stack_cache;
      RESTORE_STACK();
      for (int i = 0; i < nargs; ++i)
        extra->data[i] = FAST_POP();
      return invokev(c, extra);
    }

  struct stack_cache stack_cache;
  RESTORE_STACK();

#define __POPARG(N) value PRIMARG(N) = FAST_GET(DEC(N))
#define __INVOKE(N)                                     \
  case N:                                               \
    {                                                   \
      CONCATSEMI(N, __POPARG);                          \
      FAST_POPN(N);                                     \
      return invoke ## N(c, PRIMARGNAMES(N));           \
    }

  switch (nargs)
    {
      DOPRIMARGS(__INVOKE, SEP_EMPTY)
    default: abort();
    }

#undef __POPARG
#undef __INVOKE
}

static noreturn void cearly_error(struct primop_header *primop,
                                  enum runtime_error error, const char *msg)
{
  /* Clear primop.args[] to prevent GC of possibly-invalid values.
     The real arguments are on the interpreter stack. */
  for (int i = 0; i < primop->c.nargs; ++i)
    primop->args[i] = NULL;
  interpreted_early_runtime_error(error, msg);
}

/* Interface from machine code - backend specific */

#if defined __x86_64__ && !defined NOCOMPILER
/* called from x64builtins.S; args[nargs] must be GC-protected */
value builtin_call_interpreter(struct closure *closure, int nargs,
                               const value *args);
value builtin_call_interpreter(struct closure *closure, int nargs,
                               const value *args)
{
  if (nargs > 0)
    {
      /* Reserve stack space */
      GCPRO(closure);
      stack_make_room(nargs);
      UNGCPRO();

      for (int i = 0; i < nargs; ++i)
        stack_set(i, args[i]);
    }

  do_interpret(closure, nargs);

  return stack_pop();
}
#endif
