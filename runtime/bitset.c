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

#include "bitset.h"
#include "check-types.h"
#include "prims.h"

#include "../utils.h"

TYPEDOP(new_bitset, ,
        "`n -> `bitset. Returns an empty bitset usable for storing at"
        " least `n bits.",
	(value mbits),
	OP_TRIVIAL | OP_LEAF | OP_NOESCAPE, "n.s")
{
  long size;
  CHECK_TYPES(mbits, CT_RANGE(size, 0, MAX_STRING_SIZE * CHAR_BIT));
  size = (size + CHAR_BIT - 1) / CHAR_BIT;
  struct string *newp = alloc_string_noinit(size);
  memset(newp->str, 0, size);
  return newp;
}

TYPEDOP(bclear, ,
        "`bitset -> `bitset. Clears all bits of `bitset and returns it",
	(struct string *b),
	OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "s.s")
{
  CHECK_TYPES(b, string);
  memset(b->str, 0, string_len(b));
  return b;
}

static inline enum runtime_error ct_bit_e(long n, const char **errmsg,
                                          ulong *dstchr,
                                          unsigned char *dstmask,
                                          struct string *bitset)
{
  size_t maxn = string_len(bitset);
  if (maxn == 0)
    {
      *errmsg = "empty bitset";
      return error_bad_value;
    }
  maxn = maxn * CHAR_BIT - 1;
  if (n < 0 || (unsigned long)n > maxn)
    {
      *errmsg = out_of_range_message(n, 0, maxn);
      return error_bad_index;
    }
  ulong u = n;
  *dstchr = u / CHAR_BIT;
  *dstmask = P(u % CHAR_BIT);
  return error_none;
}

#define __CT_BIT_E(var, msg, dstchr_dstmask_bitset)             \
  ct_bit_e(var, msg, EXPAND_ARGS dstchr_dstmask_bitset)
#define CT_BIT(dstchr, dstmask, bitset)                         \
  CT_INT_P((&dstchr, &dstmask, bitset), __CT_BIT_E)

TYPEDOP(set_bitb, "set_bit!", "`bitset `n -> . Sets bit `n in `bitset",
	(struct string *bitset, value mnum),
	OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "sn.")
{
  ulong i;
  unsigned char mask;
  CHECK_TYPES(bitset, string,
              mnum, CT_BIT(i, mask, bitset));
  if (obj_readonlyp(&bitset->o))
    RUNTIME_ERROR(error_value_read_only, NULL);
  bitset->str[i] |= mask;
  undefined();
}

TYPEDOP(clear_bitb, "clear_bit!",
        "`bitset `n -> . Clears bit `n in `bitset",
	(struct string *bitset, value mnum),
	OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "sn.")
{
  ulong i;
  unsigned char mask;
  CHECK_TYPES(bitset, string,
              mnum,   CT_BIT(i, mask, bitset));
  if (obj_readonlyp(&bitset->o))
    RUNTIME_ERROR(error_value_read_only, NULL);
  bitset->str[i] &= ~mask;
  undefined();
}

static bool bit_is_set(const struct prim_op *op,
                       struct string *bitset, value mnum)
{
  ulong i;
  unsigned char mask;
  CHECK_TYPES_OP(op,
                 bitset,    string,
                 mnum, CT_BIT(i, mask, bitset));
  return bitset->str[i] & mask;
}

EXT_TYPEDOP(bit_setp, "bit_set?", "`bitset `n -> `b. True if bit `n is set",
            (struct string *bitset, value n), (bitset, n),
            OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "sn.n")
{
  return makebool(bit_is_set(THIS_OP, bitset, n));
}

TYPEDOP(bit_clearp, "bit_clear?",
        "`bitset `n -> `b. True if bit `n is not set",
	(struct string *bitset, value n),
	OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "sn.n")
{
  return makebool(!bit_is_set(THIS_OP, bitset, n));
}

/* All binary ops expect same-sized bitsets */
static struct string *bitset_binop(const struct prim_op *pop,
                                   struct string *b1, struct string *b2,
                                   bool alloc_new,
                                   void (*op)(const char *s1, const char *s2,
                                              char *to, size_t length))
{
  CHECK_TYPES_OP(pop, b1, string, b2, string);
  size_t l = string_len(b1);
  if (l != string_len(b2))
    RUNTIME_ERROR(error_bad_value, "arguments of different length");

  struct string *result;
  if (alloc_new)
    {
      GCPRO(b1, b2);
      result = alloc_string_noinit(l);
      UNGCPRO();
    }
  else if (obj_readonlyp(&b1->o))
    RUNTIME_ERROR(error_value_read_only, NULL);
  else
    result = b1;

  op(b1->str, b2->str, result->str, l);
  return result;
}

#define BITSET_OP(name, op)                             \
static void name ## _op(const char *s1, const char *s2, \
                        char *to, size_t length)        \
{                                                       \
  for (size_t pos = 0; pos < length; ++pos)             \
    to[pos] = s1[pos] op s2[pos];                       \
}                                                       \
static_assert(true, "")         /* force semicolon */

BITSET_OP(bunion, |);
BITSET_OP(bintersection, &);
BITSET_OP(bdifference, & ~);

static void bassign_op(const char *s1, const char *s2, char *to, size_t length)
{
  memcpy(to, s2, length);
}

#define B_SUFF_new ""
#define B_SUFF_mod "!"
#define B_DST_new  "`bitset3"
#define B_DST_mod  "`bitset1"
#define B_OPF_new  0
#define B_OPF_mod  OP_NOALLOC

/* 'type' is either 'new' or 'mod' to create a new bitset or modify bitset1 */
#define BITSET_BINOP(name, type, op)                                    \
TYPEDOP(name ## _ ## type, #name B_SUFF_ ## type,                       \
        "`bitset1 `bitset2 -> " B_DST_ ## type ". "                     \
        BBLHS(B_DST_ ## type " = ") "`bitset1 " #op " `bitset2.",       \
        (struct string *bitset1, struct string *bitset2),               \
        OP_TRIVIAL | OP_LEAF | OP_NOESCAPE | B_OPF_ ## type, "ss.s")    \
{                                                                       \
  return bitset_binop(THIS_OP, bitset1, bitset2, B_OPF_ ## type == 0,   \
                      name ## _op);                                     \
}

#define BBLHS(what)
BITSET_BINOP(bassign,       mod, =)
#undef BBLHS
#define BBLHS(what) what
BITSET_BINOP(bdifference,   new, -)
BITSET_BINOP(bdifference,   mod, -)
BITSET_BINOP(bintersection, new, /\\)
BITSET_BINOP(bintersection, mod, /\\)
BITSET_BINOP(bunion,        new, U)
BITSET_BINOP(bunion,        mod, U)
#undef BBLHS

TYPEDOP(bitset_inp, "bitset_in?",
        "`bitset1 `bitset2 -> `b. True if `bitset1 is a subset of `bitset2",
	(struct string *bitset1, struct string *bitset2),
	OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "ss.n")
{
  CHECK_TYPES(bitset1, string, bitset2, string);
  size_t l = string_len(bitset1);
  if (l != string_len(bitset2))
    RUNTIME_ERROR(error_bad_value, "arguments of different length");

  const char *sb1 = bitset1->str, *sb2 = bitset2->str;
  for (; l > 0; --l)
    if (*sb1++ & ~*sb2++)
      return makebool(false);

  return makebool(true);
}

TYPEDOP(bitset_eqp, "bitset_eq?",
        "`bitset1 `bitset2 -> `b. True if `bitset1 == `bitset2",
	(struct string *bitset1, struct string *bitset2),
	OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "ss.n")
{
  CHECK_TYPES(bitset1, string, bitset2, string);
  size_t l = string_len(bitset1);
  if (l != string_len(bitset2))
    RUNTIME_ERROR(error_bad_value, "arguments of different length");
  return makebool(memcmp(bitset1->str, bitset2->str, l) == 0);
}

TYPEDOP(bemptyp, "bempty?",
        "`bitset -> `b. True if `bitset has all bits clear",
	(struct string *bitset),
	OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "s.n")
{
  CHECK_TYPES(bitset, string);
  size_t l = string_len(bitset);
  const char *sb = bitset->str;
  while (l-- > 0)
    if (*sb++) return makebool(false);

  return makebool(true);
}

TYPEDOP(bcount, , "`bitset -> `n. Returns the number of bits set in `bitset",
	(struct string *bitset),
	OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "s.n")
{
  CHECK_TYPES(bitset, string);

  size_t l = string_len(bitset);
  const unsigned char *sb = (const unsigned char *)bitset->str;
  int n = 0;
  while (l >= sizeof (unsigned long))
    {
      n += popcountl(*(unsigned long *)sb);
      l -= sizeof (unsigned long);
      sb += sizeof (unsigned long);
    }
  if (l > 0)
    {
      unsigned long u = 0;
      do
        u = (u << CHAR_BIT) | *sb++;
      while (--l > 0);
      n += popcountl(u);
    }
  return makeint(n);
}

TYPEDOP(bcount_intersection, , "`bitset0 `bitset1 -> `n. Returns the number of"
        " bits set in `bitset0 /\\ `bitset1.",
	(struct string *bitset0, struct string *bitset1),
	OP_TRIVIAL | OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "ss.n")
{
  CHECK_TYPES(bitset0, string,
              bitset1, string);

  size_t l = string_len(bitset0);
  if (l != string_len(bitset1))
    RUNTIME_ERROR(error_bad_value, "arguments of different length");

  const unsigned char *sb0 = (const unsigned char *)bitset0->str;
  const unsigned char *sb1 = (const unsigned char *)bitset1->str;
  long n = 0;
  while (l >= sizeof (unsigned long))
    {
      n += popcountl(*(unsigned long *)sb0 & *(unsigned long *)sb1);
      l -= sizeof (unsigned long);
      sb0 += sizeof (unsigned long);
      sb1 += sizeof (unsigned long);
    }
  if (l > 0)
    {
      unsigned long u = 0;
      do
        u = (u << CHAR_BIT) | (*sb0++ & *sb1++);
      while (--l > 0);
      n += popcountl(u);
    }
  return makeint(n);
}

void bitset_init(void)
{
  DEFINE(new_bitset);
  DEFINE(bclear);
  DEFINE(bemptyp);

  DEFINE(set_bitb);
  DEFINE(clear_bitb);

  DEFINE(bit_setp);
  DEFINE(bit_clearp);

  DEFINE(bassign_mod);
  DEFINE(bdifference_new);
  DEFINE(bdifference_mod);
  DEFINE(bintersection_new);
  DEFINE(bintersection_mod);
  DEFINE(bunion_new);
  DEFINE(bunion_mod);

  DEFINE(bitset_inp);
  DEFINE(bitset_eqp);

  DEFINE(bcount);
  DEFINE(bcount_intersection);
}
