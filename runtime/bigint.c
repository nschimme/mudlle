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

#include <math.h>

#include "bigint.h"
#include "check-types.h"
#include "mudlle-float.h"
#include "prims.h"

#include "../utils.h"

TYPEDOP(isbigint, "bigint?", "`x -> `b. True if `x is a bigint", (value x),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "x.n")
{
  return makebool(TYPE(x, bigint));
}

TYPEDOP(bigint_likep, "bigint_like?", "`x -> `b. Returns true if `x can be"
        " converted to a bigint: a bigint or an integer.",
        (value x),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST | OP_TRIVIAL, "x.n")
{
  return makebool(is_const_typeset(x, TYPESET_BIGINT_LIKE));
}

#ifdef USE_GMP
static bool in_mudlle_gmp;

static struct alloc_list {
  struct alloc_list *next;
  void *data;
} *alloc_root;

#define MAX_BIGINT_SIZE (MAX_MUDLLE_OBJECT_SIZE         \
                         - sizeof (struct string)       \
                         - sizeof (mpz_t))

static void *mpz_alloc_fn(size_t size)
{
  if (!in_mudlle_gmp)
    return malloc(size);

  if (size > MAX_BIGINT_SIZE)
    runtime_error_message(error_bad_value, "bigint out of range");

  struct alloc_list *m = malloc(sizeof *m);
  *m = (struct alloc_list){
    .next = alloc_root,
    .data = malloc(size)
  };
  alloc_root = m;

  return m->data;
}

static void *mpz_realloc_fn(void *odata, size_t osize, size_t nsize)
{
  if (!in_mudlle_gmp)
    return realloc(odata, nsize);

  if (nsize > MAX_BIGINT_SIZE)
    runtime_error_message(error_bad_value, "bigint out of range");

  /* optimize common case */
  if (alloc_root && alloc_root->data == odata)
    {
      alloc_root->data = realloc(alloc_root->data, nsize);
      return alloc_root->data;
    }

  void *ndata = mpz_alloc_fn(nsize);
  memcpy(ndata, odata, osize);
  return ndata;
}

static void mpz_free_fn(void *data, size_t size)
{
  if (!in_mudlle_gmp)
    free(data);
}

void assert_mudlle_gmp(bool on)
{
  assert(!in_mudlle_gmp == !on);
}

void start_mudlle_gmp(void)
{
  assert_mudlle_gmp(false);
  in_mudlle_gmp = true;
}

void end_mudlle_gmp(void)
{
  for (struct alloc_list *m = alloc_root, *next; m; m = next)
    {
      next = m->next;
      free(m->data);
      free(m);
    }
  alloc_root = NULL;
  in_mudlle_gmp = false;
}

static struct bigint *get_bigint(value v)
{
  struct bigint *bi;
  if (integerp(v))
    {
      start_mudlle_gmp();
      mpz_t mpz;
      mpz_init_set_si(mpz, intval(v));
      bi = alloc_bigint(mpz);
      end_mudlle_gmp();
    }
  else if (TYPE(v, bigint))
    bi = v;
  else
    bad_typeset_error(v, TSET(integer) | TSET(bigint), -1);
  check_bigint(bi);
  return bi;
}

double bigint_to_double(struct bigint *bi)
{
  check_bigint(bi);
  return mpz_get_d(bi->mpz);
}

TYPEDOP(itobi, , "`n -> `bi. Return `n as a bigint", (value n),
        OP_LEAF | OP_NOESCAPE | OP_CONST, "n.b")
{
  start_mudlle_gmp();
  mpz_t r;
  mpz_init_set_si(r, GETINT(n));
  struct bigint *v = alloc_bigint(r);
  end_mudlle_gmp();
  return v;
}

TYPEDOP(ftobi, , "`f -> `bi. Truncates `f into a bigint",
        (struct mudlle_float *f), OP_LEAF | OP_NOESCAPE | OP_CONST, "D.b")
{
  double d;
  CHECK_TYPES(f, CT_FLOAT(d));

  if (!isfinite(d))
    RUNTIME_ERROR_ARG(0, error_bad_value, "argument is not finite");

  start_mudlle_gmp();
  mpz_t r;
  mpz_init_set_d(r, d);
  struct bigint *v = alloc_bigint(r);
  end_mudlle_gmp();

  return v;
}

#define MAX_BITOA_LEN     65535

static struct string *bitoa_base(struct bigint *m, int base,
                                 const struct prim_op *op)
{
  m = get_bigint(m);
  size_t len = mpz_sizeinbase(m->mpz, base);
  if (mpz_sgn(m->mpz))
    len += 1;
  if (len > MAX_BITOA_LEN)
    runtime_error_message(error_bad_value,
                          "number too large to convert to string");

  /* can be unrealistically expensive */
  expensive_operation(len / 8);

  start_mudlle_gmp();
  char *buf = malloc(len + 1);
  mpz_get_str(buf, base, m->mpz);
  struct string *s = make_readonly(alloc_string(buf));
  free(buf);
  end_mudlle_gmp();
  return s;
}

TYPEDOP(bitoa, , "`bi -> `s. Return a string representation for `bi.\n"
        "Causes an error if the representation execeeds"
        " " STRINGIFY(MAX_BITOA_LEN) NBSP "characters.",
        (struct bigint *bi), OP_LEAF | OP_NOESCAPE | OP_CONST, "B.s")
{
  return bitoa_base(bi, 10, THIS_OP);
}

TYPEDOP(bitoa_base, , "`bi `n -> `s. Return a string representation for `bi,"
        " base `n (2 to 36; or -2 to -36 for uppercase characters).\n"
        "Causes an error if the representation execeeds"
        " " STRINGIFY(MAX_BITOA_LEN) NBSP "characters.",
        (struct bigint *bi, value v), OP_LEAF | OP_NOESCAPE | OP_CONST,
        "Bn.s")
{
  long n;
  CHECK_TYPES(bi, any,
              v,  CT_INT(n));
  if (n < -36 || n > 36 || (n >= -1 && n <= 1))
    RUNTIME_ERROR(error_bad_value, "invalid base");
  return bitoa_base(bi, n, THIS_OP);
}

static value atobi(struct string *s, int base)
{
  start_mudlle_gmp();
  value result;
  mpz_t mpz;
  if (mpz_init_set_str(mpz, s->str, base))
    result = NULL;
  else
    result = alloc_bigint(mpz);
  end_mudlle_gmp();

  return result;
}

TYPEDOP(atobi, , "`s -> `bi|null. Return the number in `s as a bigint or null"
        " on error.",
        (struct string *str), OP_LEAF | OP_NOESCAPE | OP_CONST, "s.[bu]")
{
  CHECK_TYPES(str, string);
  return atobi(str, 0);
}

TYPEDOP(atobi_base, , "`s `n -> `bi|null. Return the number in `s encoded in"
        " base `n (2 <= `n <= 32) as a bigint or null on error.",
        (struct string *str, value mbase), OP_LEAF | OP_NOESCAPE | OP_CONST,
        "sn.[bu]")
{
  int base;
  CHECK_TYPES(str,   string,
              mbase, CT_RANGE(base, 2, 32));
  return atobi(str, base);
}

TYPEDOP(bitoi, , "`bi -> `i. Return `bi as an integer (error if overflow)",
        (struct bigint *bi), OP_LEAF | OP_NOESCAPE | OP_CONST, "B.n")
{
  bi = get_bigint(bi);

  if (!mpz_fits_slong_p(bi->mpz))
    runtime_error_message(error_bad_value, "bigint out of range");

  long l = mpz_get_si(bi->mpz);
  if (l < MIN_TAGGED_INT || l > MAX_TAGGED_INT)
    runtime_error_message(error_bad_value, "bigint out of range");

  return makeint(l);
}

TYPEDOP(bisgn, , "`bi -> `n. Return -1 if `bi < 0, 0 if `bi == 0, or 1"
        " if `bi > 0",
        (struct bigint *bi), OP_LEAF | OP_NOESCAPE | OP_CONST, "B.n")
{
  bi = get_bigint(bi);
  return makeint(mpz_sgn(bi->mpz));
}

TYPEDOP(bitof, , "`bi -> `f. Return `bi as a float",
        (struct bigint *bi), OP_LEAF | OP_NOESCAPE | OP_CONST, "B.d")
{
  double d = mpz_get_d(get_bigint(bi)->mpz);
  return alloc_float(d);
}

TYPEDOP(bicmp, , "`bi1 `bi2 -> `n. Returns < 0 if `bi1 < `bi2,"
        " 0 if `bi1 == `bi2, and > 0 if `bi1 > `bi2",
        (struct bigint *bi1, struct bigint *bi2),
        OP_LEAF | OP_NOESCAPE | OP_CONST, "BB.n")
{
  GCPRO(bi1, bi2);
  bi1 = get_bigint(bi1);
  bi2 = get_bigint(bi2);
  check_bigint(bi1);            /* could have been corrupted */
  UNGCPRO();

  return makeint(CMP(mpz_cmp(bi1->mpz, bi2->mpz), 0));
}

TYPEDOP(bishl, , "`bi1 `n -> `bi2. Returns `bi1 << `n. Shifts right for"
        " negative `n.",
        (struct bigint *bi, value mcnt), OP_LEAF | OP_NOESCAPE | OP_CONST,
        "Bn.b")
{
  long n = GETINT(mcnt);
  bi = get_bigint(bi);

  start_mudlle_gmp();
  mpz_t m;
  mpz_init(m);
  if (n < 0)
    mpz_div_2exp(m, bi->mpz, -n);
  else
    mpz_mul_2exp(m, bi->mpz, n);

  struct bigint *rm = alloc_bigint(m);
  end_mudlle_gmp();
  return rm;
}

TYPEDOP(bipow, , "`bi1 `n -> `bi2. Returns `bi1 raised to the power `n",
        (struct bigint *bi, value mexp), OP_LEAF | OP_NOESCAPE | OP_CONST,
        "Bn.b")
{
  bi = get_bigint(bi);

  long n = GETRANGE(mexp, 0, LONG_MAX);

  start_mudlle_gmp();
  mpz_t m;
  mpz_init(m);
  mpz_pow_ui(m, bi->mpz, n);
  struct bigint *rm = alloc_bigint(m);
  end_mudlle_gmp();

  return rm;
}

TYPEDOP(bisqrt, , "`bi1 -> `bi2. Returns the integer part of sqrt(`bi1)",
        (struct bigint *bi), OP_LEAF | OP_NOESCAPE | OP_CONST, "B.b")
{
  bi = get_bigint(bi);
  start_mudlle_gmp();
  if (mpz_sgn(bi->mpz) < 0)
    runtime_error_message(error_bad_value, "argument must not be negative");

  mpz_t m;
  mpz_init(m);
  mpz_sqrt(m, bi->mpz);
  bi = alloc_bigint(m);
  end_mudlle_gmp();

  return bi;
}

TYPEDOP(bifac, , "`n -> `bi1. Returns `n!",
        (value mn), OP_LEAF | OP_NOESCAPE | OP_CONST, "n.b")
{
  long n = GETRANGE(mn, 0, LONG_MAX);

  start_mudlle_gmp();
  mpz_t m;
  mpz_init(m);
  mpz_fac_ui(m, n);
  struct bigint *rm = alloc_bigint(m);
  end_mudlle_gmp();

  return rm;
}

TYPEDOP(bigcdext, , "`bi0 `bi1 -> vector(`bi2, `bi3, `bi4).\n"
        "Compute the greatest common divisor of `bi0 and `bi1, as well as"
        " the Bézout coefficients that make"
        " `bi0" NBSP "*" NBSP "`bi2" NBSP "+" NBSP "`bi1" NBSP "*" NBSP
        "`bi3 = `bi4 = gcd(`bi0," NBSP "`bi1).",
        (struct bigint *bi0, struct bigint *bi1),
        OP_LEAF | OP_NOESCAPE | OP_CONST, "BB.v")
{
  {
    GCPRO(bi0, bi1);
    bi0 = get_bigint(bi0);
    bi1 = get_bigint(bi1);
    check_bigint(bi0);            /* could have been corrupted */
    UNGCPRO();
  }

  start_mudlle_gmp();

  mpz_t g, s, t;
  mpz_init(g);
  mpz_init(s);
  mpz_init(t);
  mpz_gcdext(g, s, t, bi0->mpz, bi1->mpz);

  struct bigint *big = alloc_bigint(g), *bis = NULL, *bit = NULL;
  GCPRO(big, bis, bit);
  bis = alloc_bigint(s);
  bit = alloc_bigint(t);

  end_mudlle_gmp();

  struct vector *v = alloc_vector(3);
  v->data[0] = bis;
  v->data[1] = bit;
  v->data[2] = big;
  v->o.flags |= OBJ_READONLY | OBJ_IMMUTABLE;
  UNGCPRO();

  return v;
}

#define BIUNOP(name, sname, desc)                               \
TYPEDOP(bi ## name, sname, "`bi1 -> `bi2. Returns " desc,       \
        (struct bigint *bi),                                    \
        OP_LEAF | OP_NOESCAPE | OP_CONST,                       \
        "B.b")                                                  \
{                                                               \
  bi = get_bigint(bi);                                          \
  start_mudlle_gmp();                                           \
  mpz_t m;                                                      \
  mpz_init(m);                                                  \
  mpz_ ## name(m, bi->mpz);                                     \
  struct bigint *rm = alloc_bigint(m);                          \
  end_mudlle_gmp();                                             \
                                                                \
  return rm;                                                    \
}

#define BIBINOP(name, sname, sym, isdiv)                        \
TYPEDOP(bi ## name, sname,                                      \
        "`bi1 `bi2 -> `bi3. Returns `bi1 " #sym " `bi2",        \
        (struct bigint *bi1, struct bigint *bi2),               \
        OP_LEAF | OP_NOESCAPE | OP_CONST, "BB.b")               \
{                                                               \
  GCPRO(bi1, bi2);                                              \
  bi1 = get_bigint(bi1);                                        \
  bi2 = get_bigint(bi2);                                        \
  check_bigint(bi1);            /* could have been corrupted */ \
  UNGCPRO();                                                    \
                                                                \
  start_mudlle_gmp();                                           \
  if (isdiv && !mpz_cmp_si(bi2->mpz, 0))                        \
    runtime_error(error_divide_by_zero);                        \
                                                                \
  mpz_t m;                                                      \
  mpz_init(m);                                                  \
  mpz_ ## name(m, bi1->mpz, bi2->mpz);                          \
  struct bigint *rm = alloc_bigint(m);                          \
  end_mudlle_gmp();                                             \
                                                                \
  return rm;                                                    \
}

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

#else  /* ! USE_GMP */

void assert_mudlle_gmp(bool on)
{
}

void start_mudlle_gmp(void)
{
}

void end_mudlle_gmp(void)
{
}

#endif  /* ! USE_GMP */

value make_unsigned_int_or_bigint(unsigned long long u)
{
  if (u <= MAX_TAGGED_INT)
    return makeint((long)u);

#ifdef USE_GMP
  start_mudlle_gmp();
  mpz_t r;
  mpz_init(r);
  mpz_import(r, 1, 1, sizeof u, 0, 0, &u);
  struct bigint *bi = alloc_bigint(r);
  end_mudlle_gmp();
  return bi;
#else
  runtime_error_message(error_bad_value, "bigints not supported");
#endif
}

value make_signed_int_or_bigint(long long s)
{
  if (s >= MIN_TAGGED_INT && s <= MAX_TAGGED_INT)
    return makeint((long)s);

#ifdef USE_GMP
  start_mudlle_gmp();
  unsigned long long u = ABS(s);
  mpz_t r;
  mpz_init(r);
  mpz_import(r, 1, 1, sizeof u, 0, 0, &u);
  if (s < 0)
    mpz_neg(r, r);
  struct bigint *bi = alloc_bigint(r);
  end_mudlle_gmp();
  return bi;
#else
  runtime_error_message(error_bad_value, "bigints not supported");
#endif
}

void bigint_init(void)
{
  DEFINE(isbigint);
  DEFINE(bigint_likep);

#ifdef USE_GMP
  mp_set_memory_functions(mpz_alloc_fn, mpz_realloc_fn, mpz_free_fn);

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

  DEFINE(bigcdext);
#endif  /* USE_GMP */
}
