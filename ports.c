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

#include <ctype.h>
#include <unistd.h>

#include <sys/stat.h>

#include "alloc.h"
#include "charset.h"
#include "context.h"
#include "ports.h"
#include "strbuf.h"
#include "utils.h"

#include "runtime/mudlle-string.h"


#undef LOCAL_MUDLLE_TYPES
#define LOCAL_MUDLLE_TYPES                      \
  struct capped_oport *:       true,            \
  struct file_oport *:         true,            \
  struct line_oport *:         true,            \
  struct mudout_oport *:       true,            \
  struct sink_oport *:         true,            \
  struct string_oport *:       true,            \
  struct string_oport_block *: true,

/* The various types of input & output ports */

struct oport *mudout_port;

#define STRING_BLOCK_SIZE 512	/* Size of each block */

struct string_oport_block /* A structure in which to accumulate output */
{
  struct obj o;
  struct string_oport_block *next;
  struct string *data;
};
/* sizeof (struct string_oport_block) should equal BLOCK_SIZE (see calloc.c)
   exactly, otherwise some memory will be wasted. */

struct string_oport /* Output to a string */
{
  struct oport p;
  struct string_oport_block *first, *current;
  value pos;                    /* position in 'current' */
  value nblocks;                /* number of blocks (not counting 'current') */
};

struct file_oport /* Output to a FILE * */
{
  struct oport p;
  struct tagged_ptr file;
  value file_owned;        /* if true, we will close the file on port_close()*/
};

static struct string_oport_block *free_blocks;

static const struct oport_methods closed_file_port_methods;

/* Creation & code for the various types of ports */
/* ---------------------------------------------- */

struct oport *alloc_oport(size_t nfields, const struct oport_methods *m)
{
  struct oport *p = (struct oport *)allocate_mtemp(type_oport, nfields);
  set_oport_methods(p, m);
  return p;
}

#define ALLOC_OPORT(type)                               \
  (CHECK_MUDLLE_TYPE((struct type ## _oport *)0),       \
   (struct type ## _oport *)alloc_oport(                \
     grecord_fields(struct type ## _oport),             \
     &type ## _port_methods))

static struct string_oport *get_string_port(struct oport *p)
{
  assert(is_string_port(p));
  assert(!readonlyp(p));
  return (struct string_oport *)p;
}

static ulong port_length(struct string_oport *p)
{
  return intval(p->pos) + STRING_BLOCK_SIZE * intval(p->nblocks);
}

static void add_string_block(struct string_oport **p)
{
  struct string_oport_block *blk = free_blocks;

  if (blk != NULL)
    {
      assert(!readonlyp(blk));
      GCCHECK(blk);
      free_blocks = blk->next;
      blk->next = NULL;
    }
  else
    {
      GCPRO(*p, blk);
      blk = (struct string_oport_block *)allocate_mtemp(
        type_internal, grecord_fields(*blk));
      struct string *s = (struct string *)allocate_ctemp(
        type_internal, sizeof *s + STRING_BLOCK_SIZE);
      UNGCPRO();
      blk->data = s;
    }

  if ((*p)->current == NULL)
    {
      (*p)->current = (*p)->first = blk;
      (*p)->nblocks = makeint(0);
    }
  else
    {
      (*p)->current->next = blk;
      (*p)->current = blk;
      (*p)->nblocks = mudlle_iadd((*p)->nblocks, 1);
    }
  (*p)->pos = makeint(0);
}

void empty_string_oport(struct oport *_p)
{
  struct string_oport *p = get_string_port(_p);

  assert(p->first);
  assert(p->current);

  if (p->first != p->current)
    {
      p->current->next = free_blocks;
      free_blocks = p->first->next;
      p->first->next = NULL;
      p->current = p->first;
      p->nblocks = makeint(0);
    }

  p->pos = makeint(0);
}

static void free_string_oport(struct string_oport *p)
{
  set_oport_methods(&p->p, NULL);

  for (struct string_oport_block *b = p->first; b; b = b->next)
    {
      GCCHECK(b);
      assert(!readonlyp(b));
    }

  /* Free data (add blocks to free block list) */
  p->current->next = free_blocks;
  free_blocks = p->first;
  p->first = p->current = NULL;
}

static void string_close(struct oport *_p)
{
  struct string_oport *p = get_string_port(_p);
  free_string_oport(p);
}

static void string_flush(struct oport *_p)
{
}

static void string_putnc(struct oport *_p, int c, size_t n)
{
  struct string_oport *p = (struct string_oport *)_p;
  assert(!readonlyp(p));
  struct string_oport_block *current = p->current;
  long pos = intval(p->pos);

  while (n > 0)
    {
      size_t left = STRING_BLOCK_SIZE - pos;
      size_t cnt = n < left ? n : left;
      memset(current->data->str + pos, c, cnt);
      n -= cnt;
      pos += cnt;
      if (n == 0)
        break;

      add_string_block(&p);
      pos = 0;
      current = p->current;
    }
  p->pos = makeint(pos);
}

static void string_mswrite(struct oport *_p, const char *cs, struct string *ms,
                           size_t from, size_t nchars)
{
  struct string_oport *p = (struct string_oport *)_p;
  assert(!readonlyp(p));
  long pos = intval(p->pos);
  GCPRO(ms);
  for (;;)
    {
      size_t fit = STRING_BLOCK_SIZE - pos;
      if (fit >= nchars)
        break;

      memcpy(p->current->data->str + pos, (cs ? cs : ms->str) + from, fit);
      from += fit;
      nchars -= fit;
      add_string_block(&p);
      pos = 0;
    }
  UNGCPRO();
  memcpy(p->current->data->str + pos, (cs ? cs : ms->str) + from, nchars);
  p->pos = makeint(pos + nchars);
}

static void string_write(struct oport *p, const char *data, size_t nchars)
{
  string_mswrite(p, data, NULL, 0, nchars);
}

static void string_swrite(struct oport *p, struct string *s, size_t from,
                          size_t nchars)
{
  string_mswrite(p, NULL, s, from, nchars);
}

static void string_stat(struct oport *oport, struct oport_stat *buf)
{
  struct string_oport *p = get_string_port(oport);
  *buf = (struct oport_stat){ .size = port_length(p) };
}

static const struct oport_methods string_port_methods = {
  .name   = "string",
  .close  = string_close,
  .putnc  = string_putnc,
  .write  = string_write,
  .swrite = string_swrite,
  .flush  = string_flush,
  .stat   = string_stat,
};

static struct string_oport *new_string_port(void)
{
  return ALLOC_OPORT(string);
}

static struct string_oport *init_string_oport(struct string_oport *p)
{
  assert(!readonlyp(p));
  set_oport_methods(&p->p, &string_port_methods);
  add_string_block(&p);
  return p;
}

struct oport *make_string_port(void)
{
  return &init_string_oport(new_string_port())->p;
}

struct line_oport {
  struct string_oport soport;
  value prev_char;
  struct tagged_ptr line_methods; /* points to struct line_oport_methods */
  value line_handler_data;
};

static void line_port_close(struct oport *_p)
{
  struct line_oport *p = (struct line_oport *)_p;
  free_string_oport(&p->soport);
}

static void line_port_send(struct line_oport *oport)
{
  size_t len = string_port_length(&oport->soport.p);
  if (len == 0)
    return;
  struct string_oport_block *current = oport->soport.first;
  const struct line_oport_methods *methods
    = get_tagged_ptr(&oport->line_methods);
  GCPRO(oport);
  if (current->next == NULL)
    methods->swrite(current->data, intval(oport->soport.pos),
                    oport->line_handler_data);
  else
    {
      struct string *s = port_string(&oport->soport.p, MAX_STRING_SIZE);
      methods->swrite(s, string_len(s), oport->line_handler_data);
    }
  UNGCPRO();
  oport->prev_char = makeint(EOF);
  empty_string_oport(&oport->soport.p);
}

static void line_port_putnc(struct oport *_p, int c, size_t n)
{
  struct line_oport *p = (struct line_oport *)_p;

  GCPRO(p);

  while (n > 0)
    {
      if (p->prev_char == makeint('\n') && c != '\r')
        line_port_send(p);

      bool flush_after = ((p->prev_char == makeint('\r') && c == '\n')
                          || (p->prev_char == makeint('\n') && c == '\r'));
      size_t cnt = flush_after ? 1 : n;
      string_putnc(_p, c, cnt);
      n -= cnt;
      if (flush_after)
        line_port_send(p);
      else
        p->prev_char = makeint(c);
    }

  UNGCPRO();
}

static void line_port_mcwrite(struct line_oport *p, struct string *ms,
                              const char *cs, size_t from, size_t nchars)
{
  if (nchars == 0)
    return;

  bool is_mudlle = ms != NULL;
  assert((cs == NULL) == is_mudlle);

  GCPRO(p, ms);

  size_t pos = from;

  for (;;)
    {
      if (nchars == 0)
        break;

      if (is_mudlle)
        cs = ms->str;

      unsigned char c = cs[pos];
      if ((p->prev_char == makeint('\r') && c == '\n')
          || (p->prev_char == makeint('\n') && c == '\r'))
        {
          line_port_putnc(&p->soport.p, c, 1);
          ++pos;
          if (!--nchars)
            break;
          if (is_mudlle)
            cs = ms->str;
        }
      else if (p->prev_char == makeint('\n'))
        {
          line_port_send(p);
          if (is_mudlle)
            cs = ms->str;
        }

      const char *nl = memchr(cs + pos, '\n', nchars);
      if (nl == NULL)
        {
          p->prev_char = makeint(cs[pos + nchars - 1]);
          if (is_mudlle)
            string_swrite(&p->soport.p, ms, pos, nchars);
          else
            string_write(&p->soport.p, cs + pos, nchars);
          break;
        }

      size_t n = nl - (cs + pos) + 1;
      bool do_send = n > 1 && nl[-1] == '\r';
      if (is_mudlle)
        string_swrite(&p->soport.p, ms, pos, n);
      else
        string_write(&p->soport.p, cs + pos, n);
      if (do_send)
        line_port_send(p);
      else
        p->prev_char = makeint('\n');
      pos += n;
      nchars -= n;
      if (!nchars)
        break;
    }

  UNGCPRO();
}

static void line_port_write(struct oport *_p, const char *s, size_t nchars)
{
  struct line_oport *p = (struct line_oport *)_p;
  line_port_mcwrite(p, NULL, s, 0, nchars);
}

static void line_port_swrite(struct oport *_p, struct string *s, size_t from,
                             size_t nchars)
{
  struct line_oport *p = (struct line_oport *)_p;
  line_port_mcwrite(p, s, NULL, from, nchars);
}

static void line_port_flush(struct oport *_p)
{
  struct line_oport *p = (struct line_oport *)_p;
  line_port_send(p);
}

static void line_port_stat(struct oport *_p, struct oport_stat *buf)
{
  struct line_oport *p = (struct line_oport *)_p;
  const struct line_oport_methods *methods = get_tagged_ptr(&p->line_methods);
  methods->stat(buf, p->line_handler_data);
  size_t slen = string_port_length(_p);
  if (slen > buf->size)
    *buf = (struct oport_stat){ .size = slen };
}

static const struct oport_methods line_port_methods = {
  .name   = "line",
  .close  = line_port_close,
  .putnc  = line_port_putnc,
  .write  = line_port_write,
  .swrite = line_port_swrite,
  .flush  = line_port_flush,
  .stat   = line_port_stat,
};

struct oport *make_line_oport(const struct line_oport_methods *methods,
                              value data)
{
  GCPRO(data);
  struct line_oport *p = ALLOC_OPORT(line);
  p = (struct line_oport *)init_string_oport(&p->soport);
  set_oport_methods(&p->soport.p, &line_port_methods);
  p->prev_char = makeint(EOF);
  set_tagged_ptr(&p->line_methods, (void *)methods);
  p->line_handler_data = data;
  UNGCPRO();
  return &p->soport.p;
}

static FILE *file_port_file(struct oport *oport)
{
  assert(is_file_port(oport));
  struct file_oport *p = (struct file_oport *)oport;
  return get_tagged_ptr(&p->file);
}

static void file_close(struct oport *_p)
{
  struct file_oport *p = (struct file_oport *)_p;
  if (istrue(p->file_owned))
    fclose(file_port_file(_p));
  set_tagged_ptr(&p->file, NULL);
  set_oport_methods(&p->p, &closed_file_port_methods);
}

static void file_flush(struct oport *p)
{
  fflush(file_port_file(p));
}

static void file_putnc(struct oport *p, int c, size_t n)
{
  FILE *f = file_port_file(p);
  while (n-- > 0)
    fputc(c, f);
}

static void file_write(struct oport *p, const char *data, size_t nchars)
{
  fwrite(data, nchars, 1, file_port_file(p));
}

static void file_swrite(struct oport *p, struct string *s, size_t from,
                        size_t nchars)
{
  fwrite(s->str + from, nchars, 1, file_port_file(p));
}

static void file_stat(struct oport *p, struct oport_stat *buf)
{
  FILE *f = file_port_file(p);
  size_t size = 0;
  /* we don't fflush, so the result may be incorrect */
  struct stat fbuf;
  if (fstat(fileno(f), &fbuf) == 0)
    size = fbuf.st_size;
  *buf = (struct oport_stat){ .size = size };
}

struct sink_oport {
  struct oport p;
  value count;                  /* characters written */
};

static void sink_close(struct oport *_p)
{
}

static void sink_use(struct oport *_p, size_t n)
{
  struct sink_oport *p = (struct sink_oport *)_p;
  p->count = mudlle_iadd(p->count, n);
}

static void sink_putnc(struct oport *p, int c, size_t n)
{
  sink_use(p, n);
}

static void sink_write(struct oport *p, const char *data, size_t nchars)
{
  sink_use(p, nchars);
}

static void sink_swrite(struct oport *p, struct string *s, size_t from,
                        size_t nchars)
{
  sink_use(p, nchars);
}

static void sink_flush(struct oport *_p)
{
}

static void sink_stat(struct oport *_p, struct oport_stat *buf)
{
  struct sink_oport *p = (struct sink_oport *)_p;
  *buf = (struct oport_stat){ .size = intval(p->count) };
}

static const struct oport_methods sink_port_methods = {
  .name   = "sink",
  .close  = sink_close,
  .putnc  = sink_putnc,
  .write  = sink_write,
  .swrite = sink_swrite,
  .flush  = sink_flush,
  .stat   = sink_stat,
};

struct oport *make_sink_oport(void)
{
  struct sink_oport *p = ALLOC_OPORT(sink);
  p->count = makeint(0);
  return &p->p;
}

static const struct oport_methods file_port_methods = {
  .name   = "file",
  .close  = file_close,
  .putnc  = file_putnc,
  .write  = file_write,
  .swrite = file_swrite,
  .flush  = file_flush,
  .stat   = file_stat,
};

static void nop_close(struct oport *_p)
{
}

static void nop_putnc(struct oport *p, int c, size_t n)
{
}

static void nop_write(struct oport *p, const char *data, size_t nchars)
{
}

static void nop_swrite(struct oport *p, struct string *s, size_t from,
                       size_t nchars)
{
}

static void nop_flush(struct oport *_p)
{
}

static void nop_stat(struct oport *_p, struct oport_stat *buf)
{
  *buf = (struct oport_stat){ .size = 0 };
}

static const struct oport_methods closed_file_port_methods = {
  .name   = "closed file",
  .close  = nop_close,
  .putnc  = nop_putnc,
  .write  = nop_write,
  .swrite = nop_swrite,
  .flush  = nop_flush,
  .stat   = nop_stat,
};

struct oport *make_file_oport(FILE *f, bool file_owned)
{
  struct file_oport *p = ALLOC_OPORT(file);
  set_tagged_ptr(&p->file, f);
  p->file_owned = makebool(file_owned);
  return &p->p;
}

bool port_is_empty(struct oport *_p)
/* Return: true if the port is empty
   Requires: p be a string-type output port
*/
{
  struct string_oport *p = get_string_port(_p);
  struct string_oport_block *current = p->first;

  return current->next == NULL && intval(p->pos) == 0;
}

static void port_copy(char *s, struct string_oport *p, size_t from,
                      size_t maxlen)
{
  for (struct string_oport_block *current = p->first;
       maxlen > 0 && current;
       current = current->next)
    {
      bool last = current->next == NULL;
      size_t n = last ? intval(p->pos) : STRING_BLOCK_SIZE;
      if (from >= n)
        {
          from -= n;
          continue;
        }

      size_t ncopy = n - from;
      if (ncopy > maxlen)
        ncopy = maxlen;
      memcpy(s, current->data->str + from, ncopy);
      s += ncopy;
      maxlen -= ncopy;
      from = 0;
    }
  *s = 0;
}

void string_port_copy(char *s, struct oport *p, size_t maxlen)
{
  port_copy(s, get_string_port(p), 0, maxlen);
}

size_t string_port_length(struct oport *oport)
{
  return port_length(get_string_port(oport));
}

struct string *port_substring(struct oport *_p, size_t from, size_t nchars)
{
  struct string_oport *p = get_string_port(_p);

  size_t l = port_length(p);
  if (from > l)
    runtime_error(error_bad_value);
  if (nchars > MAX_STRING_SIZE)
    runtime_error(error_bad_value);
  if (from + nchars > l)
    runtime_error(error_bad_value);
  if (nchars == 0)
    return static_empty_string;

  GCPRO(p);
  struct string *result = alloc_string_noinit(nchars);
  UNGCPRO();

  port_copy(result->str, p, from, nchars);
  return result;
}

struct string *port_string(struct oport *_p, size_t maxlen)
{
  struct string_oport *p = get_string_port(_p);
  size_t l = port_length(p);
  if (l > maxlen)
    l = maxlen;
  return port_substring(_p, 0, l);
}

char *port_cstring(struct oport *_p)
{
  struct string_oport *p = get_string_port(_p);
  size_t len = port_length(p);

  char *s = malloc(len + 1);
  port_copy(s, p, 0, len);

  /* replace NUL by spaces */
  const char *end = s + len;
  for (char *s2 = s; (s2 = memchr(s2, 0, end - s2)); )
    *s2++ = ' ';

  return s;
}

bool port_for_blocks(struct oport *_p,
                     bool (*f)(void *data, struct string *str, size_t len),
                     void *data)
{
  struct string_oport *p = get_string_port(_p);
  struct string_oport_block *current = p->first;
  long pos = intval(p->pos);

  bool result = false;

  GCPRO(current);
  for (; current->next != NULL; current = current->next)
    if (!f(data, current->data, STRING_BLOCK_SIZE))
      goto done;
  result = f(data, current->data, pos);
 done:
  UNGCPRO();
  return result;
}

static bool port_append_block(void *dstp, struct string *str, size_t len)
{
  struct oport *dst = *(struct oport **)dstp;
  pswrite_substring(dst, str, 0, len);
  return true;
}

void port_append(struct oport *dst, struct oport *src)
/* Effects: The characters of port 'src' are appended to the end of port 'dst'.
   Modifies: 'dst'
   Requires: 'src' be a string-type output port
*/
{
  assert(dst != src);
  GCPRO(dst);
  port_for_blocks(src, port_append_block, &dst);
  UNGCPRO();
}

/* C I/O routines for use with the ports */
/* ------------------------------------- */

/* These print a string representation of the integer in base 'abs(base)' must
   be in [2..36] into 'str'. If 'base' is negative, use uppercase letters. */
char *ulongtostr(struct intstr *str, int base, unsigned long u)
{
  assert((base < -1 || base > 1) && base >= -36 && base <= 36);

  bool uc = base < 0;
  if (uc)
    base = -base;

  char *pos = str->s + sizeof str->s;
  *--pos = '\0';
  do
    {
      unsigned c = u % base;
      *--pos = (c < 10 ? '0' : (uc ? 'A' : 'a') - 10) + c;
      u /= base;
    }
  while (u > 0);
  return pos;
}

char *longtostr(struct intstr *str, int base, long l)
{
  bool minus = l < 0;
  unsigned long ul = ABS(l);
  char *pos = ulongtostr(str, base, ul);
  if (minus)
    *--pos = '-';
  return pos;
}

/* Print a string representation of the integer in base 'abs(base)' must be in
   [2..36] into 'str'. If 'base' is negative, use uppercase letters.

   If 'wide' is true, insert thousand separators into the result. */
static char *internal_inttostr(struct intstr *str, int base,
                               unsigned long long n,
                               bool is_signed, bool wide)
{
  assert((base < -1 || base > 1) && base >= -36 && base <= 36);
  bool uc = base < 0;
  if (uc)
    base = -base;

  if (wide)
    assert(base > 2);           /* struct intstr must be made larger */

  char *pos = str->s + sizeof str->s;
  *--pos = '\0';

  int comma_group = (base == 8 || base == 10) ? 3 : 4;
  int i = wide ? comma_group : -1;
  bool minus = is_signed && (long long)n < 0;
  if (minus)
    n = ABS((long long)n);

  do
    {
      if (i == 0)
        {
          *--pos = ',';
          i = comma_group;
        }
      --i;
      unsigned c = n % base;
      *--pos = (c < 10 ? '0' : (uc ? 'A' : 'a') - 10) + c;
      n /= base;
    }
  while (n > 0);
  if (minus)
    *--pos = '-';

  assert(pos >= str->s);
  return pos;
}

char *ulongtostr_wide(struct intstr *str, ulong n)
{
  return internal_inttostr(str, 10, n, false, true);
}
char *longtostr_wide(struct intstr *str, long n)
{
  return internal_inttostr(str, 10, n, true, true);
}

/* use with printf %s to signal that the next %s should be capitalized */
const char CAPITALIZE[] = "<capitalize>";

void vpprintf(struct oport *p, const char *fmt, va_list args)
{
  if (oport_methods(p) == NULL) return;

  struct intstr ibuf;

  GCPRO(p);

  struct strbuf sbfloat = SBNULL;

  bool cap = false;
  for (const char *percent, *add; (percent = strchr(fmt, '%')); )
    {
      enum {
        sz_char, sz_short, sz_int, sz_long, sz_llong
      } isize = sz_int;
      unsigned width = 0;
      int prec = -1;
      bool minus = false, zero = false, hash = false, plus = false;
      bool space = false, widefmt = false;
      size_t addlen;
      char chararg;

      port_write(p, fmt, percent - fmt);
      fmt = percent + 1;

      /* flags */
      for (;; ++fmt)
        {
          switch (*fmt)
            {
            case '-':  minus   = true; continue;
            case '+':  plus    = true; continue;
            case '0':  zero    = true; continue;
            case ' ':  space   = true; continue;
            case '#':  hash    = true; continue;
            case '\'': widefmt = true; continue;
            }
          break;
        }

      if (*fmt == '*')
	{
	  int i = va_arg(args, int);
          if (i < 0)
            minus = true;
          width = ABS(i);
	  ++fmt;
	}
      else
        for (unsigned char c; isdigit(c = *fmt); ++fmt)
          {
            int n = c - '0';
            assert(width <= MAX_VALUE(width) / 10);
            width *= 10;
            assert(width <= MAX_VALUE(width) - n);
            width += n;
          }

      if (*fmt == '.')
        {
          ++fmt;
          if (*fmt == '*')
            {
              prec = va_arg(args, int);
              if (prec < 0)
                prec = -1;
              ++fmt;
            }
          else
            {
              prec = 0;
              for (unsigned char c; isdigit(c = *fmt); ++fmt)
                prec = prec * 10 + c - '0';
            }
        }

      switch (*fmt)
        {
        case 'h':
          isize = sz_short;
          if (*++fmt == 'h')
            {
              isize = sz_char;
              ++fmt;
            }
          break;
        case 'l':
          isize = sz_long;
          if (*++fmt == 'l')
            {
              isize = sz_llong;
              ++fmt;
            }
          break;
#define ISIZE(t) _Generic((t)0,                 \
                          int:       sz_int,    \
                          long:      sz_long,   \
                          long long: sz_llong)
        case 'j': isize = ISIZE(intmax_t);  ++fmt; break;
        case 'z': isize = ISIZE(ssize_t);   ++fmt; break;
        case 't': isize = ISIZE(ptrdiff_t); ++fmt; break;
	}
#undef ISIZE

      unsigned char c = *fmt++;
      unsigned base = 10;
      unsigned predigits = 0;
      const char *prefix = "";
      switch (c)
	{
	case '%':
	  add = "%";
          addlen = 1;
          goto have_addlen;
	case 'o':
          base = 8;
          widefmt = false;
          if (hash)
            {
              prefix = "0";
              predigits = 1;
            }
          goto process_unsigned;
	case 'x':
          base = 16;
          widefmt = false;
          if (hash)
            prefix = "0x";
          goto process_unsigned;
	case 'u':
          {
          process_unsigned:
            space = plus = false;

            unsigned long long ull = 0;
            unsigned long ul = 0;
            switch (isize)
              {
              case sz_char:  ul = (unsigned char)va_arg(args, unsigned); break;
              case sz_short:
                ul = (unsigned short)va_arg(args, unsigned);
                break;
              case sz_int:   ul = va_arg(args, unsigned); break;
              case sz_long:  ul = va_arg(args, unsigned long); break;
              case sz_llong:
                ul = ull = va_arg(args, unsigned long long);
                if (ul != ull || widefmt)
                  goto generic_uint;
                break;
              }
            if (widefmt)
              {
                ull = ul;
                goto generic_uint;
              }
            add = ulongtostr(&ibuf, base, ul);
            goto add_int;
          generic_uint:
            add = internal_inttostr(&ibuf, base, ull, false, widefmt);
            goto add_int;
          }

	case 'd':
          {
            long long ll = 0;
            long l = 0;
            switch (isize)
              {
              case sz_char:  l = (signed char)va_arg(args, int); break;
              case sz_short: l = (signed short)va_arg(args, int); break;
              case sz_int:   l = va_arg(args, int); break;
              case sz_long:  l = va_arg(args, long); break;
              case sz_llong:
                l = ll = va_arg(args, long long);
                if (l != ll || widefmt)
                  goto generic_int;
                break;
              }
            if (widefmt)
              {
                ll = l;
                goto generic_int;
              }
            add = longtostr(&ibuf, 10, l);
            goto add_int;

          generic_int:
            add = internal_inttostr(&ibuf, 10, ll, true, widefmt);

          add_int:
            if (minus || prec >= 0)
              zero = false;

            bool neg = (*add == '-');
            if (neg)
              ++add;

            if (strcmp(add, "0") == 0)
              {
                if (!(base == 8 && hash))
                  add = "";
                prefix = "";
                predigits = 0;
              }

            if (prec < 0)
              prec = 1;

            /* 'ilen' is the number of digits */
            size_t ilen = strlen(add) + predigits;

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
              zeros = prec >= 0 && ilen < (unsigned)prec ? prec - ilen : 0;

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
            pputs(add, p);
            if (spaces && minus)
              pputnc(' ', spaces, p);

            continue;
          }

	case 's':
	  add = va_arg(args, const char *);
          if (add == CAPITALIZE)
            {
              cap = true;
              continue;
            }

	  if (add == NULL) add = "(null)";
	  if (prec >= 0 && memchr(add, 0, prec) == NULL)
	    {
	      addlen = prec;
	      goto have_addlen;
	    }
	  break;
	case 'c':
	  chararg = va_arg(args, int);
	  add = &chararg;
          addlen = 1;
          goto have_addlen;
	case 'a':
	case 'e':
	case 'f':
	case 'g':
          {
            sb_empty(&sbfloat);
            sb_addc(&sbfloat, '%');
            if (hash)  sb_addc(&sbfloat, '#');
            if (zero)  sb_addc(&sbfloat, '0');
            if (minus) sb_addc(&sbfloat, '-');
            if (space) sb_addc(&sbfloat, ' ');
            if (plus)  sb_addc(&sbfloat, '+');
            if (width > 0) sb_addint(&sbfloat, width);
            if (prec >= 0)
              {
                sb_addc(&sbfloat, '.');
                sb_addint(&sbfloat, prec);
              }
            sb_addc(&sbfloat, c);
            sb_addc(&sbfloat, 0);

            /* print the number after the formatting string;
               cf. special-case in sb_vprintf() */
            size_t fmtlen = sb_len(&sbfloat);
            sb_printf(&sbfloat, sb_str(&sbfloat), va_arg(args, double));

            add = sb_str(&sbfloat) + fmtlen;
            addlen = sb_len(&sbfloat) - fmtlen;
            goto have_addlen;
          }

	default:
          abort();
	}

      addlen = strlen(add);
    have_addlen: ;

      size_t npad = width > addlen ? width - addlen : 0;
      if (npad > 0 && !minus)
        pputnc(' ', npad, p);

      if (cap && addlen > 0)
	{
          pputc(TO_8UPPER(add[0]), p);
          port_write(p, add + 1, addlen - 1);
	}
      else
	port_write(p, add, addlen);

      cap = false;

      if (npad > 0 && minus)
        pputnc(' ', npad, p);
    }
  pputs(fmt, p);

  UNGCPRO();

  sb_free(&sbfloat);
}

void pprintf(struct oport *p, const char *fmt, ...)
{
  va_list args;
  va_start(args, fmt);
  vpprintf(p, fmt, args);
  va_end(args);
}

bool is_file_port(struct oport *oport)
{
  const struct oport_methods *m = oport_methods(oport);
  return m == &file_port_methods;
}

bool is_string_port(struct oport *oport)
{
  const struct oport_methods *m = oport_methods(oport);
  return m == &string_port_methods || m == &line_port_methods;
}

bool port_is_interactive(struct oport *oport)
{
  if (oport == mudout_port)
    {
      oport = mudout();
    }

  if (oport_methods(oport) == &sink_port_methods)
    return false;

  if (is_file_port(oport))
    {
      FILE *f = file_port_file(oport);
      return isatty(fileno(f));
    }
  return false;
}

static void mudout_close(struct oport *p)
{
}

static void mudout_putnc(struct oport *_p, int c, size_t n)
{
  pputnc(c, n, mudout());
}

static void mudout_write(struct oport *p, const char *data, size_t nchars)
{
  port_write(mudout(), data, nchars);
}

static void mudout_swrite(struct oport *p, struct string *s, size_t from,
                          size_t nchars)
{
  pswrite_substring(mudout(), s, from, nchars);
}

static void mudout_flush(struct oport *p)
{
  pflush(mudout());
}

static void mudout_stat(struct oport *p, struct oport_stat *buf)
{
  port_stat(mudout(), buf);
}

static const struct oport_methods mudout_port_methods = {
  .name   = "stdout",
  .close  = mudout_close,
  .putnc  = mudout_putnc,
  .write  = mudout_write,
  .swrite = mudout_swrite,
  .flush  = mudout_flush,
  .stat   = mudout_stat,
};

void ports_init(void)
{
  staticpro(&free_blocks);

  /* mudout_port doesn't have any special fields */
  struct mudout_oport {
    struct oport p;
  };
  mudout_port = &ALLOC_OPORT(mudout)->p;
  staticpro(&mudout_port);
}
