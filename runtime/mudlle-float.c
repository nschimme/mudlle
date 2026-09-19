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

#include <float.h>
#include <math.h>

#include "bigint.h"
#include "check-types.h"
#include "mudlle-float.h"
#include "prims.h"

#include "../mudlle-lpsolve.h"
#include "../random.h"
#include "../utils.h"


enum runtime_error get_floatval(double *d, value v)
{
  if (integerp(v))
    {
      *d = intval(v);
      return error_none;
    }
#ifdef USE_GMP
  if (TYPE(v, bigint))
    {
      *d = bigint_to_double(v);
      return error_none;
    }
#endif
  if (!TYPE(v, float))
    return error_bad_type;
  *d = ((struct mudlle_float *)v)->d;
  return error_none;
}

#ifdef USE_GMP
#define FLOATVAL_TYPESET (TSET(integer) | TSET(bigint) | TSET(float))
#else
#define FLOATVAL_TYPESET (TSET(integer) | TSET(float))
#endif

static double floatval_op(value v, const struct prim_op *op)
{
  double d;
  enum runtime_error e = get_floatval(&d, v);
  if (e == error_none)
    return d;
  assert(e == error_bad_type);
  primitive_bad_typeset_error(v, FLOATVAL_TYPESET, op, -1, 1, v);
}

static void floatval_op2(double *d1, double *d2, value v1, value v2,
                         const struct prim_op *op)
{
  value ev = v1;
  enum runtime_error e = get_floatval(d1, v1);
  if (e != error_none)
    goto error;
  ev = v2;
  e = get_floatval(d2, v2);
  if (e == error_none)
    return;
 error:
  primitive_bad_typeset_error(ev, FLOATVAL_TYPESET, op, -1, 2, v1, v2);
}

#define FUNOP(name, opname, doc)                        \
TYPEDOP(f ## name, ,                                    \
        "`f1 -> `f2. Returns " doc ".", (value f),      \
        OP_LEAF | OP_NOESCAPE | OP_CONST | OP_TRIVIAL,  \
        "D.d")                                          \
{                                                       \
  return alloc_float(opname(floatval_op(f, THIS_OP)));  \
}

#define FUNFUNC(name, doc) FUNOP(name, name, #name "(`f1), " doc)

#define FBINFUNC(name, fname, doc)                      \
TYPEDOP(f ## name, ,                                    \
        "`f1 `f2 -> `f3. Returns " doc ".",             \
        (value f1, value f2),                           \
        OP_LEAF | OP_NOESCAPE | OP_CONST | OP_TRIVIAL,  \
        "DD.d")                                         \
{                                                       \
  double d1, d2;                                        \
  floatval_op2(&d1, &d2, f1, f2, THIS_OP);              \
  return alloc_float(fname(d1, d2));                    \
}

#define FBINOP(name, op)                                \
TYPEDOP(f ## name, ,                                    \
        "`f1 `f2 -> `f3. Returns `f1 " #op " `f2",      \
        (value f1, value f2),                           \
        OP_LEAF | OP_NOESCAPE | OP_CONST | OP_TRIVIAL,  \
        "DD.d")                                         \
{                                                       \
  double d1, d2;                                        \
  floatval_op2(&d1, &d2, f1, f2, THIS_OP);              \
  return alloc_float(d1 op d2);                         \
}

TYPEDOP(isfloatp, "float?", "`x -> `b. Returns true if `x is a float",
        (value x),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST | OP_TRIVIAL, "x.n")
{
  return makebool(TYPE(x, float));
}

TYPEDOP(float_likep, "float_like?", "`x -> `b. Returns true if `x can be"
        " converted to a float: a float, a bigint, or an integer.",
        (value x),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST | OP_TRIVIAL, "x.n")
{
  return makebool(is_const_typeset(x, TYPESET_FLOAT_LIKE));
}

TYPEDOP(isffinitep, "ffinite?",
        "`f -> `b. Returns true if `f is neither infinite nor"
	" Not a Number (NaN).",
        (value f),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST | OP_TRIVIAL, "D.n")
{
  return makebool(isfinite(floatval_op(f, THIS_OP)));
}

TYPEDOP(isfnanp, "fnan?",
        "`f -> `b. Returns true if `f is Not a Number (NaN).", (value f),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST | OP_TRIVIAL, "D.n")
{
  return makebool(isnan(floatval_op(f, THIS_OP)));
}

TYPEDOP(isfinfp, "finf?", "`f -> `n. Returns -1 if `f is negative infinity,"
        " 1 for positive infinity, or 0 otherwise.",
        (value f),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST | OP_TRIVIAL, "D.n")
{
  return makeint(isinf(floatval_op(f, THIS_OP)));
}

FUNOP(abs, fabs, "|`f1|, the absolute value of `f1")

static inline double fneg(double d)
{
  return -d;
}

FUNOP(neg, fneg, "-`f1")

TYPEDOP(frandom, , "-> `f. Returns a random value in [0, 1)",
        (void), OP_LEAF | OP_NOESCAPE, ".d")
{
  return alloc_float(drandom());
}

#ifdef WORDS_BIGENDIAN
 /* random state does not support cross-endian use */
 #error Unsupported endianness
#endif
CASSERT_SIZEOF(struct pcg32_random, 16);

TYPEDOP(frandom_r, , "`s -> `f. Returns a random value in [0, 1).\n"
        "`s contains the random state and will be updated.\n"
        "Use `srandom() to create an initial random state.",
        (struct string *mrngstate), OP_LEAF | OP_NOESCAPE, "s.d")
{
  CHECK_TYPES(mrngstate, string);

  if (obj_readonlyp(&mrngstate->o))
    RUNTIME_ERROR(error_value_read_only, "random state is read-only");

  if (string_len(mrngstate) != sizeof (struct pcg32_random))
    RUNTIME_ERROR(error_bad_value, "invalid random state");

  struct pcg32_random *rng = (struct pcg32_random *)mrngstate->str;

  return alloc_float(drandom_r(rng));
}

TYPEDOP(fsign, , "`f -> `n. Returns -1 for negative `f (including negative"
        " zero), 1 for strictly positive, 0 for positive zero."
        " Causes an error if `f is Not a Number (NaN).",
        (value f),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST | OP_TRIVIAL,
        "D.n")
{
  double d = floatval_op(f, THIS_OP);
  if (isnan(d))
    primitive_runtime_error(error_bad_value, THIS_OP, 1, f);

  return makeint(signbit(d) ? -1 : d > 0 ? 1 : 0);
}

TYPEDOP(ftoi, , "`f -> `n. Returns `f as an integer by discarding the"
        " fractional part (truncating the value toward zero).\n"
        "Causes an error if `f is out of range (not in"
        " [`FLOAT_MININT..`FLOAT_MAXINT]) or Not a Number (NaN).",
        (value f),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST | OP_TRIVIAL, "D.n")
{
  double d = floatval_op(f, THIS_OP);
  long l;
  if (!double_to_long(&l, d) || l < MIN_TAGGED_INT || l > MAX_TAGGED_INT)
    primitive_runtime_error(error_bad_value, THIS_OP, 1, f);
  return makeint(l);
}


TYPEDOP(itof, , "`n -> `f. Returns the integer `n as a float.\n"
        "If `n cannot be represented exactly as a float, either the"
        " nearest higher or nearest lower representable value will be"
        " returned.", (value n),
        OP_LEAF | OP_NOESCAPE | OP_CONST | OP_TRIVIAL, "n.d")
{
  long l;
  CHECK_TYPES(n, CT_INT(l));
  return alloc_float(l);
}

TYPEDOP(atof, , "`s -> `f. Converts string to float."
        " Returns `s if the conversion failed.",
        (struct string *s),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY | OP_CONST | OP_TRIVIAL,
        "s.[ds]")
{
  CHECK_TYPES(s, string);

  double d;
  if (!mudlle_strtofloat(s->str, string_len(s), &d))
    return s;
  return alloc_float(d);
}

TYPEDOP(fcmp, , "`f1 `f2 -> `n. Returns -1 if `f1 < `f2, 0 if `f1 = `f2,"
        " 1 if `f1 > `f2. Causes an error if either `f1 or `f2 is"
        " Not a Number (NaN).",
        (value f1, value f2),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST | OP_TRIVIAL,
        "DD.n")
{
  double d1, d2;
  floatval_op2(&d1, &d2, f1, f2, THIS_OP);

  if (isunordered(d1, d2))
    primitive_runtime_error(error_bad_value, THIS_OP, 2, f1, f2);

  if (isless(d1, d2))
    return makeint(-1);
  return makeint(isgreater(d1, d2));
}

VAROP(lp_solve, ,
      "`v1[f]:objective `v2[v[f]]:constraints [`n1:minmax `v3[f]:lower_bound"
      " `v4[f]:upper_bound `v5[b]:integer?] -> `v[f]|`n.\nMaximize objective"
      " function `v1, given constraints `v2 and optional lower-upper bounds"
      " `v3 and `v4 (default between 0 and +inf).\n`v2 is a vector of"
      " constraints, each constraint is expressed as [`weights `sign `rhs]"
      " where `sign <, =, > 0 if constraint must be <, =, > `rhs.\n"
      "Non-zero elements of `v5 correspond to integer variables.\n"
      "If `n1 <= 0, minimize objective function instead of maximizing.\n"
      "The function returns the optimal vector or a numerical error code"
      " (see `LP_xxx constants).",
      (struct vector *mobjective, struct vector *mconstraints,
       struct vector *args),
      OP_LEAF | OP_NOESCAPE,
      ("vv.[vn]", "vvn.[vn]", "vvnv.[vn]", "vvnvv.[vn]", "vvnvvv.[vn]"))
{
  CHECK_TYPES(mobjective,   vector,
              mconstraints, vector,
              args,         CT_ARGV(0, 4));

  size_t nargs = vector_len(args);

  const size_t MAX_VARIABLES = 100;
  const size_t MAX_CONSTRAINTS = 100;

  TYPEIS(mobjective, vector);
  TYPEIS(mconstraints, vector);

  size_t variables = vector_len(mobjective);
  size_t constraints = vector_len(mconstraints);

  if (!variables || !constraints
      || variables > MAX_VARIABLES || constraints > MAX_CONSTRAINTS)
    RUNTIME_ERROR(error_bad_index, NULL);

  int UNUSED min_max = 1;
  if (nargs >= 1)
    min_max = GETINT(args->data[0]);

  struct vector *lower_bound = NULL;
  if (nargs >= 2)
    {
      lower_bound = args->data[1];
      VALUE_IS_VECTOR_LEN(lower_bound, variables);
    }

  struct vector *upper_bound = NULL;
  if (nargs >= 3)
    {
      upper_bound = args->data[2];
      TYPEIS(upper_bound, vector);
      VALUE_IS_VECTOR_LEN(upper_bound, variables);
    }

  struct vector *intvar = NULL;
  if (nargs >= 4)
    {
      intvar = args->data[3];
      VALUE_IS_VECTOR_LEN(intvar, variables);
    }

  /* Type checking */
  for (size_t j = 0; j < variables; ++j)
    floatval(mobjective->data[j]);

  if (lower_bound)
    for (size_t j = 0; j < variables; ++j)
      floatval(lower_bound->data[j]);

  if (upper_bound)
    for (size_t j = 0; j < variables; ++j)
      floatval(upper_bound->data[j]);

  if (intvar)
    for (size_t j = 0; j < variables; ++j)
      floatval(intvar->data[j]);

  for (size_t i = 0; i < constraints; ++i)
    {
      struct vector *c = mconstraints->data[i];
      VALUE_IS_VECTOR_LEN(c, variables + 2);
      for (size_t j = 0; j < variables + 2; ++j)
	floatval(c->data[j]);
    }

#ifdef USE_LPSOLVE
  /* Set up linear programming problem */
  lprec *lp = make_lp(constraints, variables);

  /* Choose maximization or minimization */
  if (min_max > 0)
    set_maxim(lp);
  else
    set_minim(lp);

  /* Set up mobjective function */
  for (size_t j = 0; j < variables; ++j)
    set_mat(lp, 0, j + 1, floatval(mobjective->data[j]));

  /* Set up bounds */
  if (lower_bound)
    for (size_t j = 0; j < variables; ++j)
      set_lowbo(lp, j + 1, floatval(lower_bound->data[j]));

  if (upper_bound)
    for (size_t j = 0; j < variables; ++j)
      set_upbo(lp, j + 1, floatval(upper_bound->data[j]));

  /* Set up constraints */
  for (size_t i = 0; i < constraints; ++i)
    {
      struct vector *c = mconstraints->data[i];
      for (size_t j = 0; j < variables; ++j)
	set_mat(lp, i + 1, j + 1, floatval(c->data[j]));

      float f = floatval(c->data[variables]);
      if (f < 0)
	set_constr_type(lp, i + 1, LE);
      else if (f > 0)
	set_constr_type(lp, i + 1, GE);
      else
	set_constr_type(lp, i + 1, EQ);

      set_rh(lp, i + 1, floatval(c->data[variables + 1]));
    }

  /* Set up integer variables */
  if (intvar)
    for (size_t j = 0; j < variables; ++j)
      set_int(lp, j + 1, floatval(intvar->data[j]) != 0);

  /* Solve */
  int rc = solve(lp);

  /* Return results */
  if (rc != 0)
    {
      delete_lp(lp);
      return makeint(rc);
    }

  struct vector *r = alloc_vector(variables);
  GCPRO(r);
  for (size_t j = 0; j < variables; ++j)
    SET_VECTOR(r, j, alloc_float(lp->best_solution[lp->rows + j + 1]));
  delete_lp(lp);
  UNGCPRO();
  return r;
#else
  return makeint(0);
#endif /* USE_LPSOLVE */
}


FUNFUNC(sqrt, "the square root of `f1")
FUNFUNC(exp, "e to the power of `f1")
FUNFUNC(log, "the natural logarithm of `f1")
FUNFUNC(sin, "the sine of `f1 radians")
FUNFUNC(cos, "the cosine of `f1 radians")
FUNFUNC(tan, "the tangent of `f1 radians")
FUNFUNC(atan, "the arc tangent of `f1 in the range [-pi/2, pi/2]")
FUNFUNC(asin, "the arc sine of `f1 in the range [-pi/2, pi/2]")
FUNFUNC(acos, "the arc cosine of `f1 in the range [0, pi]")

FUNFUNC(ceil, "the smallest integral value not less than `f1")
FUNFUNC(floor, "the largest integral value not greater than `f1")
FUNFUNC(round, "the nearest integral value, rounding halfway cases away"
        " from zero")
FUNFUNC(trunc, "the nearest integral value not larger in magnitude than `f1")

FBINFUNC(atan2, atan2,
         "the arc tangent of `f1/`f2 in [-pi, pi], using the signs to"
         " determine the quadrant of the result")
FBINFUNC(hypot, hypot, "the square root of `f1*`f1+`f2*`f2")
FBINFUNC(mod, fmod, "the floating-point remainder of `f1 divided by `f2")
FBINFUNC(pow, pow, "`f1 raised to the power of `f2")
FBINFUNC(nextafter, nextafter, "the next representable floating-point after"
         " `f1 in the direction of `f2")

FBINOP(add, +)
FBINOP(sub, -)
FBINOP(mul, *)
FBINOP(div, /)

static void sys_def_float(struct string *name, double d)
{
  system_string_define(name, alloc_float(d));
}

#define DEFCONST(name) do {                                     \
  STATIC_STRING(name_ ## name, #name);                          \
  sys_def_float(GET_STATIC_STRING(name_ ## name), name);        \
} while (0)

void float_init(void)
{
  DEFINE(fsqrt);
  DEFINE(fexp);
  DEFINE(flog);
  DEFINE(fsin);
  DEFINE(fcos);
  DEFINE(ftan);
  DEFINE(fatan);
  DEFINE(fasin);
  DEFINE(facos);
  DEFINE(fmod);

  DEFINE(fceil);
  DEFINE(ffloor);
  DEFINE(ftrunc);
  DEFINE(fround);

  DEFINE(fatan2);
  DEFINE(fhypot);
  DEFINE(fpow);
  DEFINE(fnextafter);

  DEFINE(fadd);
  DEFINE(fsub);
  DEFINE(fmul);
  DEFINE(fdiv);

  DEFINE(fneg);
  DEFINE(fabs);
  DEFINE(fsign);

  DEFINE(ftoi);
  DEFINE(itof);
  DEFINE(fcmp);
  DEFINE(atof);

  DEFINE(frandom);
  DEFINE(frandom_r);

  DEFINE(isfloatp);
  DEFINE(isfnanp);
  DEFINE(isfinfp);
  DEFINE(isffinitep);

  DEFINE(float_likep);

  DEFINE(lp_solve);

  DEFCONST(M_PI);
  DEFCONST(M_E);
  DEFCONST(M_LN2);
  DEFCONST(M_LN10);
  DEFCONST(M_1_PI);
  DEFCONST(M_SQRT2);
  DEFCONST(M_SQRT1_2);
  DEFCONST(M_LOG2E);
  DEFCONST(M_LOG10E);
  {
    const double MAX_FLOAT = DBL_MAX;
    DEFCONST(MAX_FLOAT);
  }
  DEFCONST(INFINITY);
  {
    /* (MAX_TAGGED_INT + 1) is a power of two and should always be
       representable, so the next smaller double will be truncated to
       <= MAX_TAGGED_INT */
    const double FLOAT_MAXINT = nextafter(MAX_TAGGED_INT + 1, 0);
    /* If (MIN_TAGGED_INT - 1) is a different double than MIN_TAGGED_INT (which
       is a power of two), the next higher double will be truncated to
       MIN_TAGGED_INT */
    const double FLOAT_MININT = ((double)(MIN_TAGGED_INT - 1) < MIN_TAGGED_INT
                                 ? nextafter(MIN_TAGGED_INT - 1, 0)
                                 : MIN_TAGGED_INT);
    long l;
    assert(double_to_long(&l, FLOAT_MAXINT) && l <= MAX_TAGGED_INT);
    assert(!(double_to_long(&l, nextafter(FLOAT_MAXINT, INFINITY))
             && l <= MAX_TAGGED_INT));
    assert(double_to_long(&l, FLOAT_MININT) && l >= MIN_TAGGED_INT);
    assert(!(double_to_long(&l, nextafter(FLOAT_MININT, -INFINITY))
             && l >= MIN_TAGGED_INT));
    DEFCONST(FLOAT_MAXINT);
    DEFCONST(FLOAT_MININT);
  }

#ifndef DBL_DECIMAL_DIG
  /* clang 3.8 doesn't define this C11 macro */
  #define DBL_DECIMAL_DIG __DBL_DECIMAL_DIG__
#endif
  system_define("FLOAT_DECIMAL_DIG", makeint(DBL_DECIMAL_DIG));

#ifdef USE_LPSOLVE
  /* lp_solve return codes.
   * Not all of these are currently in use, but let's reserve the names... */

  CASSERT(LP_MAJORVERSION == 5 && LP_MINORVERSION == 5);
  DEFINE_INT(LP_OPTIMAL);
  DEFINE_INT(LP_SUBOPTIMAL);
  DEFINE_INT(LP_INFEASIBLE);
  DEFINE_INT(LP_UNBOUNDED);
  DEFINE_INT(LP_DEGENERATE);
  DEFINE_INT(LP_NUMFAILURE);
  DEFINE_INT(LP_USERABORT);
  DEFINE_INT(LP_TIMEOUT);
  DEFINE_INT(LP_RUNNING);
  DEFINE_INT(LP_PRESOLVED);
#endif  /* USE_LPSOLVE */
}
