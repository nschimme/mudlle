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

#ifndef UTILS_H
#define UTILS_H

#include <stdarg.h>
#include <stddef.h>
#include <string.h>

#include "mudlle-macro.h"
#include "mudlle.h"

struct loc;
struct string;

extern bool erred;
extern bool use_nicename;

void collect_compiler_messages(void);
void send_compiler_messages(void);

void compile_error(const struct loc *loc, const char *fmt, ...)
  FMT_PRINTF(2, 3);
void compile_warning(const struct loc *loc, const char *fmt, ...)
  FMT_PRINTF(2, 3);
void compile_note(const struct loc *loc, const char *fmt, ...)
  FMT_PRINTF(2, 3);

struct cstrlen {
  const char *NONSTRING str;    /* not NUL-terminated */
  size_t len;
};

#define CSTRLEN(s) (struct cstrlen){ .str = (s), .len = sizeof (s) - 1 }

static inline struct cstrlen cstrlen_from_str(const char *s)
{
  return (struct cstrlen){ .str = s, .len = strlen(s) };
}

struct cstrlen cstrlen_from_mstr(struct string *s);

void *reverse_list_ofs(void *l, size_t ofs);

/* Reverses list 'l' of type 'type *' and returns the new list.
   *l must have a pointer field called 'next', pointing to the next item. */
#define reverse_list_field(l, type, next)                       \
  (CASSERT_TYPE(l, type *),                                     \
   CASSERT_TYPE((l)->next, type *),                             \
   (type *)reverse_list_ofs((l), offsetof(type, next)))

#define reverse_list(l, type) reverse_list_field(l, type, next)

static inline unsigned long get_stack_pointer(void)
{
  unsigned long r;
#if defined __x86_64__
  asm("movq %%rsp,%0" : "=r" (r));
#elif defined __aarch64__
  asm("mov %0,sp" : "=r" (r));
#else
 #warning Improve this
  volatile int v;
  r = (unsigned long)&v;
#endif
  return r;
}

#ifdef __GNUC__
static ALWAYS_INLINE int parity(unsigned u)
{
  return __builtin_parity(u);
}

static ALWAYS_INLINE int popcountl(unsigned long u)
{
  return __builtin_popcountl(u);
}

static ALWAYS_INLINE int popcount(unsigned u)
{
  return __builtin_popcount(u);
}

/* count leading zeros */
static ALWAYS_INLINE int clz(unsigned u)
{
  return u == 0 ? CHAR_BIT * sizeof u : __builtin_clz(u);
}

static ALWAYS_INLINE int clzl(unsigned long u)
{
  return u == 0 ? CHAR_BIT * sizeof u : __builtin_clzl(u);
}

static ALWAYS_INLINE int clzll(unsigned long long u)
{
  return u == 0 ? CHAR_BIT * sizeof u : __builtin_clzll(u);
}

#else  /* ! __GNUC__ */

int popcountl(unsigned long u);

static inline int popcount(unsigned u)
{
  return popcountl(u);
}

static inline int parity(unsigned u)
{
  return popcount(u) & 1;
}

int clz(unsigned u);
int clzl(unsigned long u);
int clzll(unsigned long long u);

int ffsl(long l);

#endif  /* ! __GNUC__ */

#define __DEF_POW2(suffix, size)                                        \
  static inline unsigned size next_pow2_u ## suffix(unsigned size u)    \
  {                                                                     \
    if (u == 0) return 1;       /* this produces better code */         \
    int bits = clz ## suffix(u | 1);                                    \
    assert(bits > 0);                                                   \
    return 1u ## suffix << (CHAR_BIT * sizeof (u) - bits);              \
  }                                                                     \
  static inline unsigned size next_pow2_u ## suffix(unsigned size u)
__DEF_POW2(, );
__DEF_POW2(l, long);
__DEF_POW2(ll, long long);
#undef __DEF_POW2

/* the next power of 2 strictly larger than 'u' */
#define NEXT_POW2(u)                                    \
  (_Generic((u),                                        \
            unsigned:           next_pow2_u,            \
            unsigned long:      next_pow2_ul,           \
            unsigned long long: next_pow2_ull)(u))

/* truncate 'src' to 'dst'; return true if successful */
bool double_to_long(long *dst, double src);

/* number of decimal digits needed to represent an n-bit unsigned number;
   28 / 93 > log 2 / log 10 */
#define BITS_DECIMAL_DIG(n) (((n) * 28 + 92) / 93)

#ifdef __x86_64__
  #define NOP1 "\x90"
  #define NOP2 "\x66\x90"
  #define NOP3 "\x0f\x1f\x00"
  #define NOP4 "\x0f\x1f\x40\x00"
  #define NOP5 "\x0f\x1f\x44\x00\x00"
  #define NOP6 "\x66\x0f\x1f\x44\x00\x00"
  #define NOP7 "\x0f\x1f\x80\x00\x00\x00\x00"
#endif

/* run body with 'bit' set to each set bit position in 'n' */
#define for_bits(n, bit)                                                \
  for (int bit, __fb_done = 0; (__fb_done = !__fb_done); )              \
    for (unsigned long __fb_n = _Generic(                               \
           (n) | 0UL, unsigned long: (n));                              \
         (__fb_n                                                        \
          ? (bit = ffsl(__fb_n) - 1, __fb_n -= 1UL << bit, true)        \
          : false); )

mode_t get_umask(void);

extern size_t pagesize;

void init_pagesize(void);

/* read-write for user/group/other */
#define S_IRWUGO (S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP | S_IROTH | S_IWOTH)

/* these handle INT_MIN and friends */
static inline unsigned abs_i(int i)
{
  return i < 0 ? -(i + 1) + 1U : (unsigned)i;
}

static inline unsigned long abs_l(long l)
{
  return l < 0 ? -(l + 1) + 1UL : (unsigned long)l;
}

static inline unsigned long long abs_ll(long ll)
{
  return ll < 0 ? -(ll + 1) + 1ULL : (unsigned long long)ll;
}

#define ABS(v) (_Generic((v) + 0,               \
                         int: abs_i,            \
                         long: abs_l,           \
                         long long: abs_ll)(v))

/* converts a digit in [0-9A-Za-z] into its value 0-35; or -1 for error */
static inline int xdigit_val(unsigned char c)
{
  if (c >= '0' && c <= '9')
    return c - '0';
  c &= ~('a' - 'A');            /* turns ASCII uppercase */
  if (c >= 'A' && c <= 'Z')
    return c - 'A' + 10;
  return -1;
}

struct strbuf;
uint64_t read_leb_u(const uint8_t **pos);
int64_t read_leb_s(const uint8_t **pos);
void sb_add_leb_u(struct strbuf *sb, uint64_t u);
void sb_add_leb_s(struct strbuf *sb, int64_t i);
unsigned leb_u_len(uint64_t u);
unsigned leb_s_len(int64_t i);

typedef void (*mudlle_log_fn)(const char *fmt, va_list va)
  FMT_PRINTF(1, 0);
void set_mudlle_log_callback(mudlle_log_fn fn);

void mudlle_log(const char *fmt, ...) FMT_PRINTF(1, 2);

#define FOR_MUDLLE_MARKUP(op, sep)              \
  op(error)  sep()                              \
  op(fn)     sep()                              \
  op(loc)    sep()                              \
  op(number) sep()                              \
  op(string) sep()                              \
  op(var)    sep()                              \
  op(type)

enum mudlle_markup {
  PREFIX_MAP(mudlle_markup_, EXPAND_ARGS, FOR_MUDLLE_MARKUP),
  mudlle_markup_types
};

const char *mudlle_markup(enum mudlle_markup mm, bool start);

void set_mudlle_markup(enum mudlle_markup mm,
                       const char *start, const char *end);

#define CMARKUP(how, what) "", (what), ""

#endif
