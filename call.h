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

#ifndef CALL_H
#define CALL_H

#include "error.h"

#define NARGS(N) N
#define NARGSPLUS(N) ~N

#define PRIMARG(N) v ## N

#define PRIMARGSPLUS(N) \
  IF_ZERO(N)(, CONCATCOMMA(N, value PRIMARG),) struct vector *argv
#define PRIMARGS(N) IF_ZERO(N)(void, CONCATCOMMA(N, value PRIMARG))

#define PRIMARGNAMESPLUS(N) IF_ZERO(N)(, CONCATCOMMA(N, PRIMARG),) argv
#define PRIMARGNAMES(N)  IF_ZERO(N)(, CONCATCOMMA(N, PRIMARG))

/* typedef op<N>_fn and op<N>plus_fn */
#define PRIMOPTYPE(N) op ## N ## _fn
#define _PRIMOPTYPEPLUS(N) op ## N ## plus_fn
#define PRIMOPTYPEPLUS(N) _PRIMOPTYPEPLUS(N)
#define DEF_OPTYPE(N) typedef value (*PRIMOPTYPE(N))(PRIMARGS(N))

DEF_OPTYPE(0);
DOPRIMARGS(DEF_OPTYPE, SEP_SEMI);

#define _DEF_OPTYPEPLUS(N) typedef value (*PRIMOPTYPEPLUS(N))(PRIMARGSPLUS(N))
#define DEF_OPTYPEPLUS(N) _DEF_OPTYPEPLUS(DEC(N))
DOVAROPARGS(DEF_OPTYPEPLUS, SEP_SEMI);

extern const char *forbid_mudlle_calls;

void fail_allow_mudlle_call(void);

static inline void check_allow_mudlle_call(void)
{
  if (forbid_mudlle_calls == NULL)
    return;
  fail_allow_mudlle_call();
}

value call_vararg(const struct prim_op *op, unsigned nfixed,
                  const value *args, struct vector *argv);

/* Effects: Calls c with listed arguments
   Returns: c's result
   Requires: callable(c, N) does not fail.
*/
value call0(value c);
#define DECL_CALL(N) value call ## N(value c, PRIMARGS(N))
DOPRIMARGS(DECL_CALL, SEP_SEMI);
#undef DECL_CALL

static ALWAYS_INLINE unsigned varop_nfixed(const struct prim_op *op)
{
  int n = ~op->nargs;
  assert(n >= 0 && n < MAX_VARARG_FIXED);
  return n;
}

static inline bool call1plus_needs_copy(struct obj *f)
{
  if (f->type != type_varargs)
    return false;
  const struct prim_op *op = ((struct primitive *)f)->op;
  return varop_nfixed(op) == 1 && (op->flags & OP_VARARG_COPY);
}

value call1plus(value c, value arg, struct vector *args);
/* Effects: Calls c with argument arg
   Returns: c's result
   Requires: callable(c, 1 + vector_len(args)) does not fail.
             If call1plus_needs_copy(c), 'args' must be newly allocated.
   Cheat: If c is a closure, it will do the argument count check, so
     the requirement is waved (otherwise cause_event/react_event
     become painful).
*/

static inline bool callv_needs_copy(struct obj *f)
{
  if (f->type != type_varargs)
    return false;
  const struct prim_op *op = ((struct primitive *)f)->op;
  return varop_nfixed(op) == 0 && (op->flags & OP_VARARG_COPY);
}

value callv(value c, struct vector *args);
/* Effects: Calls c with arguments args
   Returns: c's result
   Requires: callable(c, vector_len(args)) does not fail.
             If callv_needs_copy(c), 'args' must be newly allocated.
*/

enum runtime_error function_callable(value v, const char **errmsg, long nargs);
/* Returns: error to raise if 'v' cannot be called with nargs arguments */

void callable(value c, long nargs);
/* Effects: Causes an error of c is not something that can be called with
     nargs arguments.
*/

bool callablep(value c, long nargs);
/* Returns: false if c is not something that can be called with
     nargs arguments.
*/

bool minlevel_violator(value c, seclev_t minlev);
/* Returns: true is calling c will cause a minlevel runtime error
*/

/* As above, but trap errors. An error was caused if
   has_pending_exception(); mexception.sig and .err are set appropriately.
*/
value internal_mcatch_call0(const char *name, typeset_t rtypeset,
                            value c);
value internal_mcatch_call(const char *name, typeset_t rtypeset,
                           value c, int argc, value args[static argc]);

#define DECL_MCATCH(N)                                          \
  static inline value internal_mcatch_call ## N(                \
    const char *name, typeset_t rtypeset,                       \
    value c, PRIMARGS(N))                                       \
  {                                                             \
    return internal_mcatch_call(                                \
      name, rtypeset, c, N, (value []){ PRIMARGNAMES(N) });     \
  }
DOVAROPARGS(DECL_MCATCH, SEP_EMPTY)

#define mcatch_call__(nargs, name, typeset, func, ...)           \
  internal_mcatch_call ## nargs(name, typeset, func, __VA_ARGS__)
#define mcatch_call_(nargs, name, typeset, func, ...)    \
  mcatch_call__(nargs, name, typeset, func, __VA_ARGS__)

/* mcatch_call_rtypeset(name, return-typeset, function, args ...) */
#define mcatch_call_rtypeset(name, typeset, ...)                        \
  IF_NO_COMMA(__VA_ARGS__)(                                             \
    internal_mcatch_call0((name), (typeset), __VA_ARGS__),              \
    mcatch_call_(DEC(VA_NARGS(__VA_ARGS__)), (name), (typeset),         \
                 __VA_ARGS__))
/* mcatch_call(name, function, args ...) */
#define mcatch_call(name, ...)                                  \
  mcatch_call_rtypeset((name), TYPESET_ANY, __VA_ARGS__)

value mcatch_call1plus(const char *name, value c, value arg,
                       struct vector *arguments);
value mcatch_callv(const char *name, value c, struct vector *arguments);

/* Machine language interface */

value invoke0(struct closure *c);
#if defined __x86_64__ && !defined NOCOMPILER
#define DECL_INVOKE(N)                                                  \
value x64_invoke ## N(PRIMARGS(N), struct closure *c);                  \
static ALWAYS_INLINE value invoke ## N(struct closure *c, PRIMARGS(N))  \
{                                                                       \
  return x64_invoke ## N(PRIMARGNAMES(N), c);                           \
}                                                                       \
value x64_invoke ## N(PRIMARGS(N), struct closure *c)
#else
#define DECL_INVOKE(N)                                                  \
value invoke ## N(struct closure *c, PRIMARGS(N))
#endif
DOPRIMARGS(DECL_INVOKE, SEP_SEMI);
#undef DECL_INVOKE

/* Requires: c be a closure whose code is in machine code, i.e.
     TYPEIS(c->code, mcode);
   Effects: Executes c(arg1, ..., argN)
   Returns: c()'s result
*/

value invoke1plus(struct closure *c, value arg, struct vector *args);
/* Requires: c be a closure whose code is in machine code, i.e.
     TYPEIS(c->code, mcode);
   Effects: Executes c(args)
   Returns: c(args)'s result
*/

value invokev(struct closure *c, struct vector *args);
/* Requires: c be a closure whose code is in machine code, i.e.
     TYPEIS(c->code, mcode);
   Effects: Executes c(args)
   Returns: c(args)'s result
*/

value msetjmp(value f);
noreturn void mlongjmp(struct mjmpbuf *buf, value x);

noreturn void mrethrow(void);
noreturn void mthrow(enum mudlle_signal sig, enum runtime_error err);

void maybe_mrethrow(void);

struct mcallback;

typedef value (*mcallback_varargs_fn)(void *cbdata, struct closure *fn,
                                      struct vector *args);
bool mcallback_varargs_matches(struct closure *fn,
                               mcallback_varargs_fn callback,
                               void **cbdata);
value call_mcallback(struct mcallback *cb, struct closure *fn,
                     struct vector *locals);

/* returns a mudlle 'fn() -> x' implemented by calling 'cb(cbarg) -> x';
   'cbfree(cbarg)' is called when the mudlle reference is lost */
struct closure *make_mcallback(
  value (*cb)(void *cbdata),
  void (*cbfree)(void *cbdata),
  void *cbdata,
  const char *funcname,
  struct string *help,
  const char *filename, int line);
struct closure *make_mcallback_varargs(
  mcallback_varargs_fn cb, void (*cbfree)(void *cbdata), void *cbdata,
  const char *funcname, struct string *help, const char *filename, int line);
struct closure *make_mcallback_varargs_captured(
  mcallback_varargs_fn cb, void (*cbfree)(void *cbdata), void *cbdata,
  struct vector *captures, const char *funcname, struct string *help,
  const char *filename, int line);
struct closure *make_mcallback_varargs_captured_sec(
  mcallback_varargs_fn cb, void (*cbfree)(void *cbdata), void *cbdata,
  struct vector *captures, const char *funcname, struct string *help,
  const char *filename, int line, seclev_t seclev);

#define MAKE_MCALLBACK(cb, cbfree, cbarg, funcname, help)       \
  make_mcallback((cb), (cbfree), (cbarg), (funcname), (help),   \
                 __FILE__, __LINE__)

#endif
