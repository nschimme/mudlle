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

#ifdef __linux__
  #define _GNU_SOURCE           /* for qsort_r() */
#endif

#include <ctype.h>
#include <fenv.h>
#include <math.h>
#include <unistd.h>

#include <sys/stat.h>

#include "array.h"
#include "compile.h"
#include "context.h"
#include "ports.h"
#include "strbuf.h"             /* redundant include in MUME */
#include "tree.h"
#include "utils.h"


bool use_nicename;
bool erred;

enum log_type {
  vlog_error,
  vlog_warning,
  vlog_note
};

size_t pagesize;

void init_pagesize(void)
{
  long sz = sysconf(_SC_PAGESIZE);
  assert(sz > 0);
  pagesize = sz;
}

static struct {
  bool collecting;
  ARRAY_T(char *) m;
} compiler_messages;

void collect_compiler_messages(void)
{
  assert(!compiler_messages.collecting);
  compiler_messages.collecting = true;
}

static void send_one_compiler_message(const char *msg)
{
  pflush(mudout());

  pputs(msg, muderr());
  pputc('\n', muderr());
  pflush(muderr());
}

void send_compiler_messages(void)
{
  assert(compiler_messages.collecting);
  compiler_messages.collecting = false;

  ARRAY_FOR (compiler_messages.m, , char *, m)
    {
      send_one_compiler_message(m);
      free(m);
    }
  ARRAY_FREE(compiler_messages.m);
}

static FMT_PRINTF(3, 0) void vlog_message(
  const struct loc *loc, enum log_type ltype, const char *fmt, va_list va)
{
  if (should_suppress_compiler_messages())
    return;

  struct strbuf sb = SBNULL;

  bool use_fname = !use_nicename;

  unsigned col0 = loc->col - 1; /* zero-based column */
  if (loc != NULL && loc->line > 0 && loc->col > 0 && loc->pos >= col0
      && port_is_interactive(mudout_port))
    {
      get_compiler_line(&sb, loc->pos - col0);
      if (sb_len(&sb) > 0 && sb_len(&sb) >= col0)
        {
          if (compiler_messages.collecting)
            ARRAY_ADD(compiler_messages.m, sb_detach(&sb));
          else
            sb_addc(&sb, '\n');

          /* copy space characters verbatim in case they contain tabs */
          bool add_nl = !compiler_messages.collecting;
          size_t dstloc = sb_add_noinit(&sb, col0 + 1 + add_nl);
          char *dst = sb_mutable_str(&sb) + dstloc;
          for (const char *s = sb_str(&sb); col0 > 0; --col0, ++s)
            *dst++ = isspace((unsigned char)*s) ? *s : ' ';
          *dst++ = '^';
          if (add_nl)
            *dst++ = '\n';
          assert(dst == sb_str(&sb) + sb_len(&sb));

          if (compiler_messages.collecting)
            ARRAY_ADD(compiler_messages.m, sb_detach(&sb));
          else
            {
              port_write(muderr(), sb_str(&sb), sb_len(&sb));
              sb_empty(&sb);
            }
        }
    }

  if (loc == NULL || loc->fname == NULL)
    {
      abort();
    }

  sb_addstr(&sb, mudlle_markup(mudlle_markup_loc, true));
  sb_addstr(&sb, use_fname ? loc->fname->filename : loc->fname->nicename);
  sb_addc(&sb, ':');
  if (loc->line > 0)
    {
      sb_printf(&sb, "%d:", loc->line);
      if (loc->col > 0)
        sb_printf(&sb, "%d:", loc->col);
    }
  sb_addstr(&sb, mudlle_markup(mudlle_markup_loc, false));
  sb_addc(&sb, ' ');


  switch (ltype)
    {
    case vlog_error: erred = true; break;
    case vlog_warning: sb_addstr(&sb, "warning: "); break;
    case vlog_note: sb_addstr(&sb, "note: "); break;
    }
  if (use_fname && strcmp(loc->fname->nicename, loc->fname->filename) != 0)
    sb_printf(&sb, "[%s] ", loc->fname->nicename);

  if (ltype == vlog_error)
    sb_addstr(&sb, mudlle_markup(mudlle_markup_error, true));
  sb_vprintf(&sb, fmt, va);
  if (ltype == vlog_error)
    sb_addstr(&sb, mudlle_markup(mudlle_markup_error, false));

  if (compiler_messages.collecting)
    ARRAY_ADD(compiler_messages.m, sb_detach(&sb));
  else
    {
      send_one_compiler_message(sb_str(&sb));
      sb_free(&sb);
    }
}

void compile_error(const struct loc *loc, const char *fmt, ...)
{
  va_list args;
  va_start(args, fmt);
  vlog_message(loc, vlog_error, fmt, args);
  va_end(args);
}

void compile_warning(const struct loc *loc, const char *fmt, ...)
{
  va_list args;
  va_start(args, fmt);
  vlog_message(loc, vlog_warning, fmt, args);
  va_end(args);
}

void compile_note(const struct loc *loc, const char *fmt, ...)
{
  va_list args;
  va_start(args, fmt);
  vlog_message(loc, vlog_note, fmt, args);
  va_end(args);
}

/* ofs is the offset to the 'next' field */
void *reverse_list_ofs(void *l, size_t ofs)
{
  void *prev = NULL;
  while (l != NULL)
    {
      void **p = (void *)((char *)l + ofs);
      void *next = *p;
      *p = prev;
      prev = l;
      l = next;
    }
  return prev;
}

#ifndef __GNUC__
int popcountl(unsigned long u)
{
  static const uint8_t count[16] = {
    0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4
  };

  int n = 0;
  while (u > 0)
    {
      n += count[u & 15];
      u >>= 4;
    }
  return n;
}

/* count leading zeros */
int clz(unsigned u)
{
  CASSERT(sizeof (u) == sizeof (uint32_t));

  /* from https://en.wikipedia.org/wiki/Find_first_set */
  static const uint8_t count[16] = {
    4, 3, 2, 2, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0
  };

  unsigned n = 0;
  if ((u & 0xffff0000) == 0) {n += 16; u <<= 16;}
  if ((u & 0xff000000) == 0) {n +=  8; u <<=  8;}
  if ((u & 0xf0000000) == 0) {n +=  4; u <<=  4;}
  return n + count[(u >> (32 - 4)) & 15];
}

int clzl(unsigned long u)
{
  int r = CHAR_BIT * (sizeof (u) - sizeof (unsigned));
  while (u > UINT_MAX)
    {
      r -= CHAR_BIT * sizeof (unsigned);
      u >>= CHAR_BIT * sizeof (unsigned);
    }
  return r + clz(u);
}

int clzll(unsigned long long u)
{
  int r = CHAR_BIT * (sizeof (u) - sizeof (unsigned));
  while (u > UINT_MAX)
    {
      r -= CHAR_BIT * sizeof (unsigned);
      u >>= CHAR_BIT * sizeof (unsigned);
    }
  return r + clz(u);
}

int ffsl(long l)
{
  unsigned long u = l;
  const int INT_BIT = CHAR_BIT * sizeof (int);
  for (int add = 0; u; u >>= INT_BIT, add += INT_BIT)
    {
      int i = ffs(u);
      if (i > 0)
        return i + add;
    }
  return 0;
}

#endif  /* ! __GNUC__ */

/* truncate 'src' to 'dst'; return true if successful */
bool double_to_long(long *dst, double src)
{
#if !((defined __STDC_IEC_559__ || defined __MACH__) && defined FE_INVALID)
  #error Find an alternative.
#endif
  feclearexcept(FE_INVALID);
  *dst = lrint(trunc(src));
  return !fetestexcept(FE_INVALID);
}

mode_t get_umask(void)
{
  mode_t um = umask(0);
  umask(um);
  return um;
}

uint64_t read_leb_u(const uint8_t **pos)
{
  uint64_t r = 0;
  int bit = 0;
  for (;;)
    {
      uint8_t n = *(*pos)++;
      r |= (uint64_t)(n & 0x7f) << bit;
      if (!(n & 0x80))
        return r;
      bit += 7;
    }
}

int64_t read_leb_s(const uint8_t **pos)
{
  int64_t r = 0;
  unsigned bit = 0;
  for (;;)
    {
      uint8_t n = *(*pos)++;
      r |= (int64_t)(n & 0x7f) << bit;
      bit += 7;
      if (!(n & 0x80))
        {
          if ((n & 0x40) && bit < 64)
            r |= ~UINT64_C(0) << bit;
          return r;
        }
    }
}

void sb_add_leb_u(struct strbuf *sb, uint64_t u)
{
  do
    {
      uint8_t u8 = u & 0x7f;
      u >>= 7;
      if (u != 0)
        u8 |= 0x80;
      sb_add_u8(sb, u8);
    }
  while (u);
}

void sb_add_leb_s(struct strbuf *sb, int64_t i)
{
  for (;;)
    {
      uint8_t u8 = i & 0x7f;
      i >>= 7;
      bool done = (i == ((u8 & 0x40) ? -1 : 0));
      if (!done)
        u8 |= 0x80;
      sb_add_u8(sb, u8);
      if (done)
        break;
    }
}

unsigned leb_u_len(uint64_t u)
{
  unsigned len = 0;
  do
    {
      ++len;
      u >>= 7;
    }
  while (u);
  return len;
}

unsigned leb_s_len(int64_t i)
{
  unsigned len = 0;
  for (;;)
    {
      ++len;
      uint8_t u8 = i & 0x7f;
      i >>= 7;
      if (i == ((u8 & 0x40) ? -1 : 0))
        return len;
    }
}

static void FMT_PRINTF(1, 0) stderr_log_fn(const char *fmt, va_list va)
{
  fputs("MUDLLE: ", stderr);
  vfprintf(stderr, fmt, va);
  fputc('\n', stderr);
}

static mudlle_log_fn log_cb = stderr_log_fn;

void mudlle_log(const char *fmt, ...)
{
  va_list va;
  va_start(va, fmt);
  log_cb(fmt, va);
  va_end(va);
}

void set_mudlle_log_callback(mudlle_log_fn fn)
{
  log_cb = fn;
}

struct cstrlen cstrlen_from_mstr(struct string *s)
{
  return (struct cstrlen){ .str = s->str, .len = string_len(s) };
}

static const char *markup_strs[mudlle_markup_types][2];

const char *mudlle_markup(enum mudlle_markup mm, bool start)
{
  const char *s = markup_strs[mm][start];
  return s ? s : "";
}

void set_mudlle_markup(enum mudlle_markup mm,
                       const char *start, const char *end)
{
  markup_strs[mm][true]  = start;
  markup_strs[mm][false] = end;
}

#define IS_UNORDERED(a, b) (assert(!isunordered((a), (b))), false)

/* the following are declared in mudlle-macros.h */
int cmp_f(float a, float b)
{
  if (IS_UNORDERED(a, b))
    return CMP(!isnan(b), !isnan(a));
  return a < b ? -1 : a > b;
}

int cmp_d(double a, double b)
{
  if (IS_UNORDERED(a, b))
    return CMP(!isnan(b), !isnan(a));
  return a < b ? -1 : a > b;
}

float max_f(float a, float b)
{
  if (IS_UNORDERED(a, b))
    return isnan(a) ? b : a;
  return a > b ? a : b;
}

double max_d(double a, double b)
{
  if (IS_UNORDERED(a, b))
    return isnan(a) ? b : a;
  return a > b ? a : b;
}

float min_f(float a, float b)
{
  if (IS_UNORDERED(a, b))
    return isnan(a) ? b : a;
  return a < b ? a : b;
}

double min_d(double a, double b)
{
  if (IS_UNORDERED(a, b))
    return isnan(a) ? b : a;
  return a < b ? a : b;
}
