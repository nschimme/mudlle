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

#include "files.h"
#include "io.h"
#include "mudlle-float.h"
#include "mudlle-string.h"
#include "prims.h"

#include "../charset.h"
#include "../print.h"
#include "../strbuf.h"


#define OPORT_INFO_NULL (const struct oport_info){ 0 }

#define DOC_OPT_OPORT                                   \
  "Does nothing if `oport is null or false; otherwise," \
  " `oport must be " OPORT_TYPES "."

enum runtime_error ct_oport(struct oport **oport, const char **errmsg,
                            struct oport_info *info, bool force)
{
  if (info != NULL)
    *info = OPORT_INFO_NULL;
  struct mudlle_file_data *fdata;
  if (is_mudlle_file(*oport, &fdata))
    {
      if (fdata->f == NULL)
        {
          *errmsg = "file is closed";
          return error_bad_value;
        }
      if (!fdata->writable)
        {
          *errmsg = "file is not open for writing";
          return error_bad_value;
        }
      *oport = mudlle_file_oport(*oport);
    }
  else if (!TYPE(*oport, oport))
    {
      if (force)
        {
          *errmsg = "expected " OPORT_TYPES;
          return error_bad_type;
        }
      if (*oport != makebool(false) && *oport != NULL)
        {
          *errmsg = "expected null, false, " OPORT_TYPES;
          return error_bad_type;
        }
      *oport = NULL;
    }
  return error_none;
}

TYPEDOP(newline, , "-> . Print a newline to `stdout().", (void),
        OP_LEAF | OP_NOESCAPE, ".")
{
  pputc('\n', mudout());
  pflush(mudout());
  undefined();
}

static value pprint(struct oport *p, enum fmt_flag level, value v)
{
  struct oport_info info;
  const char *errmsg;
  GCPRO(v);
  enum runtime_error e = ct_oport(&p, &errmsg, &info, false);
  UNGCPRO();
  if (e != error_none)
    runtime_error_message(e, errmsg);
  if (p)
    output_value(p, level, v, info.use_ascii);
  undefined();
}

TYPEDOP(pdisplay, , "`oport `x -> . Print a representation of `x to"
        " `oport as `display() does.\n"
        DOC_OPT_OPORT,
        (struct oport *oport, value x),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "[ouz]x.")
{
  return pprint(oport, fmt_display, x);
}

TYPEDOP(pwrite, , "`oport `x -> . Print a representation of `x to"
        " `oport as `write() does.\n"
        DOC_OPT_OPORT,
        (struct oport *oport, value x),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY,
        "[ouz]x.")
{
  return pprint(oport, fmt_write, x);
}

TYPEDOP(pexamine, , "`oport `x -> . Print a representation of `x to"
        " `oport as `examine() does.\n"
        DOC_OPT_OPORT,
        (struct oport *oport, value x),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "[ouz]x.")
{
  return pprint(oport, fmt_examine, x);
}

TYPEDOP(write, , "`x -> . Print a representation of `x to `stdout()."
        " Cf. `pformat_object().",
        (value v),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "x.")
{
  output_value(mudout(), fmt_write, v, mudout_wants_ascii());
  pflush(mudout());
  undefined();
}

TYPEDOP(pwrite_constant, , "`oport `x `b -> . Print a representation of `x to"
        " `oport that can be read using `read_constant().\n"
        "If `b is true, replaces any non-serializable value with null.\n"
        "Throws an error if `x cannot be represented as a constant.\n"
        DOC_OPT_OPORT,
        (struct oport *oport, value x, value replace_gone_p),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "[ouz]xx.")
{
  GCPRO(x);                     /* get_port() may cause GC */
  CHECK_TYPES(oport,          CT_OPT_OPORT(NULL),
              x,              any,
              replace_gone_p, any);
  UNGCPRO();
  if (oport == NULL)
    undefined();
  unsigned flags = fmt_constant;
  if (istrue(replace_gone_p))
    flags |= fmt_flag_replace_gone;
  if (!output_value_cut(oport, x, MAX_STRING_SIZE, flags))
    runtime_error(error_bad_value);
  undefined();
}

TYPEDOP(display, , "`x -> . Display a representation of `x to `stdout().",
        (value v),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "x.")
{
  output_value(mudout(), fmt_display, v, mudout_wants_ascii());
  pflush(mudout());
  undefined();
}

TYPEDOP(examine, , "`x -> . Examine a representation of `x to `stdout().",
        (value v),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "x.")
{
  output_value(mudout(), fmt_examine, v, mudout_wants_ascii());
  pflush(mudout());
  undefined();
}

TYPEDOP(ctime, , "-> `n. Returns the number of milliseconds of CPU"
        " time. Only use the difference between two calls.",
	(void),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_TRIVIAL, ".n")
{
  struct timespec ts;
  if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts) != 0)
    {
      perror("clock_gettime()");
      abort();
    }
  long ms = ts.tv_sec * 1000L + ts.tv_nsec / 1000000;
  return makeint(ms);
}


TYPEDOP(time, ,
	"-> `n. Returns the number of seconds since the 1st of January"
        " 1970" NBSP "UTC. On 32-bit systems, negative values are used for"
        " values greater than `MAXINT (following Jan" NBSP "10 13:37:03 2004"
        NBSP "UTC).\n"
        "Cf. `time_after?() and `time_diff().",
	(void), OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_TRIVIAL, ".n")
{
  return makeint(time(NULL));
}

enum runtime_error ct_time_p(long l, const char **errmsg, time_t *dst)
{
  if (l < 0)
    {
      /* negative values are treated as 31-bit overflows */
      l += 1UL << 31;
      if (l < 0)
        {
          *errmsg = "negative time out of range";
          return error_bad_value;
        }
    }
  *dst = l;
  if (*dst != l)
    {
      *errmsg = "time out of range";
      return error_bad_value;
    }
  return error_none;
}

#define __CT_TIME_E(v, msg, dst) ct_time_p(v, msg, &dst)
#define CT_TIME(dst) CT_INT_P(dst, __CT_TIME_E)

TYPEDOP(time_diff, "time_diff",
	"`n0 `n1 -> `n2. Returns the number of seconds from time `n1 to"
        " time `n0 as returned by `time(), bounded to [`MININT..`MAXINT].\n"
        "Similar to `n0 - `n1, but handles negative values correctly on"
        " 64-bit systems.\n"
        "Cf. `time_after?().",
	(value mt0, value mt1),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "nn.n")
{
  time_t t0, t1;
  CHECK_TYPES(mt0, CT_TIME(t0),
              mt1, CT_TIME(t1));
  int64_t ll = (int64_t)t0 - (int64_t)t1;
  long l = (ll < MIN_TAGGED_INT ? MIN_TAGGED_INT
            : ll > MAX_TAGGED_INT ? MAX_TAGGED_INT
            : ll);
  return makeint(l);
}

TYPEDOP(time_afterp, "time_after?",
	"`n0 `n1 -> `b. Returns true if time `n0 is after time `n1, as"
        " returned from `time().\n"
        "Cf. `time_diff().",
	(value mt0, value mt1),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "nn.n")
{
  time_t t0, t1;
  CHECK_TYPES(mt0, CT_TIME(t0),
              mt1, CT_TIME(t1));
  return makebool(t0 > t1);
}

static value make_tm(value mt, struct tm *(*convert)(const time_t *time),
                     const struct prim_op *op)
{
  time_t timeval;
  CHECK_TYPES_OP(op, mt, CT_TIME(timeval));

  struct tm *tm = convert(&timeval);
  if (tm == NULL)
    RUNTIME_ERROR(error_bad_value, strerror(errno));

  struct vector *vtm = alloc_vector(time_fields);
  vtm->data[tm_sec]  = makeint(tm->tm_sec);
  vtm->data[tm_min]  = makeint(tm->tm_min);
  vtm->data[tm_hour] = makeint(tm->tm_hour);
  vtm->data[tm_mday] = makeint(tm->tm_mday);
  vtm->data[tm_mon]  = makeint(tm->tm_mon);
  vtm->data[tm_year] = makeint(tm->tm_year);
  vtm->data[tm_wday] = makeint(tm->tm_wday);
  vtm->data[tm_yday] = makeint(tm->tm_yday);
  CASSERT(time_fields == 8);
  return vtm;
}

TYPEDOP(gmtime, ,
	"`n -> `v. Converts time in seconds `n, as returned by `time(),"
        " to a vector of UTC time information, indexed by the `tm_xxx"
        " constants:\n"
        "  `tm_sec   \tseconds (0-59; 60 for leap seconds)\n"
        "  `tm_min   \tminutes (0-59)\n"
        "  `tm_hour  \thours (0-23)\n"
        "  `tm_mday  \tday of month (1-31)\n"
        "  `tm_mon   \tmonth (0-11 for Jan-Dec; cf. `MONTH_xxx)\n"
        "  `tm_year  \tyear since 1900\n"
        "  `tm_wday  \tday of week (0-6 for Sun-Sat)\n"
        "  `tm_yday  \tday of year (0-365 where 0 is Jan 1)",
	(value mt),
	OP_LEAF | OP_NOESCAPE, "n.v")
{
  return make_tm(mt, gmtime, THIS_OP);
}

TYPEDOP(localtime, ,
	"`n -> `v. Converts time in seconds to a vector of local time"
	" information. See `gmtime() for the format of `v.",
	(value mt),
	OP_LEAF | OP_NOESCAPE, "n.v")
{
  return make_tm(mt, localtime, THIS_OP);
}

static void get_tm_struct(struct tm *tm, struct vector *v)
{
  assert(TYPE(v, vector));

  if (vector_len(v) != time_fields)
    bad_vector_len_error(v, time_fields);

  *tm = (struct tm){
    .tm_sec    = GETRANGE(v->data[tm_sec], 0, 60),
    .tm_min    = GETRANGE(v->data[tm_min], 0, 59),
    .tm_hour   = GETRANGE(v->data[tm_hour], 0, 23),
    .tm_mday   = GETRANGE(v->data[tm_mday], 1, 31),
    .tm_mon    = GETRANGE(v->data[tm_mon], 0, 11),
    .tm_year   = GETINT(v->data[tm_year]),
    .tm_wday   = GETRANGE(v->data[tm_wday], 0, 6),
    .tm_yday   = GETRANGE(v->data[tm_yday], 0, 365),
    .tm_isdst  = false,
  };
}

TYPEDOP(asctime, ,
       "`v -> `s. Returns a string of format \"Wed Jun 30 21:49:08 1993\""
        " representing the time in `v as returned by `gmtime().\n"
        "Cf. the `tm_xxx constants.",
	(struct vector *vgmt),
	OP_LEAF | OP_NOESCAPE | OP_CONST, "v.s")
{
  CHECK_TYPES(vgmt, vector);

  struct tm gmt;
  get_tm_struct(&gmt, vgmt);
  const char *s = asctime(&gmt); /* can return NULL */
  size_t l = s ? strlen(s) : 0;
  if (l > 0 && s[l - 1] == '\n')
    --l;
  return make_readonly(alloc_string_length(s, l));
}

#ifdef MAX_STRING_LENGTH
#define TIME_STR_MAXLEN MAX_STRING_LENGTH
#else
#define TIME_STR_MAXLEN 4096
#endif

TYPEDOP(strftime, ,
	"`s0 `v -> `s1|false. Convert the `gmtime() vector `v into a string,"
        " as specified by the Unix `strftime(3) format string `s0.\n"
        "The resulting string must be shorter than "
        STRINGIFY(TIME_STR_MAXLEN) NBSP "characters.\n"
        "Returns false on error.\n"
        "See `/mhelp `strftime for help on the format string.",
	(struct string *fmt, struct vector *mgmt),
	OP_LEAF | OP_NOESCAPE | OP_STR_READONLY | OP_CONST | OP_TRACE,
        "sv.[sz]")
{
  CHECK_TYPES(fmt, string, mgmt, vector);

  struct tm gmt;
  get_tm_struct(&gmt, mgmt);

  char buf[TIME_STR_MAXLEN + 1]; /* +1 for extra space below */
  size_t r = strftime(buf, sizeof buf, fmt->str, &gmt);
  if (r >= TIME_STR_MAXLEN)
    return makebool(false);
  if (r > 0)
    return make_readonly(alloc_string(buf));

  struct strbuf sbfmt = sb_initstr(fmt->str);
  sb_addc(&sbfmt, ' ');            /* handle empty output */
  r = strftime(buf, sizeof buf, sb_str(&sbfmt), &gmt);
  sb_free(&sbfmt);
  if (r == 0 || r >= TIME_STR_MAXLEN)
    return makebool(false);
  --r;
  buf[r] = 0;
  return make_readonly(alloc_string(buf));
}

TYPEDOP(mktime, ,
        "`v -> `n. Does the inverse of `gmtime(). If values are out of their"
        " normal range, they will be normalized.\n"
        "Returns -1 on error.",
        (struct vector *mtm),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_CONST, "v.n")
{
  CHECK_TYPES(mtm, vector);

  if (vector_len(mtm) != time_fields)
    RUNTIME_ERROR(error_bad_value, NULL);

#define TMF(name) .name = GETRANGE(mtm->data[name], INT_MIN, INT_MAX)
  struct tm tm = {
    TMF(tm_sec),
    TMF(tm_min),
    TMF(tm_hour),
    TMF(tm_mday),
    TMF(tm_mon),
    TMF(tm_year),
    TMF(tm_wday),
    TMF(tm_yday),
    .tm_isdst = false
  };
#undef TMF

  time_t t = mktime(&tm);
  if (t != -1)
    t -= timezone;
  return makeint(t);
}

TYPEDOP(with_output, , "`oport `f -> `x. Evaluates `f() with output"
        " sent to `oport.\n"
        "If `oport is a character without a link, null or false, just"
        " evaluates `f().\n"
        "Output is restored when done. Returns the result of `f().\n"
        "Cf. `stdout().",
        (struct oport *oport, value mf),
        OP_APPLY, "[ouz]f.x")
{
  struct oport *oout = mudout(), *oerr = muderr();
  GCPRO(mf, oout, oerr);        /* CT_OPT_OPORT may cause GC */


  /* silence warning on 'gone' argument */
  if (TYPE(oport, gone))
    oport = NULL;

  CHECK_TYPES(oport, CT_OPT_OPORT(NULL),
              mf,    CT_CALLABLE(0));

  struct oport *newout = mudout(), *newerr = muderr();
  if (oport != NULL)
    newout = newerr = oport;

  bool same = newout == mudout() && newerr == muderr();

  if (newout == mudout_port || same)
    {
      UNGCPRO();
      return call0(mf);
    }

  session_context->ports.out = newout;
  session_context->ports.err = newerr;
  value result = mcatch_call(NULL, mf);
  UNGCPRO();
  session_context->ports.out = oout;
  session_context->ports.err = oerr;

  maybe_mrethrow();

  return result;
}

static struct {
  struct strbuf sb;
  struct oport *oport;
} format_data = { .sb = SBNULL };

static bool is_single(value v)
{
  unsigned expected = TSET(integer);
  if (integerp(v))
    return intval(v) == 1;
#ifdef USE_GMP
  expected |= TSET(bigint);
  if (TYPE(v, bigint))
    {
      struct bigint *bi = v;
      check_bigint(bi);
      return mpz_cmp_si(bi->mpz, 1) == 0;
    }
#endif
  bad_typeset_error(v, expected, -1);
}

#define MAX_FORMAT_LEN     65536

static noreturn void missing_format_param(void)
{
  runtime_error_message(error_wrong_parameters,
                        "not enough parameters for format string");
}

static noreturn void bad_format_value(const char *msg)
{
  sb_free(&format_data.sb);
  runtime_error_message(error_bad_value, msg);
}

static const char *get_int(const char *s, long *dst, const char *err)
{
  long r = 0;
  while (isdigit((unsigned char)*s))
    {
      if (r > MAX_TAGGED_INT / 10)
        bad_format_value(err);
      r *= 10;
      int n = *s++ - '0';
      if (r > MAX_TAGGED_INT - n)
        bad_format_value(err);
      r += n;
    }
  *dst = r;
  return s;
}

static void pformat(struct oport *p, struct string *str,
		    struct vector *args, const struct oport_info *info)
{
  ulong slen, spos;

  GCPRO(args, str, p);

  size_t nargs = vector_len(args);
  size_t i = 0;

  slen = string_len(str);
  spos = 0;
  while (spos < slen)
    {
      size_t ppos;
      {
        const char *percent = memchr(str->str + spos, '%', slen - spos);
        if (percent == NULL)
          {
            pswrite_substring(p, str, spos, slen - spos);
            break;
          }
        ppos = percent - str->str;
      }

      pswrite_substring(p, str, spos, ppos - spos);

      int conv;

      bool zero = false, minus = false, plus = false;
      bool hash = false, space = false;

      long prec = -1;
      ulong width = 0;

      {
        const char *s = str->str + ppos + 1, *strend = str->str + slen;

        /* look for flags */
        for (;; ++s)
          {
            if (s >= strend)
              bad_format_value("invalid trailing format conversion");
            switch (*s)
              {
              case '0': zero  = true; continue;
              case '+': plus  = true; continue;
              case '-': minus = true; continue;
              case '#': hash  = true; continue;
              case ' ': space = true; continue;
              }
            break;
          }

        if (*s == '*')
          {
            if (i >= nargs)
              missing_format_param();
            long w = GETINT(args->data[i]); i++;
            if (w < 0)
              {
                minus = true;
                width = -w;
              }
            else
              width = w;
            ++s;
          }
        else
          {
            long l;
            s = get_int(s, &l, "field width out of range");
            width = l;
          }

        if (s >= strend)
          bad_format_value("invalid trailing format conversion");

        if (*s == '.')
          {
            if (++s >= strend)
              bad_format_value("invalid trailing format conversion");
            if (*s == '*')
              {
                if (i >= nargs)
                  missing_format_param();
                long w = GETINT(args->data[i]); i++;
                if (w < 0)
                  prec = -1;
                else
                  prec = w;
                ++s;
              }
            else
              s = get_int(s, &prec, "precision out of range");

            if (s >= strend)
              bad_format_value("invalid trailing format conversion");
          }
        spos = s - str->str + 1;
        conv = *s;
      }

      enum fmt_flag print_level;

      unsigned base, predigits = 0;
      const char *prefix = "";

      struct strbuf *const sb = &format_data.sb; /* save some typing below */
      struct intstr ibuf;

      switch (conv)
        {
        default:
          bad_format_value("unknown conversion");
        case '%': pputc('%', p); break;
        case 'n': pputc('\n', p); break;
        case 'p':
          if (i >= nargs)
            missing_format_param();
          if (!is_single(args->data[i++]))
            pputc('s', p);
          break;
        case 'P':
          if (i >= nargs)
            missing_format_param();
          if (is_single(args->data[i++]))
            pputc('y', p);
          else
            pputs("ies", p);
          break;
        case 'C':
        case 'c':
          {
            if (i >= nargs)
              missing_format_param();
            value mc = args->data[i++];
            char c = GETINT(mc);
            if (conv == 'C')
              {
                conv = 'c';
                c = TO_8UPPER(c);
              }

            if (width <= 1 && !hash)
              {
                /* common case */
                pputc(c, p);
                break;
              }

            sb_empty(sb);

            if (hash)
              {
                /* emit as character constant */
                sb_addc(sb, '?');
                if (!IS_8PRINT(c) || c == C_NBSP)
                  {
                    int esc = 0;
                    switch (c)
                      {
#define _E(escchr, chr) case escchr: esc = chr; break
                        FOR_CHAR_ESCAPES(_E, SEP_SEMI);
#undef _E
                      default:
                        sb_printf(sb, "\\%03o", (unsigned char)c);
                        goto do_output;
                      }
                    sb_printf(sb, "\\%c", esc);
                  }
                else
                  {
                    if (c == '\\' || IS_8SPACE(c) || strchr("(){}[]\"", c))
                      sb_addc(sb, '\\');
                    sb_addc(sb, c);
                  }
                goto do_output;
              }

            sb_addc(sb, c);
            prec = -1;          /* precision has no effect for %c */
            goto do_output;
          }
        case 'b':
          base = 2;
          if (hash)
            prefix = "0b";
          goto do_int;
        case 'd':
        case 'u':
          base = 10;
          goto do_int;
        case 'o':
          base = 8;
          if (hash)
            {
              prefix = "0";
              predigits = 1;
            }
          goto do_int;
        case 'X':
        case 'x':
          base = 16;
          if (hash)
            prefix = conv == 'X' ? "0X" : "0x";
          goto do_int;

          {
          do_int:
            if (i >= nargs)
              missing_format_param();
            value v = args->data[i++];

            if (minus || prec >= 0)
              zero = false;

            /* 'istr' is the absolute integer */
            const char *istr;

            sb_empty(sb);
            if (integerp(v))
              {
                long l = intval(v);
                if (conv != 'd')
                  {
                    space = plus = false;
                    l &= MAX_TAGGED_UINT;
                  }

                istr = longtostr(&ibuf, conv == 'X' ? -base : base, l);
              }
#ifdef USE_GMP
            else if (TYPE(v, bigint))
              {
                struct bigint *bi = v;
                check_bigint(bi);
                size_t len = mpz_sizeinbase(bi->mpz, base) + 1;
                if (len > MAX_FORMAT_LEN)
                  bad_format_value("bigint out of range to format");
                size_t strofs = sb_add_noinit(sb, len);
                mpz_get_str(sb_mutable_str(sb) + strofs,
                            conv == 'X' ? -base : base,
                            bi->mpz);
                istr = sb_str(sb);
              }
#endif
            else
              bad_format_value("invalid parameter to integer conversion");

            bool neg = (*istr == '-');
            if (neg)
              ++istr;

            if (strcmp(istr, "0") == 0)
              {
                if (!(base == 8 && hash))
                  istr = "";
                prefix = "";
                predigits = 0;
              }

            if (prec < 0)
              prec = 1;

            /* 'ilen' is the number of digits */
            size_t ilen = strlen(istr) + predigits;

            /* 'tlen' is the total number of characters to print
               before adjusting for 'width' */
            size_t tlen = ilen;
            if (neg || plus || space)
              ++tlen;
            tlen += strlen(prefix) - predigits;

            size_t zeros;
            if (zero)
              zeros = tlen < width ? width - tlen : 0;
            else
              zeros = (prec > 0 && ilen < (size_t)prec) ? prec - ilen : 0;

            if (zeros > MAX_FORMAT_LEN || width > MAX_FORMAT_LEN)
              bad_format_value("integer too large to print");

            tlen += zeros;
            size_t spaces = tlen < width ? width - tlen : 0;

            if (spaces && !minus)
              pputnc(' ', spaces, p);
            if (neg)
              pputc('-', p);
            else if (plus)
              pputc('+', p);
            else if (space)
              pputc(' ', p);
            pputs(prefix, p);
            pputnc('0', zeros, p);
            pputs(istr, p);
            if (spaces && minus)
              pputnc(' ', spaces, p);
            break;
          }
        case 's':
        case 'S':
          print_level = fmt_display;
          goto do_string;
        case 'w':
        case 'W':
          {
            print_level = hash ? fmt_examine : fmt_write;
          do_string:
            if (i >= nargs)
              missing_format_param();

            if (plus && prec < 0)
              bad_format_value("precision needed with '+'");

            unsigned flags = print_level;
            if (!plus)
              flags |= fmt_flag_truncate;
            if (!zero)
              flags |= fmt_flag_quote;
            if (info->use_ascii)
              flags |= fmt_flag_ascii;

            bool simple = width == 0 && !isupper((unsigned char)conv);
            struct oport *dest = p;
            if (!simple)
              {
                dest = format_data.oport;
                sb_empty(sb);
              }
            if (prec > MAX_FORMAT_LEN)
              bad_format_value("precision out of range");
            output_value_cut(dest,
                             args->data[i++],
                             prec >= 0 ? (size_t)prec : MAX_STRING_SIZE,
                             flags);
            if (simple)
              break;
          do_output:
            if (prec > MAX_FORMAT_LEN)
              bad_format_value("precision out of range");
            if (width > MAX_FORMAT_LEN)
              bad_format_value("field width out of range");
            if (prec >= 0)
              assert(sb_len(sb) <= (size_t)prec);
            size_t spaces = sb_len(sb) < width ? width - sb_len(sb) : 0;
            if (spaces && !minus)
              pputnc(' ', spaces, p);
            if (sb_len(sb) == 0)
              ;
            else if (isupper((unsigned char)conv))
              {
                pputc(TO_8UPPER(sb_str(sb)[0]), p);
                port_write(p, sb_str(sb) + 1, sb_len(sb) - 1);
              }
            else
              port_write(p, sb_str(sb), sb_len(sb));
            sb_free(sb);
            if (spaces && minus)
              pputnc(' ', spaces, p);
            break;
          }
        case 'a':
        case 'e':
        case 'f':
        case 'g':
          if (i >= nargs)
            missing_format_param();
          double d = floatval(args->data[i++]);
          sb_empty(sb);
          sb_addc(sb, '%');
          if (hash)
            sb_addc(sb, '#');
          if (zero)
            sb_addc(sb, '0');
          if (minus)
            sb_addc(sb, '-');
          if (space)
            sb_addc(sb, ' ');
          if (plus)
            sb_addc(sb, '+');
          if (width > 0)
            sb_addint(sb, width);
          if (prec >= 0)
            {
              sb_addc(sb, '.');
              if (prec > 0)
                sb_addint(sb, prec);
            }
          sb_addc(sb, conv);

          if (prec > MAX_FORMAT_LEN)
            bad_format_value("precision out of range");
          if (width > MAX_FORMAT_LEN)
            bad_format_value("field width out of range");

          char *fmt = sb_detach(sb);
          sb_printf(sb, fmt, d);
          free(fmt);
          port_write(p, sb_str(sb), sb_len(sb));
          break;
        }
    }

  if (i != nargs)
    runtime_error_message(error_wrong_parameters,
                          "too many parameters for format string");

  UNGCPRO();
  sb_free(&format_data.sb);
}


static struct string *sformat(struct string *fmt, struct vector *argv)
{
  struct oport *p;
  {
    GCPRO(fmt, argv);
    p = make_string_port();
    UNGCPRO();
  }

  struct string *str;
  {
    GCPRO(p);
    pformat(p, fmt, argv, &OPORT_INFO_NULL);
    str = port_string(p, SIZE_MAX);
    UNGCPRO();
  }
  port_close(p);
  return make_readonly(str);
}

VAROP(dformat, ,
      "`s `x1 `x2 ... -> . Displays formatted string `s to `stdout()"
      " with parameters `x1, ... See `format() for syntax. Equivalent"
      " to `display(`format(`s, `x1, ...)).",
      (struct string *fmt, struct vector *args),
      OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "sx*.")
{
  CHECK_TYPES(fmt,  string,
              args, CT_ARGV(0, -1));
  struct oport_info info = {
    .use_ascii = mudout_wants_ascii()
  };
  pformat(mudout(), fmt, args, &info);
  pflush(mudout());
  undefined();
}

TYPEDOP(dvformat, , "`s `v -> . Displays formatted string `s to `stdout()"
        " with parameters in `v."
        " See `format() for syntax. Equivalent to `display(`vformat(`s, `v)).",
        (struct string *fmt, struct vector *argv),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY | OP_TRACE, "sv.")
{
  CHECK_TYPES(fmt,  string,
              argv, vector);
  struct oport_info info = {
    .use_ascii = mudout_wants_ascii()
  };
  pformat(mudout(), fmt, argv, &info);
  pflush(mudout());
  undefined();
}

#define FMT_FLAG_EXTRA ""

TYPEDOP(pformat_object, ,
        "`oport `x `n0 `n1 -> . Print a string representation of `x to `oport,"
        " " OPORT_TYPES ", using at most `n0 characters, with settings in"
        " `n1.\n\n"
        "`n1 must be one of `fmt_xxx:\n"
        "  `fmt_constant  \tprint a constant that can be read using"
        " `read_constant(); throws an error if unable to\n"
        "  `fmt_display   \tuse `display() style output\n"
        "  `fmt_write     \tuse `write() style output\n"
        "  `fmt_examine   \tuse `examine() style output\n\n"
        "optionally bitwise OR with a max pretty-print nesting level"
        " in [0..`fmt_nest_max] shifted left `fmt_nest_shift.\n\n"
        "optionally bitwise OR with one of `fmt_base_xxx:\n"
        "  `fmt_base_bin  \tuse binary output for integers\n"
        "  `fmt_base_oct  \tuse octal output for integers\n"
        "  `fmt_base_dec  \tuse decimal output for integers (default)\n"
        "  `fmt_base_hex  \tuse hexadecimal output for integers\n\n"
        "optionally bitwise OR with `fmt_flag_xxx:\n"
        "  `fmt_flag_ascii         \tonly use ASCII characters in output\n"
        "  `fmt_flag_quote         \tprefix compound objects with a single"
        " quote (')\n"
        "  `fmt_flag_nref          \tindicate recursions using \"#N\"\n"
        "  `fmt_flag_truncate      \ttruncate output to `n0 characters;"
        " default is to fit output to `n0 characters; not used with"
        " `fmt_constant\n"
        "  `fmt_flag_replace_gone  \treplace values of types that cannot be"
        " printed with null; only used with `fmt_constant\n"
        "  `fmt_flag_storable      \tadd markup to make the object roundtrip"
        " storable as text like `save_data(); only used with `fmt_constant"
        FMT_FLAG_EXTRA,
        (struct oport *oport, value x, value mmaxlen, value mflags),
        OP_LEAF | OP_NOESCAPE, "oxnn.")
{
  long flags, maxlen;
  struct oport_info info;
  GCPRO(x);                     /* CT_OPORT() may cause GC */
  CHECK_TYPES(oport,   CT_OPORT(&info),
              x,       any,
              mmaxlen, CT_RANGE(maxlen, 0, MAX_STRING_SIZE),
              mflags,  CT_INT(flags));
  UNGCPRO();

  enum fmt_flag level = flags & fmt_level_mask;
  unsigned base = flags & fmt_base_mask;
  switch (base)
    {
    case fmt_base_bin:
    case fmt_base_oct:
    case fmt_base_dec:
    case fmt_base_hex:
      break;
    default:
      goto bad_flags;
    }

  if ((flags & ~(fmt_mudlle_flags | fmt_level_mask | fmt_base_mask
                 | fmt_nest_mask)) != 0
      || (level != fmt_display && level != fmt_write && level != fmt_examine
          && level != fmt_constant)
      || (level != fmt_constant && (flags & fmt_flag_storable)))
    goto bad_flags;

  if (info.use_ascii)
    flags |= fmt_flag_ascii;

  if (!output_value_cut(oport, x, maxlen, flags) && level == fmt_constant)
    runtime_error(error_bad_value);

  undefined();

 bad_flags:
  RUNTIME_ERROR(error_bad_value, "invalid flags");
}

VAROP(pformat, ,
      "`oport `s `x1 `x2 ... -> . Outputs formatted string `s to `oport,"
      " with parameters `x1, ... See `format() for syntax.\n"
      DOC_OPT_OPORT,
      (struct oport *p, struct string *fmt, struct vector *args),
      OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "[ouz]sx*.")
{
  struct oport_info info;
  GCPRO(fmt, args);                     /* CT_OPT_OPORT may cause GC */
  CHECK_TYPES(p,    CT_OPT_OPORT(&info),
              fmt,  string,
              args, CT_ARGV(0, -1));
  UNGCPRO();

  if (p != NULL)
    pformat(p, fmt, args, &info);

  undefined();
}

TYPEDOP(pvformat, , "`oport `s `v -> . Output formatted string `s0 with"
        " parameters in `v to `oport. See `format() for syntax.\n"
        DOC_OPT_OPORT,
        (struct oport *oport, struct string *fmt, struct vector *argv),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY | OP_TRACE, "[ouz]sv.")
{
  GCPRO(fmt, argv);                     /* CT_OPT_OPORT may cause GC */
  struct oport_info info;
  CHECK_TYPES(oport, CT_OPT_OPORT(&info),
              fmt,   string,
              argv,  vector);
  UNGCPRO();
  if (oport != NULL)
    pformat(oport, fmt, argv, &info);
  undefined();
}

TYPEDOP(vformat, , "`s0 `v -> `s1. Formats string `s0 with"
        " parameters in `v. See `format() for syntax.",
        (struct string *fmt, struct vector *argv),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY | OP_TRACE, "sv.s")
{
  CHECK_TYPES(fmt,  string,
              argv, vector);
  return sformat(fmt, argv);
}

VAROP(sformat, ,
      "`s0|null `s1 `x1 `x2 ... -> `n. Formats into writable string `s0"
      " using format `s1 and arguments `x1 `x2 ... ; throws an error if `s0"
      " and `s1 are the same string, if `s0 is not writable, or if `s0 is"
      " too short for the formatted result.\n"
      "Return value `n is the number of characters written into `s0, or the"
      " required string length if `s0 is null. The terminating null character"
      " is not counted.\n"
      "Note that `n might be greater than `MAX_STRING_SIZE.\n"
      "If `s0 is a string, `sformat() will place a null character at"
      " `s0[`n] if and only if `n is less than `slength(`s0).\n"
      "See `format() for syntax.",
      (struct string *dst, struct string *fmt, struct vector *args),
      OP_LEAF | OP_NOESCAPE, "[su]sx*.n")
{
  CHECK_TYPES(dst,  OR(string, null),
              fmt,  string,
              args, CT_ARGV(0, -1));
  if (dst != NULL && readonlyp(dst))
    RUNTIME_ERROR(error_value_read_only, NULL);

  if (dst == fmt)
    RUNTIME_ERROR(error_bad_value,
                  "the destination cannot be the format string");

  /* REVISIT: it would be convenient to have a "struct string" oport so
   * we could format directly into args->data[0] instead of having to
   * use a strbuf oport. */

  struct strbuf sb = SBNULL;
  GCPRO(dst, fmt, args);
  struct oport *p = dst == NULL ? make_sink_oport() : make_strbuf_oport(&sb);
  pformat(p, fmt, args, &OPORT_INFO_NULL);
  UNGCPRO();

  if (dst == NULL)
    {
      struct oport_stat stat;
      port_stat(p, &stat);
      return makeint(stat.size);
    }

  size_t plen = sb_len(&sb);
  if (string_len(dst) < plen)
    {
      sb_free(&sb);
      runtime_error(error_bad_value);
    }

  memcpy(dst->str, sb_str(&sb), plen + 1);
  sb_free(&sb);
  return makeint(plen);
}

#define EXTRA_CONVERSIONS ""
#define EXTRA_FLAGS ""

VAROP(format, ,
      "`s0 `x1 `x2 ... -> `s1. Formats string `s0 with parameters `x1, ...\n"
      "The string `s0 can contain formatting directives starting with '%'"
      " followed by zero or more flag characters, an optional field width,"
      " an optional precision, and the conversion specifier.\n"
      "\n"
      "Flag for for `b, `o, `x, `X, `e, `f, `g, and `a conversions:\n"
      "  `#   \tPrefix non-zero numbers with \"0b\" (`b conversion),"
      " \"0\" (`o conversion), \"0x\" (`x conversion),"
      " or \"0X\" (`X conversion).\n"
      "      \tFor `a, `e, `f, and `g conversions, the result will always"
      " contains a decimal point.\n"
      "      \tFor `g conversions, trailing zeros are not removed from"
      " the result.\n"
      "Flags for `b, `o, `d, `x, `X, `a, `e, `f, and `g conversions:\n"
      "  `0   \tZero-pad to fill up the field width.\n"
      "  ' ' \t(space) Add a space before non-negative signed numbers.\n"
      "  `+   \tForce a sign ('+' or '-') before signed numbers.\n"
      "Flags for `c, `C, `s, `S, `w, `W, `b, `o, `d, `x, `X, `a, `e, `f,"
      " and `g conversions:\n"
      "  `-   \tLeft justify the result (default is right justified).\n"
      "Flag for `c and `C conversions:\n"
      "  `#   \tWrite the character as a character constant (\"?x\").\n"
      "Flags for `s, `S, `w, and `W conversions:\n"
      "  `0   \tInhibit any leading apostrophe from compound values and"
      " write null as \"()\".\n"
      "  `+   \tFormat the output to fit the output to the specified"
      " precision, rather than truncating it.\n"
      "Flag for `w and `W conversions:\n"
      "  `#   \tUse `examine() style output instead of `write().\n"
      EXTRA_FLAGS
      "\n"
      "Field width and precision are only used for the `c, `C, `s, `S,"
      " `w, `W, `b, `o, `d, `x, `X, `a, `e, `f, and `g conversions.\n"
      "\n"
      "The field width can be either a non-negative integer or an asterisk"
      " ('*'), meaning to use the next parameter (an integer) as field"
      " width. If the parameter is negative, this is taken as the `- flag"
      " and the absolute value is used for the field width.\n"
      "The output will be padded with spaces or zeros as necessary to fill"
      " up to the field width.\n"
      "\n"
      "The precision is a period ('.') followed by either an optional"
      " non-negative integer or an asterisk ('*'),"
      " meaning to use the next parameter (an integer) as precision. If"
      " the parameter is negative, this is taken as a precision of zero.\n"
      "For conversions `b, `o, `d, `u, `x, and `X, the precision is the"
      " minimum number of digits to print, zero-padding as necessary."
      " A precision of zero when printing zero means no output.\n"
      "For conversions `s, `S, `w, and `W, the precision is the maximum"
      " number of characters to include.\n"
      "For conversions `a, `e, and `f, the precision is the number of digits"
      " to print after the decimal point.\n"
      "For the `g conversion, the precision is the maximum number of"
      " significant digits.\n"
      "\n"
      "Field width and precision can at most be"
      " " STRINGIFY(MAX_FORMAT_LEN) ".\n"
      "\n"
      "Available conversions:\n"
      "  `%   \tA % sign.\n"
      "  `c   \tThe character in the next parameter (an integer).\n"
      "  `C   \tLike `c but capitalize the character.\n"
      "  `n   \tEnd of line (equivalent to \"\\n\").\n"
      "  `p   \tIf the next parameter (integer or bigint) is 1 \"\";"
      " otherwise \"s\".\n"
      "  `P   \tIf the next parameter (integer or bigint) is 1 \"y\";"
      " otherwise \"ies\".\n"
      "\n"
      "  `s   \tA string representation of the next parameter"
      " as output by `display().\n"
      "  `S   \tLike `s but capitalize the first character.\n"
      "  `w   \tA string representation of the next parameter"
      " as output by `write() or, with the `# flag, `examine(). Long strings"
      " will be truncated, unless a precision is specified.\n"
      "  `W   \tLike `w but capitalize the first character.\n"
      "\n"
      "  `d   \tThe next parameter (integer or bigint) converted to"
      " decimal.\n"
      "  `b, `o, `u, `x\n"
      "      \tThe next parameter (integer or bigint) converted to"
      " binary, octal, decimal, or hexadecimal; an integer will be"
      " considered unsigned.\n"
      "  `X   \tSame as `x but use uppercase characters.\n"
      "\n"
      "  `e   \tThe next parameter (a float, integer, or bigint) in"
      " \"[-]d.ddde<+->dd\" style.\n"
      "  `f   \tThe next parameter (a float, integer, or bigint) in"
      " \"[-]ddd.ddd\" style.\n"
      "  `g   \tThe next parameter as `e conversion if the exponent is"
      " less than -4 or greater than or equal to the precision; otherwise"
      " as `f conversion.\n"
      "  `a   \tThe next parameter (a float, integer, or bigint) in"
      " \"[-]0xh.hhhhp<+->d\" style." EXTRA_CONVERSIONS,
      (struct string *fmt, struct vector *args),
      OP_LEAF | OP_NOESCAPE | OP_STR_READONLY | OP_CONST,
      "sx*.s")
{
  CHECK_TYPES(fmt,  string,
              args, CT_ARGV(0, -1));
  return sformat(fmt, args);
}

TYPEDOP(pputnc, , "`oport `n0 `n1 -> . Print `n1 characters `n0 to"
        " output port `oport.\n"
        DOC_OPT_OPORT,
        (struct oport *oport, value mchar, value mcount),
        OP_LEAF | OP_NOESCAPE, "[ouz]nn.")
{
  long count;
  unsigned char c;
  CHECK_TYPES(oport,  CT_OPT_OPORT(NULL),
              mchar,  CT_RANGE(c, SCHAR_MIN, UCHAR_MAX),
              mcount, CT_RANGE(count, 0, MAX_STRING_SIZE));
  pputnc(c, count, oport);
  undefined();
}

TYPEDOP(pputc, , "`oport `n -> . Print character `n to output port `oport.\n"
        DOC_OPT_OPORT,
        (struct oport *oport, value mchar), OP_LEAF | OP_NOESCAPE, "[ouz]n.")
{
  unsigned char c;
  CHECK_TYPES(oport, CT_OPT_OPORT(NULL),
              mchar, CT_RANGE(c, SCHAR_MIN, UCHAR_MAX));
  pputc(c, oport);
  undefined();
}

TYPEDOP(pprint, , "`oport `s -> . Print `s to output port `oport.\n"
        DOC_OPT_OPORT,
        (struct oport *oport, struct string *mstr),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "[ouz]s.")
{
  GCPRO(mstr);                  /* CT_OPT_OPORT may cause GC */
  CHECK_TYPES(oport, CT_OPT_OPORT(NULL),
              mstr,  string);
  UNGCPRO();

  if (oport == NULL)
    undefined();
  pswrite(oport, mstr);
  undefined();
}


TYPEDOP(pprint_substring, ,
        "`oport `s `n0 `n1 -> . Print `n1 characters of `s to `oport,"
        " starting with character `n0.\n"
        DOC_OPT_OPORT,
        (struct oport *oport, struct string *mstr,
         value mstart, value mlength),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "[ouz]snn.")
{
  long start, length;
  GCPRO(mstr);                     /* CT_OPT_OPORT may cause GC */
  CHECK_TYPES(oport,   CT_OPT_OPORT(NULL),
              mstr,    string,
              mstart,  CT_STR_IDX(start, mstr, true),
              mlength, CT_RANGE(length, 0, LONG_MAX));
  if ((ulong)(start + length) > string_len(mstr))
    RUNTIME_ERROR(error_bad_index, NULL);
  UNGCPRO();
  pswrite_substring(oport, mstr, start, length);
  undefined();
}

TYPEDOP(make_string_port, ,
        "-> `oport. Returns a new string output port.",
	(void),
	OP_LEAF | OP_NOESCAPE, ".o")
{
  return make_string_port();
}

TYPEDOP(portp, "port?", "`x -> `b. True if `x is an output port.", (value v),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY, "x.n")
{
  return makebool(TYPE(v, oport));
}

TYPEDOP(string_portp, "string_port?",
        "`x -> `b. True if `x is a string output port.",
        (struct oport *x),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY, "x.n")
{
  return makebool(TYPE(x, oport) && is_string_port(x));
}

TYPEDOP(port_string, ,
        "`oport -> `s. Returns the contents of string port `oport.\n"
        "Throws an error if `oport contains more than `MAX_STRING_SIZE"
        " characters.",
	(struct oport *oport),
	OP_LEAF | OP_NOESCAPE, "o.s")
{
  CHECK_TYPES(oport, CT_STR_OPORT);
  return port_string(oport, SIZE_MAX);
}

TYPEDOP(port_substring, ,
        "`oport `n0 `n1 -> `s. Returns a substring of starting at `n0 of"
        " length `n1 from the string port `oport.\n"
        "Throws an error if attempting to extract more than"
        " `MAX_STRING_SIZE characters",
        (struct oport *oport, value mfrom, value mnchars),
	OP_LEAF | OP_NOESCAPE, "onn.s")
{
  long start, nchars;
  CHECK_TYPES(oport,   CT_STR_OPORT,
              mfrom,   CT_RANGE(start,  0, LONG_MAX),
              mnchars, CT_RANGE(nchars, 0, LONG_MAX));
  return port_substring(oport, start, nchars);
}

TYPEDOP(port_copy, ,
        "`oport `s `n0 `n1 -> `n2. Copies the first `n1 characters of string"
        " port `oport into the supplied string `s starting at position `n0.\n"
	"String `s must be writable and at least `n0 + `n1 bytes long;"
	" neither `n0 nor `n1 can be negative.\n"
        "Returns `n2 in range [0, `n1] as the number of bytes written.\n"
        "Note: `port_copy() will place a null character at `s[`n0 + `n2]"
	" if and only if `n0 + `n2 is less than slength(`s).",
	(struct oport *oport, struct string *mstr,
         value mstart, value mlength),
	OP_LEAF | OP_NOESCAPE, "osnn.n")
{
  ulong start, length;
  CHECK_TYPES(oport,   CT_STR_OPORT,
              mstr,    string,
              mstart,  CT_RANGE(start, 0, LONG_MAX),
              mlength, CT_RANGE(length, 0, LONG_MAX));

  if (readonlyp(mstr))
    runtime_error(error_value_read_only);

  size_t plen = string_port_length(oport);
  size_t slen = string_len(mstr);

  if (slen < start + length)
    runtime_error(error_bad_value);

  size_t copied = (plen < length) ? plen : length;
  GCPRO(mstr);
  string_port_copy(mstr->str + start, oport, copied);
  UNGCPRO();

  assert(mstr->str[start + copied] == '\0');
  return makeint(copied);
}

TYPEDOP(port_append, ,
        "`oport0 `oport1 -> . Prints the contents of string port `oport1"
        " to port `oport0.",
	(struct oport *dst, struct oport *src),
	OP_LEAF | OP_NOESCAPE, "oo.")
{
  CHECK_TYPES(dst, oport,
              src, CT_STR_OPORT);
  if (dst == src)
    RUNTIME_ERROR(error_bad_value, "cannot copy port to itself");
  port_append(dst, src);
  undefined();
}

TYPEDOP(string_port_length, ,
        "`oport -> `n. Returns the number of characters in the string"
        " port `oport.",
	(struct oport *oport),
	OP_LEAF | OP_NOESCAPE, "o.n")
{
  CHECK_TYPES(oport, CT_STR_OPORT);
  return makeint(string_port_length(oport));
}

TYPEDOP(port_empty, "port_empty!",
        "`oport -> . Empties the contents of string port `oport.",
        (struct oport *oport),
        OP_LEAF | OP_NOESCAPE, "o.")
{
  CHECK_TYPES(oport, CT_STR_OPORT);
  empty_string_oport(oport);
  undefined();
}

#define EXTRA_INTERACTIVE ""

TYPEDOP(port_interactivep, "port_interactive?",
        "`oport -> `b. True if output port `oport is interactive: a file"
        " open on a terminal" EXTRA_INTERACTIVE ".",
        (struct oport *oport),
        OP_LEAF | OP_NOESCAPE | OP_NOALLOC, "o.n")
{
  CHECK_TYPES(oport, oport);
  return makebool(port_is_interactive(oport));
}

#undef stdout                   /* needed on macOS */
TYPEDOP(stdout, ,
        "-> `port. Returns the standard `display() output port.",
        (void), OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_TRIVIAL, ".o")
{
  return mudout_port;
}

void io_init(void)
{
  DEFINE(stdout);
  DEFINE(pdisplay);
  DEFINE(pwrite);
  DEFINE(pwrite_constant);
  DEFINE(pexamine);
  DEFINE(display);
  DEFINE(write);
  DEFINE(examine);
  DEFINE(newline);
  DEFINE(ctime);
  DEFINE(time);
  DEFINE(time_afterp);
  DEFINE(time_diff);
  DEFINE(asctime);
  DEFINE(strftime);
  DEFINE(gmtime);
  DEFINE(localtime);
  DEFINE(mktime);
  DEFINE(with_output);
  DEFINE(pputc);
  DEFINE(pputnc);
  DEFINE(pprint);
  DEFINE(pprint_substring);
  DEFINE(portp);
  DEFINE(string_portp);
  DEFINE(make_string_port);
  DEFINE(port_empty);
  DEFINE(port_string);
  DEFINE(port_substring);
  DEFINE(port_copy);
  DEFINE(port_append);
  DEFINE(port_interactivep);
  DEFINE(string_port_length);
  DEFINE(pformat);
  DEFINE(pvformat);
  DEFINE(dformat);
  DEFINE(dvformat);
  DEFINE(format);
  DEFINE(sformat);
  DEFINE(vformat);
  DEFINE(pformat_object);


  format_data.oport = make_strbuf_oport(&format_data.sb);
  staticpro(&format_data.oport);
}
