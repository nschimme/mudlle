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

#include <stdio.h>

#include <sys/resource.h>

#include "alloc.h"
#include "context.h"
#include "stack.h"
#include "utils.h"

#include "runtime/bigint.h"
#include "runtime/mudlle-string.h"
#include "runtime/runtime.h"

/* Function contexts */
/* ----------------- */

/* Mudlle call contexts, stacked */
struct call_stack *call_stack;

/* Catch contexts */
/* -------------- */

struct catch_context *catch_context;

struct ccontext ccontext;

seclev_t internal_seclevel;
bool seclevel_valid;
value internal_maxseclevel = makeint(MAX_SECLEVEL);
seclev_t internal_trace_seclevel = MAX_SECLEVEL;

struct mexception mexception;

const struct session_info cold_session = {
  .minlevel    = 0,
  .maxseclevel = MAX_SECLEVEL
};

value seclevel_to_maxseclevel(seclev_t seclev)
{
  return makeint(maxseclevel_for(seclev));
}

seclev_t get_effective_seclevel(void)
{
  seclev_t seclev = get_seclevel();
  seclev_t maxlev = c_maxseclevel();
  return seclev > maxlev ? maxlev : seclev;
}

static bool mcatch_setjmp(void (*fn)(void *fndata), void *fndata,
                          struct catch_context *context)
{
  if (sigsetjmp(context->exception_jmp_buf, 0) != 0)
    return false;               /* longjmp() */

  /* normal case */
  fn(fndata);
  return true;
}

static bool safe_mcatch(void (*fn)(void *fndata), void *fndata,
                        struct catch_context *context)
{
  assert_mudlle_gmp(false);

  /* hard stack limit can temporarily be changed by check_segv() to handle
     exceptions using the alternate signal stack */
  ulong old_hard_mudlle_stack_limit = hard_mudlle_stack_limit;
  if (mcatch_setjmp(fn, fndata, context))
    {
      /* successful, no longjmp(), case */
      mexception.sig = SIGNAL_NONE;
      assert(call_stack == context->old_call_stack);
      assert(mudlle_forbid == context->old_forbid);
      return true;
    }

  /* we received a signal (longjmp) */
  end_mudlle_gmp();

  hard_mudlle_stack_limit = old_hard_mudlle_stack_limit;

  ccontext = context->old_ccontext;
#ifdef USE_CCONTEXT
#define __CALLER_GCCHECK(n, reg) GCCHECK(ccontext.caller.reg)
#define __CALLEE_GCCHECK(n, reg) GCCHECK(ccontext.callee.reg)
  FOR_CALLER_SAVE(__CALLER_GCCHECK, SEP_SEMI);
  FOR_CALLEE_SAVE(__CALLEE_GCCHECK, SEP_SEMI);
#undef __CALLEE_GCCHECK
#undef __CALLER_GCCHECK
#endif
  gcpro = context->old_gcpro;
  call_stack = context->old_call_stack;

  /* pop any extra stuff from stack */
  int extra_depth = stack_depth() - context->old_stack_depth;
  assert(extra_depth >= 0);
  while (extra_depth--)
    stack_pop();

  mudlle_forbid = context->old_forbid;

  forbid_mudlle_calls = NULL;

  return false;
}

bool mcatch(void (*fn)(void *x), void *x, enum call_trace_mode call_trace_mode)
{

  struct catch_context context = {
    .call_trace_mode = call_trace_mode,
    .parent          = catch_context,
    .old_ccontext    = ccontext,
    .old_gcpro       = gcpro,
    .old_stack_depth = stack_depth(),
    .old_call_stack  = call_stack,
    .old_forbid      = mudlle_forbid
  };
  catch_context = &context;

  seclev_t old_seclevel = internal_seclevel;
  value old_maxseclevel = m_maxseclevel();
  seclev_t old_trace_seclevel = trace_seclevel();

  check_allow_mudlle_call();

  bool ok = safe_mcatch(fn, x, &context);

  assert(forbid_mudlle_calls == NULL);

  set_seclevel(old_seclevel);
  set_m_maxseclevel(old_maxseclevel);
  set_trace_seclevel(old_trace_seclevel);

  catch_context = context.parent;

  /* handle setjmp context */
  if (context.mjmpbuf)
    {
      bool was_used = context.mjmpbuf->result == NULL;
      context.mjmpbuf->context = NULL;
      context.mjmpbuf->result = NULL;
      context.mjmpbuf = NULL;

      switch (mexception.sig)
        {
        case SIGNAL_NONE:
          break;
        case SIGNAL_LONGJMP:
          if (was_used)
            {
              ok = true;
              break;
            }
          FALLTHROUGH;
        case SIGNAL_ERROR:
          mrethrow();
        }
    }

  return ok;
}

value mjmpbuf(value *result)
{
  assert(catch_context->mjmpbuf == NULL);
  struct mjmpbuf *jb = (struct mjmpbuf *)allocate_ctemp(
    type_private, sizeof *jb);
  jb->p.ptype = makeint(PRIVATE_MJMPBUF);
  jb->context = catch_context;
  jb->result  = result;
  catch_context->mjmpbuf = jb;
  return jb;
}

bool is_mjmpbuf(value buf)
{
  struct mjmpbuf *mbuf = buf;
  return (TYPE(mbuf, private)
          && mbuf->p.ptype == makeint(PRIVATE_MJMPBUF)
          && mbuf->context != NULL);
}

/* Session context */
/* --------------- */

struct session_context *session_context;

volatile atomic_ulong internal_xcount; /* Loop detection */
seclev_t minlevel;                     /* Minimum security level */

ulong mudlle_stack_limit, hard_mudlle_stack_limit;

void session_start(struct session_context *context,
                   const struct session_info *info)
{
  assert(info->maxseclevel >= MIN_SECLEVEL
         && info->maxseclevel <= MAX_SECLEVEL);

  *context = (struct session_context){
    .s = (struct call_stack){
      .next = call_stack,
      .type = call_session
    },
    .parent = session_context,
    .ports = {
      .out = info->mout,
      .err = info->merr
    },
    .old_stack_limit    = mudlle_stack_limit,
    .old_minlevel       = minlevel,
    .old_maxseclevel    = c_maxseclevel(),
    .old_trace_seclevel = trace_seclevel(),
    .old_xcount         = get_xcount(),
    .old_gcpro          = gcpro,
    .rethrow_error      = error_none
  };
  call_stack = &context->s;
  session_context = context;

  mudlle_stack_limit = get_stack_pointer() - MAX_STACK_DEPTH;
  if (mudlle_stack_limit < hard_mudlle_stack_limit)
    mudlle_stack_limit = hard_mudlle_stack_limit;

  minlevel = info->minlevel;

  set_c_maxseclevel(info->maxseclevel);
  set_trace_seclevel(info->maxseclevel);

  set_xcount(MAX_LOOP_COUNT);
}

void cold_session_start(struct session_context *context,
                        seclev_t maxseclev)
{
  struct session_info info = cold_session;
  info.maxseclevel = maxseclev;
  session_start(context, &info);
}

void session_end(void)
{
  assert(gcpro == session_context->old_gcpro);
  assert(call_stack == &session_context->s);
  call_stack = session_context->s.next;
  minlevel = session_context->old_minlevel;
  set_c_maxseclevel(session_context->old_maxseclevel);
  set_trace_seclevel(session_context->old_trace_seclevel);
  mudlle_stack_limit = session_context->old_stack_limit;
  set_xcount(session_context->old_xcount);
  session_context = session_context->parent;
}

void unlimited_execution(void)
{
  /* Effectively remove execution limits for current session */
  set_xcount(MAX_TAGGED_INT);
  mudlle_stack_limit = hard_mudlle_stack_limit;
}


/* Global context */
/* -------------- */

void reset_mudlle_context(void)
{
#define assert_null(what) assert(what == NULL)
  assert_null(call_stack);
  assert_null(catch_context);
  assert_null(session_context);
  stack_clear();
  ccontext = (struct ccontext){ 0 };
}

/* if RLIMIT_STACK is not infinite, set the hard mudlle stack limit,
   reserving some space */
void set_mudlle_stack_limit(unsigned long reserved)
{
  struct rlimit lim;
  if (getrlimit(RLIMIT_STACK, &lim) < 0)
    {
      perror("getrlimit(RLIMIT_STACK, ...)");
      exit(EXIT_FAILURE);
    }

  rlim_t size = lim.rlim_cur;
  if (size == RLIM_INFINITY || size <= reserved)
    return;

  size -= reserved;
  unsigned long sp = get_stack_pointer();
  if (sp <= size)
    return;

  hard_mudlle_stack_limit = sp - size;
}

void context_init(void)
{
  if (hard_mudlle_stack_limit == 0)
    set_mudlle_stack_limit(4096);
}
