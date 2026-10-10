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

#include <string.h>

#include "alloc.h"
#include "call.h"
#include "compile.h"
#include "context.h"
#include "interpret.h"
#include "stack.h"


/* Interface to machine code. */

#ifdef NOCOMPILER
value invoke0(struct closure *c) { return NULL; }
#define DEF_INVOKE(N) \
value invoke ## N(struct closure *c, PRIMARGS(N)) { return NULL; }
DOPRIMARGS(DEF_INVOKE, SEP_EMPTY)

value invoke1plus(struct closure *c, value arg, struct vector *args)
{ return NULL; }

value invokev(struct closure *c, struct vector *args) { return NULL; }
#endif  /* NOCOMPILER */

bool minlevel_violator(value c, seclev_t minlev)
{
  if (!pointerp(c))
    {
      abort();
    }
  struct obj *o = c;
  enum mudlle_type t = o->type;
  struct code *code;
  if (t == type_closure)
    code = ((struct closure *)o)->code;
  else if (t == type_icode || t == type_mcode)
    code = (struct code *)o;
  else
    return false;

  return code->seclevel < minlev;
}

static bool closure_callable(struct closure *cl, long nargs)
{
  assert(nargs >= 0);

  size_t arglen = vector_len(cl->code->arguments);
  if (arglen == (ulong)nargs)
    return true;
  if (arglen == 0)
    return false;

  if (nargs > MAX_FUNCTION_ARGS)
    return false;

  if ((ulong)nargs > arglen)
    {
      struct list *lastarg = cl->code->arguments->data[arglen - 1];
      return lastarg->cdr == NULL; /* variable-length argument */
    }

  struct list *arg = cl->code->arguments->data[nargs];
  value mtypeset = arg->cdr;
  if (mtypeset == NULL)
    return true;                /* variable-length argument */
  assert(integerp(mtypeset));
  return intval(arg->cdr) & TYPESET_FLAG_OPTIONAL;
}

bool callablep(value c, long nargs)
/* Returns: false if c is not something that can be called with
     nargs (>= 0) arguments.
*/
{
  assert(nargs >= 0);

  if (!pointerp(c))
    return false;

  struct obj *o = c;
  switch (o->type)
    {
    case type_closure:
      return closure_callable(c, nargs);
    case type_secure:
    case type_primitive:
      return ((struct primitive *)o)->op->nargs == nargs;
    case type_varargs:
      {
        const struct prim_op *op = ((struct primitive *)o)->op;
        unsigned nfixed = varop_nfixed(op);
        return nfixed <= nargs && nargs <= MAX_FUNCTION_ARGS;
      }
    default:
      return false;
    }
}

enum runtime_error function_callable(value v, const char **errmsg, long nargs)
{
  if (!is_function(v))
    {
      *errmsg = bad_typeset_message(v, TYPESET_FUNCTION);
      return error_bad_function;
    }

  struct obj *f = v;
  switch (f->type)
    {
    case type_closure:
      if (closure_callable((struct closure *)f, nargs))
        return error_none;
      goto wrong_parameters;
    case type_secure:
      {
        const seclev_t op_seclevel = ((struct primitive *)f)->op->seclevel;

        /* Security for Valar: disallow calling A+ secures without going
         * through mudlle code (which has its own security checks). */
        if (DEFAULT_SECLEVEL < op_seclevel)
          {
            if (errmsg)
              *errmsg = "primitive seclevel too high";
            return error_security_violation;
          }

        /* Security for Maiar: enforce maxseclevel if it has a meaningful
         * value. */
        if (in_mudlle_session() && c_maxseclevel() < op_seclevel)
          {
            if (errmsg)
              *errmsg = "maxseclevel too low";
            return error_security_violation;
          }
      }
      FALLTHROUGH;
    case type_primitive:
      if (((struct primitive *)f)->op->nargs == nargs)
        return error_none;
      goto wrong_parameters;
    case type_varargs:
      {
        const struct prim_op *op = ((struct primitive *)f)->op;
        unsigned nfixed = varop_nfixed(op);
        if (nfixed <= nargs && nargs <= MAX_FUNCTION_ARGS)
          return error_none;
        goto wrong_parameters;
      }
    default:
      abort();
    }

 wrong_parameters:
  if (errmsg)
    *errmsg = not_callable_message(nargs);
  return error_wrong_parameters;
}

void callable(value c, long nargs)
/* Effects: Causes an error if c is not something that can be called with
     nargs arguments.
*/
{
  const char *errmsg;
  enum runtime_error error = function_callable(c, &errmsg, nargs);
  if (error != error_none)
    runtime_error_message(error, errmsg);
}

/* if not NULL, name of function/primitive forbidding calls */
const char *forbid_mudlle_calls;

noreturn
void fail_allow_mudlle_call(void)
{
  abort();
}

value call0(value c)
/* Effects: Calls c with no arguments
   Returns: c's result
   Requires: callable(c, 0) does not fail.
*/
{
  check_allow_mudlle_call();

  switch (((struct obj *)c)->type)
    {
    case type_closure:
      {
	struct closure *cl = c;
	if (cl->code->o.type == type_mcode)
	  return invoke0(cl);

        do_interpret(cl, 0);
        return stack_pop();
      }

    case type_secure: case type_primitive:
      {
        struct primitive *prim = c;
        return ((op0_fn)prim->op->op)();
      }

    case type_varargs:
      {
        struct primitive *prim = c;
        const struct prim_op *op = prim->op;
	struct vector *argv = ALLOC_RECORD_NOINIT(vector, 0);
	return ((op0plus_fn)op->op)(argv);
      }

    default: break;
    }
  abort();
}

value call_vararg(const struct prim_op *op, unsigned nfixed,
                  const value *args, struct vector *argv)
{
  switch (nfixed)
    {
#define __VARG(N) args[DEC(N)]
#define __CALL(N) case DEC(N):                                          \
      return ((PRIMOPTYPEPLUS(DEC(N)))op->op)(                          \
        IF_ONE(N)(, CONCATCOMMA(DEC(N), __VARG),) argv)
      DOVAROPARGS(__CALL, SEP_SEMI);
#undef __CALL
#undef __VARG
    }
  abort();
}

#if defined __x86_64__ && !defined NOCOMPILER

/* called from x64builtins.S */
value builtin_call_vararg(const struct prim_op *op, long nargs,
                          const value *args);
value builtin_call_vararg(const struct prim_op *op, long nargs,
                          const value *args)
{
  unsigned nfixed = varop_nfixed(op);
  if (nargs < nfixed || nargs > MAX_FUNCTION_ARGS)
    runtime_error(error_wrong_parameters);

  int nvec = nargs - nfixed;
  struct vector *argv = ALLOC_RECORD_NOINIT(vector, nvec);
  memcpy(argv->data, args + nfixed, sizeof *args * nvec);

  return call_vararg(op, nfixed, args, argv);
}

/* called from x64builtins.S */
value builtin_apply_vararg(const struct prim_op *op, value *args);
value builtin_apply_vararg(const struct prim_op *op, value *args)
{
  unsigned nfixed = varop_nfixed(op);
  size_t nvec = vector_len((struct vector *)(args[nfixed]));
  struct vector *argv = ALLOC_RECORD_NOINIT(vector, nvec);
  memcpy(argv->data, ((struct vector *)(args[nfixed]))->data,
         nvec * sizeof argv->data[0]);
  return call_vararg(op, nfixed, args, argv);
}
#endif  /* ! __x86_64__ || NOCOMPILER */

#define __STACK_SET(N) stack_set(DEC(N), PRIMARG(N))
#define __VSET(N) do {                          \
    if (DEC(N) < nfixed)                        \
      args[DEC(N)] = PRIMARG(N);                \
    else                                        \
      argv->data[DEC(N) - nfixed] = PRIMARG(N); \
  } while (0)

#define CALL_N(N)                                                       \
value call ## N(value c, PRIMARGS(N))                                   \
/* Effects: Calls c with arguments arg1...argN                          \
   Returns: c's result                                                  \
   Requires: callable(c, N) does not fail.                              \
*/                                                                      \
{                                                                       \
  check_allow_mudlle_call();                                            \
                                                                        \
  switch (((struct obj *)c)->type)                                      \
    {                                                                   \
    case type_closure:                                                  \
      {                                                                 \
        struct closure *cl = c;                                         \
        if (cl->code->o.type == type_mcode)                             \
          return invoke ## N(cl, PRIMARGNAMES(N));                      \
                                                                        \
        GCPRO(PRIMARGNAMES(N));                                         \
        stack_make_room(N);                                             \
        UNGCPRO();                                                      \
        CONCATSEMI(N, __STACK_SET);                                     \
        do_interpret(cl, N);                                            \
        return stack_pop();                                             \
      }                                                                 \
                                                                        \
    case type_secure: case type_primitive:                              \
      {                                                                 \
        struct primitive *prim = c;                                     \
        return ((PRIMOPTYPE(N))prim->op->op)(PRIMARGNAMES(N));          \
      }                                                                 \
                                                                        \
    case type_varargs:                                                  \
      {                                                                 \
        struct primitive *prim = c;                                     \
        const struct prim_op *op = prim->op;                            \
        unsigned nfixed = varop_nfixed(op);                             \
        assert(nfixed <= N);                                            \
        unsigned nvec = N - nfixed;                                     \
        GCPRO(PRIMARGNAMES(N));                                         \
        struct vector *argv = ALLOC_RECORD_NOINIT(vector, nvec);        \
        UNGCPRO();                                                      \
        value args[N];                                                  \
        CONCATSEMI(N, __VSET);                                          \
        return call_vararg(op, nfixed, args, argv);                     \
      }                                                                 \
                                                                        \
    default: break;                                                     \
    }                                                                   \
  abort();                                                              \
}

DOPRIMARGS(CALL_N, SEP_EMPTY)

#define __VECT1ARG(N) IF_ONE(N)(arg, args->data[DEC(DEC(N))])
#define __V1CALLOP(N) \
  case N: return ((PRIMOPTYPE(N))prim->op->op)(CONCATCOMMA(N, __VECT1ARG))

value call1plus(value c, value arg, struct vector *args)
/* Effects: Calls c with argument arg
   Returns: c's result
   Requires: callable(c, 1 + vector_len(args)) does not fail.
             If call1plus_needs_copy(c), 'args' must be newly allocated.
   Cheat: If c is a closure, it will do the argument count check, so
     the requirement is waved (otherwise cause_event/react_event
     become painful).
*/
{
  check_allow_mudlle_call();

  size_t nargs = 1 + vector_len(args);
  switch (((struct obj *)c)->type)
    {
    case type_closure:
      {
	struct closure *cl = c;

	if (cl->code->o.type == type_mcode)
	  return invoke1plus(cl, arg, args);

        GCPRO(cl, arg, args);
        stack_make_room(nargs);
        UNGCPRO();
        for (size_t i = 0; i < vector_len(args); ++i)
          stack_set(i + 1, args->data[i]);
        stack_set(0, arg);

        do_interpret(cl, nargs);
        return stack_pop();
      }

    case type_secure: case type_primitive:
      {
        struct primitive *prim = c;
        switch (nargs)
          {
            DOPRIMARGS(__V1CALLOP, SEP_SEMI);
          }
        abort();
      }

    case type_varargs:
      {
	struct primitive *prim = c;
        const struct prim_op *op = prim->op;

        unsigned nfixed = varop_nfixed(op);
        if (nfixed == 1)
          return call_vararg(op, nfixed, &arg, args); /* easy */

        assert(nfixed <= nargs);
        unsigned nvec = nargs - nfixed;

        value fixedargs[nfixed ? nfixed : 1];

        GCPRO(arg, args);
	struct vector *argv = ALLOC_RECORD_NOINIT(vector, nvec);
        for (unsigned i = 0; i < nfixed; ++i)
          fixedargs[i] = i == 0 ? arg : args->data[i - 1];
        for (unsigned i = nfixed; i < nargs; ++i)
          argv->data[i - nfixed] = i == 0 ? arg : args->data[i - 1];
	UNGCPRO();

	return call_vararg(op, nfixed, fixedargs, argv);
      }

    default: break;
    }
  abort();
}

value callv(value c, struct vector *args)
/* Effects: Calls c with arguments args
   Returns: c's result
   Requires: callable(c, vector_len(args)) does not fail.
             If callv_needs_copy(c), 'args' must be newly allocated.
*/
{
  int nargs = vector_len(args);
  if (nargs == 0)
    return call0(c);

  check_allow_mudlle_call();

  switch (((struct obj *)c)->type)
    {
    case type_closure:
      {
	struct closure *cl = c;

	if (cl->code->o.type == type_mcode)
	  return invokev(cl, args);

        GCPRO(cl, args);
        stack_make_room(nargs);
        UNGCPRO();
        for (int i = 0; i < nargs; ++i)
          stack_set(i, args->data[i]);

        do_interpret(cl, nargs);
        return stack_pop();
      }

    case type_secure: case type_primitive:
      {
        struct primitive *prim = c;
        switch (nargs)
          {
#define __VECTARG(N) args->data[DEC(N)]
#define __VCALLOP(N)                                                    \
            case N:                                                     \
              return ((PRIMOPTYPE(N))prim->op->op)(                     \
                CONCATCOMMA(N, __VECTARG))
            DOPRIMARGS(__VCALLOP, SEP_SEMI);
#undef __VCALLOP
#undef __VECTARG
          }
        abort();
      }
    case type_varargs:
      {
        struct primitive *prim = c;
        const struct prim_op *op = prim->op;
        unsigned nfixed = varop_nfixed(op);
        struct vector *argv;
        if (nfixed > 0)
          {
            unsigned nvec = nargs - nfixed;
            GCPRO(args);
            argv = ALLOC_RECORD_NOINIT(vector, nvec);
            UNGCPRO();
            memcpy(argv->data, args->data + nfixed,
                   nvec * sizeof argv->data[0]);
          }
        else
          argv = args;
        return call_vararg(op, nfixed, args->data, argv);
      }

    default: break;
    }
  abort();
}

struct call_argv_info {
  value c, result;
  int nargs;
  value *args;
  const char *name;
  typeset_t rtypeset;
};

static void docall_argv(void *data)
{
  struct call_argv_info *info = data;
  assert(info->nargs > 0);

  struct {
    struct call_stack_c_header c;
    value args[MAX_PRIMITIVE_ARGS];
  } me;

  bool has_name = info->name;
  if (has_name)
    {
      me.c = (struct call_stack_c_header){
	.s = {
	  .next = call_stack,
	  .type = call_string_args,
	},
	.u.name = info->name,
	.nargs = info->nargs
      };
      call_stack = &me.c.s;
    }

  if (info->nargs > MAX_PRIMITIVE_ARGS)
    {
      GCPRO(info->c);
      me.c.nargs = 0;		/* in case there's GC */
      struct vector *argv = make_vector(info->nargs, info->args);
      me.c.s.type = call_string_argv;
      me.c.nargs = 1;
      UNGCPRO();
      me.args[0] = argv;

      callable(info->c, info->nargs);
      info->result = callv(info->c, argv);
      goto done;
    }

  for (int i = 0; i < info->nargs; ++i)
    me.args[i] = info->args[i];
  callable(info->c, info->nargs);

  switch (info->nargs)
    {
#define __ARG(N) me.args[DEC(N)]
#define __CALLN(N)                                                      \
      case N:                                                           \
        info->result = call ## N(info->c, CONCATCOMMA(N, __ARG));       \
        goto done
      DOPRIMARGS(__CALLN, SEP_SEMI);
#undef __CALLN
#undef __ARG
    }

 done:
  if (info->rtypeset != TYPESET_ANY
      && !is_typeset(info->result, info->rtypeset))
    runtime_error_message(
      error_bad_type,
      message_when_returning(
        bad_typeset_message(info->result, info->rtypeset)));
  if (has_name)
    call_stack = me.c.s.next;
}

/* Calls with error trapping */

static inline enum call_trace_mode call_trace_mode(void)
{
  if (catch_context && catch_context->call_trace_mode != call_trace_barrier)
    return catch_context->call_trace_mode;
  return call_trace_on;
}

struct setjmp_data {
  value func;
  value result;
};

static void docall0_setjmp(void *_data)
{
  struct setjmp_data *data = _data;

  value f = data->func;
  GCPRO(f);
  value buf = mjmpbuf(&data->result);
  UNGCPRO();
  data->result = call1(f, buf);
}

value msetjmp(value f)
{
  struct setjmp_data data = { .func = f };
  mcatch(docall0_setjmp, &data, call_trace_mode());
  return data.result;
}

void mlongjmp(struct mjmpbuf *buf, value x)
{
  assert(is_mjmpbuf(buf));
  *buf->result = x;
  buf->result = NULL;           /* mark as target of longjmp() */
  mthrow(SIGNAL_LONGJMP, error_none);
}

void mrethrow(void)
{
  siglongjmp(catch_context->exception_jmp_buf, 1);
}

void mthrow(enum mudlle_signal sig, enum runtime_error err)
{
  mexception = (struct mexception){ .sig = sig, .err = err };
  mrethrow();
}

void maybe_mrethrow(void)
{
  if (has_pending_exception())
    mrethrow();
}

struct call_info {
  value c, result;
  const char *name;
  struct vector *args;
};

static void docallv(void *x)
{
  struct call_info *info = x;
  callable(info->c, vector_len(info->args));
  info->result = callv(info->c, info->args);
}

static void docallv_named(void *x)
{
  struct call_info *info = x;
  struct {
    struct call_stack_c_header c;
    value args[1];
  } me = {
    .c = {
      .s = {
	.next = call_stack,
	.type = call_string_argv
      },
      .u.name = info->name,
      .nargs = 1
    },
    .args = { info->args }
  };
  call_stack = &me.c.s;
  docallv(x);
  call_stack = me.c.s.next;
}

value mcatch_callv(const char *name, value c, struct vector *arguments)
{
  struct call_info info = {
    .c = c, .args = arguments, .name = name
  };
  if (mcatch(name == NULL ? docallv : docallv_named, &info, call_trace_mode()))
    return info.result;
  return NULL;
}

static void docall_argv0(void *data)
{
  struct call_argv_info *info = data;
  callable(info->c, 0);
  info->result = call0(info->c);
}

static void docall_argv0_named(void *data)
{
  struct call_argv_info *info = data;
  struct call_stack_c_header me = {
    .s = {
      .next = call_stack,
      .type = call_string_args,
    },
    .u.name = info->name,
    .nargs  = 0
  };
  call_stack = &me.s;
  docall_argv0(data);
  call_stack = me.s.next;
}

value internal_mcatch_call0(const char *name, typeset_t rtypeset,
                            value c)
{
  struct call_argv_info info = {
    .c        = c,
    .nargs    = 0,
    .name     = name,
    .rtypeset = rtypeset
  };
  if (mcatch(name == NULL ? docall_argv0 : docall_argv0_named, &info,
             call_trace_mode()))
    return info.result;
  return NULL;
}

value internal_mcatch_call(const char *name, typeset_t rtypeset, value c,
                           int argc, value args[static argc])
{
  assert(argc > 0);
  struct call_argv_info info = {
    .c        = c,
    .nargs    = argc,
    .name     = name,
    .rtypeset = rtypeset,
    .args     = args,
  };
  bool ok = mcatch(docall_argv, &info, call_trace_mode());
  return ok ? info.result : NULL;
}

struct call1plus_info {
  value c, result;
  value arg;
  const char *name;
  struct vector *args;
};

static void docall1plus(void *x)
{
  struct call1plus_info *info = x;
  const char *errmsg;
  enum runtime_error err = function_callable(
    info->c, &errmsg, 1 + vector_len(info->args));
  if (err != error_none)
    bad_call_error_1plus(err, errmsg, info->c, info->arg, info->args);
  info->result = call1plus(info->c, info->arg, info->args);
}

static void docall1plus_named(void *x)
{
  struct call1plus_info *info = x;
  struct {
    struct call_stack_c_header c;
    value args[2];
  } me = {
    .c = {
      .s = {
        .next = call_stack,
        .type = call_string_argv
      },
      .u.name = info->name,
      .nargs = 2,
    },
    .args = { info->arg, info->args }
  };
  call_stack = &me.c.s;
  docall1plus(x);
  call_stack = me.c.s.next;
}

value mcatch_call1plus(const char *name, value c, value arg,
                       struct vector *arguments)
{
  struct call1plus_info info = {
    .c = c, .arg = arg, .args = arguments, .name = name
  };
  if (mcatch(name == NULL ? docall1plus : docall1plus_named, &info,
             call_trace_mode()))
    return info.result;
  return NULL;
}

struct mcallback
{
  struct mprivate p;
  value (*cb)(void *cbdata);
  mcallback_varargs_fn cb_varargs;
  void *cbdata;
};

value call_mcallback(struct mcallback *cb, struct closure *fn,
                     struct vector *locals)
{
  assert(TYPE(cb, private));
  assert(cb->p.ptype == makeint(PRIVATE_MCALLBACK));
  if (cb->cb_varargs != NULL)
    {
      assert(vector_len(locals) > 0);
      struct variable *var = locals->data[0];
      assert(TYPE(var->vvalue, vector));
      return cb->cb_varargs(cb->cbdata, fn, var->vvalue);
    }
  assert(cb->cb != NULL);
  return cb->cb(cb->cbdata);
}

struct closure *make_mcallback(
  value (*cb)(void *cbdata),
  weak_ref_free_fn cbfree,
  void *cbdata,
  const char *funcname,
  struct string *help,
  const char *filename, int line)
{
  struct mcallback *c = (struct mcallback *)alloc_weak_ref(
    type_private, sizeof (struct mcallback), cbdata,
    cbfree);
  c->p.ptype = makeint(PRIVATE_MCALLBACK);
  c->cb = cb;
  c->cb_varargs = NULL;
  c->cbdata = cbdata;
  return make_primitive_closure(c, funcname, help, filename, line);
}

struct closure *make_mcallback_varargs(
  mcallback_varargs_fn cb, weak_ref_free_fn cbfree, void *cbdata,
  const char *funcname, struct string *help, const char *filename, int line)
{
  struct mcallback *c = (struct mcallback *)alloc_weak_ref(
    type_private, sizeof (struct mcallback), cbdata, cbfree);
  c->p.ptype = makeint(PRIVATE_MCALLBACK);
  c->cb = NULL;
  c->cb_varargs = cb;
  c->cbdata = cbdata;
  return make_primitive_closure_varargs_captured(
    c, funcname, help, filename, line, NULL);
}

struct closure *make_mcallback_varargs_captured(
  mcallback_varargs_fn cb, weak_ref_free_fn cbfree, void *cbdata,
  struct vector *captures, const char *funcname, struct string *help,
  const char *filename, int line)
{
  GCPRO(captures);
  struct mcallback *c = (struct mcallback *)alloc_weak_ref(
    type_private, sizeof (struct mcallback), cbdata, cbfree);
  c->p.ptype = makeint(PRIVATE_MCALLBACK);
  c->cb = NULL;
  c->cb_varargs = cb;
  c->cbdata = cbdata;
  struct closure *closure = make_primitive_closure_varargs_captured(
    c, funcname, help, filename, line, captures);
  UNGCPRO();
  return closure;
}

struct closure *make_mcallback_varargs_captured_sec(
  mcallback_varargs_fn cb, weak_ref_free_fn cbfree, void *cbdata,
  struct vector *captures, const char *funcname, struct string *help,
  const char *filename, int line, seclev_t seclev)
{
  GCPRO(captures);
  struct mcallback *c = (struct mcallback *)alloc_weak_ref(
    type_private, sizeof (struct mcallback), cbdata, cbfree);
  c->p.ptype = makeint(PRIVATE_MCALLBACK);
  c->cb = NULL;
  c->cb_varargs = cb;
  c->cbdata = cbdata;
  struct closure *closure = make_primitive_closure_varargs_captured_sec(
    c, funcname, help, filename, line, captures, seclev);
  UNGCPRO();
  return closure;
}
