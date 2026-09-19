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
#include <string.h>

#include "arith.h"
#include "mudlle-string.h"
#include "prims.h"

#include "../random.h"

static inline void check_integers(value a, value b, const struct prim_op *op)
{
  if ((long)a & (long)b & 1)
    return;
  primitive_bad_type_error(integerp(a) ? b : a, type_integer, op, 2, a, b);
}

static inline void check_division(value a, value b, const struct prim_op *op)
{
  check_integers(a, b, op);
  if (b == makeint(0))
    primitive_runtime_error(error_divide_by_zero, op, 2, a, b);
}

TYPEDOP(sqrt, , "`n1 -> `n2. Returns the truncated square root of the"
        " non-negative integer `n1.", (value n),
	OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "n.n")
{
  long l;
  CHECK_TYPES(n, CT_RANGE(l, 0, LONG_MAX));
  long r = sqrtl(l);
  CASSERT(FLT_RADIX == 2);                /* if-logic below relies on this */
  if (LDBL_MANT_DIG < TAGGED_INT_BITS - 1 /* sign bit doesn't count */
      && (l >> LDBL_MANT_DIG) > 0)
    {
      /* the argument to sqrt() was rounded to the nearest long double and the
         result might be too high */
      while (r * r > l)
        --r;
    }
  return makeint(r);
}

TYPEDOP(integerp, "integer?", "`x -> `b. Returns true if `x is an integer.",
        (value x),
	OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "x.n")
{
  return makebool(integerp(x));
}

EXT_TYPEDOP(plus, "+",
            "`x1 `x2 -> `x3. For integers `x1 and `x2, returns their"
            " sum. For strings `x1 and `x2, returns their concatenation as a"
            " new string.",
            (value v1, value v2), (v1, v2),
            OP_TRIVIAL | OP_LEAF | OP_NOESCAPE | OP_OPERATOR,
            ("nn.n", "ss.s"))
{
  /* test for strings first as compiled code does integer addition and calls
     this primitive only to add strings */
  if (TYPE(v1, string) && TYPE(v2, string))
    return string_plus(v1, v2);
  check_integers(v1, v2, THIS_OP);
  return (value)((long)v1 + (long)v2 - 1);
}

value string_plus(struct string *s1, struct string *s2)
{
  return string_append(s1, s2, &op_plus);
}

EXT_TYPEDOP(iadd, ,
            "`n1 `n2 -> `n3. Returns the sum of integers `n1 and `n2.",
            (value v1, value v2), (v1, v2),
            (OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE
             | OP_CONST), "nn.n")
{
  check_integers(v1, v2, THIS_OP);
  return (value)(((long)v1 + (long)v2) - 1);
}

EXT_TYPEDOP(subtract, "-", "`n1 `n2 -> `n3. Returns `n2 subtracted from `n1.",
            (value v1, value v2), (v1, v2),
            (OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE
             | OP_CONST | OP_OPERATOR),
            "nn.n")
{
  check_integers(v1, v2, THIS_OP);
  return (value)((long)v1 - (long)v2 + 1);
}

TYPEDOP(negate, , "`n1 -> `n2. Returns the negation of `n1. For `MININT,"
        " return `MININT.", (value n),
	(OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE
         | OP_CONST | OP_OPERATOR), "n.n")
{
  CHECK_TYPES(n, integer);
  return (value)(2 - (long)n);
}

const struct prim_op *const negate_prim_ext = &op_negate;

value code_multiply(value v1, value v2); /* used in x64builtins.S */
EXT_TYPEDOP(multiply, "*", "`n1 `n2 -> `n3. Returns `n1 multiplied by `n2.",
            (value v1, value v2), (v1, v2),
            (OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE
             | OP_CONST | OP_OPERATOR),
            "nn.n")
{
  check_integers(v1, v2, THIS_OP);
  return makeint(intval(v1) * intval(v2));
}

value code_divide(value v1, value v2);
EXT_TYPEDOP(divide, "/", "`n1 `n2 -> `n3. Returns `n1 divided by `n2,"
            " truncating towards zero.\n"
            "Causes `error_divide_by_zero if `n2 is zero.",
            (value v1, value v2), (v1, v2),
            (OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE
             | OP_CONST | OP_OPERATOR),
            "nn.n")
{
  check_division(v1, v2, THIS_OP);
  return makeint(intval(v1) / intval(v2));
}

value code_remainder(value v1, value v2); /* used in x64builtins.S */
EXT_TYPEDOP(remainder, "%",
            "`n1 `n2 -> `n3. Returns the remainder of `n1 divided by `n2,"
            " truncated towards zero.\n"
            "(`n1 / `n2) * `n2 + `n3 = `n1.\n"
            "`n3 will be zero or have the same sign as `n1. Cf. `modulo().\n"
            "Causes `error_divide_by_zero if `n2 is zero.",
            (value v1, value v2), (v1, v2),
            (OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE
             | OP_CONST | OP_OPERATOR),
            "nn.n")
{
  check_division(v1, v2, THIS_OP);
  return makeint(intval(v1) % intval(v2));
}

TYPEDOP(modulo, , "`n1 `n2 -> `n3. Returns the remainder of `n1 divided"
        " by `n2 rounded down towards negative infinity.\n"
        "floor(`n1 / `n2) * `n2 + `n3 = `n1.\n"
        "`n3 will be zero or have the same sign as `n2. Cf. `%.\n"
        "Causes `error_divide_by_zero if `n2 is zero.",
        (value v1, value v2),
        OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "nn.n")
{
  check_division(v1, v2, THIS_OP);
  long p1 = intval(v1), p2 = intval(v2);
  long result = p1 % p2;
  if (result && (p1 ^ p2) < 0)
    result += p2;
  return makeint(result);
}

#define CMPOP(name, op, desc)                                           \
EXT_TYPEDOP(name, #op, "`n1 `n2 -> `b. Returns true if `n1 is "         \
            desc " `n2.",                                               \
            (value v1, value v2), (v1, v2),                             \
            (OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST \
             | OP_OPERATOR),                                            \
            "nn.n")                                                     \
{                                                                       \
  check_integers(v1, v2, THIS_OP);                                      \
  return makebool((long)v1 op (long)v2);                                \
}

CMPOP(smaller,       <,  "less than")
CMPOP(smaller_equal, <=, "less than or equal to")
CMPOP(greater,       >,  "greater than")
CMPOP(greater_equal, >=, "greater than or equal to")

TYPEDOP(max, , "`n1 `n2 -> `n3. Returns the greater value of `n1 and `n2.",
        (value v1, value v2),
	OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "nn.n")
{
  check_integers(v1, v2, THIS_OP);
  return (long)v1 < (long)v2 ? v2 : v1;
}

TYPEDOP(min, , "`n1 `n2 -> `n3. Returns the lesser value of `n1 and `n2.",
        (value v1, value v2),
	OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "nn.n")
{
  check_integers(v1, v2, THIS_OP);
  return (long)v1 < (long)v2 ? v1 : v2;
}

TYPEDOP(abs, , "`n1 -> `n2. Returns the absolute value of `n1. For `MININT,"
        " returns `MININT.", (value n),
        OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "n.n")
{
  CHECK_TYPES(n, integer);
  return (value)(labs((long)n - 1) + 1);
}

EXT_TYPEDOP(bitor, "|", "`n1 `n2 -> `n3. Returns `n1 bitwise OR `n2.",
            (value v1, value v2), (v1, v2),
            (OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE
             | OP_CONST | OP_OPERATOR),
            "nn.n")
{
  check_integers(v1, v2, THIS_OP);
  return (value)((long)v1 | (long)v2);
}

TYPEDOP(bitxor, "^", "`n1 `n2 -> `n3. Returns `n1 bitwise exclusive OR `n2.",
        (value v1, value v2),
        (OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE
         | OP_CONST | OP_OPERATOR), "nn.n")
{
  check_integers(v1, v2, THIS_OP);
  return (value)(((long)v1 ^ (long)v2) | 1);
}

EXT_TYPEDOP(bitand, "&", "`n1 `n2 -> `n3. Returns `n1 bitwise AND `n2.",
            (value v1, value v2), (v1, v2),
            (OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE
             | OP_CONST | OP_OPERATOR),
            "nn.n")
{
  check_integers(v1, v2, THIS_OP);
  return (value)((long)v1 & (long)v2);
}

#if defined __x86_64__
 #define SHIFT_EXTRA_DOC \
    "On 64-bit x86, only the 6 least significant bits of `n2 are used."
#elif defined __aarch64__
 #define SHIFT_EXTRA_DOC \
    "On 64-bit ARM, only the 6 least significant bits of `n2 are used."
#else
 #error Unsupported architecture
#endif

#define SHIFT_MASK (CHAR_BIT * sizeof (long))

value code_shift_left(value v1, value v2); /* used in x64builtins.S */
EXT_TYPEDOP(shift_left, "<<", "`n1 `n2 -> `n3. Returns `n1 bitwise shifted"
            " left `n2.\n" SHIFT_EXTRA_DOC,
            (value v1, value v2), (v1, v2),
            (OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE
             | OP_CONST | OP_OPERATOR),
            "nn.n")
{
  check_integers(v1, v2, THIS_OP);
  return makeint(uintval(v1) << (uintval(v2) % SHIFT_MASK));
}

value code_shift_right(value v1, value v2); /* used in x64builtins.S */
EXT_TYPEDOP(shift_right, ">>", "`n1 `n2 -> `n3. Returns `n1 bitwise shifted"
            " right `n2 steps.\n" SHIFT_EXTRA_DOC,
            (value v1, value v2), (v1, v2),
            (OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE
             | OP_CONST | OP_OPERATOR),
            "nn.n")
{
  check_integers(v1, v2, THIS_OP);
  /* right shift of negative numbers is implemented-defined; assert that it
     rounds to negative infinity */
  CASSERT((-3 >> 1) == -2);
  return makeint(intval(v1) >> (uintval(v2) % SHIFT_MASK));
}

EXT_TYPEDOP(bitnot, "~", "`n1 -> `n2. Returns the bitwise NOT of `n1.",
            (value n), (n),
            (OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE
             | OP_CONST | OP_OPERATOR), "n.n")
{
  CHECK_TYPES(n, integer);
  return (value)((long)n ^ -2);
}

TYPEDOP(ffs, , "`n1 -> `n2. Returns the position of the first"
        " (least significant) bit set in `n1.\n"
        "The least significant bit is position 1.\n"
        "If `n1 is zero, 0 is returned.",
        (value n),
        OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "n.n")
{
  CHECK_TYPES(n, integer);
  return makeint(ffsl(intval(n)));
}

TYPEDOP(random, ,
	"`n1 `n2 -> `n3. Returns a uniformly distributed pseudo-random number"
        " between `n1 and `n2 (inclusive). Cf. `frandom()."
        " `n1 must not be larger than `n2.",
	(value n1, value n2),
	OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "nn.n")
{
  CHECK_TYPES(n1, integer,
              n2, integer);
  long min = intval(n1);
  long max = intval(n2);
  if (min > max)
    RUNTIME_ERROR(error_bad_value, "lower bound > upper bound");

  unsigned long range = max - min;
  if (range <= UINT32_MAX)
    return makeint(min + random_range32(range));

  return makeint(min + (unsigned long)random_range64(range));
}

#ifdef WORDS_BIGENDIAN
 /* random state does not support cross-endian use */
 #error Unsupported endianness
#endif
CASSERT_SIZEOF(struct pcg32_random, 16);

/* assert that the random state is properly aligned when stored a mudlle
   string */
CASSERT(_Alignof(struct pcg32_random) <= _Alignof(struct string)
        && _Alignof(struct pcg32_random) <= offsetof(struct string, str));

TYPEDOP(random_r, ,
	"`s `n1 `n2 -> `n3. Returns a uniformly distributed pseudo-random"
        " number between `n1 and `n2 (inclusive).\n"
        "`s contains the random state and will be updated.\n"
        "Use `srandom() to create an initial random state.",
        (struct string *mrng, value mmin, value mmax),
	OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "snn.n")
{
  CHECK_TYPES(mrng, string,
              mmin, integer,
              mmax, integer);

  if (obj_readonlyp(&mrng->o))
    RUNTIME_ERROR_ARG(0, error_value_read_only, "random state is read-only");

  if (string_len(mrng) != sizeof (struct pcg32_random))
    RUNTIME_ERROR_ARG(0, error_bad_value, "invalid random state");

  struct pcg32_random *rng = (struct pcg32_random *)mrng->str;

  long min = intval(mmin);
  long max = intval(mmax);
  if (min > max)
    RUNTIME_ERROR(error_bad_value, "lower bound > upper bound");

  unsigned long range = max - min;
  if (range <= UINT32_MAX)
    return makeint(min + random_range32_r(rng, range));

  return makeint(min + (unsigned long)random_range64_r(rng, range));
}

TYPEDOP(srandom, ,
        "`n|null -> `s. Creates a random state from seed `n (or a randomly"
        " generated value if null) for use with `random_r().",
        (value mseed), OP_LEAF | OP_NOESCAPE, "[nu].s")
{
  struct string *mrng = alloc_string_noinit(sizeof (struct pcg32_random));
  struct pcg32_random *rng = (struct pcg32_random *)mrng->str;
  if (mseed == NULL)
    pcg32_srandom(rng);
  else
    pcg32_srandom_r(rng, intval(mseed), intval(mseed));
  return mrng;
}

TYPEDOP(overflow_neg, "overflow:neg",
        "`n0 -> `n1. Return -`n0, throwing an error on integer overflow.",
        (value n),
        OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "n.n")
{
  CHECK_TYPES(n, integer);
  long r;
  if (__builtin_sub_overflow(2, (long)n, &r))
    RUNTIME_ERROR(error_bad_value, "overflow");
  return (value)r;
}

TYPEDOP(overflow_abs, "overflow:abs",
        "`n0 -> `n1. Return the absolute value of `n0, throwing an error on"
        " integer overflow.",
        (value n),
        OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "n.n")
{
  CHECK_TYPES(n, integer);
  if (n == makeint(MIN_TAGGED_INT))
    RUNTIME_ERROR(error_bad_value, "overflow");
  return (value)(labs((long)n - 1) + 1);
}

TYPEDOP(overflow_add, "overflow:add",
        "`n0 `n1 -> `n2. Return `n0 + `n1, throwing an error on integer"
        " overflow.",
        (value a, value b),
        OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "nn.n")
{
  CHECK_TYPES(a, integer,
              b, integer);
  long r;
  if (__builtin_add_overflow((long)a, (long)b - 1, &r))
    RUNTIME_ERROR(error_bad_value, (long)a > 0 ? "overflow" : "underflow");
  return (value)r;
}

TYPEDOP(overflow_sub, "overflow:sub",
        "`n0 `n1 -> `n2. Return `n0 - `n1, throwing an error on integer"
        " overflow.",
        (value a, value b),
        OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "nn.n")
{
  CHECK_TYPES(a, integer,
              b, integer);
  long r;
  if (__builtin_sub_overflow((long)a, (long)b - 1, &r))
    RUNTIME_ERROR(error_bad_value, (long)a > 0 ? "overflow" : "underflow");
  return (value)r;
}

TYPEDOP(overflow_mul, "overflow:mul",
        "`n0 `n1 -> `n2. Return `n0 * `n1, throwing an error on integer"
        " overflow.",
        (value a, value b),
        OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "nn.n")
{
  CHECK_TYPES(a, integer,
              b, integer);
  long r;
  if (__builtin_mul_overflow((long)a >> 1, (long)b - 1, &r))
    RUNTIME_ERROR(error_bad_value,
                  ((long)a ^ (long)b) >= 0 ? "overflow" : "underflow");
  return (value)(r | 1);
}

TYPEDOP(overflow_div, "overflow:div",
        "`n0 `n1 -> `n2. Return `n0 / `n1, throwing an error on integer"
        " overflow.\n"
        "`n1 must be non-zero.",
        (value a, value b),
        OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "nn.n")
{
  CHECK_TYPES(a, integer,
              b, integer);
  if (b == makeint(0))
    RUNTIME_ERROR(error_divide_by_zero, NULL);

  if (a == makeint(MIN_TAGGED_INT) && b == makeint(-1))
    RUNTIME_ERROR(error_bad_value, "overflow");
  return makeint(intval(a) / intval(b));
}

TYPEDOP(overflow_shl, "overflow:shl",
        "`n0 `n1 -> `n2. Return `n0 << `n1, throwing an error on integer"
        " overflow, which happens if the new sign bit differs from any bits"
        " shifted out.\n"
        "`n1 must be non-negative.",
        (value a, value b),
        OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "nn.n")
{
  unsigned long bn;
  CHECK_TYPES(a, integer,
              b, CT_AUTO_RANGE(bn));
  long an = intval(a);

  if (bn >= TAGGED_INT_BITS)
    {
      if (an == 0)
        return makeint(0);
    }
  else
    {
      /* the new (mudlle) sign bit must equal all bits shifted out, so the (C)
         topmost 'bn + 2' bits must be equal */
      long mask = ~0UL << (TAGGED_INT_BITS - 1 - bn);
      long ah = an & mask;
      if (ah == 0 || ah == mask)
        return makeint(an << bn);
    }

  RUNTIME_ERROR(error_bad_value, an >= 0 ? "overflow" : "underflow");
}

TYPEDOP(overflow_shr, "overflow:shr",
        "`n0 `n1 -> `n2. Return arithmetic right shift of `n0 by `n1 steps.\n"
        "`n1 must non-negative.",
        (value a, value b),
        OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "nn.n")
{
  unsigned long bn;
  CHECK_TYPES(a, integer,
              b, CT_AUTO_RANGE(bn));
  long an = intval(a);
  if (bn >= TAGGED_INT_BITS)
    return makeint(an >= 0 ? 0 : -1);
  /* right shift of negative numbers is implemented-defined; assert that it
     rounds to negative infinity */
  CASSERT((-3 >> 1) == -2);
  return makeint(an >> bn);
}

void arith_init(void)
{
  DEFINE(integerp);
  DEFINE(plus);
  DEFINE(iadd);
  DEFINE(subtract);
  DEFINE(negate);
  DEFINE(multiply);
  DEFINE(divide);
  DEFINE(remainder);
  DEFINE(modulo);
  DEFINE(smaller);
  DEFINE(smaller_equal);
  DEFINE(greater);
  DEFINE(greater_equal);
  DEFINE(min);
  DEFINE(max);
  DEFINE(abs);
  DEFINE(bitor);
  DEFINE(bitxor);
  DEFINE(bitand);
  DEFINE(shift_left);
  DEFINE(shift_right);
  DEFINE(bitnot);
  DEFINE(ffs);

  DEFINE(sqrt);
  DEFINE(random);
  DEFINE(random_r);
  DEFINE(srandom);

  DEFINE(overflow_abs);
  DEFINE(overflow_neg);
  DEFINE(overflow_add);
  DEFINE(overflow_sub);
  DEFINE(overflow_mul);
  DEFINE(overflow_div);
  DEFINE(overflow_shl);
  DEFINE(overflow_shr);

  system_define("MAXINT", makeint(MAX_TAGGED_INT));
  system_define("MININT", makeint(MIN_TAGGED_INT));
  system_define("INTBITS", makeint(TAGGED_INT_BITS));
}
