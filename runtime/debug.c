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

#include <sys/resource.h>

#include "debug.h"
#include "mudlle-string.h"
#include "prims.h"
#include "vector.h"

#include "../global.h"
#include "../hash.h"
#include "../print.h"
#include "../strbuf.h"
#include "../utils.h"


static void show_function(struct closure *c);

#  define HELP_PREFIX ""

SECOP(help, HELP_PREFIX "help",
      "`f -> . Prints help on function `f", (value v),
      LVL_VALA, OP_LEAF | OP_NOESCAPE, "x.")
{
  struct primitive *op = v; /* Only valid for type_{sec,prim,va} */
  if (TYPE(v, secure)
      || (TYPE(v, primitive) && op->op->flags & OP_FASTSEC))
    pprintf(mudout(), "Secure %d: %s", op->op->seclevel, op->op->help->str);
  else if (TYPE(v, primitive) || TYPE(v, varargs))
    pputs(op->op->help->str, mudout());
  else if (TYPE(v, closure))
    show_function(v);
  else
    pprintf(mudout(), "This variable isn't executable\n");
  pputc('\n', mudout());
  undefined();
}

SECOP(help_string, ,
      "`f -> `s|null. Returns `f's help string, or null if none.\n"
      "Ms- mudlle can only access closures below its own level.",
      (value f), 1, OP_LEAF | OP_NOESCAPE, "f.[su]")
{
  CHECK_TYPES(f, CT_FUNCTION);
  seclev_t seclev = get_effective_seclevel();

  if (is_any_primitive(f))
    {
      if (seclev < LVL_VALA)
        RUNTIME_ERROR(error_security_violation, NULL);

      struct primitive *op = f;

      if (op->op->flags & OP_CONST)
        {
          size_t len = string_len(op->op->help);
          struct strbuf sb = sb_initf(
            "%s%sMay be evaluated at compile-time%s.",
            op->op->help->str,
            (len == 0
             ? ""
             : op->op->help->str[len - 1] == '.' ? "\n" : ".\n"),
            (op->op == indexed_sequence_ext
             ? ", even if the arguments are mutable pairs"
             : ""));
          struct string *s = strbuf_to_mudlle(&sb);
          sb_free(&sb);
          return s;
        }
      return op->op->help;
    }

  assert(TYPE(f, closure));
  struct closure *c = f;

  if (seclev < LVL_VALA && seclev < c->code->seclevel)
    RUNTIME_ERROR(error_security_violation, NULL);

  return c->code->help;
}

TYPEDOP(defined_in, , "`f -> `v. Returns information on where `f (any"
        " primitive, closure, icode, or mcode) in `v, indexed by `di_xxx:\n"
        "  `di_line      \t1-based line number\n"
        "  `di_column    \t1-based column number\n"
        "  `di_nicename  \tnice name\n"
        "  `di_filename  \tfile name",
        (value f),
        OP_LEAF | OP_NOESCAPE, "[fo].v")
{
  CHECK_TYPES(f, CT_TYPESET(TYPESET_FUNCTION
                            | TSET(mcode) | TSET(icode)));

  struct string *filename, *nicename;
  int column, lineno;

  if (TYPE(f, closure))
    f = ((struct closure *)f)->code;

  if (TYPE(f, icode) || TYPE(f, mcode))
    {
      struct code *code = f;
      nicename = code_nicename(code);
      filename = code_filename(code);
      lineno   = code->lineno;
      column   = code->column;
    }
  else
    {
      assert(is_any_primitive(f));
      struct primitive *prim = f;
      lineno   = prim->op->lineno;
      nicename = filename = alloc_string(prim->op->filename);
      column   = 1;
    }

  GCPRO(filename, nicename);
  struct vector *v = alloc_vector(di_fields);
  UNGCPRO();
  v->data[di_line]     = makeint(lineno);
  v->data[di_column]   = makeint(column);
  v->data[di_nicename] = nicename;
  v->data[di_filename] = filename;
  return v;
}

UNSAFEOP(set_use_nicename, "set_use_nicename!",
         "`b -> . Set whether to (only) use nicenames for call traces and"
         " compiler messages. Cf. `use_nicename().",
         (value enable),
         OP_LEAF | OP_NOESCAPE | OP_NOALLOC, "x.")
{
  use_nicename = istrue(enable);
  undefined();
}

TYPEDOP(use_nicename, , "-> `b. True if (only) nicenames will be used"
        " in call traces and compiler messages. Cf. `set_use_nicename!().",
        (void),
        OP_LEAF | OP_NOESCAPE | OP_NOALLOC, ".n")
{
  return makebool(use_nicename);
}

UNSAFEOP(closure_variables, ,
         "`f -> `v. Returns a vector of the closure variable values of"
         " function `f",
         (struct closure *f),
         OP_LEAF | OP_NOESCAPE, "f.v")
{
  CHECK_TYPES(f, closure);
  ulong nbvar = ((f->o.size - offsetof(struct closure, variables))
                 / sizeof (value));

  GCPRO(f);
  struct vector *res = alloc_vector(nbvar);
  for (ulong i = 0; i < nbvar; ++i)
    res->data[i] = f->variables[i];
  UNGCPRO();

  return res;
}

TYPEDOP(variable_value, , "`v -> `x. Returns the value in variable `v",
        (struct variable *var),
        OP_LEAF | OP_NOESCAPE | OP_NOALLOC | OP_TRIVIAL, "o.x")
{
  CHECK_TYPES(var, variable);
  return var->vvalue;
}

TYPEDOP(function_seclevel, , "`f -> `n. Returns the security level of `f"
        " (any primitive, closure, icode, or mcode).",
	(value f), OP_LEAF | OP_NOESCAPE | OP_NOALLOC, "f.n")
{
  CHECK_TYPES(f, CT_TYPESET(TYPESET_FUNCTION | TSET(mcode) | TSET(icode)));

  if (is_any_primitive(f))
    return makeint(((struct primitive *)f)->op->seclevel);

  struct code *code;
  if (TYPE(f, mcode) || TYPE(f, icode))
    code = (struct code *)f;
  else
    {
      assert(TYPE(f, closure));
      code = ((struct closure *)f)->code;
    }

  return makeint(code->seclevel);
}

TYPEDOP(function_name, , "`f -> `s|false. Returns name of `f (any primitive,"
        " closure, icode, or mcode) if available; false otherwise.",
	(value f),
	OP_LEAF | OP_NOESCAPE | OP_NOALLOC, "[fo].[sz]")
{
  CHECK_TYPES(f, CT_TYPESET(TYPESET_FUNCTION | TSET(mcode) | TSET(icode)));

  if (is_any_primitive(f))
    return ((struct primitive *)f)->op->name;

  struct string *name;
  if (TYPE(f, mcode) || TYPE(f, icode))
    name = ((struct code *)f)->varname;
  else
    {
      assert(TYPE(f, closure));
      struct closure *c = f;
      name = c->code->varname;
    }

  return name ? name : makebool(false);
}

static void show_function(struct closure *c)
{
  struct code *code = c->code;
  if (code->help)
    pswrite(mudout(), code->help);
  else
    pputs("undocumented", mudout());
  pputs(" [", mudout());
  pswrite(mudout(), code_nicename(code));
  pprintf(mudout(), ":%d", code->lineno);
  pputc(']', mudout());
}

#ifdef PROFILE_CALL_COUNT
#define PROFILE_CALL_COUNT_DOC ""
#else
#define PROFILE_CALL_COUNT_DOC \
  "Call count is set for interpreted mudlle; -1 otherwise.\n"
#endif

TYPEDOP(function_call_count, ,
        "`f -> `x. Returns call count information for the function"
        " `f as cons(#`calls, #`instructions).\n"
        PROFILE_CALL_COUNT_DOC
        "The number of instructions executed is set for interpreted"
        " mudlle functions; -1 otherwise.",
        (value f),
        OP_LEAF | OP_NOESCAPE, "[fo].k")
{
  CHECK_TYPES(f, CT_TYPESET(TYPESET_FUNCTION | TSET(icode) | TSET(mcode)));

  long ccount = -1;
  long icount = -1;

  if (is_any_primitive(f))
    {
#ifdef PROFILE_CALL_COUNT
      ccount = *((struct primitive *)f)->op->call_count;
#endif
    }
  else
    {
      if (TYPE(f, closure))
        f = ((struct closure *)f)->code;

      if (TYPE(f, icode))
        {
          struct icode *c = f;
          icount = c->instruction_count;
        }

#ifdef PROFILE_CALL_COUNT
      struct code *c = f;
      ccount = c->call_count;
#endif
    }

  return alloc_list(makeint(ccount), makeint(icount));
}

#define _CT_MPROFILE(edst, v, msg, arg)         \
  if (!is_profile_data(v))                      \
    {                                           \
      *msg = "expected profile data";           \
      edst = error_bad_type;                    \
    }
#define CT_PROFILE F(TSET(private), _CT_MPROFILE, )

UNSAFEOP(collect_profile, , "`f `profile|null -> (`profile . `x)."
         " Calls `f() -> `x, collecting call profile statistics.\n"
         "If `profile is non-null, profile data is added to that profile.\n"
         "Otherwise, a new profile object is created.\n"
         "The function returns cons(`profile, `x) where `x is the return value"
         " from `f().",
         (value f, value mprofile), 0, "f[ou].k")
{
  CHECK_TYPES(f,        CT_CALLABLE(0),
              mprofile, OR(null, CT_PROFILE));
  return profile_call0(f, mprofile);
}

UNSAFEOP(start_profile, , "`profile|null -> `profile. Starts collecting"
         " profile data.\n"
         "If `profile is non-null, profile data is added to that profile.\n"
         "Otherwise, a new profile object is created.",
         (value mprofile), 0, "[ou].o")
{
  CHECK_TYPES(mprofile, OR(null, CT_PROFILE));
  return start_profiling(mprofile);
}

UNSAFEOP(stop_profile, , "`profile -> . Stops collecting profiling data in"
         " `profile.",
         (value mprofile), 0, "o.")
{
  CHECK_TYPES(mprofile, CT_PROFILE);
  stop_profiling(mprofile);
  undefined();
}

TYPEDOP(extract_profile, , "`profile -> `v. Extracts profile information from"
        " `profile into a tree where each node is a vector indexed by"
        " `prof_node_xxx.", (value mprofile), 0, "o.v")
{
  CHECK_TYPES(mprofile, CT_PROFILE);
  return extract_profile(mprofile);
}

SECOP(apropos, HELP_PREFIX "apropos",
      "`s -> . Finds all global variables whose name contains"
      " the substring `s and prints them (with help)",
      (struct string *s), LVL_VALA, OP_LEAF | OP_NOESCAPE, "s.")
{
  CHECK_TYPES(s, string);

  GCPRO(s);
  for (long i = 0, envused = nglobals(); i < envused; ++i)
    {
      if (mudlle_string_isearch(GNAME(i), s) < 0)
        continue;

      pswrite(mudout(), GNAME(i));
      pputs("\n  ", mudout());

      if (is_any_primitive(GVAR(i)))
        {
          struct primitive *op = GVAR(i);
          pprintf(mudout(), "Primitive: %s\n", op->op->help->str);
        }
      else if (TYPE(GVAR(i), closure))
        {
          pputs("Function: ", mudout());
          show_function(GVAR(i));
          pputc('\n', mudout());
        }
      else
        {
          pputs("Variable: ", mudout());
          output_value_cut(mudout(), GVAR(i), 69, fmt_write | fmt_flag_quote);
          pputc('\n', mudout());
        }
    }
  UNGCPRO();
  undefined();
}

VAROP(quit, , "[`n] -> . Exit mudlle, optionally with exit code `n.",
      (struct vector *args),
      0, ("n.", "."))
{
  size_t nargs = vector_len(args);

  int code;
  if (nargs == 0)
    code = EXIT_SUCCESS;
  else if (nargs == 1)
    code = GETINT(args->data[0]);
  else
    runtime_error(error_wrong_parameters);
  exit(code);
}

#ifdef GCSTATS
TYPEDOP(gcstats, , "-> `v. Returns GC statistics: vector(`minor_count,"
        " `major_count, `size, `usage_minor, `usage_major, last gc sizes,"
        " gen0 gc sizes, gen1 gc sizes). The sizes vectors are vectors"
        " of vector(`objects, `rosize, `rwsize).", (void),
        OP_LEAF | OP_NOESCAPE, ".v")
{
  struct vector *last = NULL;
  struct vector *gen[2] = { 0 };
  GCPRO(gen[0], gen[1], last);
  for (int g = 0; g < 2; ++g)
    gen[g] = alloc_vector(mudlle_types);
  last = alloc_vector(mudlle_types);
  for (int i = 0; i < mudlle_types; i++)
    {
      struct vector *v = alloc_vector(2);
      v->data[0] = makeint(gcstats.l.types[i].nb);
      v->data[1] = makeint(gcstats.l.types[i].size);
      last->data[i] = v;
      for (int g = 0; g < 2; ++g)
        {
          v = alloc_vector(3);
          v->data[0] = makeint(gcstats.gen[g].types[i].nb);
          v->data[1] = makeint(gcstats.gen[g].types[i].rosize);
          v->data[2] = makeint(gcstats.gen[g].types[i].rwsize);
          gen[g]->data[i] = v;
        }
    }
  struct vector *v = alloc_vector(8);
  v->data[0] = makeint(gcstats.minor_count);
  v->data[1] = makeint(gcstats.major_count);
  v->data[2] = makeint(gcstats.size);
  v->data[3] = makeint(gcstats.usage_minor);
  v->data[4] = makeint(gcstats.usage_major);
  v->data[5] = last;
  v->data[6] = gen[0];
  v->data[7] = gen[1];

  UNGCPRO();

  return v;
}

SECOP(reset_gcstats, "reset_gcstats!", "-> . Reset short GC statistics.",
      (void), LVL_VALA,
      OP_LEAF | OP_NOALLOC | OP_NOESCAPE, ".")
{
  gcstats.a = GCSTATS_ALLOC_NULL;
  undefined();
}

TYPEDOP(short_gcstats, , "-> `v. Returns short GC statistics. `v[`n] is"
        " a vector(`objects, `bytes) allcated for type `n.", (void),
        OP_LEAF | OP_NOESCAPE, ".v")
{
  struct gcstats stats = gcstats;
  struct vector *v = alloc_vector(mudlle_types);
  GCPRO(v);
  for (int i = 0; i < mudlle_types; ++i)
    {
      struct vector *w = alloc_vector(2);
      w->data[0] = makeint(stats.a.types[i].nb);
      w->data[1] = makeint(stats.a.types[i].size);
      v->data[i] = w;
    }
  UNGCPRO();
  return v;
}

#endif  /* GCSTATS */

TYPEDOP(gc_generation, , "-> `n. Returns the number of garbage collections"
	" run so far (minor or major). Cf. `gc_cmp().",
	(void), OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_TRIVIAL, ".n")
{
  return makeint(gc_generation());
}

TYPEDOP(gc_cmp, , "`x0 `x1 -> `n. Compares `x0 and `x1 as == does, and"
        " returns -1 if `x0 is less than `x1, 0 if they are equal, or 1 if `x0"
	" is greater than `x1. The results are only stable within"
	" one `gc_generation().",
	(value a, value b),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_TRIVIAL, "xx.n")
{
  return makeint(CMP((long)a, (long)b));
}

TYPEDOP(gc_hash, ,
        "`x -> `n. Returns a non-negative hash number for object `x,"
        " which is valid while `gc_generation() is constant.",
	(value x),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_TRIVIAL, "x.n")
{
  return makeint(symbol_nhash((const char *)&x, sizeof x,
                              TAGGED_INT_BITS - 1));
}

UNSAFEOP(garbage_collect, , "`n -> . Does a forced garbage collection,"
         " asserting room for `n bytes of allocations before another"
         " garbage collection has to be done.",
         (value mbytes),
         OP_LEAF | OP_NOESCAPE, "n.")
{
  unsigned long bytes;
  CHECK_TYPES(mbytes, CT_RANGE(bytes, 0, LONG_MAX));

  struct rlimit rlp;
  if (getrlimit(RLIMIT_AS, &rlp) < 0)
    RUNTIME_ERROR(error_abort, errno_message(errno, "getrlimit()"));

  /* this only catches some values that are known to crash */
  if (rlp.rlim_cur != RLIM_INFINITY && bytes > rlp.rlim_cur)
    RUNTIME_ERROR_ARG(0, error_bad_value,
                      "value beyond process virtual memory limit");

  garbage_collect(bytes);
  undefined();
}


TYPEDOP(add_call_trace_port, "add_call_trace_port!",
        "`x `b -> . Also send call traces to `x (an output port"
        " or character). If `b is true, only send those not handled"
        " otherwise.",
        (value oport, value only_unhandled_p), OP_LEAF | OP_NOESCAPE, "ox.")
{
  bool is_char = TYPE(oport, character);
  CHECK_TYPES(oport,            CT_TYPES(oport, character),
              only_unhandled_p, any);
  remove_call_trace(oport);
  add_call_trace(oport, istrue(only_unhandled_p), is_char, NULL, NULL);
  undefined();
}

TYPEDOP(remove_call_trace_port, "remove_call_trace_port!",
        "`x -> . Stop sending call traces to `x (an output port or character)."
        " Cf. `add_call_trace_port!().",
        (value oport), OP_LEAF | OP_NOESCAPE, "o.")
{
  CHECK_TYPES(oport, CT_TYPES(oport, character));
  remove_call_trace(oport);
  undefined();
}

void debug_init(void)
{
  DEFINE(garbage_collect);
  DEFINE(help);
  DEFINE(help_string);
  DEFINE(defined_in);
  DEFINE(set_use_nicename);
  DEFINE(use_nicename);
  DEFINE(closure_variables);
  DEFINE(variable_value);
  DEFINE(function_name);
  DEFINE(function_seclevel);
  DEFINE(function_call_count);
  DEFINE(collect_profile);
  DEFINE(extract_profile);
  DEFINE(start_profile);
  DEFINE(stop_profile);
  DEFINE(apropos);
  DEFINE(quit);
#ifdef GCSTATS
  DEFINE(gcstats);
  DEFINE(short_gcstats);
  DEFINE(reset_gcstats);
#endif  /* GCSTATS */
  DEFINE(gc_generation);
  DEFINE(gc_cmp);
  DEFINE(gc_hash);

  DEFINE(add_call_trace_port);
  DEFINE(remove_call_trace_port);

}
