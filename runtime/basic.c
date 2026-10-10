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

#include "../mudlle-config.h"

#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

#include <arpa/inet.h>

#include <sys/stat.h>
#include <sys/utsname.h>

#include "basic.h"
#include "files.h"
#include "mudlle-string.h"
#include "prims.h"
#include "symbol.h"
#include "vector.h"

#ifdef MUDLLE_USE_LLVM
#include "llvm.h"
#endif

#include "../compile.h"
#include "../mcompile.h"
#include "../mtree.h"
#include "../table.h"
#include "../tree.h"


TYPEDOP(functionp, "function?", "`x -> `b. True if `x is a function;"
        " cf. `callable?().",
        (value v),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "x.n")
{
  return makebool(is_function(v));
}

TYPEDOP(callablep, "callable?", "`f `n -> `b. True if function `f"
        " can be called with `n arguments; cf. `function?().",
        (value f, value mnargs),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "fn.n")
{
  long nargs;
  CHECK_TYPES(f,      CT_FUNCTION,
              mnargs, CT_RANGE(nargs, 0, LONG_MAX));
  return makebool(callablep(f, nargs));
}

TYPEDOP(may_callp, "may_call?", "`f -> `b. True if the caller is allowed to"
	" call `f without a security violation due to minlevel.", (value f),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "f.n")
{
  CHECK_TYPES(f, CT_FUNCTION);
  return makebool(!minlevel_violator(f, minlevel));
}

FULLOP(apply, ,
       "`f `x1 `x2 ... `v -> `x. Executes `f with arguments `x1, `x2, ... and"
       " tail arguments in `v, returning its result.",
       SPLUS(2), (struct obj *f, value arg0, struct vector *args),
       0, ("f", NULL), 0,
       OP_APPLY, ("fv.x", "fxv.x", "fxxv.x", "fxxxv.x", "fxxxxx*.x"), static)
{
  CHECK_TYPES(f,    CT_FUNCTION,
              arg0, any,
              args, CT_ARGV(0, -1));

  size_t args_len = vector_len(args);
  struct vector *tail = args_len == 0 ? arg0 : args->data[args_len - 1];
  if (!TYPE(tail, vector))
    RUNTIME_ERROR_ARG(args_len + 1, error_bad_type,
                      bad_type_message(tail, type_vector));
  size_t tail_len = vector_len(tail);

  const char *errmsg;
  enum runtime_error err = function_callable(f, &errmsg, args_len + tail_len);
  if (err != error_none)
    RUNTIME_ERROR_ARG(0, err, errmsg);

  bool use_arg0 = args_len == 1;

  struct vector *argv = tail;
  if (args_len > 1
      || (use_arg0 ? call1plus_needs_copy : callv_needs_copy)(f))
    {
      GCPRO(f, arg0, args);
      argv = ALLOC_RECORD_NOINIT(vector, tail_len + args_len);
      UNGCPRO();

      if (args_len == 0)
        tail = arg0;            /* in case of GC */
      else
        {
          tail = args->data[args_len - 1]; /* in case of GC */
          argv->data[0] = arg0;
          memcpy(&argv->data[1], &args->data[0],
                 sizeof (value) * (args_len - 1));
        }
      memcpy(&argv->data[args_len], &tail->data[0], sizeof (value) * tail_len);
      use_arg0 = false;
    }

  if (f->type == type_closure)
    return use_arg0 ? call1plus(f, arg0, argv): callv(f, argv);

  struct primitive *prim = (struct primitive *)f;

  struct {
    struct call_stack_c_header c;
    value args[MAX_PRIMITIVE_ARGS];
  } me = {
    .c = {
      .s = {
        .next = call_stack,
        .type = call_c
      },
      .u.prim = prim,
      .nargs = use_arg0
    }
  };

  value *dst = me.args;
  if (use_arg0)
    *dst++ = arg0;

  if (f->type == type_varargs)
    {
      *dst++ = argv;
      ++me.c.nargs;
    }
  else
    {
      long nargs = vector_len(argv);
      me.c.nargs += nargs;
      memcpy(dst, argv->data, nargs * sizeof argv->data[0]);
    }

  call_stack = &me.c.s;
  value r = use_arg0 ? call1plus(f, arg0, argv) : callv(f, argv);
  call_stack = me.c.s.next;
  return r;
}

static value do_eval(value input, struct table *cache, enum parser_mode pmode)
{
  bool user_syms = false;

  ASSERT_NOALLOC_START();

  size_t nlines;
  struct string **strs;
  if (TYPE(input, string))
    {
      nlines = 1;
      strs = (struct string **)&input;
    }
  else
    {
      assert(TYPE(input, vector));
      struct vector *iv = input;
      nlines = vector_len(iv);
      strs = (struct string **)&iv->data[0];
      for (size_t i = 0; i < nlines; ++i)
        TYPEIS(strs[i], string);
    }
  struct cstrlen *lines = nlines ? malloc(nlines * sizeof *lines) : NULL;
  for (size_t i = 0; i < nlines; ++i)
    lines[i] = cstrlen_from_mstr(strs[i]);

  ASSERT_NOALLOC();

  bool is_const = (pmode == parser_mode_constant
                   || pmode == parser_mode_storable);

  const struct parser_config pconfig = {
    .filename = {
      .filename = "<eval>",
      .nicename = "<eval>"
    },
    .pmode       = pmode,
    .nstrs       = nlines,
    .strs        = lines,
    .user_syms   = user_syms,
    .no_messages = is_const
  };

  struct compiler_state cstate;
  push_compiler_state(&cstate, &pconfig);

  collect_compiler_messages();

  struct mfile *f = NULL;
  struct constant *c = NULL;
  bool ok = is_const ? parse_constant(&c, &pconfig) : parse(&f, &pconfig);

  ASSERT_NOALLOC();
  send_compiler_messages();

  free(lines);

  value result = makebool(false);
  enum runtime_error error = error_none;
  const char *errmsg = NULL;
  struct closure *closure = NULL;

  if (pmode == parser_mode_constant || pmode == parser_mode_storable)
    {
      if (ok)
        result = alloc_list(make_shared_string_constant(c, cache), NULL);
      goto done;
    }

  if (!ok)
    {
      if (!user_syms)
        error = error_compile;
      goto done;
    }

  if (f->vclass != f_plain)
    {
      error = error_bad_value;
      errmsg = (f->vclass == f_library
                ? "cannot eval libraries"
                : "cannot eval modules");
      goto done;
    }

  if (mstart(cstate.block, f, get_seclevel()))
    {
      closure = compile_code(f, get_seclevel());
      mstop(f);
    }

 done:
  pop_compiler_state(&cstate);

  if (closure != NULL)
    return alloc_list(call0(closure), NULL);
  if (error != error_none)
    runtime_error_message(error, errmsg);
  return result;
}

#  define EVAL_NAME "ieval"
SECOP(eval, EVAL_NAME,
      "`s|`v -> list(`x)|false. Execute the expression in `s, or a vector"
      " of strings `v, and return its result as list(`x).\n"
      "On compile error, the message is printed using `display() and"
      " false is returned.",
      (value expr), 1, OP_TRACE, "[sv].[zk]")
{
  CHECK_TYPES(expr, CT_TYPES(string, vector));
  return do_eval(expr, NULL, parser_mode_file);
}

VAROP(read_constant, ,
      "`s|`v [`t|null `b] -> `p|false. Evaluate `s (or `v, a vector of"
      " strings) as a constant and return its value `x as list(`x).\n\n"
      "`t is a table (or ctable) of shared strings. If a string for which `t"
      " has has a symbol, a new string is not created. Unless `t is a ctable,"
      " the resulting string may then have different case or accents.\n\n"
      "If `t is writable, any newly created strings are added to `t"
      " (with value true).\n\n"
      "`t can be null (default) to disable string sharing.\n\n"
      "The input will be interpreted as if it started with an apostrophe (')"
      " and cannot contain any comma-prefixed expressions.\n\n"
      "If `b is true, allow access modes \"#ro\", \"#rw\", and \"#im\". This"
      " allows readnig an object written with `fmt_flag_storable; cf."
      " `pformat_object(). The default is false.\n\n"
      "On syntax error, false is returned.\n\n"
      "See also `pwrite_constant().",
      (value expr, struct vector *argv), 0,
      ("[sv].[zk]", "[sv][tu].[zk]", "[sv][tu]x.[zk]"))
{
  CHECK_TYPES(expr,   CT_TYPES(string, vector),
              argv,   CT_ARGV(0, 2));

  struct table *scache = NULL;
  enum parser_mode pmode = parser_mode_constant;
  switch (vector_len(argv))
    {
    case 2:
      if (istrue(argv->data[1]))
        pmode = parser_mode_storable;
      FALLTHROUGH;
    case 1:
      scache = argv->data[0];
      if (scache != NULL && !TYPE(scache, table))
        RUNTIME_ERROR_ARG(
          1, error_bad_type,
          bad_typeset_message(scache, TSET(null) | TSET(table)));
      FALLTHROUGH;
    case 0:
      break;
    default: abort();
    }
  return do_eval(expr, scache, pmode);
}

TYPEDOP(call_trace, , "`n `b -> `v. Returns current call trace at most to"
        " depth `n.\n"
        "Each entry is either a function, a machine code object (`type_mcode),"
        " or a string.\n"
        "If `b is true, each entry becomes cons(`called, `line), where"
        " `line is null if unknown.",
        (value mmaxdepth, value mlines_p),
        OP_NOESCAPE | OP_LEAF, "nx.v")
{
  size_t maxdepth;
  CHECK_TYPES(mmaxdepth, CT_RANGE(maxdepth, 1, SIZE_MAX),
              mlines_p,  any);
  return get_mudlle_call_trace(maxdepth, istrue(mlines_p));
}

TYPEDOP(maxseclevel, ,
        "-> `n. Returns the current maxseclevel, which is the highest"
        " secure primitive seclevel that currently may be called."
        " Cf. `effective_seclevel().",
        (void), OP_LEAF | OP_NOALLOC | OP_NOESCAPE, ".n")
{
  return m_maxseclevel();
}

TYPEDOP(trace_seclevel, ,
        "-> `n. Returns the security level for viewing call traces generated"
        " by the current session.\n"
        "Cf. `with_maxseclevel().",
        (void), OP_LEAF | OP_NOALLOC | OP_NOESCAPE, ".n")
{
  return makeint(trace_seclevel());
}

SECOP(effective_seclevel, ,
      "-> `n. Returns the effective seclevel used for security checks"
      " when calling secure primitives. This is the lowest value"
      " of `maxseclevel() and `seclevel().",
      (void), 1, OP_LEAF | OP_NOALLOC | OP_NOESCAPE, ".n")
{
  return makeint(get_effective_seclevel());
}

TYPEDOP(error, , "`n -> . Causes error `n", (value merrno),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "n.")
{
  enum runtime_error n;
  CHECK_TYPES(merrno, CT_RANGE(n, 0, last_runtime_error - 1));
  runtime_error_message_hide_tos(n, NULL, THIS_OP);
}

TYPEDOP(error_message, , "`n `s -> . Displays `s and causes error `n.",
        (value merrno, struct string *mstr),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY, "ns.")
{
  enum runtime_error n;
  CHECK_TYPES(merrno, CT_RANGE(n, 0, last_runtime_error - 1),
              mstr,   string);
  LOCAL_C_STR(msg, mstr, 1024);
  runtime_error_message_hide_tos(n, msg, THIS_OP);
}

TYPEDOP(fail_no_match, , "`x -> . Cause `error_no_match for invalid value `x.",
        (value mvalue),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "x.")
{
  no_match_error(mvalue);
  abort();
}

TYPEDOP(warning, , "`s -> . Prints the warning message `s and a stack trace.",
        (struct string *mstr),
        OP_STR_READONLY, "s.")
{
  CHECK_TYPES(mstr, string);
  LOCAL_C_STR(msg, mstr, 1024);
  runtime_warning(msg, THIS_OP);
  undefined();
}

TYPEDOP(compiledp, "compiled?",
        "-> `b. Returns true if called from compiled code, ignoring"
        " levels of primitives.",
        (void), OP_LEAF | OP_NOALLOC | OP_NOESCAPE, ".n")
{
  struct call_stack *cstack = call_stack;
  while (cstack && cstack->type == call_c)
    cstack = cstack->next;
  return makebool(cstack && cstack->type == call_compiled);
}

TYPEDOP(max_loop_count, ,
        "-> `n. Returns the maximum loop count before an `error_loop is"
        " generated. See `loop_count().",
        (void),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE, ".n")
{
  return makeint(MAX_LOOP_COUNT);
}

TYPEDOP(loop_count, ,
        "-> `n. Returns the current loop counter. This counter is"
        " decremented at every function call and every iteration of a loop"
        " statement. When `n reaches 0, an `error_loop is generated.\n"
        "A good way to test for whether we are approaching an error is"
        " 0 < `n && `n < 1000, or (`max_loop_count() >> 8) instead"
        " of 1000.",
        (void),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE, ".n")
{
  return makeint(get_xcount());
}

TYPEDOP(stack_space, ,
        "-> `n. Returns the number of bytes of stack space available until the"
        " `error_recurse recursion limit is reached.",
        (void), OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_TRIVIAL, ".n")
{
  ulong n = 0;
  if (get_stack_pointer() >= mudlle_stack_limit)
    n = MIN(get_stack_pointer() - mudlle_stack_limit, MAX_TAGGED_INT);
  return makeint(n);
}

struct call0_data {
  struct string *name;
  value func;
  value result;
};

static void docall0(void *_data)
{
  struct call0_data *data = _data;
  data->result = call0(data->func);
}

static void docall0_named(void *_data)
{
  struct call0_data *data = _data;
  struct call_stack_c_header me = {
    .s = {
      .next = call_stack,
      .type = call_mstring,
    },
    .u.mstring = data->name,
    .nargs  = 0
  };
  call_stack = &me.s;
  data->result = call0(data->func);
  call_stack = me.s.next;
}

TYPEDOP(rethrow_error, ,
        "-> . Call from the error handler in `trap_error() to continue"
        " propagating the error.",
        (void), 0, ".")
{
  if (session_context->rethrow_error == error_none)
    runtime_error_message(
      error_abort, "not called from a trap_error() error handler");

  mthrow(SIGNAL_ERROR, session_context->rethrow_error);
}

/* calls f() and returns value in "result"

   if f() causes an error:
     for loop errors, re-raise the error

     if handler is non-null, call handler(errno) and returns its value

     if handler is null, return errno
 */
static value trap_error(value f, value handler, struct string *desc,
                        enum call_trace_mode call_trace_mode)
{
  ulong cur_xcount = get_xcount();
  ulong saved_xcount = cur_xcount / 10 + 100;
  if (saved_xcount > cur_xcount)
    saved_xcount = cur_xcount;
  set_xcount(cur_xcount - saved_xcount);

  enum runtime_error old_rethrow_error = session_context->rethrow_error;
  session_context->rethrow_error = error_none;

  {
    struct call0_data d = { .func = f, .name = desc };
    GCPRO(handler);
    bool ok = mcatch(desc ? docall0_named : docall0, &d, call_trace_mode);
    UNGCPRO();

    /* careful in case f() called with_unlimited_execution() */
    cur_xcount = get_xcount();
    set_xcount(cur_xcount > MAX_TAGGED_INT - saved_xcount
               ? MAX_TAGGED_INT
               : cur_xcount + saved_xcount);

    if (ok)
      return d.result;
  }

  if (mexception.sig == SIGNAL_ERROR)
    {
      enum runtime_error err = mexception.err;
      /* if we are really out of loop space, rethrow the error */
      if (err == error_loop && get_xcount() == 0)
        goto propagate;

      if (handler == NULL)
        return makeint(err);

      session_context->rethrow_error = err;
      value r = call1(handler, makeint(err));
      session_context->rethrow_error = old_rethrow_error;
      return r;
    }

 propagate:
  mrethrow();
}

TYPEDOP(trap_error, ,
        "`f0 `f1|null `n `s|null -> `x. Executes `f0() and returns its return"
        " value.\n\n"
        "If an error occurs in `f0(), calls `f1(`errno) and returns its"
        " return value instead. If `f1() calls `rethrow_error(), the error"
        " will continue propagating.\n\n"
        "If `f1 is null, return the error number instead (an `error_xxx"
        " constant).\n\n"
        "By default, call traces are sent to the `with_output() target"
        " as well as observers added using `add_call_trace_port!().\n\n"
        "`n controls how call traces are sent from `f0():\n"
        "  `call_trace_off      \tdo not send call traces to anyone\n"
        "  `call_trace_barrier  \tonly print call traces down to the"
        " current stack level\n"
        "  `call_trace_on       \tprint complete call traces\n\n"
        "`s is an (optional) extra description that will be inserted"
        " in any call trace",
        (value f, value handler, value ct_mode, struct string *mstr),
        OP_TRACE | OP_STR_READONLY, "f[fu]n[su].x")
{
  long call_trace_mode;
  CHECK_TYPES(f,       CT_CALLABLE(0),
              handler, OR(null, CT_CALLABLE(1)),
              ct_mode, CT_INT(call_trace_mode),
              mstr,    OR(null, string));

  if (call_trace_mode != call_trace_off
      && call_trace_mode != call_trace_barrier
      && call_trace_mode != call_trace_on)
    RUNTIME_ERROR_ARG(2, error_bad_value, "invalid call trace mode");

  return trap_error(f, handler, mstr, call_trace_mode);
}

SECOP(with_minlevel, ,
      "`n `c -> `x. Call `c() with the minimum function security level"
      " set to `n and return its result, where 0 <= `n <= the calling"
      " closure's `function_seclevel().\n"
      "No closure whose `function_seclevel() is less than `n can be called"
      " from `c(), or an `error_security_violation will be caused.\n"
      "Returns the return value of `c().",
      (value mlvl, value f), 1, OP_APPLY, "nf.x")
{
  seclev_t new_minlevel;
  CHECK_TYPES(mlvl, CT_RANGE(new_minlevel, 0, LVL_IMPLEMENTOR),
              f,    CT_CALLABLE(0));
  if (new_minlevel > get_seclevel())
    RUNTIME_ERROR(error_security_violation, NULL);

  seclev_t old_minlevel = minlevel;
  minlevel = new_minlevel;
  value r = call0(f);
  minlevel = old_minlevel;

  return r;
}

#define FORBID_DOC(what, spc)                                   \
  "  `forbid_" #what spc "  \t" FORBID_MSG_ ## what "\n"

CASSERT(forbid_all == P(6) - 1); /* add documentation below otherwise */

TYPEDOP(with_forbid, ,
        "`n `c -> `x. Call `c(), forbidding actions in `n, bitwise OR of"
        " `forbid_xxx flags (or `forbid_all for all of them):\n"
        FORBID_DOC(create, "  ")
        FORBID_DOC(exec, "    ")
        FORBID_DOC(follow, "  ")
        FORBID_DOC(move, "    ")
        FORBID_DOC(position, "")
        FORBID_DOC(purge, "   ")
        "Returns the return value of `c().",
        (value mforbid, value f), OP_APPLY, "nf.x")
{
  unsigned forbid_what;
  CHECK_TYPES(mforbid, CT_RANGE(forbid_what, 0, forbid_all),
              f,       CT_CALLABLE(0));
  PUSH_FORBID(what);            /* super-hacky */
  value r = call0(f);
  POP_FORBID();
  return r;
}

#define MSL_TRACE_LEVEL_SHIFT 16

SECOP(with_maxseclevel, ,
      "`n `c -> `x. Temporarily change `maxseclevel() to `n"
      " (or `LVL_IMPLEMENTOR if `n >= `LVL_VALA), then calls `c()"
      " and returns its result.\n\n"
      "`n can optionally be bitwise OR with the call trace security level"
      " shifted left `msl:`trace_seclevel_shift. Cf. `trace_seclevel().\n\n"
      "Use this function in your code to make it available to Ms- even if you"
      " need to call secure primitives.\n"
      "The typical invocation is:\n"
      "   \t`with_maxseclevel(\t`seclevel(), fn () secure_call(...))",
      (value mlvl, value f), 1, OP_APPLY, "nf.x")
{
  long new_maxseclev;
  CHECK_TYPES(mlvl, CT_INT(new_maxseclev),
              f,    CT_CALLABLE(0));

  long new_tracelev = new_maxseclev >> MSL_TRACE_LEVEL_SHIFT;
  new_maxseclev &= P(MSL_TRACE_LEVEL_SHIFT) - 1;

  if (new_maxseclev < MIN_SECLEVEL || new_maxseclev > MAX_SECLEVEL)
    RUNTIME_ERROR_ARG(0, error_bad_value, "invalid max security level");
  if (new_tracelev != 0
      && (new_tracelev < MIN_SECLEVEL || new_tracelev > MAX_SECLEVEL))
    RUNTIME_ERROR_ARG(0, error_bad_value, "invalid call trace security level");

  if (new_maxseclev > get_seclevel() || new_tracelev > get_seclevel())
    RUNTIME_ERROR(error_security_violation, NULL);

  seclev_t old_trace_level = trace_seclevel();
  if (new_tracelev)
    set_trace_seclevel(new_tracelev);

  /* The compiled mudlle code paths assume that maxseclevel is set to
   * MAX_SECLEVEL (ie. noop) if it shouldn't be checked. */
  if (new_maxseclev >= LEGACY_SECLEVEL)
    new_maxseclev = MAX_SECLEVEL;

  value old_maxseclev = m_maxseclevel();
  set_c_maxseclevel(new_maxseclev);
  value r = call0(f);
  set_m_maxseclevel(old_maxseclev);
  set_trace_seclevel(old_trace_level);

  return r;
}

UNSAFEOP(with_unlimited_execution, ,
         "`c -> `x. Call `c() with stack and loop limits set to the maximum"
         " allowed and return its return value.",
         (value f), OP_APPLY, "f.x")
{
  CHECK_TYPES(f, CT_CALLABLE(0));
  ulong old_mudlle_stack_limit = mudlle_stack_limit;
  ulong old_xcount = get_xcount();
  unlimited_execution();
  value r = call0(f);
  set_xcount(old_xcount);
  mudlle_stack_limit = old_mudlle_stack_limit;
  return r;
}

TYPEDOP(setjmp, ,
        "`f -> `x. Executes `f(`buf). `buf can be used with `longjmp(). The"
        " return value is either the result of `f(`buf), or the value `x1"
        " passed to `longjmp(`buf, `x1)",
        (value f), 0, "f.x")
{
  CHECK_TYPES(f, CT_CALLABLE(1));
  return msetjmp(f);
}

TYPEDOP(longjmp, ,
        "`buf `x -> . Returns `x from the `setjmp() that created `buf",
        (value mjmpbuf, value x), 0, "ox.")
{
  if (!is_mjmpbuf(mjmpbuf))
    runtime_error(error_bad_value);

  mlongjmp(mjmpbuf, x);
}

UNSAFEOP(session, , "`f -> . Calls `f() in its own session and return its"
         " result.\n"
         "A session has its own loop and stack depth limits;"
         " cf. `loop_count().\n"
         "If `f() causes an error, return null.",
         (value f), OP_APPLY, "f.x")
{
  CHECK_TYPES(f, CT_CALLABLE(0));

  struct session_context newc;
  session_start(&newc,
                &(const struct session_info){
                  .minlevel    = minlevel,
                  .maxseclevel = c_maxseclevel(),
                  .mout        = mudout(),
                  .merr        = muderr() });
  value aresult = mcatch_call(NULL, f);
  session_end();

  return aresult;
}

EXT_TYPEDOP(ref, ,
            "`x1 `x2 -> `x3. Generic interface to lookup operations:"
            " `x1[`x2] -> `x3. See `set!() for allowed types.",
            (value x1, value x2), (x1, x2),
            OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_OPERATOR,
            ("vn.x", "sn.n", "[ton]s.x"))
{
  if (!pointerp(x1)) goto bad_type;
  switch (((struct obj *)x1)->type)
    {
    case type_vector:
      return vector_ref(x1, x2, THIS_OP);
    case type_string:
      return string_ref(x1, x2, THIS_OP);
    case type_table:
      return table_ref(x1, x2, THIS_OP);
    default:
      goto bad_type;
    }
 bad_type:
  ref_bad_type_error(x1, x2);
}

#define SYMBOL_REF_EXTRA_TYPES ""

TYPEDOP(symbol_ref, ,
        "`x `s -> `sym. Returns the symbol for `x[`s], creating it if"
        " necessary. `x can be a table" SYMBOL_REF_EXTRA_TYPES ".",
        (value x, struct string *s),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "[ton]s.y")
{
  CHECK_TYPES(x, any,
              s, string);
  struct table *t;

  if (integerp(x))
    {
    }
  else if (x == NULL)
    ;
  else
    switch (((struct obj *)x)->type)
      {
      case type_table:
        t = x;
        goto ok;
      default:
        break;
      }

  RUNTIME_ERROR(error_bad_type, NULL);

 ok:
  return table_symbol_ref(t, s, NULL);
}

const struct prim_op *const ref_prim_ext = &op_ref;

void ref_bad_type_error(value x1, value x2)
{
  primitive_runtime_error(error_bad_type, &op_ref, 2, x1, x2);
}

#define SET_EXTRA_TYPES " or a table"

EXT_TYPEDOP(setb, "set!",
            "`x1 `x2 `x3 -> `x3. Generic set operation: `x1[`x2] = `x3.\n"
            "`x1 can be a vector or a string (`x2 is the integer index,"
            " where negative values are counted from the end)"
            SET_EXTRA_TYPES
            " (`x2 is the string symbol name).\n"
            "For string `x1, `x3 must be an integer and the returned"
            " value is the stored value (`x3 & 255).",
            (value x1, value x2, value x3), (x1, x2, x3),
            OP_LEAF | OP_NOESCAPE | OP_OPERATOR,
            ("vnx.3", "snn.n", "[ton]sx.3"))
{
  if (!pointerp(x1)) goto bad_type;
  switch (((struct obj *)x1)->type)
    {
    case type_vector:
      return vector_set(x1, x2, x3, THIS_OP);
    case type_string:
      return mudlle_string_set(x1, x2, x3, THIS_OP);
    case type_table:
      return do_table_set(x1, x2, x3, THIS_OP);
    default:
      goto bad_type;
    }
 bad_type:
  set_bad_type_error(x1, x2, x3);
}

const struct prim_op *const setb_prim_ext = &op_setb;

void set_bad_type_error(value x1, value x2, value x3)
{
  primitive_runtime_error(error_bad_type, &op_setb, 3, x1, x2, x3);
}

static void free_weak_mref(void *data)
{
}

TYPEDOP(weak_deref, , "`r -> `x. Returns the value of the weak reference `r."
        " Cf. `weak_ref().",
        (struct mweak_ref *ref), 0, "o.x")
{
  CHECK_TYPES(ref, weak_ref);
  return ref->v;
}

TYPEDOP(weak_ref, , "`x -> `r. Return a weak reference to `x, which"
        " is read using `weak_deref(`r).\n"
        "If only weak references exist to a mudlle object, the next garbage"
        " collection may free the object and `weak_deref(`r) will return a"
        " gone object.",
        (value x), OP_LEAF | OP_NOESCAPE, "x.o")
{
  GCPRO(x);
  struct mweak_ref *r = (struct mweak_ref *)alloc_weak_ref(
    type_weak_ref, sizeof *r, NULL, free_weak_mref);
  UNGCPRO();
  r->v = x;
  return r;
}

/* "Object" manipulation:
   load, save, size
   protect, test status, etc
*/

/* MDATA_MAGIC + MDATA_VER_xxx is the actual magic number */
#define MDATA_MAGIC         0x871f54ab  /* just a random number */

static value do_save_data(struct string *file, value x,
                          int (*rename_fn)(const char *oldpath,
                                           const char *newpath),
                          const struct prim_op *op)
{
  CHECK_TYPES_OP(op,
                 file, CT_PATHNAME,
                 x,    any);
  char *fname;
  ALLOCA_PATH(fname, file);


  size_t size;
  const void *data = gc_save(x, &size);

  assert(size <= SSIZE_MAX && size <= UINT32_MAX);

  static const char tpattern[] = "%s.XXXXXX";
  size_t tmplen = strlen(fname) + strlen(tpattern) - 2 /* %s */;
  char tmpname[tmplen + 1];
  if (snprintf(tmpname, sizeof tmpname, tpattern, fname) != (int)tmplen)
    abort();

  const char *errmsg = NULL;

  int fd = mkstemp(tmpname);
  if (fd < 0)
    {
      errmsg = errno_message(errno, "opening temporary file");
      goto failed;
    }

  uint32_t magic   = htonl(MDATA_MAGIC + MDATA_VER_CURRENT);
  uint32_t nsize   = htonl(size);
  bool ok = (write(fd, &magic, sizeof magic) == sizeof magic
             && write(fd, &nsize, sizeof nsize) == sizeof nsize
             && write(fd, data, size) == (ssize_t)size);
  if (!ok)
    errmsg = errno_message(errno, "writing temporary file");


  /* set mode to a+rw modified by umask */
  fchmod(fd, S_IRWUGO & ~get_umask());

  close(fd);

  if (ok && rename_fn(tmpname, fname) != 0)
    {
      errmsg = errno_message(errno, "renaming temporary file");
      ok = false;
    }


  if (!ok)
    unlink(tmpname);

 failed:


  if (errmsg != NULL)
    RUNTIME_ERROR(error_bad_value, errmsg);

  undefined();
}

UNSAFEOP(save_data, , "`s `x -> . Writes mudlle value `x to file `s.\n"
         "Cf. `load_data().",
         (struct string *file, value x),
         OP_LEAF | OP_NOESCAPE, "sx.")
{
  return do_save_data(file, x, rename, THIS_OP);
}

UNSAFEOP(load_data, , "`s -> `x. Loads a value from the mudlle save file `s.\n"
         "Cf. `save_data().",
         (struct string *mfile),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "s.x")
{
  CHECK_TYPES(mfile, CT_PATHNAME);


  const char *errmsg = NULL;

  int fd = open(mfile->str, O_RDONLY);
  if (fd < 0)
    {
      errmsg = errno_message(errno, "opening file");
      goto failed_open;
    }

  errmsg = "does not contain mudlle data";

  uint32_t magic;
  if (read(fd, &magic, sizeof magic) != sizeof magic)
    goto failed;
  magic = ntohl(magic);

  uint32_t v = magic - MDATA_MAGIC;
  if (v > MDATA_VER_CURRENT)
    goto failed;
  enum mudlle_data_version version = v;

  errmsg = "invalid mudlle data";

  uint32_t size;
  if (read(fd, &size, sizeof size) != sizeof size)
    goto failed;
  size = ntohl(size);

  char *data = malloc(size);
  if (read(fd, data, size) == size)
    {
      close(fd);
      value res = gc_load(data, size, version);
      free(data);
      return res;
    }
  free(data);

 failed:
  close(fd);

 failed_open:


  runtime_error_message(error_bad_value, errmsg);
}

TYPEDOP(size_data, ,
        "`x -> `v. Return the size of object `x in bytes as"
        " vector(`total, `mutable, `static).\n"
        "Throws `error_bad_value if out of memory.", (value x),
        OP_LEAF | OP_NOESCAPE, "x.v")
{
  struct gc_size size;
  if (!gc_size(x, &size))
    runtime_error(error_bad_value);
  struct vector *v = alloc_vector(3);
  v->data[0] = makeint(size.s_total);
  v->data[1] = makeint(size.s_mutable);
  v->data[2] = makeint(size.s_static);
  return v;
}

UNSAFEOP(staticpro_data, , "-> `v. Returns a vector of all statically"
         " protected data", (void), OP_LEAF | OP_NOESCAPE, ".v")
{
  return get_staticpro_data();
}

UNSAFEOP(dynpro_data, , "-> `l. Returns a list of all dynamically"
         " protected data as vector(`x, `s, `n).",
         (void), OP_LEAF | OP_NOESCAPE, ".l")
{
  return get_dynpro_data();
}

UNSAFEOP(all_code, , "-> `v. Return a vector of all defined"
         " primitives, icode and mcode objects.",
         (void), OP_LEAF | OP_NOESCAPE, ".v")
{
  return all_mudlle_code();
}

TYPEDOP(immutablep, "immutable?",
        "`x -> `b. Returns true if `x is an immutable value",
	(value x),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "x.n")
{
  return makebool(immutablep(x));
}

TYPEDOP(compiler_stable_closurep, "compiler_stable_closure?",
        "`x -> `b. Internal compiler predicate for stable backend closures.",
        (value x), OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "x.b")
{
#ifdef MUDLLE_USE_LLVM
  return makebool(llvm_stable_closure(x));
#else
  return makebool(false);
#endif
}

TYPEDOP(readonlyp, "readonly?",
        "`x -> `b. Returns true if `x is a read-only value",
	(value x),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "x.n")
{
  return makebool(readonlyp(x));
}

TYPEDOP(protect, , "`x -> `x. Makes object `x readonly."
        " Outport ports will silently not be made readonly. Cf. `rprotect().",
	(struct obj *x),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "x.1")
{
  if (staticp(x))
    return x;

  switch (x->type)
    {
    case type_table:
      protect_table((struct table *)x);
      break;
    case type_oport:
      break;
    default:
      x->flags |= OBJ_READONLY;
    }

  return x;
}

enum rprotect_result {
  r_no,                         /* is mutable */
  r_maybe,                      /* has non-trivial recursion */
  r_yes                         /* was (made) immutable */
};

/* if 'force', also make non-trivially recursive data immutable */
static enum rprotect_result rprotect(value v, bool force)
{
  if (!pointerp(v))
    return r_yes;
  struct grecord *rec = v;
  if (!obj_readonlyp(v))
    {
      if (rec->o.type == type_oport)
        return r_no;
      rec->o.flags |= OBJ_READONLY;
    }
  if (rec->o.flags & OBJ_IMMUTABLE)
    return r_yes;
  if (rec->o.flags & OBJ_FLAG_0) /* found recursion */
    return r_maybe;
  switch (rec->o.type)
    {
    case type_pair:
    case type_vector:
    case type_symbol:
    case type_table:
      {
        /* Use FLAG_0 to indicate that we've already been here and to
           prevent infinite recursion. */
        rec->o.flags |= force ? OBJ_IMMUTABLE : OBJ_FLAG_0;
        enum rprotect_result r = r_yes;
        for (size_t i = 0, len = grecord_len(rec); i < len; ++i)
          {
            value v2 = rec->data[i];
            if (v == v2)
              continue;         /* trivially self-recursive */
            enum rprotect_result r2 = rprotect(v2, force);
            if (r2 < r)
              r = r2;
          }
        if (force)
          assert(r == r_yes);
        else
          {
            rec->o.flags &= ~OBJ_FLAG_0;
            if (r == r_yes)
              rec->o.flags |= OBJ_IMMUTABLE;
          }
        return r;
      }
    default:
      return r_no;
    }
}

TYPEDOP(rprotect, , "`x -> `x. Recursively (for pairs, vectors, symbols, and"
        " tables) makes value `x readonly and, if possible, immutable.\n"
        "Outport ports will silently not be made readonly.\n"
        "The recursion stops at immutable objects, so any strings only"
        " reachable through immutable objects will not be made readonly.\n"
        "Cf. `protect().",
	(value x), OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "x.1")
{
  if (rprotect(x, false) == r_maybe
      && rprotect(x, true) != r_yes)
    abort();
  return x;
}

UNSAFEOP(detect_immutability, , "-> . Detects immutable values.",
         (void),
         OP_LEAF | OP_NOESCAPE, ".")
{
  detect_immutability();
  undefined();
}

TYPEDOP(check_immutable, , "`x -> `x. Makes `x immutable if possible without"
        " recursion.", (value x),
        OP_LEAF | OP_NOESCAPE, "x.1")
{
  if (!pointerp(x))
    return x;
  if (TYPE(x, table))
    return try_make_table_immutable(x);
  try_make_immutable(x);
  return x;
}

TYPEDOP(typeof, , "`x -> `n. Return type of `x, one of the `type_xxx"
        " constants. Cf. `mudlle_types and `type_names.",
	(value x),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "x.n")
{
  return makeint(TYPEOF(x));
}

SECOP(seclevel, , "-> `n. Returns the current value of the global seclevel"
      " variable.\n"
      "When called directly from a closure, this returns that closure's"
      " `function_seclevel().\n"
      "All function calls from inside closures except those to regular"
      " (non-secure and non-vararg) primitives set seclevel.\n"
      "Use `with_minlevel() and `minlevel() if you need to write secure"
      " functions in mudlle.\n"
      "Cf. `effective_seclevel().",
      (void),
      1, OP_LEAF | OP_NOALLOC | OP_NOESCAPE, ".n")
{
  return makeint(get_seclevel());
}

TYPEDOP(minlevel, , "-> `n. Returns the minimum security level of the"
	" current session. Calling a function with seclevel less than"
	" minlevel will result in a security violation error.", (void),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, ".n")
{
  return makeint(minlevel);
}

#ifdef ALLOC_STATS

UNSAFEOP(alloc_stats, , "-> `v", (void), OP_LEAF | OP_NOESCAPE,
         ".v")
{
  return get_alloc_stats();
}

#endif

TYPEDOP(uname, , "-> `v. Returns a vector of strings of system information,"
        " indexed by `un_xxx:\n"
        "  `un_sysname  \toperating system name\n"
        "  `un_release  \toperating system release\n"
        "  `un_version  \toperating system version\n"
        "  `un_machine  \thardware identifier",
        (void), OP_LEAF | OP_NOESCAPE, ".v")
{
  CHECK_TYPES();

  struct utsname u;
  if (uname(&u) != 0)
    RUNTIME_ERROR(error_abort, errno_message(errno, "uname()"));

  struct vector *v = alloc_vector(un_fields);
  GCPRO(v);
  SET_VECTOR(v, un_sysname, alloc_string(u.sysname));
  SET_VECTOR(v, un_release, alloc_string(u.release));
  SET_VECTOR(v, un_version, alloc_string(u.version));
  SET_VECTOR(v, un_machine, alloc_string(u.machine));
  CASSERT(un_fields == 4);
  UNGCPRO();
  return v;
}

void basic_init(void)
{
  DEFINE(functionp);
  DEFINE(callablep);
  DEFINE(may_callp);

  DEFINE(error);
  DEFINE(error_message);
  DEFINE(fail_no_match);
  DEFINE(warning);
  DEFINE(trap_error);
  DEFINE(rethrow_error);

  DEFINE(with_minlevel);
  DEFINE(with_maxseclevel);
  DEFINE(with_unlimited_execution);

  STATIC_STRING(sstr_seclev_globals, "SECLEVEL_GLOBALS");
  system_write(GET_STATIC_STRING(sstr_seclev_globals),
               makeint(SECLEVEL_GLOBALS));

  DEFINE_INT(call_trace_off);
  DEFINE_INT(call_trace_barrier);
  DEFINE_INT(call_trace_on);

  define_string_vector("error_messages", mudlle_errors, last_runtime_error);

  FOR_MUDLLE_TYPES(DEFINE_INT, SEP_SEMI);

  /* just a subset */
  system_define("TSET_CHAR", makeint(1 << type_character));
  system_define("TSET_INT",  makeint(1 << type_integer));
  system_define("TSET_NULL", makeint(1 << type_null));
  system_define("TSET_OBJ",  makeint(1 << type_object));
  system_define("TSET_PAIR", makeint(1 << type_pair));
  system_define("TSET_SYM",  makeint(1 << type_symbol));
  system_define("TSET_STR",  makeint(1 << type_string));
  system_define("TSET_TAB",  makeint(1 << type_table));
  system_define("TSET_VEC",  makeint(1 << type_vector));

  define_string_vector(
    "type_names", mudlle_type_names, mudlle_synthetic_types);

  {
    struct vector *v = alloc_vector(mudlle_synthetic_types);
    for (enum mudlle_type t = 0; t < mudlle_synthetic_types; ++t)
      v->data[t] = makeint(type_typeset(t));
    system_define("type_typesets", make_immutable(v));
  }

  DEFINE(setjmp);
  DEFINE(longjmp);

  DEFINE(session);
  DEFINE(apply);
  DEFINE(eval);
  DEFINE(read_constant);

  DEFINE(call_trace);
  DEFINE(max_loop_count);
  DEFINE(loop_count);
  DEFINE(stack_space);
  DEFINE(compiledp);

  DEFINE(typeof);
  DEFINE(immutablep);
  DEFINE(compiler_stable_closurep);
  DEFINE(readonlyp);
  DEFINE(protect);
  DEFINE(rprotect);
  DEFINE(detect_immutability);
  DEFINE(check_immutable);

  DEFINE(size_data);
  DEFINE(staticpro_data);
  DEFINE(dynpro_data);
  DEFINE(save_data);

  DEFINE(all_code);

  DEFINE(load_data);

  DEFINE(symbol_ref);
  DEFINE(ref);
  DEFINE(setb);

  DEFINE(weak_ref);
  DEFINE(weak_deref);

  DEFINE(seclevel);
  DEFINE(minlevel);
  DEFINE(maxseclevel);
  DEFINE(trace_seclevel);
  DEFINE(effective_seclevel);

  system_define("msl:trace_seclevel_shift", makeint(MSL_TRACE_LEVEL_SHIFT));

  DEFINE(with_forbid);

#ifdef ALLOC_STATS
  DEFINE(alloc_stats);
#endif

  DEFINE(uname);
}
