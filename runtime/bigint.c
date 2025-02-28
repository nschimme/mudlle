/*
 * Copyright (c) 1993-2012 David Gay and Gustav H�llberg
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

#include <stdlib.h>
#include <limits.h>
#include <math.h>
#include <string.h>

#include "bigint.h"
#include "check-types.h"
#include "mudlle-float.h"
#include "prims.h"

TYPEDOP(isbigint, "bigint?", "`x -> `b. True if `x is a bigint", 1, (value x),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "x.n")
{
  return makebool(TYPE(x, bigint));
}

#ifdef USE_GMP
static struct alloc_list {
  struct alloc_list *next;
  void *data;
} *alloc_root = 0;

#define MAX_BIGINT_SIZE (MAX_MUDLLE_OBJECT_SIZE         \
                         - sizeof (struct string)       \
                         - sizeof (mpz_t))

static void *mpz_alloc_fn(size_t size)
{
  if (size > MAX_BIGINT_SIZE)
    runtime_error(error_bad_value);

  struct alloc_list *m = malloc(sizeof *m);
  m->next = alloc_root;
  m->data = malloc(size);
  alloc_root = m;

  return m->data;
}

static void *mpz_realloc_fn(void *odata, size_t osize, size_t nsize)
{
  /* optimize common case */
  if (alloc_root && alloc_root->data == odata)
    {
      if (nsize > MAX_BIGINT_SIZE)
        runtime_error(error_bad_value);
      alloc_root->data = realloc(alloc_root->data, nsize);
      return alloc_root->data;
    }

  void *ndata = mpz_alloc_fn(nsize);
  memcpy(ndata, odata, osize);
  return ndata;
}

static void mpz_free_fn(void *data, size_t size)
{
}

void free_mpz_temps(void)
{
  for (struct alloc_list *m = alloc_root; m; )
    {
      struct alloc_list *next = m->next;
      free(m->data);
      free(m);
      m = next;
    }
  alloc_root = NULL;
}

static struct bigint *get_bigint(value v)
{
  if (integerp(v))
    {
      mpz_t mpz;

      mpz_init_set_si(mpz, intval(v));
      v = (value)alloc_bigint(mpz);

      free_mpz_temps();
    }
  else if (!TYPE(v, bigint))
    bad_typeset_error(v, TSET(integer) | TSET(bigint));
  check_bigint(v);
  return v;
}

double bigint_to_double(struct bigint *bi)
{
  check_bigint(bi);
  return mpz_get_d(bi->mpz);
}

TYPEDOP(itobi, 0, "`n -> `bi. Return `n as a bigint", 1, (value n),
        OP_LEAF | OP_NOESCAPE | OP_CONST, "n.b")
{
  mpz_t r;
  mpz_init_set_si(r, GETINT(n));
  struct bigint *v = alloc_bigint(r);
  free_mpz_temps();

  return v;
}

TYPEDOP(ftobi, 0, "`f -> `bi. Truncates `f into a bigint",
        1, (struct mudlle_float *f), OP_LEAF | OP_NOESCAPE | OP_CONST, "D.b")
{
  double d = floatval(f);

  if (!isfinite(d))
    runtime_error(error_bad_value);

  mpz_t r;
  mpz_init_set_d(r, d);
  struct bigint *v = alloc_bigint(r);
  free_mpz_temps();

  return v;
}

TYPEDOP(bitoa, 0, "`bi -> `s. Return a string representation for `bi",
        1, (struct bigint *m), OP_LEAF | OP_NOESCAPE | OP_CONST, "B.s")
{
  m = get_bigint(m);
  char buf[mpz_sizeinbase(m->mpz, 10) + 2];
  mpz_get_str(buf, 10, m->mpz);

  return make_readonly(alloc_string(buf));
}

TYPEDOP(bitoa_base, 0, "`bi `n -> `s. Return a string representation for `bi,"
        " base `n (2 - 32)",
        2, (struct bigint *m, value v), OP_LEAF | OP_NOESCAPE | OP_CONST,
        "Bn.s")
{
  m = get_bigint(m);
  int n = GETRANGE(v, 2, 32);

  char buf[mpz_sizeinbase(m->mpz, n) + 2];
  mpz_get_str(buf, n, m->mpz);

  return make_readonly(alloc_string(buf));
}

static value atobi(struct string *s, int base)
{
  value result;
  mpz_t mpz;
  if (mpz_init_set_str(mpz, s->str, base))
    result = NULL;
  else
    result = alloc_bigint(mpz);
  free_mpz_temps();

  return result;
}

TYPEDOP(atobi, 0, "`s -> `bi. Return the number in `s as a bigint or null"
        " on error.",
        1, (struct string *s), OP_LEAF | OP_NOESCAPE | OP_CONST, "s.[bu]")
{
  CHECK_TYPES(s, string);
  return atobi(s, 0);
}

TYPEDOP(atobi_base, 0, "`s `n -> `bi. Return the number in `s encoded in"
        " base `n (2 <= `n <= 32) as a bigint or null on error.",
        2, (struct string *s, value mbase), OP_LEAF | OP_NOESCAPE | OP_CONST,
        "sn.[bu]")
{
  int base;
  CHECK_TYPES(s,     string,
              mbase, CT_RANGE(base, 2, 32));
  return atobi(s, base);
}

TYPEDOP(bitoi, 0, "`bi -> `i. Return `bi as an integer (error if overflow)",
        1, (struct bigint *m), OP_LEAF | OP_NOESCAPE | OP_CONST, "B.n")
{
  m = get_bigint(m);

  if (mpz_cmp_si(m->mpz, MAX_TAGGED_INT) > 0
      || mpz_cmp_si(m->mpz, MIN_TAGGED_INT) < 0)
    runtime_error(error_bad_value);

  return makeint(mpz_get_si(m->mpz));
}

TYPEDOP(bisgn, 0, "`bi -> `n. Return -1 if `bi < 0, 0 if `bi == 0, or 1"
        " if `bi > 0",
        1, (struct bigint *bi), OP_LEAF | OP_NOESCAPE | OP_CONST, "B.n")
{
  bi = get_bigint(bi);
  return makeint(mpz_sgn(bi->mpz));
}

TYPEDOP(bitof, 0, "`bi -> `f. Return `bi as a float",
        1, (struct bigint *m), OP_LEAF | OP_NOESCAPE | OP_CONST, "B.d")
{
  double d = mpz_get_d(get_bigint(m)->mpz);
  return makefloat(d);
}

TYPEDOP(bicmp, 0, "`bi1 `bi2 -> `n. Returns < 0 if `bi1 < `bi2,"
        " 0 if `bi1 == `bi2, "
        "and > 0 if `bi1 > `bi2", 2, (struct bigint *m1, struct bigint *m2),
        OP_LEAF | OP_NOESCAPE | OP_CONST, "BB.n")
{
  GCPRO(m1, m2);
  m1 = get_bigint(m1);
  m2 = get_bigint(m2);
  UNGCPRO();

  int res = mpz_cmp(m1->mpz, m2->mpz);
  return makeint(res < 0 ? -1 : res ? 1 : 0);
}

TYPEDOP(bishl, 0, "`bi1 `n -> `bi2. Returns `bi1 << `n. Shifts right for"
        " negative `n.",
        2, (struct bigint *bi, value v), OP_LEAF | OP_NOESCAPE | OP_CONST,
        "Bn.b")
{
  long n = GETINT(v);
  bi = get_bigint(bi);

  mpz_t m;
  mpz_init(m);
  if (n < 0)
    mpz_div_2exp(m, bi->mpz, -n);
  else
    mpz_mul_2exp(m, bi->mpz, n);

  struct bigint *rm = alloc_bigint(m);
  free_mpz_temps();
  return rm;
}

TYPEDOP(bipow, 0, "`bi1 `n -> `bi2. Returns `bi1 raised to the power `n",
        2, (struct bigint *bi, value v), OP_LEAF | OP_NOESCAPE | OP_CONST,
        "Bn.b")
{
  bi = get_bigint(bi);

  long n = GETRANGE(v, 0, LONG_MAX);

  mpz_t m;
  mpz_init(m);
  mpz_pow_ui(m, bi->mpz, n);
  struct bigint *rm = alloc_bigint(m);
  free_mpz_temps();

  return rm;
}

TYPEDOP(bisqrt, 0, "`bi1 -> `bi2. Returns the integer part of sqrt(`bi1)",
        1, (struct bigint *bi), OP_LEAF | OP_NOESCAPE | OP_CONST, "B.b")
{
  bi = get_bigint(bi);
  if (mpz_sgn(bi->mpz) < 0)
    runtime_error(error_bad_value);

  mpz_t m;
  mpz_init(m);
  mpz_sqrt(m, bi->mpz);
  bi = alloc_bigint(m);
  free_mpz_temps();

  return bi;
}

TYPEDOP(bifac, 0, "`n -> `bi1. Returns `n!",
        1, (value v), OP_LEAF | OP_NOESCAPE | OP_CONST, "n.b")
{
  long n = GETRANGE(v, 0, LONG_MAX);

  mpz_t m;
  mpz_init(m);
  mpz_fac_ui(m, n);
  struct bigint *rm = alloc_bigint(m);
  free_mpz_temps();

  return rm;
}

#define BIUNOP(name, sname, desc)                               \
TYPEDOP(bi ## name, sname, "`bi1 -> `bi2. Returns " desc,       \
        1, (struct bigint *bi),                                 \
        OP_LEAF | OP_NOESCAPE | OP_CONST,                       \
        "B.b")                                                  \
{                                                               \
  bi = get_bigint(bi);                                          \
  mpz_t m;                                                      \
  mpz_init(m);                                                  \
  mpz_ ## name(m, bi->mpz);                                     \
  struct bigint *rm = alloc_bigint(m);                          \
  free_mpz_temps();                                             \
                                                                \
  return rm;                                                    \
}

#define BIBINOP(name, sname, sym, isdiv)                        \
TYPEDOP(bi ## name, sname,                                      \
        "`bi1 `bi2 -> `bi3. Returns `bi1 " #sym " `bi2",        \
        2, (struct bigint *bi1, struct bigint *bi2),            \
        OP_LEAF | OP_NOESCAPE | OP_CONST, "BB.b")               \
{                                                               \
  GCPRO(bi1, bi2);                                              \
  bi1 = get_bigint(bi1);                                        \
  bi2 = get_bigint(bi2);                                        \
  UNGCPRO();                                                    \
                                                                \
  if (isdiv && !mpz_cmp_si(bi2->mpz, 0))                        \
    runtime_error(error_divide_by_zero);                        \
                                                                \
  mpz_t m;                                                      \
  mpz_init(m);                                                  \
  mpz_ ## name(m, bi1->mpz, bi2->mpz);                          \
  struct bigint *rm = alloc_bigint(m);                          \
  free_mpz_temps();                                             \
                                                                \
  return rm;                                                    \
}

#else  /* ! USE_GMP */

void free_mpz_temps(void)
{
}

UNIMPLEMENTED(itobi, 0, "`n -> `bi. Return `n as a bigint", 1, (value n),
              OP_LEAF | OP_NOESCAPE, "n.b")

UNIMPLEMENTED(ftobi, 0, "`f -> `bi. Truncates `f into a bigint",
              1, (struct mudlle_float *f), OP_LEAF | OP_NOESCAPE, "D.b")

UNIMPLEMENTED(bitoa, 0, "`bi -> `s. Return a string representation for `bi",
              1, (struct bigint *m), OP_LEAF | OP_NOESCAPE, "B.s")

UNIMPLEMENTED(bitoa_base, 0, "`bi `n -> `s. Return a string representation"
              " for `bi, base `n (2 - 32)",
              2, (struct bigint *m, value v), OP_LEAF | OP_NOESCAPE, "Bn.s")

UNIMPLEMENTED(atobi, 0, "`s -> `bi. Return the number in `s as a bigint",
              1, (struct string *s), OP_LEAF | OP_NOESCAPE, "s.b")

UNIMPLEMENTED(atobi_base, 0, "`s `n -> `bi. Return the number in `s,"
              " encoded in base `n (2 <= `n <= 32), as a bigint",
              2, (struct string *s, value mbase), OP_LEAF | OP_NOESCAPE,
              "sn.b")

UNIMPLEMENTED(bitoi, 0, "`bi -> `i. Return `bi as an integer (error if"
              " overflow)",
              1, (struct bigint *m), OP_LEAF | OP_NOESCAPE, "B.n")

UNIMPLEMENTED(bisgn, 0, "`bi -> `n. Return -1 if `bi < 0, 0 if `bi == 0, or 1"
              " if `bi > 0",
              1, (struct bigint *bi), OP_LEAF | OP_NOESCAPE, "B.n")

UNIMPLEMENTED(bitof, 0, "`bi -> `f. Return `bi as a float",
              1, (struct bigint *m), OP_LEAF | OP_NOESCAPE, "B.d")

UNIMPLEMENTED(bicmp, 0, "`bi1 `bi2 -> `n. Returns < 0 if `bi1 < `bi2,"
              " 0 if `bi1 == `bi2, "
              "and > 0 if `bi1 > `bi2",
              2, (struct bigint *m1, struct bigint *m2),
              OP_LEAF | OP_NOESCAPE, "BB.n")

UNIMPLEMENTED(bishl, 0, "`bi1 `n -> `bi2. Returns `bi1 << `n. Shifts right for"
              " negative `n. The latter rounds towards zero.",
              2, (struct bigint *bi, value v),
              OP_LEAF | OP_NOESCAPE | OP_CONST,
              "Bn.b")

UNIMPLEMENTED(bipow, 0, "`bi1 `n -> `bi2. Returns `bi1 raised to the power `n",
              2, (struct bigint *bi, value v), OP_LEAF | OP_NOESCAPE,
              "Bn.b")

UNIMPLEMENTED(bisqrt, 0, "`bi1 -> `bi2. Returns the integer part of"
              " sqrt(`bi1)",
              1, (struct bigint *bi), OP_LEAF | OP_NOESCAPE, "B.b")

UNIMPLEMENTED(bifac, 0, "`n -> `bi1. Returns `n!",
              1, (value v), OP_LEAF | OP_NOESCAPE, "n.b")

#define BIUNOP(name, sname, desc)                               \
UNIMPLEMENTED(bi ## name, sname, "`bi1 -> `bi2. Returns " desc, \
              1, (struct bigint *bi), OP_LEAF | OP_NOESCAPE,    \
              "B.b")

#define BIBINOP(name, sname, sym, isdiv)                        \
UNIMPLEMENTED(bi ## name, sname,                                \
              "`bi1 `bi2 -> `bi3. Returns `bi1 " #sym " `bi2",  \
              2, (struct bigint *bi1, struct bigint *bi2),      \
              OP_LEAF | OP_NOESCAPE, "BB.b")

#endif /* ! USE_GMP */

BIUNOP(com, "binot", "~`bi")
BIUNOP(neg, "bineg", "-`bi")
BIUNOP(abs, "biabs", "|`bi|")

BIBINOP(add,    "biadd", +, false)
BIBINOP(sub,    "bisub", -, false)
BIBINOP(mul,    "bimul", *, false)
BIBINOP(tdiv_q, "bidiv", /, true)
BIBINOP(tdiv_r, "bimod", %, true)
BIBINOP(and,    "biand", &, false)
BIBINOP(ior,    "bior",  |, false)

value make_unsigned_int_or_bigint(unsigned long long u)
{
  if (u <= MAX_TAGGED_INT)
    return makeint((long)u);

#ifdef USE_GMP
  mpz_t r;
  mpz_init(r);
  mpz_import(r, 1, 1, sizeof u, 0, 0, &u);
  struct bigint *bi = alloc_bigint(r);
  free_mpz_temps();
  return bi;
#else
  runtime_error(error_bad_value);
#endif
}

value make_signed_int_or_bigint(long long s)
{
  if (s >= MIN_TAGGED_INT && s <= MAX_TAGGED_INT)
    return makeint((long)s);

#ifdef USE_GMP
  /* strange expession to handle LLONG_MIN */
  unsigned long long u = s < 0 ? -(s + 1) + 1ULL : s;
  mpz_t r;
  mpz_init(r);
  mpz_import(r, 1, 1, sizeof u, 0, 0, &u);
  if (s < 0)
    mpz_neg(r, r);
  struct bigint *bi = alloc_bigint(r);
  free_mpz_temps();
  return bi;
#else
  runtime_error(error_bad_value);
#endif
}

void bigint_init(void)
{
#ifdef USE_GMP
  mp_set_memory_functions(&mpz_alloc_fn, &mpz_realloc_fn, &mpz_free_fn);
#endif

  DEFINE(isbigint);
  DEFINE(bicmp);
  DEFINE(bisgn);

  DEFINE(bitoi);
  DEFINE(itobi);
  DEFINE(bitoa);
  DEFINE(atobi);
  DEFINE(atobi_base);
  DEFINE(bitof);
  DEFINE(ftobi);
  DEFINE(bitoa_base);
  DEFINE(bineg);
  DEFINE(bicom);
  DEFINE(biabs);

  DEFINE(bishl);
  DEFINE(bipow);
  DEFINE(bifac);
  DEFINE(bisqrt);

  DEFINE(biadd);
  DEFINE(bisub);
  DEFINE(bimul);
  DEFINE(bitdiv_q);
  DEFINE(bitdiv_r);
  DEFINE(biand);
  DEFINE(biior);
}
