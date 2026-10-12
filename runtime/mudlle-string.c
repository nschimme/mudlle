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

#include <ctype.h>
#include <errno.h>
#include <fnmatch.h>
#include <iconv.h>
#include <locale.h>

#ifdef USE_ICU
#include <unicode/uchar.h>
#endif

#include "../charset.h"
#include "../hash.h"
#include "../print.h"
#include "../utils.h"

#include "mudlle-string.h"
#include "prims.h"


#ifdef USE_PCRE
#  define PCRE2_CODE_UNIT_WIDTH 8
#  include <pcre2.h>
#endif

#ifdef USE_PCRE
/* these flags overlap with some of PCRE's normal flags on 32-bit hosts */
#define PCRE_7BIT     ((MAX_TAGGED_INT >> 1) + 1) /* highest bit */
#define PCRE_INDICES  (PCRE_7BIT >> 1)            /* second highest bit */
#define PCRE_BOOLEAN  (PCRE_7BIT >> 2)            /* third highest bit */
#define PCRE_SUBMATCH (PCRE_7BIT >> 3)            /* fourth highest bit */

#undef LOCAL_MUDLLE_TYPES
#define LOCAL_MUDLLE_TYPES struct mregexp *: true,

struct mregexp_data {
  pcre2_code *re;
  pcre2_match_data *mdata;
};

struct mregexp {
  struct obj o;
  struct mregexp_data *data;
};
#endif  /* USE_PCRE */

enum runtime_error ct_string_index(long idx, const char **errmsg,
                                   struct string *str, bool beyond,
                                   long *dst)
{
  if (idx < 0)
    idx += string_len(str);
  if (idx < 0 || (size_t)idx >= string_len(str) + beyond)
    {
      *errmsg = "string index out of range";
      return error_bad_index;
    }
  *dst = idx;
  return error_none;
}

TYPEDOP(stringp, "string?", "`x -> `b. True if `x is a string", (value v),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY, "x.n")
{
  return makebool(TYPE(v, string));
}

TYPEDOP(make_string, , "`n -> `s. Create an all-zero string of length `n,"
        " where 0 <= `n <= `MAX_STRING_SIZE.",
        (value msize), OP_LEAF | OP_NOESCAPE, "n.s")
{
  int size = GETRANGE(msize, 0, MAX_STRING_SIZE);
  struct string *newp = alloc_string_noinit(size);
  /* alloc_string_noinit() doesn't zero its data,
   * and we don't want to pass sensitive info to
   * someone on accident, so let's zero away... */
  memset(newp->str, 0, size);
  return newp;
}

TYPEDOP(slength, , "`s -> `n. Returns the length of string `s.",
        (struct string *str),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY, "s.n")
{
  CHECK_TYPES(str, string);
  return makeint(string_len(str));
}


#define DEF_MEM_TRANS(name, op)                         \
static void name(char *dst, const char *src, size_t l)  \
{                                                       \
  for (; l; --l, ++src, ++dst)                          \
    *dst = op(*src);                                    \
}                                                       \
static void name(char *dst, const char *src, size_t l)

DEF_MEM_TRANS(mem8lwr, TO_8LOWER);
DEF_MEM_TRANS(mem8upr, TO_8UPPER);
DEF_MEM_TRANS(mem7prt, TO_7PRINT);

static value string_translate(struct string *src,
                              void (*f)(char *, const char *, size_t),
                              const struct prim_op *op)
{
  CHECK_TYPES_OP(op, src, string);
  size_t l = string_len(src);

  GCPRO(src);
  struct string *dst = alloc_string_noinit(l);
  UNGCPRO();

  f(dst->str, src->str, l);
  return dst;
}

TYPEDOP(string_downcase, , "`s0 -> `s1. Returns a copy of `s0 with all"
        " characters lowercase",
	(struct string *s),
	OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "s.s")
{
  return string_translate(s, mem8lwr, THIS_OP);
}

TYPEDOP(string_upcase, , "`s0 -> `s1. Returns a copy of `s0 with all"
        " characters uppercase",
	(struct string *s),
	OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "s.s")
{
  return string_translate(s, mem8upr, THIS_OP);
}

TYPEDOP(string_7bit, , "`s0 -> `s1. Returns a copy of `s0 with all characters"
        " converted to printable 7 bit form",
	(struct string *s),
	OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "s.s")
{
  return string_translate(s, mem7prt, THIS_OP);
}


static value string_span(const char *start, const char *end,
                         const char *accept, long alen)
{
  const char *str = start;
  if (alen == 1)
    {
      char c = *accept;
      for (; str < end; ++str)
        if (*str != c)
          break;
    }
  else
    for (; str < end; ++str)
      if (memchr(accept, *str, alen) == NULL)
        break;
  return makeint(str - start);
}

static value string_cspan(const char *start, const char *end,
                          const char *reject, long rlen)
{
  const char *str = start;
  if (rlen == 0)
    ;
  else if (rlen == 1)
    {
      char c = *reject;
      for (; str < end; ++str)
        if (*str == c)
          break;
    }
  else
    for (; str < end; ++str)
      if (memchr(reject, *str, rlen) != NULL)
        break;
  return makeint(str - start);
}

static value string_xspan(struct string *s, value mofs, value mmax,
                          struct string *filter,
                          value (*func)(const char *, const char *,
                                        const char *, long),
                          const struct prim_op *op)
{
  long ofs, max;
  CHECK_TYPES_OP(op,
                 s,      string,
                 mofs,   CT_STR_IDX(ofs, s, true),
                 mmax,   CT_RANGE(max, 0, LONG_MAX),
                 filter, string);
  const char *start = s->str + ofs;
  size_t slen = string_len(s);
  max += ofs;
  if ((ulong)max > slen)
    max = slen;
  const char *end = s->str + max;
  return func(start, end, filter->str, string_len(filter));
}

TYPEDOP(string_span, , "`s0 `n0 `n1 `s1 -> `n2. Returns the number of"
        " characters, but at most `n1, in string `s0, starting at offset `n0,"
        " that consist entirely of characters in `s1.\n"
        "See also `string_cspan().",
        (struct string *s, value mofs, value mmax, struct string *accept),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY | OP_CONST, "snns.n")
{
  return string_xspan(s, mofs, mmax, accept, string_span, THIS_OP);
}

TYPEDOP(string_cspan, , "`s0 `n0 `n1 `s1 -> `n2. Returns the number of"
        " characters, at most `n1, in string `s0 starting at offset `n0"
        " that consists entirely of characters not in `s1.\n"
        "See also `string_span().",
        (struct string *s, value mofs, value mmax, struct string *reject),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY | OP_CONST, "snns.n")
{
  return string_xspan(s, mofs, mmax, reject, string_cspan, THIS_OP);
}

TYPEDOP(sdelete, "sdelete", "`n `s0 -> `s1. Return a copy of `s0 without any"
        " occurrence of character `n.",
        (value mc, struct string *src),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY | OP_CONST, "ns.s")
{
  unsigned char c;
  CHECK_TYPES(mc,  CT_RANGE(c, SCHAR_MIN, UCHAR_MAX),
              src, string);
  size_t slen = string_len(src);

  long count = 0;
  for (const char *sp = src->str, *const send = sp + slen;
       (sp = memchr(sp, c, send - sp));
       ++sp)
    ++count;

  /* count is now the number of occurrences of c */
  GCPRO(src);
  struct string *dst = alloc_string_noinit(slen - count);
  UNGCPRO();

  char *dp = dst->str;
  for (const char *sp = src->str, *const send = sp + slen; sp < send; ++sp)
    {
      unsigned char x = *sp;
      if (x != c)
        *dp++ = x;
    }
  return dst;
}

TYPEDOP(sfillb, "sfill!", "`s `n -> `s. Set all characters of `s to"
        " character `n",
	(struct string *str, value mc),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "sn.1")
{
  unsigned char c;
  CHECK_TYPES(str, string,
              mc,  CT_RANGE(c, SCHAR_MIN, UCHAR_MAX));

  size_t len = string_len(str);
  /* allow readonly for empty string */
  if (len == 0)
    return str;
  if (obj_readonlyp(&str->o))
    RUNTIME_ERROR(error_value_read_only, NULL);
  memset(str->str, c, len);
  return str;
}

TYPEDOP(string_from_utf8, , "`s0 `n -> `s1. Returns the UTF-8 string `s0"
        " converted to an ISO" NBSP "8859-1 string. `n controls how conversion"
        " errors are handled:\n"
        "   0  \tcharacters that cannot be represented in ISO" NBSP "8859-1"
        " and incorrect UTF-8 codes cause a runtime error\n"
        "   1  \tcharacters that cannot be represented are translitterated"
        " if possible; incorrect codes cause a runtime error\n"
        "   2  \tcharacters that cannot be represented are translitterated"
        " if possible; incorrect codes are skipped\n"
        "   3  \tcharacters that cannot be represented and incorrect"
        " codes are skipped",
        (struct string *s, value mmode),
	OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "sn.s")
{
  int mode;
  CHECK_TYPES(s,     string,
              mmode, CT_RANGE(mode, 0, 3));
  const char *toenc = NULL;
  switch (mode)
    {
    case 0: toenc = "ISO-8859-1"; break;
    case 1: case 2: toenc = "ISO-8859-1//TRANSLIT"; break;
    case 3: toenc = "ISO-8859-1//IGNORE"; break;
    }
  if (toenc == NULL)
    runtime_error(error_bad_value);

  iconv_t cd = iconv_open(toenc, "UTF-8");
  if (cd == (iconv_t)-1)
    RUNTIME_ERROR(error_bad_value, NULL);

  struct oport *op = NULL;
  GCPRO(op, s);

  struct string *result;

  size_t inpos = 0;
  size_t inlen = string_len(s);
  for (;;)
    {
      char buf[4096];
      size_t r, oused;
      {
        char *instr = s->str + inpos;
        size_t olen = sizeof buf;
        char *ostr = buf;
        r = iconv(cd, &instr, &inlen, &ostr, &olen);
        oused = ostr - buf;
        inpos = instr - s->str;
      }
      if (r == (size_t)-1 && errno != E2BIG && inlen > 0)
        {
          if (mode >= 2)
            {
              --inlen;
              ++inpos;
            }
          else
            {
              iconv_close(cd);
              runtime_error(error_bad_value);
            }
        }
      if (op == NULL)
        {
          if (inlen == 0)
            {
              /* common (?) case; everything converted in one go */
              result = alloc_string_length(buf, oused);
              break;
            }
          op = make_string_port();
        }
      port_write(op, buf, oused);
      if (inlen == 0)
        {
          result = port_string(op, SIZE_MAX);
          break;
        }
    }
  UNGCPRO();
  iconv_close(cd);
  return result;
}

value string_ref(struct string *str, value midx, const struct prim_op *op)
{
  long idx;
  CHECK_TYPES_OP(op,
                 str,  string,
                 midx, CT_STR_IDX(idx, str, false));
  return makeint((unsigned char)str->str[idx]);
}

TYPEDOP(string_ref, , "`s `n1 -> `n2. Return the code (`n2) of the `n1'th"
        " character of `s. Negative `n1 are counted from the end of `s.",
        (struct string *str, value midx),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY, "sn.n")
{
  return string_ref(str, midx, THIS_OP);
}

value mudlle_string_set(struct string *str, value midx, value mc,
                    const struct prim_op *op)
{
  long idx;
  long c;
  CHECK_TYPES_OP(op,
                 str, string,
                 midx,   CT_STR_IDX(idx, str, false),
                 mc,  CT_INT(c));
  if (obj_readonlyp(&str->o))
    RUNTIME_ERROR(error_value_read_only, NULL);
  return makeint((unsigned char)(str->str[idx] = c));
}

TYPEDOP(string_set, "string_set!", "`s `n1 `n2 -> `n3. Set the `n1'th"
        " character of `s to the character whose code is `n2.\n"
        "Negative `n1 are counted from the end of `s.\n"
        "The return value is the actual stored value, which is `n2 & 255.",
        (struct string *str, value midx, value mc),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "snn.n")
{
  return mudlle_string_set(str, midx, mc, THIS_OP);
}

static void check_string_binop(struct string *s1, struct string *s2,
                               const struct prim_op *op)
{
  CHECK_TYPES_OP(op, s1, string, s2, string);
}

#define STRING_CMP(type, desc, canon)                                   \
static int string_n ## type ## cmp(struct string *s1,                   \
                                   struct string *s2, ulong lmax)       \
{                                                                       \
  size_t l1 = string_len(s1);                                           \
  if (l1 > lmax) l1 = lmax;                                             \
  size_t l2 = string_len(s2);                                           \
  if (l2 > lmax) l2 = lmax;                                             \
  const char *t1 = s1->str;                                             \
  const char *t2 = s2->str;                                             \
                                                                        \
  size_t minlen = MIN(l1, l2);                                          \
  if (IF_EMPTY(type)(true, false))                                      \
    {                                                                   \
      int r = memcmp(t1, t2, minlen);                                   \
      r = r == 0 ? CMP(l1, l2) : CMP(r, 0);                             \
      return r;                                                         \
    }                                                                   \
                                                                        \
  for (size_t i = 0; i < minlen; ++i, ++t1, ++t2)                       \
    {                                                                   \
      int diff = CMP(canon(*t1), canon(*t2));                           \
      if (diff) return diff;                                            \
    }                                                                   \
  return CMP(l1, l2);                                                   \
}                                                                       \
                                                                        \
TYPEDOP(string_n ## type ## cmp, , "`s1 `s2 `n0 -> `n1. Compare at"     \
        " most `n0 characters of two strings" desc "."                  \
        " Returns 0 if `s1 = `s2, < 0 if `s1 < `s2"                     \
        " and > 0 if `s1 > `s2",                                        \
	(struct string *s1, struct string *s2, value nmax),             \
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE                              \
        | OP_STR_READONLY | OP_CONST,                                   \
        "ssn.n")                                                        \
{                                                                       \
  ulong lmax;                                                           \
  CHECK_TYPES(s1,   string,                                             \
              s2,   string,                                             \
              nmax, CT_AUTO_RANGE(lmax));                               \
  return makeint(string_n ## type ## cmp(s1, s2, lmax));                \
}                                                                       \
                                                                        \
TYPEDOP(string_ ## type ## cmp, , "`s1 `s2 -> `n. Compare two"          \
        " strings" desc ". Returns 0 if `s1 = `s2, < 0 if `s1 < `s2"    \
        " and > 0 if `s1 > `s2",                                        \
	(struct string *s1, struct string *s2),                         \
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE                              \
        | OP_STR_READONLY | OP_CONST,                                   \
        "ss.n")                                                         \
{                                                                       \
  check_string_binop(s1, s2, THIS_OP);                                  \
  return makeint(string_n ## type ## cmp(s1, s2, LONG_MAX));            \
}                                                                       \
                                                                        \
TYPEDOP(string_ ## type ## equalp, "string_" #type "equal?",            \
        "`s1 `s2 -> `b. Return true if `s1 and `s2 are equal" desc ".", \
        (struct string *s1, struct string *s2),                         \
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE                              \
        | OP_STR_READONLY | OP_CONST,                                   \
        "ss.n")                                                         \
{                                                                       \
  check_string_binop(s1, s2, THIS_OP);                                  \
  return makebool(string_n ## type ## cmp(s1, s2, LONG_MAX) == 0);      \
}

STRING_CMP(, , (unsigned char))
STRING_CMP(8i, " ignoring case", TO_8LOWER)
STRING_CMP(i, " ignoring accentuation and case", TO_7LOWER)

int mudlle_strcmp(struct string *a, struct string *b)
{
  return string_ncmp(a, b, LONG_MAX);
}

int mudlle_istrcmp(struct string *a, struct string *b)
{
  return string_nicmp(a, b, LONG_MAX);
}

static value string_index(struct string *haystack, char needle, long ofs)
{
  const char *str = haystack->str;
  const char *found = memchr(str + ofs, needle, string_len(haystack) - ofs);
  if (found == NULL)
    return makeint(-1);
  return makeint(found - str);
}

TYPEDOP(string_index, ,
        "`s `n1 -> `n2. Returns the index in `s of the first occurrence"
        " of the character `n1, or -1 if not found.",
        (struct string *haystack, value mneedle),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY | OP_CONST,
        "sn.n")
{
  long needle;
  CHECK_TYPES(haystack, string,
              mneedle,  CT_INT(needle));
  return string_index(haystack, needle, 0);
}

TYPEDOP(string_index_offset, ,
        "`s `n1 `n2 -> `n3. Returns the index in `s of the first occurrence,"
        " not before index `n2, of the character `n1, or -1 if not found.",
        (struct string *haystack, value mneedle, value mofs),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY | OP_CONST,
        "snn.n")
{
  long ofs, needle;
  CHECK_TYPES(haystack, string,
              mneedle,  CT_INT(needle),
              mofs,     CT_STR_IDX(ofs, haystack, true));
  return string_index(haystack, needle, ofs);
}

/* find distance from the last character to its previous occurrence
   or length of string if none */
static size_t steplen(const char *s, size_t l)
{
  char c = s[l - 1];
  for (size_t step = 1; step < l; ++step)
    if (s[l - 1 - step] == c)
      return step;
  return l;
}

static size_t step7ilen(const char *s, size_t l)
{
  unsigned char c = TO_7LOWER(s[l - 1]);
  for (size_t step = 1; step < l; ++step)
    if (TO_7LOWER(s[l - 1 - step]) == c)
      return step;
  return l;
}

static int string_search(struct string *s1, struct string *s2,
                         long ofs,
                         int (*cmpfn)(const void *, const void *, size_t),
                         void *(*chrfn)(const void *, int, size_t),
                         size_t (*stepfn)(const char *, size_t))
{
  size_t l1 = string_len(s1);
  size_t l2 = string_len(s2);

  if (ofs < 0)
    ofs += l1;
  if (ofs < 0 || (ulong)ofs > l1)
    runtime_error(error_bad_value);
  l1 -= ofs;

  /* Immediate termination conditions */
  if (l2 == 0) return 0;
  if (l2 > l1) return -1;

  const char *t1 = s1->str + ofs;
  const char *t2 = s2->str;

  size_t c2_step = stepfn(t2, l2);
  char lastc2 = t2[l2 - 1];
  size_t i = l2 - 1; /* No point in starting earlier */
  for (;;)
    {
      /* Search for lastc2 in t1 starting at i */
      const char *next_c2 = chrfn(t1 + i, lastc2, l1 - i);
      if (next_c2 == NULL)
        return -1;

      const char *check_start = next_c2 - (l2 - 1);
      if (cmpfn(check_start, t2, l2 - 1) == 0)
        return check_start - t1 + ofs;

      i += c2_step;
      if (i >= l1)
        return -1;
    }
}

int mudlle_string_isearch(struct string *haystack, struct string *needle)
{
  return string_search(haystack, needle, 0, mem7icmp, mem7ichr, step7ilen);
}

static value string_msearch(struct string *s1, struct string *s2,
                            long ofs,
                            int (*cmpfn)(const void *, const void *, size_t),
                            void *(*chrfn)(const void *, int, size_t),
                            size_t (*stepfn)(const char *, size_t))
{
  return makeint(string_search(s1, s2, ofs, cmpfn, chrfn, stepfn));
}

#define DEF_STRING_SEARCH(infix, cmpfn, chrfn, stepfn, doc)             \
TYPEDOP(string_ ## infix ## search, ,                                   \
        "`s1 `s2 -> `n. Searches in string `s1 for string `s2" doc "."  \
        " Returns the first index in `s1 where `s2 was found,"          \
        " or -1 if not found.",                                         \
	(struct string *s1, struct string *s2),                         \
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY | OP_CONST, \
        "ss.n")                                                         \
{                                                                       \
  CHECK_TYPES(s1, string,                                               \
              s2, string);                                              \
  return string_msearch(s1, s2, 0, cmpfn, chrfn, stepfn);               \
}                                                                       \
                                                                        \
TYPEDOP(string_ ## infix ## search_offset, ,                            \
        "`s1 `n0 `s2 -> `n1. Searches in string `s1, starting at"       \
        " offset `n0, for string `s2" doc ".\n"                         \
        "Returns the first index in `s1 where `s2 was found,"           \
        " or -1 if not found.",                                         \
	(struct string *s1, value mofs, struct string *s2),             \
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY | OP_CONST, \
        "sns.n")                                                        \
{                                                                       \
  long ofs;                                                             \
  CHECK_TYPES(s1,   string,                                             \
              mofs, CT_INT(ofs),                                        \
              s2,   string);                                            \
  return string_msearch(s1, s2, ofs, cmpfn, chrfn, stepfn);             \
}

DEF_STRING_SEARCH(,  memcmp,   memchr,   steplen, "")
DEF_STRING_SEARCH(i, mem7icmp, mem7ichr, step7ilen,
                  " (case- and accentuation-insensitive)")

TYPEDOP(substring, , "`s1 `n1 `n2 -> `s2. Extract substring of `s1 starting"
        " at `n1 of length `n2. The first character is numbered 0",
	(struct string *s, value start, value length),
	OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "snn.s")
{
  long first, size;
  CHECK_TYPES(s,      string,
              start,  CT_STR_IDX(first, s, true),
              length, CT_RANGE(size, 0, LONG_MAX));
  if ((ulong)(first + size) > string_len(s))
    RUNTIME_ERROR(error_bad_index, NULL);

  GCPRO(s);
  struct string *newp = alloc_string_noinit(size);
  UNGCPRO();
  memcpy(newp->str, s->str + first, size);

  return newp;
}

bool string_equalp(struct string *a, struct string *b)
{
  assert(TYPE(a, string) && TYPE(b, string));
  size_t la = string_len(a);
  return la == string_len(b) && memcmp(a->str, b->str, la) == 0;
}

VAROP(sconcat, , "`s0 `s1 ... -> `s. Returns the concatenated"
      " strings `s0, `s1, ... as a new string.\n"
      "The result cannot have more than `MAX_STRING_SIZE characters.",
      (struct vector *args),
      OP_STR_READONLY | OP_LEAF | OP_NOESCAPE, "s*.s")
{
  size_t nargs = vector_len(args);
  long size = 0;
  for (ulong n = 0; n < nargs; ++n)
    {
      TYPEIS(args->data[n], string);
      size += string_len((struct string *)(args->data[n]));
    }
  if (size > MAX_STRING_SIZE)
    runtime_error(error_bad_value);
  GCPRO(args);
  struct string *res = alloc_string_noinit(size);
  UNGCPRO();
  char *dest = res->str;
  for (ulong n = 0; n < nargs; ++n)
    {
      size_t l = string_len((struct string *)(args->data[n]));
      memcpy(dest, ((struct string *)(args->data[n]))->str, l);
      dest += l;
    }
  return res;
}

value concat_strings(long count, struct string **strings)
{
  enum runtime_error error = error_bad_type;
  long size = 0;
  for (long n = 0; n < count; ++n)
    {
      if (!TYPE(strings[n], string))
        goto got_error;
      size += string_len(strings[n]);
    }
  if (size > MAX_STRING_SIZE)
    {
      error = error_bad_value;
      goto got_error;
    }

  struct string *res = alloc_string_noinit(size);
  char *dest = res->str;
  for (int n = 0; n < count; ++n)
    {
      size_t l = string_len(strings[n]);
      memcpy(dest, strings[n]->str, l);
      dest += l;
    }
  return res;

 got_error: ;
  struct vector *v = alloc_vector(count);
  memcpy(v->data, strings, count * sizeof *strings);
  primitive_runtime_error(error, &op_sconcat, NARGSPLUS(0), v);
}

value string_append(struct string *s1, struct string *s2,
                    const struct prim_op *op)
{
  size_t l1 = string_len(s1);
  size_t l2 = string_len(s2);

  long nl = l1 + l2;
  if (nl > MAX_STRING_SIZE)
    primitive_runtime_error_msg(
      error_bad_value,
      fmt_error_message("result would exceed %s%s%s characters",
                        CMARKUP(var, "MAX_STRING_SIZE")),
      op, -1, 2, s1, s2);

  GCPRO(s1, s2);
  struct string *newp = alloc_string_noinit(nl);
  UNGCPRO();
  memcpy(newp->str, s1->str, l1);
  memcpy(newp->str + l1, s2->str, l2);

  return newp;
}

TYPEDOP(split_words, , "`s -> `l. Split string `s into a list of"
        " space-separated words.\n"
        "Single- or double-quoted sequences of words are kept together.",
        (struct string *s),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "s.l")
{
  CHECK_TYPES(s, string);

  size_t slen = string_len(s);
  struct list *head = NULL, *last = NULL;
  GCPRO(head, last, s);

  size_t idx = 0;

  for (;;)
    {
      while (idx < slen && s->str[idx] == ' ')
        ++idx;

      if (idx == slen)
        break;

      const char *endp;
      size_t end;
      if ((s->str[idx] == '\'' || s->str[idx] == '"') /* quoted words */
          && (endp = memchr(s->str + idx + 1, s->str[idx], slen - idx - 1)))
        end = endp - s->str + 1;
      else
        {
          end = idx + 1;
          while (end < slen && s->str[end] != ' ')
            ++end;
        }

      size_t len = end - idx;
      struct string *wrd = alloc_string_noinit(len);
      memcpy(wrd->str, s->str + idx, len);

      idx = end;

      struct list *this = alloc_list(wrd, NULL);
      if (head == NULL)
        head = this;
      else
        last->cdr = this;
      last = this;
    }

  UNGCPRO();

  return head;
}

TYPEDOP(atoi, , "`s -> `n|`s. Converts the string `s into an integer.\n"
        "Returns `s if the conversion failed.\n"
        "Handles binary, octal, decimal, and hexadecimal notation.\n"
        "Equivalent to `atoi_base(`s, 0).",
	(struct string *s),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY | OP_CONST,
        "s.[sn]")
{
  CHECK_TYPES(s, string);
  long n;
  if (!mudlle_strtolong(s->str, string_len(s), &n, 0, false))
    return s;
  return makeint(n);
}

TYPEDOP(atoi_base, , "`s `n0 -> `n1|`s. Converts the string `s into an"
        " integer.\n"
        "`n0 specifies the base, which must be between 2 and 36 inclusive,"
        " or the special value 0.\n"
        "Any leading whitespace is ignored. Then there may be an optional"
        " sign character (\"+\" or \"-\").\n"
        "For base 0, a following prefix decides the base: \"0x\" for"
        " hexadecimal (also allowed for base 16), \"0\" for octal,"
        " or \"0b\" for binary (also allowed for base 2). Any other digit"
        " means decimal base.\n"
        "Following the optional prefix, the rest of the number is"
        " interpreted according to the (possibly deduced) base.\n"
        "Returns `s if the conversion failed.",
	(struct string *s, value mbase),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY | OP_CONST,
        "sn.[sn]")
{
  long base;
  CHECK_TYPES(s,     string,
              mbase, CT_INT(base));
  if (base != 0 && (base < 2 || base > 36))
    RUNTIME_ERROR_ARG(
      1, error_bad_value,
      fmt_error_message("expected %s%d%s or [%s%d%s..%s%d%s]; got %s%ld%s",
                        CMARKUP(number, 0), CMARKUP(number, 2),
                        CMARKUP(number, 36), CMARKUP(number, base)));

  long n;
  if (!mudlle_strtolong(s->str, string_len(s), &n, base, false))
    return s;
  return makeint(n);
}

TYPEDOP(itoa, , "`n -> `s. Converts integer into string", (value mn),
        OP_LEAF | OP_NOESCAPE | OP_CONST, "n.s")
{
  long n;
  CHECK_TYPES(mn, CT_INT(n));

  struct intstr istr;
  return make_readonly(alloc_string(longtostr(&istr, 10, n)));
}

TYPEDOP(itoa_base, , "`n0 `n1 -> `s. Converts integer into string in base"
        " `n1 (2 to 36; or -2 to -36 for uppercase characters).",
        (value mn, value mbase),
        OP_LEAF | OP_NOESCAPE | OP_CONST, "nn.s")
{
  long n, base;
  CHECK_TYPES(mn,    CT_INT(n),
              mbase, CT_INT(base));

  if (base < -36 || base > 36 || (base >= -1 && base <= 1))
    RUNTIME_ERROR(error_bad_value, "invalid base");

  struct intstr istr;
  return make_readonly(alloc_string(longtostr(&istr, base, n)));
}

TYPEDOP(calphap, "calpha?", "`n -> `b. True if `n is a letter (allowed in"
        " keywords)",
	(value n),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST | OP_TRIVIAL, "n.n")
{
  unsigned char c;
  CHECK_TYPES(n, CT_RANGE(c, SCHAR_MIN, UCHAR_MAX));
  return makebool(IS_8NAME(c));
}

TYPEDOP(calnump, "calnum?", "`n -> `b. True if `n is a letter (allowed in"
        " keywords) or a digit.\n"
        "Equivalent to `calpha?(`n) || `cdigit?(`n).",
	(value n),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST | OP_TRIVIAL, "n.n")
{
  unsigned char c;
  CHECK_TYPES(n, CT_RANGE(c, SCHAR_MIN, UCHAR_MAX));
  return makebool(IS_8NAMENUM(c));
}

TYPEDOP(cdigitp, "cdigit?", "`n -> `b. True if `n is a digit",
	(value n),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST | OP_TRIVIAL, "n.n")
{
  unsigned char c;
  CHECK_TYPES(n, CT_RANGE(c, SCHAR_MIN, UCHAR_MAX));
  return makebool(IS_8DIGIT(c));
}

TYPEDOP(cxdigitp, "cxdigit?", "`n -> `b. True if `n is a hexadecimal digit",
	(value n),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST | OP_TRIVIAL, "n.n")
{
  unsigned char c;
  CHECK_TYPES(n, CT_RANGE(c, SCHAR_MIN, UCHAR_MAX));
  return makebool(isxdigit(c));
}

TYPEDOP(cprintp, "cprint?", "`n -> `b. True if `n is a printable character",
        (value n),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST | OP_TRIVIAL, "n.n")
{
  unsigned char c;
  CHECK_TYPES(n, CT_RANGE(c, SCHAR_MIN, UCHAR_MAX));
  return makebool(IS_8PRINT(c));
}

TYPEDOP(cspacep, "cspace?", "`n -> `b. True if `n is a whitespace character."
        " N.b., returns false for non-breaking space (`NBSP).",
        (value n),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST | OP_TRIVIAL, "n.n")
{
  unsigned char c;
  CHECK_TYPES(n, CT_RANGE(c, SCHAR_MIN, UCHAR_MAX));
  /* not using IS_8SPACE() so any line-wrapping code that uses
     cspace?() to find potential line breaks keeps working */
  return makebool(isspace(c));
}

TYPEDOP(cupperp, "cupper?", "`n -> `b. True if `n is an uppercase character",
        (value n),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST | OP_TRIVIAL, "n.n")
{
  unsigned char c;
  CHECK_TYPES(n, CT_RANGE(c, SCHAR_MIN, UCHAR_MAX));
  return makebool(TO_8LOWER(c) != c);
}

TYPEDOP(clowerp, "clower?", "`n -> `b. True if `n is an lowercase character",
        (value n),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST | OP_TRIVIAL, "n.n")
{
  unsigned char c;
  CHECK_TYPES(n, CT_RANGE(c, SCHAR_MIN, UCHAR_MAX));
  return makebool(TO_8UPPER(c) != c);
}

TYPEDOP(cupper, , "`n0 -> `n1. Return `n0's uppercase variant", (value n),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST | OP_TRIVIAL, "n.n")
{
  unsigned char c;
  CHECK_TYPES(n, CT_RANGE(c, SCHAR_MIN, UCHAR_MAX));
  return makeint(TO_8UPPER(c));
}

TYPEDOP(clower, , "`n0 -> `n1. Return `n0's lowercase variant", (value n),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST | OP_TRIVIAL, "n.n")
{
  unsigned char c;
  CHECK_TYPES(n, CT_RANGE(c, SCHAR_MIN, UCHAR_MAX));
  return makeint(TO_8LOWER(c));
}

TYPEDOP(cicmp, , "`n0 `n1 -> `n2. Compare characters `n0 and `n1 as"
        " `string_icmp() does. Returns -1, 0, or 1 if `n0 is less than,"
        " equal, or greater than `n1.",
        (value n0, value n1),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST | OP_TRIVIAL, "nn.n")
{
  unsigned char c0, c1;
  CHECK_TYPES(n0, CT_RANGE(c0, SCHAR_MIN, UCHAR_MAX),
              n1, CT_RANGE(c1, SCHAR_MIN, UCHAR_MAX));
  return makeint(CMP(TO_7LOWER(c0), TO_7LOWER(c1)));
}

TYPEDOP(c7bit, , "`n0 -> `n1. Return `n0's 7 bit variant", (value n),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST | OP_TRIVIAL, "n.n")
{
  unsigned char c;
  CHECK_TYPES(n, CT_RANGE(c, SCHAR_MIN, UCHAR_MAX));
  return makeint(TO_7PRINT(c));
}

TYPEDOP(unicode_char_name, , "`n -> `s|false. Returns the name of Unicode"
        " character `n, or false if unknown.", (value mchar),
        OP_LEAF | OP_NOESCAPE | OP_CONST, "n.[sz]")
{
  long lchar;
  CHECK_TYPES(mchar, CT_INT(lchar));

#ifdef USE_ICU
  if (lchar < 0 || lchar > UCHAR_MAX_VALUE)
    return makebool(false);

  static size_t namesize;
  static char *name;

  for (;;)
    {
      UErrorCode ustatus = U_ZERO_ERROR;
      int32_t len = u_charName(lchar, U_UNICODE_CHAR_NAME,
                               name, namesize, &ustatus);
      if (len <= 0)
        return makebool(false);

      if ((size_t)len < namesize)
        return make_readonly(alloc_string(name));

      free(name);
      namesize = NEXT_POW2((size_t)len);
      assert(namesize > (size_t)len);
      name = malloc(namesize);
    }
#else  /* ! USE_ICU */
  if (lchar < 0 || lchar >= 256)
    return makebool(false);
  const char *name = iso88591_char_name(lchar);
  if (name == NULL)
    return makebool(false);
  return make_readonly(alloc_string(name));
#endif /* ! USE_ICU */
}


TYPEDOP(string_hash, , "`s -> `n. Returns a case-sensitive hash value for `s.",
        (struct string *s),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY | OP_CONST, "s.n")
{
  CHECK_TYPES(s, string);
  return makeint(mudlle_string_hash(s));
}

TYPEDOP(string_ihash, , "`s -> `n. Returns a case-insensitive hash value"
        " for `s.",
        (struct string *s),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY | OP_CONST, "s.n")
{
  CHECK_TYPES(s, string);
  return makeint(mudlle_string_8ihash(s));
}

TYPEDOP(string_7ihash, , "`s -> `n. Returns a case- and"
        " accentuation-insensitive hash value for `s.",
        (struct string *s),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY | OP_CONST, "s.n")
{
  CHECK_TYPES(s, string);
  return makeint(mudlle_string_7ihash(s));
}

#ifdef USE_PCRE
static int mregexp_recursion_guard(uint32_t limit, void *data)
{
  if (get_stack_pointer() < mudlle_stack_limit)
    return -1;
  return 0;
}

struct pcre2_real_match_context_8 *get_pcre2_match_context(void)
{
  static pcre2_match_context *mregexp_match_context;

  if (mregexp_match_context != NULL)
    return mregexp_match_context;

  mregexp_match_context = pcre2_match_context_create(NULL);
  pcre2_set_heap_limit(mregexp_match_context, 256); /* kilobytes */
  pcre2_set_match_limit(mregexp_match_context, 4096);
  return mregexp_match_context;
}

struct pcre2_real_compile_context_8 *get_iso88591_pcre2_compile_context(void)
{
  static pcre2_compile_context *mregexp_compile_context;
  static bool been_here = false;

  if (been_here)
    return mregexp_compile_context;

  been_here = true;
  char *olocale = strdup(setlocale(LC_ALL, NULL));
  if (setlocale(LC_ALL, "en_US.iso88591") != NULL
      || setlocale(LC_ALL, "en_US.ISO8859-1") != NULL)
    {
      const uint8_t *table = pcre2_maketables(NULL);
      mregexp_compile_context = pcre2_compile_context_create(NULL);
      pcre2_set_character_tables(mregexp_compile_context, table);
      pcre2_set_parens_nest_limit(mregexp_compile_context, 32);
      pcre2_set_compile_recursion_guard(
        mregexp_compile_context, mregexp_recursion_guard, NULL);
      setlocale(LC_ALL, olocale);
    }
  else
    perror("setlocale(LC_ALL, \"en_US.iso88591\")");
  free(olocale);
  return mregexp_compile_context;
}
#endif /* ! USE_PCRE */

TYPEDOP(is_regexp, "regexp?", "`x -> `b. Returns true if `x is a"
        " regular expression, as created by `make_regexp()",
        (value re), OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_TRIVIAL, "x.n")
{
  return makebool(TYPE(re, regexp));
}

TYPEDOP(fnmatch, , "`s0 `s1 `n -> `b. Returns true if the glob pattern `s0"
        " matches the string `s1 using flags in `n:\n"
        "  \t`FNM_NOESCAPE  \tdo not treat backslash (\\) as an escape"
        " character\n"
        "  \t`FNM_PATHNAME  \tperform a pathname match, where wildcards"
        " (* and ?) only match between slashes\n"
        "  \t`FNM_PERIOD    \tdo not let wildcards match leading periods",
        (struct string *pat, struct string *str, value mflags),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY | OP_CONST,
        "ssn.n")
{
  long flags;
  CHECK_TYPES(pat,    string,
              str,    string,
              mflags, CT_INT(flags));
  if (flags & ~(FNM_NOESCAPE | FNM_PATHNAME | FNM_PERIOD))
    RUNTIME_ERROR(error_bad_value, "invalid flags");

  /* zero bytes cannot match or be matched */
  if (string_len(pat) != strlen(pat->str)
      || string_len(str) != strlen(str->str))
    return makebool(false);

  return makebool(fnmatch(pat->str, str->str, flags) == 0);
}

#ifdef USE_PCRE

static void free_mregexp(void *data)
{
  struct mregexp_data *rdata = data;
  pcre2_code_free(rdata->re);
  pcre2_match_data_free(rdata->mdata);
  free(rdata);
}

TYPEDOP(make_regexp, , "`s `n -> `r. Create a matcher for the regular"
        " expression `s with flags `n.\n"
        "Returns cons(`errorstring, `erroroffset) on error.\n"
	"The following flags are supported:\n"
	"  \t`PCRE_7BIT       \tconvert pattern to its 7-bit equivalent\n"
	"  \t`PCRE_ANCHORED   \tforce pattern anchoring\n"
	"  \t`PCRE_CASELESS   \tdo caseless matching\n"
	"  \t`PCRE_DOLLAR_ENDONLY\n"
	"                  \t$ only matches end of string,"
	" and not newline\n"
	"  \t`PCRE_DOTALL     \t. matches anything, including newline\n"
	"  \t`PCRE_EXTENDED   \tignore whitespace and # comments\n"
	"  \t`PCRE_MULTILINE  \t^ and $ match at newlines\n"
	"  \t`PCRE_UNGREEDY   \tinvert greedyness of quantifiers",
	(struct string *mpat, value mflags),
	OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "sn.[ok]")
{
  long flags;
  CHECK_TYPES(mpat,   string,
              mflags, CT_INT(flags));

  if (flags & ~(PCRE_7BIT | PCRE2_ANCHORED | PCRE2_CASELESS
                | PCRE2_DOLLAR_ENDONLY | PCRE2_DOTALL | PCRE2_EXTENDED
                | PCRE2_MULTILINE | PCRE2_UNGREEDY))
    RUNTIME_ERROR(error_bad_value, "invalid flags");

  char *patcopy = NULL;
  const char *cpat = mpat->str;

  if (flags & PCRE_7BIT)
    {
      cpat = patcopy = mudlle_string_dup(mpat);
      for (size_t i = 0; i < string_len(mpat); ++i)
        patcopy[i] = TO_7PRINT(patcopy[i]);
      flags &= ~PCRE_7BIT;
    }

  flags |= REQUIRED_PCRE_FLAGS;

  int errcode;
  size_t errofs;

  pcre2_code *re = pcre2_compile(
    (PCRE2_UCHAR8 *)cpat, string_len(mpat), flags, &errcode, &errofs,
    get_iso88591_pcre2_compile_context());

  free(patcopy);

  if (re == NULL)
    {
      char errstr[128];         /* the manual says this is enough */
      pcre2_get_error_message(errcode, (PCRE2_UCHAR8 *)errstr, sizeof errstr);
      return alloc_list(alloc_string(errstr), makeint(errofs));
    }

  struct mregexp_data *rdata = malloc(sizeof *rdata);
  struct mregexp *mre = (struct mregexp *)alloc_weak_ref(
    type_regexp, sizeof *mre, rdata, free_mregexp);
  mre->data = rdata;
  *rdata = (struct mregexp_data) { .re = re };
  return mre;
}

TYPEDOP(regexp_capture_groups, ,
        "`r -> `n. Returns the number of capture groups in regular"
        " expression `r.",
        (struct mregexp *mre), OP_LEAF | OP_NOESCAPE | OP_NOALLOC, "o.n")
{
  CHECK_TYPES(mre, regexp);
  uint32_t nfields;
  /* this should probably be an assertion */
  if (pcre2_pattern_info(
        mre->data->re, PCRE2_INFO_CAPTURECOUNT, &nfields) != 0)
    runtime_error(error_bad_value);
  return makeint(nfields);
}

TYPEDOP(regexp_exec, ,
        "`r `s `n0 `n1 -> `v|`b. Tries to match the string `s, starting at"
	" character `n0 with regexp matcher `r and flags `n1.\n\n"
	"Returns false if no match; otherwise, it returns a vector of"
	" submatches unless `PCRE_BOOLEAN or `PCRE_SUBMATCH are specified"
        " (see below).\n\n"
	"A submatch is either a string matched by the corresponding"
	" parenthesis group, or null if that group was not used.\n\n"
        "If `n1 & `PCRE_BOOLEAN, the result is a boolean saying whether a"
        " match was found.\n\n"
	"If `n1 & `PCRE_INDICES, submatches are instead represented as"
	" cons(`start, `length) or null.\n\n"
        "If `n1 & `PCRE_SUBMATCH, the result is instead information on the"
        " first matching submatch as vector(`submatch, `start, `length), where"
        " `submatch is the number of the first matching submatch. If no"
        " submatch matched, returns `submatch zero for the entire match.\n\n"
        "At most one of `PCRE_BOOLEAN, `PCRE_INDICES and `PCRE_SUBMATCH may"
        " be set.\n\n"
	"The following flags are supported:\n"
	"  \t`PCRE_7BIT      \tconvert the haystack to its 7-bit equivalent"
	" before matching\n"
	"  \t`PCRE_ANCHORED  \tmatch only at the first position\n"
        "  \t`PCRE_BOOLEAN   \tsee above\n"
	"  \t`PCRE_INDICES   \tsee above\n"
        "  \t`PCRE_SUBMATCH  \tsee above\n"
	"  \t`PCRE_NOTBOL    \t`s is not the beginning of a line\n"
	"  \t`PCRE_NOTEMPTY  \tan empty string is not a valid match\n"
	"  \t`PCRE_NOTEOL    \t`s is not the end of a line",
        (struct mregexp *mre, struct string *str, value mofs, value mflags),
	OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "osnn.[vn]")
{
  long flags, sofs;
  CHECK_TYPES(mre,    regexp,
              str,    string,
              mofs,   CT_STR_IDX(sofs, str, true),
              mflags, CT_INT(flags));

  bool boolean  = flags & PCRE_BOOLEAN;
  bool indices  = flags & PCRE_INDICES;
  bool submatch = flags & PCRE_SUBMATCH;
  flags &= ~(PCRE_INDICES | PCRE_BOOLEAN | PCRE_SUBMATCH);
  if (indices + boolean + submatch > 1)
    RUNTIME_ERROR(
      error_bad_value,
      "at most one of PCRE_{BOOLEAN,INDICES,SUBMATCH} may be specified");

  if (flags & ~(PCRE_7BIT | PCRE2_ANCHORED | PCRE2_NOTBOL | PCRE2_NOTEMPTY
                | PCRE2_NOTEOL))
    RUNTIME_ERROR(error_bad_value, "invalid flags");

  const char *haystack = str->str;
  size_t slen = string_len(str);
  char *lstr = NULL;

  if (flags & PCRE_7BIT)
    {
      lstr = malloc(slen + 1);
      for (size_t idx = 0; idx <= slen; ++idx)
        lstr[idx] = TO_7PRINT(haystack[idx]);
      haystack = lstr;
      flags &= ~PCRE_7BIT;
    }

  pcre2_match_data *mdata = mre->data->mdata;
  if (mdata == NULL)
    mdata = mre->data->mdata = pcre2_match_data_create_from_pattern(
      mre->data->re, NULL);
  int res = pcre2_match(mre->data->re, (PCRE2_UCHAR8 *)haystack, slen, sofs,
                        flags, mdata, get_pcre2_match_context());
  uint32_t mfields = pcre2_get_ovector_count(mdata);
  PCRE2_SIZE *ovector = pcre2_get_ovector_pointer(mdata);

  free(lstr);

  if (res == PCRE2_ERROR_NOMATCH)
    return makebool(false);
  if (res < 0)
    {
      char errstr[128];
      pcre2_get_error_message(res, (PCRE2_UCHAR8 *)errstr, sizeof errstr);
      RUNTIME_ERROR(error_bad_value, errstr);
    }
  if (boolean)
    return makebool(true);

  if (submatch)
    for (uint32_t i = 1; ; ++i)
      {
        if (i >= mfields)
          i = 0;            /* if no submatches, use the entire match */
        PCRE2_SIZE st = ovector[i * 2];
        if (st == PCRE2_UNSET)
          {
            assert(i != 0); /* the entire match must have matched */
            continue;
          }
        PCRE2_SIZE ln = ovector[i * 2 + 1] - st;
        struct vector *v = alloc_vector(3);
        v->data[0] = makeint(i);
        v->data[1] = makeint(st);
        v->data[2] = makeint(ln);
        return v;
      }

  struct vector *v = NULL;
  GCPRO(v, str);
  v = alloc_vector(mfields);

  for (uint32_t i = 0; i < mfields; ++i)
    {
      PCRE2_SIZE st = ovector[i * 2];
      if (st == PCRE2_UNSET)
        continue;
      PCRE2_SIZE ln = ovector[i * 2 + 1] - st;
      if (indices)
        SET_VECTOR(v, i, alloc_list(makeint(st), makeint(ln)));
      else
        {
          struct string *tmp = alloc_string_noinit(ln);
          memcpy(tmp->str, str->str + st, ln);
          v->data[i] = tmp;
        }
    }

  UNGCPRO();
  return v;
}

#endif /* USE_PCRE */

static void define_strings(void)
{
  const char host_type[] =
#if defined __x86_64__
    "x86_64"
#elif defined __aarch64__
    "arm64"
#elif defined __riscv && __riscv_xlen == 64
    "riscv64"
#else
#  error Fix me
#endif
    ;
  system_define("host_type", make_readonly(alloc_string(host_type)));
}

STATIC_STRING(static_obj_empty_string, "");
struct string *const static_empty_string
  = GET_STATIC_STRING(static_obj_empty_string);

void string_init(void)
{
  DEFINE(stringp);
  DEFINE(make_string);
  DEFINE(slength);
  DEFINE(sfillb);
  DEFINE(string_ref);
  DEFINE(string_set);
  DEFINE(string_cmp);
  DEFINE(string_icmp);
  DEFINE(string_8icmp);
  DEFINE(string_ncmp);
  DEFINE(string_nicmp);
  DEFINE(string_n8icmp);
  DEFINE(string_equalp);
  DEFINE(string_iequalp);
  DEFINE(string_8iequalp);
  DEFINE(string_search);
  DEFINE(string_search_offset);
  DEFINE(string_isearch);
  DEFINE(string_isearch_offset);
  DEFINE(string_index);
  DEFINE(string_index_offset);
  DEFINE(string_span);
  DEFINE(string_cspan);
  DEFINE(sdelete);
  DEFINE(substring);
  DEFINE(sconcat);
  DEFINE(split_words);
  DEFINE(itoa);
  DEFINE(itoa_base);
  DEFINE(atoi);
  DEFINE(atoi_base);
  DEFINE(string_upcase);
  DEFINE(string_downcase);
  DEFINE(string_7bit);
  DEFINE(string_from_utf8);

  DEFINE(calnump);
  DEFINE(calphap);
  DEFINE(cdigitp);
  DEFINE(clowerp);
  DEFINE(cprintp);
  DEFINE(cspacep);
  DEFINE(cupperp);
  DEFINE(cxdigitp);

  DEFINE(cupper);
  DEFINE(clower);
  DEFINE(cicmp);
  DEFINE(c7bit);

  DEFINE(unicode_char_name);


  DEFINE(string_hash);
  DEFINE(string_ihash);
  DEFINE(string_7ihash);

  define_strings();

  DEFINE(fnmatch);
  DEFINE_INT(FNM_NOESCAPE);
  DEFINE_INT(FNM_PATHNAME);
  DEFINE_INT(FNM_PERIOD);

  DEFINE(is_regexp);

#ifdef USE_PCRE
  DEFINE(make_regexp);
  DEFINE(regexp_exec);
  DEFINE(regexp_capture_groups);

  /* PCRE options */
  DEFINE_INT(PCRE_7BIT);
  DEFINE_INT(PCRE_BOOLEAN);
  DEFINE_INT(PCRE_INDICES);
  DEFINE_INT(PCRE_SUBMATCH);
#define DEF_PCRE(name) system_define("PCRE_" #name, makeint(PCRE2_ ## name))
  DEF_PCRE(ANCHORED);
  DEF_PCRE(CASELESS);
  DEF_PCRE(DOLLAR_ENDONLY);
  DEF_PCRE(DOTALL);
  DEF_PCRE(EXTENDED);
  DEF_PCRE(MULTILINE);
  DEF_PCRE(NOTBOL);
  DEF_PCRE(NOTEMPTY);
  DEF_PCRE(NOTEOL);
  DEF_PCRE(UNGREEDY);
#undef DEF_PCRE
#endif  /* USE_PCRE */

  DEFINE_INT(MAX_STRING_SIZE);
}
