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
#include <inttypes.h>
#include <math.h>

#include "charset.h"
#include "dwarf.h"
#include "global.h"
#include "ins.h"
#include "print.h"
#include "profile.h"
#include "strbuf.h"
#include "table.h"
#include "tree.h"

#include "runtime/bigint.h"
#include "runtime/files.h"


enum {
  DEFAULT_MAX_ATOM_LEN = 400,   /* max characters in string/bigint */
  NESTED_MAX_ATOM_LEN  = 80,    /* max inside containers (except last items) */
};

struct seen_obj {
  struct dynpro obj;
  size_t start, list_end, uses;
  size_t number;
};

enum nref_type {
  nref_def,                     /* "#N=" or ". #N=(" */
  nref_use,                     /* "#N" */
  nref_list_end,                /* ")" */
};

struct nref {
  size_t pos;
  enum nref_type type;
  struct seen_obj *seen;
};

struct print_config {
  struct oport *f;              /* GCPRO'ed */
  size_t maxlen;                /* max chars to print */
  size_t maxatomlen;            /* max chars per atom (string, bigint) */
  size_t nested_maxatomlen;     /* max chars per contained atom */
  size_t markup_len;            /* markup characters printed */
  enum rwmode rwmode;           /* for fmt_flag_storable */
  unsigned max_indent_level;
  unsigned nest_level;
  unsigned flags;
  unsigned base;                /* base for integers: 2-36 */
  bool use_strbuf;
  /* 'sb' and 'seen' are used (and 'f' is a strbuf oport) unless
     level != fmt_constant && fmt_flag_truncate && !fmt_flag_nref */
  struct strbuf sb;
  ARRAY_T(struct seen_obj *) seen;
  /* 'nrefs' holds the positions of reference markers to be printed */
  ARRAY_T(struct nref) nrefs;
};

struct p_pos {
  size_t sblen;
  size_t maxlen;
};

static inline enum fmt_flag p_level(const struct print_config *config)
{
  return config->flags & fmt_level_mask;
}

static inline struct p_pos p_pos(struct print_config *config)
{
  return (struct p_pos){
    .sblen      = sb_len(&config->sb),
    .maxlen     = config->maxlen,
  };
}

static void p_setpos(struct print_config *config,
                     const struct p_pos *pos)
{
  sb_setlen(&config->sb, pos->sblen);
  config->maxlen     = pos->maxlen;

  for (size_t i = 0; i < ARRAY_ENTRIES(config->nrefs); )
    {
      struct nref *nref = &ARRAY_GET(config->nrefs, i);
      if (nref->pos >= pos->sblen
          || (nref->type == nref_list_end && nref->pos == SIZE_MAX
              && nref->seen->start >= pos->sblen))
        {
          if (nref->type == nref_use && --nref->seen->uses == 0)
            {
              /* removed last use of 'nref->seen'; renumber all the following
                 entries */
              bool found = false;
              ARRAY_FOR (config->seen, , struct seen_obj *, seen)
                if (found)
                  --seen->number;
                else if (seen == nref->seen)
                  found = true;
            }
          ARRAY_DEL(config->nrefs, i);
          continue;
        }
      ++i;
    }

  for (size_t i = ARRAY_ENTRIES(config->seen); i-- > 0; )
    {
      struct seen_obj *seen = ARRAY_GET(config->seen, i);
      if (seen->start <= pos->sblen)
        break;
      assert(seen->uses == 0);
      ARRAY_DEL(config->seen, i);
      undynpro(&seen->obj);
      free(seen);
    }
}

static size_t p_use(struct print_config *config, size_t nchars)
{
  if (nchars <= config->maxlen)
    {
      config->maxlen -= nchars;
      return nchars;
    }
  nchars = config->maxlen;
  config->maxlen = 0;
  return nchars;
}

static void p_undo_use(struct print_config *config, size_t nchars)
{
  assert(config->maxlen <= SIZE_MAX - nchars);
  config->maxlen += nchars;
}

static void p_mem(struct print_config *config, const void *data,
                  size_t nchars, bool do_count)
{
  if (do_count)
    nchars = p_use(config, nchars);
  else
    config->markup_len += nchars;
  port_write(config->f, data, nchars);
}

static inline bool do_trunc(const struct print_config *config)
{
  return config->flags & fmt_flag_truncate;
}

static bool p_str(struct print_config *config, const char *str)
{
  size_t len = strlen(str);
  bool r = config->maxlen >= len;
  if (!r && !do_trunc(config))
    return false;
  p_mem(config, str, len, true);
  return r;
}

static FMT_PRINTF(2, 0) bool p_fmt(struct print_config *config,
                                   const char *fmt, ...)
{
  size_t oldlen = sb_len(&config->sb);

  va_list va;
  va_start(va, fmt);
  int used = sb_vprintf(&config->sb, fmt, va);
  assert(used >= 0);
  va_end(va);

  bool r = config->maxlen >= (size_t)used;
  if (config->use_strbuf)
    p_use(config, used);
  else
    {
      p_mem(config, sb_str(&config->sb) + oldlen, used, true);
      sb_setlen(&config->sb, oldlen);
    }
  return r;
}


static void p_msubstr(struct print_config *config, struct string *str,
                      size_t from, size_t nchars)
{
  nchars = p_use(config, nchars);
  pswrite_substring(config->f, str, from, nchars);
}

static bool p_mstr(struct print_config *config, struct string *str)
{
  size_t len = string_len(str);
  bool r = config->maxlen >= len;
  if (!r && !do_trunc(config))
    return false;
  p_msubstr(config, str, 0, len);
  return r;
}

static bool p_nchar(struct print_config *config, size_t n, int c)
{
  bool r = config->maxlen >= n;
  pputnc(c, p_use(config, n), config->f);
  return r;
}

static bool p_char(struct print_config *config, int c)
{
  return p_nchar(config, 1, c);
}

static bool p_indent(struct print_config *config, unsigned lvl)
{
  return p_char(config, '\n') && p_nchar(config, lvl * 2, ' ');
}

static unsigned indent_need(unsigned lvl)
{
  return lvl * 2 + 1;
}

struct p_grp {
  struct print_config *config;
  struct p_pos pstart;          /* location of the first character */
  struct p_pos plast;           /* location where we can insert a ... suffix */
  unsigned char suffix;         /* zero for none */
  bool did_indent;              /* true if we emitted indentation */
  bool last_indent;             /* 'did_indent' state at 'plast' */
  bool result;                  /* 'true' if the group was successful */
};

static void p_grp_fail(struct p_grp *grp)
{
  if (grp->config->flags & fmt_flag_truncate)
    return;

  p_setpos(grp->config, &grp->plast);
  grp->did_indent = grp->last_indent;

  if (grp->plast.sblen <= grp->pstart.sblen)
    return;

  if (!p_str(grp->config, "..."))
    abort();
  if (grp->did_indent)
    {
      grp->did_indent = false;
      p_undo_use(grp->config, indent_need(grp->config->nest_level));
      if (!p_indent(grp->config, grp->config->nest_level))
        abort();
    }
  if (grp->suffix != 0)
    {
      p_undo_use(grp->config, 1);
      if (!p_char(grp->config, grp->suffix))
        abort();
    }
  grp->result = true;
}

static bool p_grp_token(struct p_grp *grp, const char *token, bool do_indent)
{
  if (do_indent)
    {
      if (!p_indent(grp->config, grp->config->nest_level + 1))
        goto fail;
      if (!grp->did_indent)
        {
          if (!do_trunc(grp->config))
            {
              size_t need = 0;
              need = indent_need(grp->config->nest_level + 1);
              if (p_use(grp->config, need) != need)
                goto fail;
            }
          grp->did_indent = true;
        }
    }
  else if (*token != 0 && !p_str(grp->config, token))
    goto fail;

  if (*token == 0 || do_trunc(grp->config))
    return true;

  if (grp->config->maxlen >= 3) /* "..." */
    {
      grp->plast = p_pos(grp->config);
      grp->last_indent = grp->did_indent;
    }
  return true;

 fail:
  p_grp_fail(grp);
  return false;
}

static bool p_grp_start(struct print_config *config, const char *prefix,
                        unsigned char suffix, struct p_grp *grp)
{
  *grp = (struct p_grp){
    .config     = config,
    .pstart     = p_pos(config),
    .suffix     = suffix,
    .result     = false,
    .did_indent = false
  };
  grp->plast = grp->pstart;
  if ((suffix
       && !do_trunc(config)
       && p_use(config, 1) != 1)
      || !p_grp_token(grp, prefix, false))
    return false;

  return true;
}

static void p_grp_end(struct p_grp *grp)
{
  if (grp->did_indent)
    {
      if (!(grp->config->flags & fmt_flag_truncate))
        p_undo_use(grp->config, indent_need(grp->config->nest_level));
      if (!p_indent(grp->config, grp->config->nest_level))
        goto fail;
      grp->did_indent = false;
    }
  if (grp->suffix != 0)
    {
      if (!(grp->config->flags & fmt_flag_truncate))
        p_undo_use(grp->config, 1);
      if (!p_char(grp->config, grp->suffix))
        goto fail;
    }

  grp->result = true;
  return;

 fail:
  assert(grp->config->flags & fmt_flag_truncate);
}

static unsigned char writable_chars[P(CHAR_BIT) / CHAR_BIT];

static void set_writable(unsigned char c, bool ok)
{
  unsigned char *dst = &writable_chars[c / CHAR_BIT];
  unsigned char mask = P(c % CHAR_BIT);
  if (ok)
    *dst |= mask;
  else
    *dst &= ~mask;
}

static inline bool writable(unsigned char c, bool use_ascii)
{
  if (use_ascii && c > 0x7f)
    return false;
  return writable_chars[c / CHAR_BIT] & P(c % CHAR_BIT);
}

static bool check_recursion(struct print_config *config, size_t savelen,
                            const char *prefix, struct obj *obj,
                            struct seen_obj **seen, bool *result);
static void pop_from_seen(struct print_config *config,
                          struct seen_obj *expected);

static bool print_value_save(struct print_config *config, value v,
                             size_t savelen);
static bool print_value(struct print_config *config, value v);

bool mudout_wants_ascii(void)
{
  return true;
}

static enum rwmode flags_rwmode(unsigned flags)
{
  return ((flags & OBJ_IMMUTABLE) ? rwmode_im
          : (flags & OBJ_READONLY) ? rwmode_ro
          : rwmode_rw);
}

static bool push_rwmode(struct print_config *config, enum rwmode *prev,
                        unsigned flags, bool is_string)
{
  enum rwmode old = config->rwmode;
  *prev = old;

  if (!(config->flags & fmt_flag_storable))
    return true;

  enum rwmode new = flags_rwmode(flags);

  if (is_string)
    {
      /* Strings are always immutable. When printing they always default to
         readonly. */
      old = rwmode_ro;
      if (new == rwmode_im) new = rwmode_ro;
    }

  if (old == new)
    return true;

  config->rwmode = new;

  return (p_str(config, rwmode_names[config->rwmode])
          && p_char(config, ' '));
}

static inline void pop_rwmode(struct print_config *config, enum rwmode prev)
{
  config->rwmode = prev;
}

#define p_markup_start(config, what) true
#define p_markup_end(config, what)   true

void sb_write_string(struct strbuf *sb, const char *str, size_t len,
                     bool use_ascii)
{
  if (len != SIZE_MAX)
    sb_makeroom(sb, 2 + len);   /* conservative */
  sb_addc(sb, '"');

  const char *end = len == SIZE_MAX ? NULL : str + len;
  for (;;)
    {
      const char *s = str;
      while (s != end && writable(*s, use_ascii))
        ++s;
      sb_addmem(sb, str, s - str);
      str = s;

      if (str == end)
        break;

      unsigned char c = *str++;
      if (c == 0 && end == NULL)
        break;
      sb_addc(sb, '\\');
      switch (c)
        {
        case '\\': case '"': sb_addc(sb, c); break;
#define _E(escchr, chr) case escchr: sb_addc(sb, chr); break
          FOR_CHAR_ESCAPES(_E, SEP_SEMI);
#undef _E
        default: sb_printf(sb, "%03o", c); break;
        }
    }

  sb_addc(sb, '"');
}

static size_t chr_plen(const struct print_config *config, unsigned char c)
{
  if (writable(c, config->flags & fmt_flag_ascii))
    return 1;

  switch (c)
    {
#define _E(escchr, chr) case escchr:
          FOR_CHAR_ESCAPES(_E, SEP_EMPTY);
#undef _E
    case '\\': case '"': return 2; /* "\X" */
    default:
      return 4;                    /* "\012" */
    }
}

static bool output_string(struct print_config *config, struct string *print)
{
  size_t l = string_len(print);

  if (p_level(config) == fmt_display)
    {
      p_msubstr(config, print, 0, l);
      return true;
    }

  if (l == 0)
    return p_nchar(config, 2, '"');

  size_t maxplen = MIN(config->maxlen, config->maxatomlen);

  bool do_triple = (config->nest_level < config->max_indent_level
                    && maxplen >= 32 + 6
                    && l >= 32
                    && memchr(print->str, '\n', l - 1) != NULL);

 again: ;
  const char *suffix = do_triple ? "\"\"\"" : "\"";

  const char *ellipsis = do_triple ? "...\"\"\"" : "...\"";
  const size_t ellipsis_len = do_triple ? 6 : 4;

  bool result = true;

  unsigned quote_count = do_triple ? 2 : 0;

  bool add_hash_rw = ((config->flags & fmt_flag_storable)
                      && !(print->o.flags & OBJ_READONLY));

  size_t plen = do_triple ? 3 : 1;   /* open quote */
  if (add_hash_rw)
    plen += 4;                               /* "#rw " */
  size_t slen = do_trunc(config) ? 0 : plen; /* (required) close quote */
  size_t last_fit = 0;
  for (size_t idx = 0; idx < l; ++idx)
    {
      if (plen + ellipsis_len <= maxplen)
        last_fit = idx;
      unsigned nquote_count = 0;
      unsigned char c = print->str[idx];
      if (c == '\n' && do_triple)
        ++plen;
      else if (c != '"' || !do_triple)
        plen += chr_plen(config, c);
      else if (++quote_count == 3 || idx + 1 == l)
        ++plen;
      else
        {
          nquote_count = quote_count + 1;
          plen += 2;
        }
      quote_count = nquote_count;
      if (plen + slen <= maxplen)
        continue;

      if (p_level(config) == fmt_constant)
        return false;

      if (do_triple && last_fit < 32)
        {
          do_triple = false;
          goto again;
        }

      if (plen + slen <= config->maxlen || !do_trunc(config))
        {
          if (!do_trunc(config)
              && last_fit == 0
              && config->maxlen < 1 + ellipsis_len) /* "\"...\"" */
            return false;
          l = last_fit;
          suffix = ellipsis;
        }
      else
        {
          result = false;
          l = idx + 1;
          suffix = "";
        }
      break;
    }

  GCPRO(print);

  bool use_ascii = config->flags & fmt_flag_ascii;

  if (add_hash_rw)
    p_str(config, "#rw ");

  p_markup_start(config, code_string);
  p_nchar(config, do_triple ? 3 : 1, '"');

  quote_count = do_triple ? 2 : 0;

  for (size_t idx = 0; idx < l; ++idx)
    {
      size_t n = 0;
      while (idx + n < l && writable(print->str[idx + n], use_ascii))
        ++n;
      if (n > 0)
        {
          quote_count = 0;
          p_msubstr(config, print, idx, n);
          idx += n;
        }

      if (idx == l)
        break;

      unsigned char c = print->str[idx];
      if (do_triple
          && (c == '\n'
              || ((c == '"'
                   && ++quote_count < 3
                   && idx + 1 < l)
                  ? true
                  : (quote_count = 0))))
        {
          p_char(config, c);
          continue;
        }
      p_char(config, '\\');
      switch (c)
        {
        case '\\': case '"': p_char(config, c); break;
#define _E(escchr, chr) case escchr: p_char(config, chr); break
          FOR_CHAR_ESCAPES(_E, SEP_SEMI);
#undef _E
        default:
          p_fmt(config, config->base == 16 ? "x%02x" : "%03o", c);
          break;
        }
    }
  UNGCPRO();

  p_str(config, suffix);
  p_markup_end(config, code_string);
  return result;
}

static uint32_t last_instr_line;

static const char *global_name(int idx)
{
  if (idx < 0 || (unsigned)idx >= vector_len(global_names))
    return "<unknown>";

  static struct strbuf sb = SBNULL;
  sb_empty(&sb);
  sb_addmstr(&sb, GNAME(idx));
  return sb_str(&sb);
}

static void print_global_exec(struct strbuf *sb, const char *type, int nargs,
                              uint16_t uw)
{
  sb_printf(sb, "execute[%s %u %s] %d\n", type, uw, global_name(uw), nargs);
}

static int write_instruction(struct strbuf *sb, union instruction *i,
                             ulong ofs, uint32_t line)
{
  union instruction *old_i = i;
  static const char *const brname[] = { "", "(loop)", "(nz)", "(z)" };
  static const char *const builtin_names[] = {
    "eq", "neq", "gt", "lt", "le", "ge", "ref", "set",
    "add", "sub", "bitand", "bitor", "bitnot", "not", "car", "cdr" };
  CASSERT_VLEN(builtin_names, op_builtin_cdr - op_builtin_eq + 1);

#define insinstr()  (*i++)
#define insoper()   (insinstr().op)
#define insuint8()  (insinstr().u)
#define insint8()   (insinstr().s)
#define insuint16() (i += 2, (i[-2].u << 8) + i[-1].u)
#define insint16()  ((int16_t)insuint16())

  enum operator op = insoper();

  if (line != last_instr_line)
    sb_printf(sb, "%5" PRIu32 ": ", line);
  else
    sb_addstr(sb, "       ");
  last_instr_line = line;

  sb_printf(sb, "%5lu: ", ofs);

  static const char *const var_class_names[] = {
    [vclass_local]   = "local",
    [vclass_closure] = "closure",
    [vclass_global]  = "global"
  };
#define VAR_CLASSES VLENGTH(var_class_names)

  CASSERT(op_recall + VAR_CLASSES == op_assign);
  CASSERT(op_assign + VAR_CLASSES == op_closure_var);

  if (op >= op_recall && op < op_closure_var + VAR_CLASSES)
    {
      static const char *const opnames[] = {
        "recall", "assign", "closure var"
      };

      const char *opname = opnames[(op - op_recall) / VAR_CLASSES];
      enum variable_class vclass = (op - op_recall) % VAR_CLASSES;
      if (vclass == vclass_global)
        {
          unsigned uw = insuint16();
          sb_printf(sb, "%s[global] %u %s\n", opname, uw, global_name(uw));
        }
      else
        sb_printf(sb, "%s[%s] %u\n", opname, var_class_names[vclass],
                  (unsigned)insuint8());
    }
  else if (op >= op_builtin_eq && op <= op_builtin_cdr)
    sb_printf(sb, "builtin:%s\n", builtin_names[op - op_builtin_eq]);
  else if (op == op_typeset_check)
    sb_printf(sb, "typeset_check %d\n", insuint8());
  else if (op >= op_typecheck && op < op_typecheck + mudlle_synthetic_types)
    sb_printf(sb, "typecheck %s %d\n",
              mudlle_type_names[op - op_typecheck],
              insuint8());
  else switch (op)
    {
    case op_define: sb_addstr(sb, "define\n"); break;
    case op_return: sb_addstr(sb, "return\n"); break;
    case op_null: sb_addstr(sb, "constant null\n"); break;
    case op_constant1: sb_printf(sb, "constant %u\n", insuint8()); break;
    case op_constant2: sb_printf(sb, "constant %u\n", insuint16()); break;
    case op_integer1: sb_printf(sb, "integer1 %d\n", insint8()); break;
    case op_integer2: sb_printf(sb, "integer2 %d\n", insint16()); break;
    case op_closure: sb_printf(sb, "closure %u\n", insuint8()); break;
    case op_closure_code1:
      sb_printf(sb, "closure code %u\n", insuint8());
      break;
    case op_closure_code2:
      sb_printf(sb, "closure code %u\n", insuint16());
      break;
    case op_execute: sb_printf(sb, "execute %u\n", insuint8()); break;
    case op_execute2: sb_printf(sb, "execute %u\n", insuint16()); break;
    case op_execute_primitive:
      sb_printf(sb, "execute_primitive %u\n", insuint8());
      break;
    case op_execute_primitive2:
      sb_printf(sb, "execute_primitive %u\n", insuint16());
      break;
    case op_execute_secure: sb_printf(sb, "execute_secure %u\n", insuint8());
      break;
    case op_execute_secure2:
      sb_printf(sb, "execute_secure %u\n", insuint16());
      break;
    case op_execute_varargs: sb_printf(sb, "execute_varargs %u\n", insuint8());
      break;
    case op_execute_varargs2:
      sb_printf(sb, "execute_varargs %u\n", insuint16());
      break;
    case op_execute_global_1arg:
      print_global_exec(sb, "global", 1, insuint16());
      break;
    case op_execute_global_2arg:
      print_global_exec(sb, "global", 2, insuint16());
      break;
    case op_execute_primitive_1arg:
      print_global_exec(sb, "primitive", 1, insuint16()); break;
    case op_execute_primitive_2arg:
      print_global_exec(sb, "primitive", 2, insuint16()); break;
    case op_args_fixed: sb_printf(sb, "args_fixed %u\n", insuint8()); break;
    case op_args_range: sb_addstr(sb, "args_range\n"); break;
    case op_args_vararg: sb_addstr(sb, "args_vararg\n"); break;
    case op_discard: sb_addstr(sb, "discard\n"); break;
    case op_pop_args: sb_addstr(sb, "pop_args\n"); break;
    case op_exit_n: sb_printf(sb, "exit %u\n", insuint8()); break;
    case op_exit_discard_n:
      sb_printf(sb, "exit discard %u\n", insuint8()); break;
    case op_branch1: case op_branch_z1: case op_branch_nz1: case op_loop1:
      {
        int8_t sgnbyte = insint8();
        sb_printf(sb, "branch%s %d (to %lu)\n", brname[(op - op_branch1) / 2],
                  sgnbyte, ofs + (i - old_i + sgnbyte));
        break;
      }
    case op_branch2: case op_branch_z2: case op_branch_nz2: case op_loop2:
      {
        int16_t word1 = insint16();
        sb_printf(sb, "wbranch%s %d (to %lu)\n", brname[(op - op_branch1) / 2],
                  word1, ofs + (i - old_i + word1));
        break;
      }
    case op_clear_local:
      sb_printf(sb, "clear[local] %u\n", (unsigned)insuint8());
      break;
    case op_c_callback:
      sb_addstr(sb, "c_callback\n");
      break;
    default:
      sb_printf(sb, "unknown opcode %d\n", op); break;
    }
  return i - old_i;
}

static bool write_code(struct print_config *config, value v)
{
  struct icode *c = v;
  last_instr_line = UINT32_MAX;

  size_t old_maxlen = config->maxlen;
  if (config->flags & fmt_flag_full_code)
    config->maxlen = SIZE_MAX;

  GCPRO(c);
  union instruction *ins = (union instruction *)&c->constants[c->nb_constants];
  long nbins = (union instruction *)((char *)c + c->code.o.size) - ins;
  p_fmt(config, "Code %ld bytes:\n", nbins);

  {
    struct strbuf sb = SBNULL;
    for (long i = 0; i < nbins; )
      {
        uint32_t line = dwarf_lookup_line_number(&c->code, i);
        sb_empty(&sb);
        ins = (union instruction *)&c->constants[c->nb_constants];
        ASSERT_NOALLOC_START();
        i += write_instruction(&sb, ins + i, i, line);
        ASSERT_NOALLOC();
        p_str(config, sb_str(&sb));
      }
    sb_free(&sb);
  }

  p_fmt(config, "\n%u locals, %u stack, seclevel %u, %u constants:\n",
        c->nb_locals, c->stkdepth, c->code.seclevel, c->nb_constants);
  for (long i = 0; i < c->nb_constants; i++)
    {
      p_fmt(config, "%lu: ", i);

      if (config->flags & fmt_flag_full_code)
        config->maxlen = old_maxlen;

      if (integerp(c->constants[i]))
        {
          long l = intval(c->constants[i]);
          struct strbuf sb = sb_initf("%ld (%#lx)", l, l);
          p_str(config, sb_str(&sb));
          sb_free(&sb);
        }
      else if (!print_value(config, c->constants[i]))
        break;

      if (config->flags & fmt_flag_full_code)
        config->maxlen = SIZE_MAX;

      p_char(config, '\n');
    }
  UNGCPRO();

  if (config->flags & fmt_flag_full_code)
    config->maxlen = old_maxlen;

  return true;
}

static bool write_primitive(struct print_config *config, value v)
{
  struct primitive *prim = v;
  const struct prim_op *op = prim->op;
  return (p_markup_start(config, code_fn)
          && p_mstr(config, op->name)
          && p_markup_end(config, code_fn)
          && p_str(config, "()"));
}

static bool write_closure(struct print_config *config, value v)
{
  struct closure *c = v;
  if (p_level(config) != fmt_examine)
    {
      struct code *code = c->code;
      return (p_markup_start(config, code_fn)
              && (code->varname
                  ? p_mstr(config, code->varname)
                  : p_str(config, "fn"))
              && p_markup_end(config, code_fn)
              && p_str(config, "()"));
    }

  unsigned oflags = config->flags;

  ulong nbvar = ((c->o.size - offsetof(struct closure, variables))
                 / sizeof (value));
  GCPRO(c);
  bool r = p_str(config, "Closure, code is\n");
  r = r && print_value(config, c->code);

  r = r && p_fmt(config, "\nand %lu variable%s\n", nbvar,
                 nbvar == 0 ? "s" : nbvar == 1 ? " is" : "s are");

  config->flags = (config->flags & ~fmt_level_mask) | fmt_write;
  for (ulong i = 0; i < nbvar; i++)
    {
      r = r && p_fmt(config, "%lu: ", i);
      r = r && print_value(config, c->variables[i]);
      r = r && p_char(config, '\n');
    }
  config->flags = oflags;

  UNGCPRO();

  return r;
}

static bool is_simple(value v)
{
  if (v == NULL || integerp(v))
    return true;

  switch (TYPEOF(v))
    {
    case type_vector:
      return vector_len((struct vector *)v) == 0;
    case type_string:
      return string_len((struct string *)v) <= 32;
    case type_float:
      return true;
    default:
      return false;
    }
}

/* Returns how many characters to save to print at least one more entry in a
   sequence.
   'left' is the number of remaining elements in the sequence.
   If 'left' is 1, 'v' holds the next element */
static size_t tail_savelen(struct p_grp *grp, size_t left, value v)
{
  if (left == 0 || (grp->config->flags & fmt_flag_truncate))
    return 0;

  size_t ind = (grp->did_indent
                ? indent_need(grp->config->nest_level)
                : 1);
  if (left > 1)
    return 3 + ind;             /* "..." */
  if (v == NULL)
    return 2 + ind;             /* "()" */
  if (integerp(v))
    {
      long l = intval(v);
      if (l == 0 || (grp->config->base == 10 && l >= 0 && l < 10))
        return 1 + ind;         /* "N" */
      if (grp->config->base == 8 && l >= 0 && l < 8)
        return 2 + ind;         /* "0N" */
      if (grp->config->base == 10 && l >= -9 && l <= 99)
        return 2 + ind;         /* "-N" or "NN" */
    }
  else if (TYPE(v, string) && string_len((struct string *)v) == 0)
    return 2 + ind;
  else if (TYPE(v, vector) && vector_len((struct vector *)v) == 0)
    return 2 + ind;
  /* misses empty table "{}" */
  return 3 + ind;               /* "..." */
}

static bool print_nested_value(struct print_config *config, value v,
                               size_t savelen)
{
  ++config->nest_level;
  bool r = print_value_save(config, v, savelen);
  --config->nest_level;
  return r;
}

static bool write_vector(struct print_config *config, value v)
{
  struct vector *vec = v;
  GCPRO(vec);

  size_t oldmaxatomlen = config->maxatomlen;

  bool do_indent = (config->nest_level < config->max_indent_level
                    && vector_len(vec) > 1
                    && !(vector_len(vec) == 2
                         && is_simple(vec->data[0])
                         && is_simple(vec->data[1])));

  struct p_grp grp;
  if (!p_grp_start(config, "[", ']', &grp))
    goto done;

  for (ulong i = 0, len = vector_len(vec); i < len; i++)
    {
      if (!p_grp_token(&grp, i == 0 ? "" : " ", do_indent))
        goto done;

      config->maxatomlen = (i + 1 < len
                            ? config->nested_maxatomlen
                            : oldmaxatomlen);
      size_t savelen = tail_savelen(
        &grp, len - 1 - i, i + 1 < len ? vec->data[i + 1] : NULL);
      if (!print_nested_value(config, vec->data[i], savelen))
        {
          p_grp_fail(&grp);
          goto done;
        }
    }

  p_grp_end(&grp);

 done:
  config->maxatomlen = oldmaxatomlen;
  UNGCPRO();
  return grp.result;
}

static bool write_list(struct print_config *config, value v)
{
  enum rwmode rwmode = config->rwmode;

  struct list *l = v;
  GCPRO(l);

  struct seen_and_pos {
    struct seen_obj *seen;
    size_t pos;
  };
  ARRAY_T(struct seen_and_pos) seen_added = ARRAY_NULL;

  struct p_grp grp;
  if (!p_grp_start(config, "(", ')', &grp))
    goto done;

  bool first = true;
  bool do_indent = config->nest_level < config->max_indent_level;
  if (do_indent && is_simple(l->car))
    {
      struct list *next = l->cdr;
      if (next == NULL
          || (TYPE(next, pair) && next->cdr == NULL && is_simple(next->car)))
        do_indent = false;
    }

  size_t oldmaxatomlen = config->maxatomlen;
  config->maxatomlen = config->nested_maxatomlen;
  for (;;)
    {
      if (l->cdr == NULL)
        config->maxatomlen = oldmaxatomlen;

      if (!p_grp_token(&grp, first ? "" : " ", do_indent))
        goto done;

      bool result;
      struct seen_obj *seen = NULL;

      if (first)
        first = false;
      else if (check_recursion(config, 0, ". ", &l->o,
                               &seen, &result))
        {
          if (!result)
            p_grp_fail(&grp);
          else
            p_grp_end(&grp);
          goto done;
        }

      if (seen != NULL)
        {
          seen->list_end = SIZE_MAX;
          struct seen_and_pos added = {
            .seen = seen, .pos = sb_len(&config->sb)
          };
          ARRAY_ADD(seen_added, added);
        }

      struct list *next = l->cdr;
      size_t savelen = (next == NULL
                        ? 0
                        : (TYPE(next, pair) && next->cdr == NULL
                           ? tail_savelen(&grp, 1, next->car)
                           : tail_savelen(&grp, 2, NULL)));
      if (!print_nested_value(config, l->car, savelen))
        {
          p_grp_fail(&grp);
          goto done;
        }

      if (!TYPE(l->cdr, pair))
        break;
      next = l->cdr;            /* in case of GC */

      if (config->flags & fmt_flag_storable)
        {
          enum rwmode new = flags_rwmode(next->o.flags);
          if (new != rwmode)
            break;
        }

      l = next;
    }

  config->maxatomlen = oldmaxatomlen;
  if (l->cdr != NULL)
    {
      /* split in two to allow "..." to be inserted after the first space */
      if (!p_grp_token(&grp, " ", do_indent)
          || !p_grp_token(&grp, ". ", false))
        goto done;
      if (!print_nested_value(config, l->cdr, 0))
        {
          p_grp_fail(&grp);
          goto done;
        }
    }
  p_grp_end(&grp);

 done:
  for (size_t i = ARRAY_ENTRIES(seen_added); i-- > 0; )
    {
      struct seen_and_pos *seen = &ARRAY_GET(seen_added, i);
      if (seen->pos >= sb_len(&config->sb))
        ;
      else if (!(config->flags & (fmt_flag_nref | fmt_flag_storable)))
        pop_from_seen(config, seen->seen);
      else
        seen->seen->list_end = sb_len(&config->sb);
    }
  ARRAY_FREE(seen_added);

  UNGCPRO();
  return grp.result;
}

static bool p_type(struct print_config *config, const char *tname,
                   bool do_close)
{
  if (!do_trunc(config)
      && config->maxlen < 1 + strlen(tname) + do_close)
    return false;

  return (p_char(config, '{')
          && p_markup_start(config, code_type)
          && p_str(config, tname)
          && p_markup_end(config, code_type)
          && (!do_close || p_char(config, '}')));
}

static bool write_table(struct print_config *config, value v)
{
  struct table *t = v;

  switch (p_level(config))
    {
    case fmt_constant:
    case fmt_examine:
      break;
    case fmt_write:
      if (config->maxlen != SIZE_MAX)
        break;
      FALLTHROUGH;
    default:
      if (table_entries(t) > 10)
        return p_type(config, is_ctable(t) ? "ctable" : "table", true);
    }

  bool is_c = is_ctable(t);
  struct vector *buckets = sorted_table_vector(t);
  size_t size = vector_len(buckets);
  if (size == 0)
    return p_str(config, is_c ? "{c}" : "{}");

  GCPRO(buckets);

  struct p_grp grp;
  if (!p_grp_start(config, is_ctable(t) ? "{c" : "{", '}', &grp))
    goto done;

  bool do_indent = config->nest_level < config->max_indent_level && size > 1;

  const char *prefix = "";
  if (is_c && !do_indent)
    prefix = " ";

  for (size_t i = 0; i < size; ++i)
    {
      if (!p_grp_token(&grp, prefix, do_indent))
        goto done;
      prefix = " ";

      struct p_grp subgrp;
      p_grp_start(config, "", 0, &subgrp);

      enum rwmode prev_rwmode;
      struct symbol *sym = buckets->data[i];
      if (push_rwmode(config, &prev_rwmode, sym->o.flags, false)
          && print_nested_value(config, sym->name, 2) /* "=X" */
          && p_grp_token(&subgrp, "=", false))
        {
          sym = buckets->data[i];    /* restore if we caused GC */
          size_t savelen = tail_savelen(
            &grp, size - 1 - i, i + 1 < size ? buckets->data[i + 1] : NULL);
          if (!print_nested_value(config, sym->data, savelen))
            p_grp_fail(&subgrp);
          else
            p_grp_end(&subgrp);
        }

      pop_rwmode(config, prev_rwmode);

      if (!subgrp.result)
        {
          p_grp_fail(&grp);
          goto done;
        }
    }

  p_grp_end(&grp);
 done:
  UNGCPRO();
  return grp.result;
}

static bool write_symbol(struct print_config *config, value v)
{
  struct symbol *sym = v;
  GCPRO(sym);

  struct p_grp grp;
  if (!p_grp_start(config, "<", '>', &grp))
    goto done;

  if (!print_nested_value(config, sym->name, 2)) /* "=X" */
    {
      p_grp_fail(&grp);
      goto done;
    }

  if (!p_grp_token(&grp, "=", false))
    abort();
  if (!print_nested_value(config, sym->data, 0))
    {
      p_grp_fail(&grp);
      goto done;
    }
  p_grp_end(&grp);

 done:
  UNGCPRO();
  return grp.result;
}

static bool write_weak_ref(struct print_config *config, value v)
{
  struct mweak_ref *ref = v;
  GCPRO(ref);
  bool res = (p_markup_start(config, code_fn)
              && p_str(config, "weak_ref")
              && p_markup_end(config, code_fn)
              && p_char(config, '(')
              && (ref->v == NULL
                  ? (p_markup_start(config, code_const)
                     && p_str(config, "null")
                     && p_markup_end(config, code_const))
                  : print_value_save(config, ref->v, 1))
              && p_char(config, ')'));
  UNGCPRO();
  return res;
}



static bool write_oport(struct print_config *config, value v)
{
  struct oport *op = v;

  bool r;


  struct strbuf sb = sb_initf("%s oport", port_name(op));
  r = p_type(config, sb_str(&sb), true);
  sb_free(&sb);

  if (!r && !do_trunc(config))
    r = p_type(config, "oport", true);
  return r;
}

static bool write_float(struct print_config *config, value v)
{
  struct mudlle_float *f = v;
  double d = f->d;
  if (isnan(d))
    {
      /* mudlle doesn't support different types of NaNs; they're not
         portable anyway */
      return (p_markup_start(config, code_const)
              && p_str(config, "nan")
              && p_markup_end(config, code_const));
    }

  struct p_pos spos = p_pos(config);
  switch (isinf(d))
    {
    case -1:
      p_char(config, '-');
      FALLTHROUGH;
    case 1:
      if (p_markup_start(config, code_const)
          && p_str(config, "inf")
          && p_markup_end(config, code_const))
        return true;
      if (!do_trunc(config))
        p_setpos(config, &spos);
      return false;
    case 0:
      break;
    default:
      abort();
    }

  assert(isfinite(d));

#ifndef DBL_DECIMAL_DIG
  /* clang 3.8 doesn't define this C11 macro */
  #define DBL_DECIMAL_DIG __DBL_DECIMAL_DIG__
#endif

  p_markup_start(config, code_number);
  char buf[DBL_DECIMAL_DIG + 16];
  int prec = p_level(config) == fmt_constant ? DBL_DECIMAL_DIG : 6;
  int len = snprintf(buf, sizeof buf, "%.*g", prec, d);
  assert(len < (int)sizeof buf);
  if (!p_str(config, buf))
    goto fail;

  /* append ".0" if the result looks like an integer */
  const char *s = buf;
  if (*s == '-')
    ++s;
  for (; *s; ++s)
    if (!isdigit((unsigned char)*s))
      goto skip_tail;
  if (!p_str(config, ".0"))
    goto fail;
 skip_tail:
  p_markup_end(config, code_number);
  return true;

 fail:
  if (!do_trunc(config))
    p_setpos(config, &spos);
  return false;
}

struct prefix {
  const char *str;
  size_t len;
};
#define PREFIX(s) { .str = (s), .len = sizeof (s) - 1 }
static const struct prefix prefix_none   = PREFIX("");
static const struct prefix prefix_binary = PREFIX("0b");
static const struct prefix prefix_octal  = PREFIX("0");
static const struct prefix prefix_hex    = PREFIX("0x");
#undef PREFIX

static const struct prefix *base_prefix(unsigned base)
{
  switch (base)
    {
    case 2:  return &prefix_binary;
    case 8:  return &prefix_octal;
    case 10: return &prefix_none;
    case 16: return &prefix_hex;
    default: abort();
    }
}

static bool write_bigint(struct print_config *config, value v)
{
#ifdef USE_GMP
  struct bigint *bi = v;
  check_bigint(bi);
  const struct prefix *prefix = &prefix_none;
  if (mpz_cmp_si(bi->mpz, 0) != 0)
    prefix = base_prefix(config->base);
  size_t size = mpz_sizeinbase(bi->mpz, config->base) + prefix->len;

  size_t maxlen = MIN(config->maxlen, config->maxatomlen);
  bool show_prefix = p_level(config) != fmt_display;
  if (!do_trunc(config)
      && size + (show_prefix ? 2 : 0) > maxlen)
    {
      if (p_level(config) == fmt_constant)
        return false;
      return p_type(config, "bigint", true);
    }

  start_mudlle_gmp();
  /* if number is much larger than the number of characters to print,
     divide by a power of the base to make printing cheaper */
  bool do_quotient = maxlen < SIZE_MAX - 128 && size > maxlen + 128;
  mpz_t mquotient;
  if (do_quotient)
    {
      mpz_init_set_ui(mquotient, config->base);
      /* 3 for luck */
      mpz_pow_ui(mquotient, mquotient, size - maxlen - 3);
      mpz_div(mquotient, bi->mpz, mquotient);
      size = mpz_sizeinbase(mquotient, config->base) + prefix->len;
    }

  struct p_pos spos = p_pos(config);
  bool r = true;
  p_markup_start(config, code_number);
  char *buf = malloc(size + 2); /* space for sign and nul */
  mpz_get_str(buf, config->base, do_quotient ? mquotient : bi->mpz);
  if (do_quotient)
    mpz_clear(mquotient);
  if (show_prefix)
    r = r && p_str(config, "#b");
  const char *str = buf;
  if (prefix->len > 0)
    {
      if (*str == '-')
        r = r && p_char(config, *str++);
      r = r && p_str(config, prefix->str);
    }
  r = r && p_str(config, str);
  end_mudlle_gmp();
  free(buf);
  p_markup_end(config, code_number);
  if (!r && !do_trunc(config))
    p_setpos(config, &spos);
  return r;
#else
  return p_type(config, "bigint", true);
#endif
}

static bool write_variable(struct print_config *config, value v)
{
  struct variable *var = v;
  GCPRO(var);
  bool r = (p_type(config, "var", true)
            && p_char(config, '='));
  UNGCPRO();
  return r && print_value(config, var->vvalue);
}

static bool str_needs_quote(const char *s)
{
  if (!*s)
    return true;
  for (unsigned char c; (c = *s); ++s)
    if (!isalnum(c) && !ispunct(c))
      return true;
  return false;
}

static bool write_file(struct print_config *config, value v)
{
  struct mudlle_file_data *fdata;
  if (!is_mudlle_file(v, &fdata))
    abort();

  struct p_pos spos = p_pos(config);
  bool r = p_type(config, "file", false);
  r = r && p_char(config, ' ');
  if (!str_needs_quote(fdata->filename))
    r = r && p_str(config, fdata->filename);
  else
    {
      struct strbuf sb = SBNULL;
      sb_write_string(&sb, fdata->filename, SIZE_MAX, false);
      r = r && p_str(config, sb_str(&sb));
      sb_free(&sb);
    }

  static const char *const modes[] = {
    "no access", "r", "w", "r/w"
  };
  const char *mstr = "closed";
  if (fdata->f != NULL)
    mstr = modes[fdata->readable | (fdata->writable << 1)];
  r = r && p_fmt(config, " (%s)}", mstr);
  if (!r && !do_trunc(config))
    {
      p_setpos(config, &spos);
      return p_type(config, "file", true);
    }
  return r;
}

static bool write_private(struct print_config *config, value v)
{
  struct mprivate *val = v;
  assert(integerp(val->ptype));
  switch (intval(val->ptype))
    {
    case PRIVATE_MJMPBUF:
      {
        struct mjmpbuf *buf = (struct mjmpbuf *)val;
        return p_type(config, buf->context ? "jmpbuf" : "old jmpbuf", true);
      }
    case PRIVATE_PROFILE:
      return p_type(config, "profile data", true);
    case PRIVATE_MCALLBACK:
      return p_type(config, "C callback", true);
    default:
      return p_type(config, "private", true);
    }
}

static bool print_value_save(struct print_config *config, value v,
                             size_t savelen)
{
  if (do_trunc(config))
    savelen = 0;

  if (config->maxlen <= savelen)
    return false;

  savelen = p_use(config, savelen);
  bool r = print_value(config, v);
  p_undo_use(config, savelen);
  return r;
}

static bool check_recursion(struct print_config *config, size_t savelen,
                            const char *prefix, struct obj *obj,
                            struct seen_obj **seenp, bool *result)
{
  *seenp = NULL;
  if ((do_trunc(config) || p_level(config) == fmt_constant)
      && !(config->flags & (fmt_flag_nref | fmt_flag_storable)))
    return false;

  if (do_trunc(config))
    savelen = 0;

  for (size_t iseen = 0, nseen = ARRAY_ENTRIES(config->seen);
       iseen < nseen;
       ++iseen)
    {
      struct seen_obj *seen = ARRAY_GET(config->seen, iseen);
      if (seen->obj.obj != obj)
        continue;

      if (p_use(config, savelen) != savelen
          || !p_str(config, prefix))
        {
          *result = false;
          return true;
        }

      size_t nnumber = seen->number + 1;
      size_t ndigits = 1; /* number of digits in 'nnumber' */
      size_t nextpow10 = 10;
      while (nnumber >= nextpow10)
        {
          ++ndigits;
          nextpow10 *= 10;
        }

      if (config->flags & fmt_flag_nref)
        {
          bool fail = false;

          if (seen->uses == 0)
            {
              size_t need = 3 + 2 * ndigits; /* "#N=" + "#N" */
              for (size_t i = iseen + 1, n9 = nextpow10 - 1; i < nseen; ++i)
                {
                  /* Find all following seen objects with a number less than a
                     next power of 10. They need to be printed with one extra
                     digit. */
                  struct seen_obj *s = ARRAY_GET(config->seen, i);
                  if (s->uses > 0 && s->number == n9)
                    {
                      need += 1 + s->uses;
                      /* one less than the next power of 10 */
                      n9 = n9 * 10 + 9;
                    }
                }

              if (seen->list_end > 0)
                need += 4;    /* ". (" + ")" */
              fail = need != p_use(config, need);
              if (fail && !do_trunc(config))
                {
                  *result = false;
                  goto done_seen;
                }

              for (size_t i = iseen; i < nseen; ++i)
                {
                  /* renumber this and following seen objects */
                  struct seen_obj *s = ARRAY_GET(config->seen, i);
                  ++s->number;
                }

              if (seen->list_end > 0)
                ARRAY_ADD(config->nrefs, ((struct nref){
                      .type = nref_list_end,
                      .seen = seen,
                      .pos  = SIZE_MAX /* see fixup_nref_list_end() */
                    }));
              ARRAY_ADD(config->nrefs, ((struct nref){
                    .pos  = seen->start,
                    .type = nref_def,
                    .seen = seen
                  }));
            }
          else
            {
              size_t need = 1 + ndigits; /* "#N" */
              fail = need != p_use(config, need);
              if (fail && !do_trunc(config))
                {
                  *result = false;
                  goto done_seen;
                }
            }

          ++seen->uses;
          ARRAY_ADD(config->nrefs, ((struct nref){
                .pos  = sb_len(&config->sb),
                .type = nref_use,
                .seen = seen
              }));
          *result = !fail;
          goto done_seen;
        }

      if (config->flags & fmt_flag_storable)
        {
          *result = false;
          return true;
        }

      struct strbuf sb = sb_initf("recursive %s",
                                  mudlle_type_names[obj->type]);
      *result = p_type(config, sb_str(&sb), true);
      if (!*result)
        *result = p_type(config, "recursion", true);
      sb_free(&sb);

    done_seen:
      p_undo_use(config, savelen);
      return true;
    }

  struct seen_obj *last_seen = NULL;
  size_t nseen = ARRAY_ENTRIES(config->seen);
  if (nseen > 0)
    last_seen = ARRAY_GET(config->seen, nseen - 1);

  struct seen_obj *seen = malloc(sizeof *seen);
  *seen = (struct seen_obj){
    .start  = sb_len(&config->sb),
    .number = nseen == 0 ? 0 : last_seen->number
  };
  dynpro(&seen->obj, obj);
  ARRAY_ADD(config->seen, seen);
  *seenp = seen;
  return false;
}

static void pop_from_seen(struct print_config *config,
                          struct seen_obj *expected)
{
  struct seen_obj *seen = ARRAY_POP(config->seen);
  assert(seen == expected);
  undynpro(&seen->obj);
  free(seen);
}

static bool print_integer(struct print_config *config, long l)
{
  const struct prefix *prefix = &prefix_none;
  if (l != 0)
    prefix = base_prefix(config->base);
  static struct intstr buf; /* static to save stack space */
  const char *str = (config->base == 10
                     ? longtostr(&buf, config->base, l)
                     : ulongtostr(&buf, config->base, l & MAX_TAGGED_UINT));
  if (!do_trunc(config)
      && config->maxlen < prefix->len + strlen(str))
    return false;
  p_markup_start(config, code_number);
  if (prefix->len > 0)
    p_str(config, prefix->str);
  p_str(config, str);
  p_markup_end(config, code_number);
  return true;
}

static bool print_value(struct print_config *config, value v)
{
  static const bool hidden[][mudlle_types] = {
    [fmt_display] = {
      [type_icode]    = true,
      [type_gone]     = true,
      [type_internal] = true,
      [type_mcode]    = true,
      [type_regexp]   = true,
      [type_symbol]   = true,
      [type_table]    = true,
      [type_variable] = true,
    },
    [fmt_write] = {
      [type_icode]    = true,
      [type_gone]     = true,
      [type_internal] = true,
      [type_mcode]    = true,
      [type_regexp]   = true,
    },
    [fmt_examine] = {
      [type_gone]     = true,
      [type_internal] = true,
      [type_mcode]    = true,
      [type_regexp]   = true,
    }
  };

  if (config->maxlen == 0)
    return false;

  if (integerp(v))
    return print_integer(config, intval(v));

  if (v == NULL)
    return p_str(config, "()");

  if (get_stack_pointer() < hard_mudlle_stack_limit
      && config->maxlen >= 256)
    return false;

  static bool (*const funcs[])(struct print_config *, value) = {
    [type_bigint]     = write_bigint,
    [type_closure]    = write_closure,
    [type_icode]      = write_code,
    [type_file]       = write_file,
    [type_float]      = write_float,
    [type_gone]       = NULL,   /* always hidden */
    [type_integer]    = NULL,   /* handled above */
    [type_internal]   = NULL,   /* always hidden */
    [type_null]       = NULL,   /* handled above */
    [type_oport]      = write_oport,
    [type_pair]       = write_list,
    [type_primitive]  = write_primitive,
    [type_private]    = write_private,
    [type_weak_ref]   = write_weak_ref,
    [type_regexp]     = NULL,   /* always hidden */
    [type_secure]     = write_primitive,
    [type_string]     = NULL,   /* special case */
    [type_symbol]     = write_symbol,
    [type_table]      = write_table,
    [type_varargs]    = write_primitive,
    [type_variable]   = write_variable,
    [type_vector]     = write_vector,
  };
  CASSERT_VLEN(funcs, mudlle_types);

  enum mudlle_type type = ((struct obj *)v)->type;

  if ((config->flags & fmt_flag_storable)
      && saveable_object_type[type])
    {
      /* fmt_flag_storable must fail for any none-gone object referenced
         multiple times */
      struct seen_obj *seen;
      bool r;
      if (check_recursion(config, 0, "", v, &seen, &r))
        return r;
    }

  size_t oldmaxatomlen = config->maxatomlen;

  switch (type)
    {
    case type_pair:
    case type_symbol:
    case type_table:
    case type_vector:
      {
        struct seen_obj *seen = NULL;
        bool r;
        if (!(config->flags & fmt_flag_storable)
            && check_recursion(config, 0, "", v, &seen, &r))
          return r;
        config->maxatomlen = config->nested_maxatomlen;

        enum rwmode prev_rwmode;
        r = (push_rwmode(config, &prev_rwmode, ((struct obj *)v)->flags,
                         type == type_string)
             && funcs[type](config, v));
        pop_rwmode(config, prev_rwmode);

        config->maxatomlen = oldmaxatomlen;
        if (seen != NULL
            && !(config->flags & (fmt_flag_nref | fmt_flag_storable)))
          pop_from_seen(config, seen);
        return r;
      }
    case type_string:
      return output_string(config, v);
    case type_float:
    case type_bigint:
      break;
    default:
      if (p_level(config) != fmt_constant)
        {
          if (hidden[p_level(config)][type])
            return p_type(config, mudlle_type_names[type], true);
          break;
        }
      if (config->flags & fmt_flag_replace_gone)
        return p_fmt(config, "(/*%s*/)", mudlle_type_names[type]);
      if (config->flags & fmt_flag_storable)
        return p_str(config, "#gone");
      return false;
    }

  struct p_pos pos = p_pos(config);
  bool r = funcs[type](config, v);

  if (r || do_trunc(config))
    return r;

  p_setpos(config, &pos);
  return p_type(config, mudlle_type_names[type], true);
}

static bool simple_print(struct oport *f, const char *s, enum fmt_flag level,
                         unsigned flags, size_t maxlen)
{
  size_t len = strlen(s);
  bool ok = len <= maxlen;
  if (!ok)
    {
      if (level == fmt_constant)
        return false;
      if (!(flags & fmt_flag_truncate))
        {
          if (maxlen < 3)
            return false;
          pputs("...", f);
          return true;
        }
      len = maxlen;
    }
  port_write(f, s, len);
  return ok;
}

static void fixup_nref_list_end(struct nref *nref)
{
  if (nref->type == nref_list_end && nref->pos == SIZE_MAX)
    nref->pos = nref->seen->list_end;
}

static int cmp_nref(const void *a, const void *b)
{
  const struct nref *na = a;
  const struct nref *nb = b;
  int r = CMP(na->pos, nb->pos);
  if (r != 0)
    return r;

  /* nref_use must be emitted before nref_list_end */
  if (na->type == nref_use && nb->type == nref_list_end)
    return -1;
  if (na->type == nref_list_end && nb->type == nref_use)
    return 1;

  if (na->type == nref_def && nb->type == nref_def)
    {
      /* list pair must be emitted before list element */
      if (na->seen->list_end != 0
          && nb->seen->list_end == 0)
        return -1;
      if (na->seen->list_end == 0
          && nb->seen->list_end != 0)
        return 1;
    }

  abort();
}

/* return true if printed correctly */
bool output_value_cut(struct oport *f, value v, size_t maxlen, unsigned flags)
{
  if (f == NULL)
    return true;

  enum fmt_flag level = flags & fmt_level_mask;
  if (level == fmt_constant)
    {
      flags |= fmt_flag_truncate;
      if (flags & fmt_flag_storable)
        flags &= ~fmt_flag_nref;
    }
  else
    flags &= ~fmt_flag_replace_gone;

  /* optimise common cases */
  if (integerp(v) && (flags & fmt_base_mask) == fmt_base_dec)
    {
      struct intstr buf;
      bool r = simple_print(f, longtostr(&buf, 10, intval(v)),
                            level, flags, maxlen);
      return r;
    }

  if (v == NULL)
    {
      const char *s;
      if (!(flags & fmt_flag_quote))
        s = "()";
      else if (level == fmt_constant)
        s = "'()";
      else
        {
          bool r = simple_print(f, "null", level, flags, maxlen);
          return r;
        }
      return simple_print(f, s, level, flags, maxlen);
    }

  struct print_config config = {
    .f                 = f,
    .flags             = flags,
    .maxlen            = maxlen,
    .maxatomlen        = level == fmt_constant ? maxlen : DEFAULT_MAX_ATOM_LEN,
    .nested_maxatomlen = level == fmt_constant ? maxlen : NESTED_MAX_ATOM_LEN,
    .max_indent_level  = (flags >> fmt_nest_shift) & fmt_nest_max,
    .sb                = SBNULL,
    .seen              = ARRAY_NULL,
    .rwmode            = (level != fmt_constant
                          ? rwmode_rw
                          : ((flags & fmt_flag_storable)
                             ? rwmode_rw
                             : rwmode_im))
  };

  switch (flags & fmt_base_mask)
    {
    case fmt_base_bin: config.base = 2;  break;
    case fmt_base_oct: config.base = 8;  break;
    case fmt_base_dec: config.base = 10; break;
    case fmt_base_hex: config.base = 16; break;
    default: abort();
    }

  if (TYPE(v, string) && maxlen == SIZE_MAX && !(flags & fmt_flag_storable))
    {
      GCPRO(config.f);
      if (!output_string(&config, v))
        abort();
      UNGCPRO();
      return true;
    }

  GCPRO(config.f, f, v);

  if (level == fmt_constant
      || !(flags & fmt_flag_truncate)
      || (flags & fmt_flag_nref))
    {
      config.use_strbuf = true;
      config.f = make_strbuf_oport(&config.sb);
    }

  bool result = true;
  if ((flags & fmt_flag_quote) && pointerp(v))
    switch (((struct obj *)v)->type)
      {
      case type_pair:
      case type_vector:
      case type_symbol:
      case type_table:
        result = result && p_char(&config, '\'');
        break;
      default:
        break;
      }

  result = result && print_value(&config, v);
  if (config.use_strbuf)
    {
      port_close(config.f);

      if (!result && level == fmt_constant)
        ;
      else if (!result && sb_len(&config.sb) == 0)
        {
          if (maxlen >= 3)
            {
              pputs("...", f);
              result = true;
            }
        }
      else if (ARRAY_IS_EMPTY(config.nrefs))
        port_write(f, sb_str(&config.sb), sb_len(&config.sb));
      else
        {
          /* reset 'config' to print to 'f' */
          config.use_strbuf = false;
          config.maxlen     = maxlen + config.markup_len;
          config.f          = f;

          ARRAY_FOR (config.nrefs, , struct nref *, nref)
            fixup_nref_list_end(nref);
          ARRAY_QSORT(config.nrefs, cmp_nref);

          size_t cpos = 0;
          /* config.sb may be used as a temporary buffer, so save the value */
          size_t strlen = sb_len(&config.sb);
          char *str = sb_detach(&config.sb);
          ARRAY_FOR (config.nrefs, i, struct nref *, nref)
            {
              p_mem(&config, str + cpos, nref->pos - cpos, true);
              cpos = nref->pos;
              if (nref->seen->uses == 0)
                continue;
              switch (nref->type)
                {
                case nref_def:
                  if (nref->seen->list_end > 0)
                    p_str(&config, ". ");
                  p_fmt(&config, "#%zd=", nref->seen->number);
                  if (nref->seen->list_end > 0)
                    p_char(&config, '(');
                  break;
                case nref_use:
                  p_fmt(&config, "#%zd", nref->seen->number);
                  break;
                case nref_list_end:
                  p_char(&config, ')');
                  break;
                }
            }
          p_mem(&config, str + cpos, strlen - cpos, true);
          free(str);
          ARRAY_FREE(config.nrefs);
        }
    }

  ARRAY_FREE(config.nrefs);

  if (!(flags & (fmt_flag_nref | fmt_flag_storable)))
    assert(ARRAY_IS_EMPTY(config.seen));
  else
    while (!ARRAY_IS_EMPTY(config.seen))
      {
        struct seen_obj *last = ARRAY_GET(config.seen,
                                          ARRAY_ENTRIES(config.seen) - 1);
        pop_from_seen(&config, last);
      }
  ARRAY_FREE(config.seen);
  sb_free(&config.sb);
  UNGCPRO();
  return result;
}

void output_value(struct oport *f, enum fmt_flag level, value v,
                  bool use_ascii)
{
  unsigned flags = level | fmt_flag_quote | fmt_flag_nref;
  if (use_ascii)
    flags |= fmt_flag_ascii;
  if (level == fmt_examine)
    flags |= fmt_flag_full_code;
  output_value_cut(f, v, 1024, flags);
}

void describe_fn(struct strbuf *sb, value v)
{
  if (!pointerp(v))
    goto no_fn;

  struct obj *o = v;
  switch (o->type)
    {
    case type_primitive:
    case type_secure:
    case type_varargs:
      {
        struct primitive *prim = v;
        sb_printf(sb, "%s() [%s]", prim->op->name->str,
                  mudlle_type_names[o->type]);
        return;
      }
    case type_closure:
      {
        struct closure *cl = v;
        struct code *code = cl->code;
        struct string *name = code->varname;
        sb_printf(sb, "%s() [%s:%d]",
                  name ? name->str : "<fn>",
                  code_filename(code)->str,
                  code->lineno);
        return;
      }
    default:
      break;
    }

 no_fn: ;

  GCPRO(v);
  struct oport *op = make_strbuf_oport(sb);
  UNGCPRO();
  output_value(op, fmt_display, v, false);
}

#define C_DEL '\177'
#define C_SOFT_HYPHEN '\255'

void print_init(void)
{
  for (unsigned char c = 32; c < 128; c++)
    {
      set_writable(c, true);
      set_writable(c | 0x80, true);
    }
  set_writable('"', false);
  set_writable('\\', false);
  set_writable(C_DEL, false);
  set_writable(C_NBSP, false);
  set_writable(C_SOFT_HYPHEN, false);
}

void sb_add_seclevel(struct strbuf *sb, int lev)
{
  sb_addint(sb, lev);
}
