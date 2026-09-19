#ifndef STRBUF_H
#define STRBUF_H

#include "mudlle-config.h"

#include <stdarg.h>
#include <string.h>

#include "mvalgrind.h"
#include "types.h"

#ifdef WORDS_BIGENDIAN
 /* bitfield layouts below assume little-endian bit layout */
 #error Unsupported endianness
#endif

struct sb_big {
  /* invariants: isbig == true
                 size.n > STRBUF_SMALL_SIZE
                 len < size.n
                 buf == malloc(size.n)
                 buf[len] == 0 */
  struct sb_big_size {
    bool isbig : 1;
    size_t n   : CHAR_BIT * sizeof (size_t) - 1;
  } size;
  size_t len;
  char *buf;                    /* nul-terminated */
};

#define STRBUF_SMALL_SIZE (sizeof (struct sb_big) - 1)

struct sb_small {
  /* invariants: isbig == false
                 len.n < STRBUF_SMALL_SIZE
                 buf[len.n] == 0 */
  struct sb_small_len {
    bool isbig      : 1;
    unsigned char n : CHAR_BIT - 1;
  } len;
  char buf[STRBUF_SMALL_SIZE];  /* nul-terminated */
};

CASSERT(sizeof (struct sb_small) == sizeof (struct sb_big));

struct strbuf {
  union {
    struct sb_small small;
    struct sb_big big;
    bool isbig : 1;
  } u;
};

struct strbuf_node {
  struct strbuf_node *next;
  struct strbuf sb;
};

#define SBNULL { .u.small.len.isbig = false }

/* return number of characters in strbuf (excluding nul) */
static inline size_t sb_len(const struct strbuf *sb)
{
  return sb->u.isbig ? sb->u.big.len : sb->u.small.len.n;
}
/* return pointer to the string in strbuf */
static inline const char *sb_str(const struct strbuf *sb)
{
  return sb->u.isbig ? sb->u.big.buf : sb->u.small.buf;
}
/* return mutable pointer to the string in strbuf; the terminating nul
   must not be modified */
static inline char *sb_mutable_str(struct strbuf *sb)
{
  return sb->u.isbig ? sb->u.big.buf : sb->u.small.buf;
}

/* bytes of heap memory allocated */
static inline size_t sb_alloc_size(const struct strbuf *sb)
{
  return sb->u.isbig ? sb->u.big.size.n : 0;
}

static inline size_t internal_sb_size(const struct strbuf *sb)
{
  return sb->u.isbig ? sb->u.big.size.n : STRBUF_SMALL_SIZE;
}

/* free unused memory */
void sb_trim(struct strbuf *sb);

/* make strbuf have room for at least 'need' characters (including nul) */
void internal_sb_setminsize(struct strbuf *sb, size_t need);

/* set string length to 'len'; requires size > 'len' */
static inline void internal_sb_setlen(struct strbuf *sb, size_t len)
{
  assert(internal_sb_size(sb) > len);
  if (sb->u.isbig)
    {
      sb->u.big.len = len;
      sb->u.big.buf[len] = 0;
    }
  else
    {
      sb->u.small.len = (struct sb_small_len){ .isbig = false, .n = len };
      sb->u.small.buf[len] = 0;
    }
}

/* set number of characters (not counting nul) in strbuf to 'len' */
void sb_setlen(struct strbuf *sb, size_t len);

/* create new strbuf from memory */
struct strbuf sb_initmem(const void *data, size_t len);

/* create new strbuf from string */
static inline struct strbuf sb_initstr(const char *str)
{
  return sb_initmem(str, strlen(str));
}

/* create new strbuf from formatted string */
struct strbuf sb_initf(const char *fmt, ...)
  FMT_PRINTF(1, 2);
struct strbuf sb_initvf(const char *fmt, va_list va)
  FMT_PRINTF(1, 0);

/* make room for at least 'len' additional characters */
static inline void sb_makeroom(struct strbuf *sb, size_t len)
{
  /* note we need room for trailing nul as well */
  size_t used = sb_len(sb);
  size_t need = used + len + 1;
  if (need > internal_sb_size(sb))
    internal_sb_setminsize(sb, need);
  VALGRIND_MAKE_MEM_UNDEFINED(sb_str(sb) + used + 1, len);
}

/* add 'len' non-initialized characters; return starting offset */
static inline size_t sb_add_noinit(struct strbuf *sb, size_t len)
{
  sb_makeroom(sb, len);
  size_t ofs = sb_len(sb);
  internal_sb_setlen(sb, ofs + len);
  return ofs;
}

/* add memory */
void sb_addmem(struct strbuf *sb, const void *data, size_t len);

/* add string */
static inline void sb_addstr(struct strbuf *sb, const char *str)
{
  sb_addmem(sb, str, strlen(str));
}

/* add mudlle string */
static inline void sb_addmstr(struct strbuf *sb, struct string *str)
{
  sb_addmem(sb, str->str, string_len(str));
}

/* add strbuf */
static inline void sb_addsb(struct strbuf *sb, const struct strbuf *src)
{
  assert(sb != src);
  sb_addmem(sb, sb_str(src), sb_len(src));
}

/* add characters */
static inline void sb_addnc(struct strbuf *sb, int c, size_t n)
{
  if (n == 0)
    return;
  size_t dstofs = sb_add_noinit(sb, n);
  memset(sb_mutable_str(sb) + dstofs, c, n);
}

/* add byte */
static inline void sb_add_u8(struct strbuf *sb, uint8_t u)
{
  size_t dstofs = sb_add_noinit(sb, 1);
  sb_mutable_str(sb)[dstofs] = u;
}

/* add character */
static ALWAYS_INLINE void sb_addc(struct strbuf *sb, int c)
{
  sb_add_u8(sb, c);
}

void sb_addint_l(struct strbuf *sb, long l);
void sb_addint_ul(struct strbuf *sb, unsigned long l);

#define sb_addint(sb, i)                                        \
  (_Generic((i) | 0L,                                           \
            long: sb_addint_l,                                  \
            unsigned long: sb_addint_ul)((sb), (i)))

/* initialize strbuf to hold the empty string */
static inline void sb_init(struct strbuf *sb)
{
  sb->u.small.len = (struct sb_small_len){ .isbig = false, .n = 0 };
  VALGRIND_MAKE_MEM_UNDEFINED(sb->u.small.buf + 1, STRBUF_SMALL_SIZE - 1);
}

/* free strbuf; leaves it in initialized (empty) state */
static inline void sb_free(struct strbuf *sb)
{
  if (sb->u.isbig)
    free(sb->u.big.buf);
  sb_init(sb);
}

/* empty strbuf */
static inline void sb_empty(struct strbuf *sb)
{
  sb_setlen(sb, 0);
}

/* return malloced contents of strbuf, which is left initialized (empty) */
char *sb_detach(struct strbuf *sb);

/* true if '*a' and '*b' have equal content */
static inline bool sb_equal(const struct strbuf *a, const struct strbuf *b)
{
  size_t len = sb_len(a);
  if (len != sb_len(b))
    return false;
  return memcmp(sb_str(a), sb_str(b), len) == 0;
}

/* add formatted string */
int sb_printf(struct strbuf *sb, const char *fmt, ...)
  FMT_PRINTF(2, 3);
int sb_vprintf(struct strbuf *sb, const char *fmt, va_list va)
  FMT_PRINTF(2, 0);

struct tm;
void sb_strftime(struct strbuf *sb, const char *fmt, const struct tm *tm)
  __attribute__((format(strftime, 2, 0)));

void sb_addmem_json(struct strbuf *sb, const char *str, size_t len);
void sb_addstr_json(struct strbuf *sb, const char *str);

extern const char base64chars[];

void sb_add_base64(struct strbuf *sb, const void *data, size_t len, bool pad);

struct oport *make_strbuf_oport(struct strbuf *sb);

#endif  /* STRBUF_H */
