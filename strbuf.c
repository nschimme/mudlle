#include <time.h>

#include "ports.h"
#include "strbuf.h"
#include "utils.h"

static void sb_setsize_big(struct strbuf *sb, size_t size)
{
  assert(size > STRBUF_SMALL_SIZE);
  if (size == internal_sb_size(sb))
    return;
  size_t len = sb_len(sb);
  if (len == 0)
    {
      /* avoid copying old string */
      if (sb->u.isbig)
        free(sb->u.big.buf);
      sb->u.big = (struct sb_big){
        .size = {
          .isbig = true,
          .n     = size
        },
        .len = len,
        .buf = malloc(size)
      };
    }
  else if (len >= size && sb->u.isbig)
    {
      len = size - 1;
      sb->u.big = (struct sb_big){
        .size = {
          .isbig = true,
          .n     = size
        },
        .len = len,
        .buf = realloc(sb->u.big.buf, size)
      };
    }
  else
    {
      char *nbuf = malloc(size);
      memcpy(nbuf, sb_str(sb), len);
      if (sb->u.isbig)
        free(sb->u.big.buf);
      sb->u.big = (struct sb_big){
        .size = {
          .isbig = true,
          .n     = size
        },
        .len = len,
        .buf = nbuf
      };
    }
  sb->u.big.buf[len] = 0;
  VALGRIND_MAKE_MEM_NOACCESS(sb->u.big.buf + len + 1, size - len - 1);
}

void internal_sb_setminsize(struct strbuf *sb, size_t need)
{
  sb_setsize_big(sb, NEXT_POW2(need - 1));
}

void sb_setlen(struct strbuf *sb, size_t len)
{
  assert(len < internal_sb_size(sb));
  char *UNUSED buf = sb_mutable_str(sb);
  size_t used = sb_len(sb);
  if (len > used)
    VALGRIND_MAKE_MEM_UNDEFINED(buf + used + 1, len - used);
  else if (sb->u.isbig)
    VALGRIND_MAKE_MEM_NOACCESS(buf + len + 1, used - len);
  else
    VALGRIND_MAKE_MEM_UNDEFINED(buf + len + 1, used - len);
  internal_sb_setlen(sb, len);
}

static inline char *sb_initlen(struct strbuf *sb, size_t len)
{
  size_t size = len + 1;
  if (size <= STRBUF_SMALL_SIZE)
    {
      sb->u.small.len = (struct sb_small_len){ .isbig = false, .n = len };
      VALGRIND_MAKE_MEM_UNDEFINED(sb->u.small.buf, STRBUF_SMALL_SIZE);
      sb->u.small.buf[len] = 0;
      return sb->u.small.buf;
    }

  char *buf = malloc(size);
  buf[len] = 0;
  sb->u.big = (struct sb_big){
    .size = { .isbig = true, .n = size },
    .len  = len,
    .buf  = buf
  };
  return buf;
}

struct strbuf sb_initmem(const void *data, size_t len)
{
  struct strbuf sb;
  memcpy(sb_initlen(&sb, len), data, len);
  return sb;
}

char *sb_detach(struct strbuf *sb)
{
  char *result;
  if (sb->u.isbig)
    result = sb->u.big.buf;
  else
    {
      size_t size = sb->u.small.len.n + 1;
      result = malloc(size);
      memcpy(result, sb->u.small.buf, size);
    }
  sb_init(sb);
  return result;
}

int sb_vprintf(struct strbuf *sb, const char *fmt, va_list va)
{
  bool is_self = fmt == sb_str(sb);
  if (is_self)
    {
      /* special-case using self as format buffer; must end in explicit null */
      size_t l = sb_len(sb);
      if (l == 0)
        return 0;
      assert(sb_str(sb)[l - 1] == 0);
    }

  va_list va2;
  va_copy(va2, va);
  int need = vsnprintf(NULL, 0, fmt, va2);
  va_end(va2);
  size_t dstofs = sb_add_noinit(sb, need);
  if (is_self)
    fmt = sb_str(sb);
  int used = vsprintf(sb_mutable_str(sb) + dstofs, fmt, va);
  assert(need == used);
  return used;
}

int sb_printf(struct strbuf *sb, const char *fmt, ...)
{
  va_list va;
  va_start(va, fmt);
  int used = sb_vprintf(sb, fmt, va);
  va_end(va);
  return used;
}

void sb_strftime(struct strbuf *sb, const char *fmt, const struct tm *tm)
{
  size_t orig_len = sb_len(sb);
  size_t avail = 0;
  size_t step = internal_sb_size(sb) - 1 - orig_len;
  if (step == 0)
    step = 32;
  struct strbuf sbfmt = SBNULL;
  for (;; step = step < 32 ? 32 : step * 2)
    {
      sb_add_noinit(sb, step);
      avail += step;
      size_t r = strftime(sb_mutable_str(sb) + orig_len, avail, fmt, tm);
      if (r > 0)
        {
          if (sb_len(&sbfmt) > 0)
            --r;                /* 'sbfmt' has an extra space */
          sb_free(&sbfmt);
          sb_setlen(sb, orig_len + r);
          return;
        }
      if (sb_len(&sbfmt) == 0)
        {
          /* add space after 'fmt' to avoid empty output */
          sb_addstr(&sbfmt, fmt);
          sb_addc(&sbfmt, ' ');
          fmt = sb_str(&sbfmt);
        }
    }
}

struct strbuf sb_initvf(const char *fmt, va_list va)
{
  va_list va2;
  va_copy(va2, va);

  int need = vsnprintf(NULL, 0, fmt, va);

  struct strbuf sb;
  int used = vsprintf(sb_initlen(&sb, need), fmt, va2);
  va_end(va2);
  assert(need == used);

  return sb;
}

struct strbuf sb_initf(const char *fmt, ...)
{
  va_list va;
  va_start(va, fmt);
  struct strbuf sb = sb_initvf(fmt, va);
  va_end(va);
  return sb;
}

void sb_trim(struct strbuf *sb)
{
  size_t len = sb_len(sb);
  if (len >= STRBUF_SMALL_SIZE)
    sb_setsize_big(sb, len + 1);
  else if (sb->u.isbig)
    {
      char *src = sb->u.big.buf;
      memcpy(sb_initlen(sb, len), src, len);
      free(src);
    }
}

void sb_addmem(struct strbuf *sb, const void *data, size_t len)
{
  if (len == 0)
    return;
  size_t dstofs = sb_add_noinit(sb, len);
  memcpy(sb_mutable_str(sb) + dstofs, data, len);
}

void sb_addint_l(struct strbuf *sb, long l)
{
  struct intstr istr;
  sb_addstr(sb, longtostr(&istr, 10, l));
}

void sb_addint_ul(struct strbuf *sb, unsigned long l)
{
  struct intstr istr;
  sb_addstr(sb, ulongtostr(&istr, 10, l));
}

/* if 'nul_terminate', the string ends at the first NUL character; otherwise
   the string has 'len' characters */
static void add_json_str(struct strbuf *sb, const char *str, size_t len,
                         bool nul_terminate)
{
  sb_addc(sb, '"');
  for (const char *pos = str, *const end = str + len; ; ++pos)
    {
      /* 'str' poitns to the start of the current normal character sequence;
         'pos' points to the current character */

      if (nul_terminate ? *pos == 0 : pos == end)
        {
          sb_addmem(sb, str, pos - str);
          sb_addc(sb, '"');
          return;
        }
      unsigned char c = *pos;
      if (c >= 0x20 && c < 0x7f && c != '"' && c != '\\')
        continue;

      sb_addmem(sb, str, pos - str);
      sb_addc(sb, '\\');
      switch (c)
        {
        case '\b': sb_addc(sb, 'b'); break;
        case '\f': sb_addc(sb, 'f'); break;
        case '\n': sb_addc(sb, 'n'); break;
        case '\r': sb_addc(sb, 'r'); break;
        case '\t': sb_addc(sb, 't'); break;
        case '\\':
        case '"': sb_addc(sb, c); break;
        default:
          sb_printf(sb, "u%.4x", c);
          break;
        }

      str = pos + 1;            /* the beginning of the next normal sequence */
    }
}

void sb_addmem_json(struct strbuf *sb, const char *str, size_t len)
{
  add_json_str(sb, str, len, false);
}

void sb_addstr_json(struct strbuf *sb, const char *str)
{
  add_json_str(sb, str, 0, true);
}


const char base64chars[] = ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef"
                            "ghijklmnopqrstuvwxyz0123456789+/");

void sb_add_base64(struct strbuf *sb, const void *data, size_t len, bool pad)
{
  size_t need = pad ? ((len + 2) / 3) * 4 : (len * 4 + 2) / 3;
  size_t dstofs = sb_add_noinit(sb, need);
  char *const dst = sb_mutable_str(sb);

  const unsigned char *chars = data;
  enum { s0, s1, s2 } state = s0;
  unsigned char prev = 0;
  while (len > 0)
    {
      unsigned char c, this = *chars++;
      --len;
      switch (state)
        {
        case s0:                 /*   | _6_ | (2) */
          c = this >> 2;
          ++state;
          break;
        case s1:                 /* 2 | _4_ | (4) */
          c = ((prev & 3) << 4) | (this >> 4);
          ++state;
          break;
        case s2:                 /* 4 | _2_ | (6) */
          c = ((prev & 0xf) << 2) | (this >> 6);
          dst[dstofs++] = base64chars[c];
          c = this & 0x3f;
          state = s0;
          break;
        default:
          abort();
        }
      dst[dstofs++] = base64chars[c];
      prev = this;
    }
  unsigned char c, npad;
  switch (state)
    {
    case s0:                 /*   | _6_ | (2) */
      return;
    case s1:                 /* 2 | _4_ | (4) */
      c = ((prev & 3) << 4);
      npad = 2;
      break;
    case s2:                 /* 4 | _2_ | (6) */
      c = ((prev & 0xf) << 2);
      npad = 1;
      break;
    default:
      abort();
    }
  dst[dstofs++] = base64chars[c];
  if (pad)
    while (npad-- > 0)
      dst[dstofs++] = '=';
  assert(dstofs == sb_len(sb));
}

struct strbuf_port {
  struct oport oport;
  struct tagged_ptr sb;
};

static struct strbuf *get_port_strbuf(struct oport *p)
{
  struct strbuf_port *sp = (struct strbuf_port *)p;
  return get_tagged_ptr(&sp->sb);
}

static void strbuf_port_close(struct oport *p)
{
  struct strbuf_port *sp = (struct strbuf_port *)p;
  set_tagged_ptr(&sp->sb, NULL);
}

static void strbuf_port_flush(struct oport *p)
{
}

static void strbuf_port_putnc(struct oport *p, int c, size_t n)
{
  struct strbuf *sb = get_port_strbuf(p);
  sb_addnc(sb, c, n);
}

static void strbuf_port_write(struct oport *p, const char *data, size_t nchars)
{
  struct strbuf *sb = get_port_strbuf(p);
  sb_addmem(sb, data, nchars);
}

static void strbuf_port_swrite(struct oport *p, struct string *s, size_t from,
                               size_t nchars)
{
  struct strbuf *sb = get_port_strbuf(p);
  sb_addmem(sb, s->str + from, nchars);
}

static void strbuf_port_stat(struct oport *p, struct oport_stat *buf)
{
  struct strbuf *sb = get_port_strbuf(p);
  *buf = (struct oport_stat){ .size = sb_len(sb) };
}

static const struct oport_methods strbuf_port_methods = {
  .name   = "strbuf",
  .close  = strbuf_port_close,
  .putnc  = strbuf_port_putnc,
  .write  = strbuf_port_write,
  .swrite = strbuf_port_swrite,
  .flush  = strbuf_port_flush,
  .stat   = strbuf_port_stat,
};

struct oport *make_strbuf_oport(struct strbuf *sb)
{
  struct strbuf_port *p = (struct strbuf_port *)alloc_oport(
    grecord_fields(*p), &strbuf_port_methods);
  set_tagged_ptr(&p->sb, sb);
  return &p->oport;
}
