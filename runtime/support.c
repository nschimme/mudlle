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

#include <errno.h>

#include "check-types.h"
#include "list.h"
#include "prims.h"
#include "support.h"
#include "vector.h"

#include "../builtins.h"
#include "../compile.h"
#include "../dwarf.h"
#include "../global.h"
#include "../jitdump.h"
#include "../module.h"
#include "../mtree.h"
#include "../ports.h"
#include "../strbuf.h"
#include "../table.h"
#include "../tree.h"

TYPEDOP(mudlle_parse, , "`s0 `s1|null `n0 -> `x. Parses mudlle expression"
        " `s0 and returns one of the following:\n"
        "  `v       \ta parse tree vector\n"
        "  true    \t`s0 does not contain code\n"
        "  false   \tparsing failed\n"
        "  `n1 . `v  \tif `mp_allow_tail is set, `n1 is the number of"
        " characters that were used in the input, and `v is the parse tree"
        " vector\n\n"
        "`s1 is the filename; can be null for \"<string>\".\n\n"
        "`n0 is one of the `mp_mode_xxx values:\n"
        "  `mp_mode_file          \tparse a mudlle file (default)\n"
        "  `mp_mode_any_expr      \tparse a single expression\n"
        "  `mp_mode_paren_expr    \tparse a single expression in parentheses\n"
        "  `mp_mode_primary_expr  \tparse a single primary expression\n"
        "optionally bitwise OR with `mp_xxx flags:\n"
        "  `mp_pure_ast           \tgenerate a pure AST\n"
        "  `mp_user_symbols       \tallow \"$...\" user variables\n"
        "  `mp_allow_tail         \tallow trailing non-matched input;"
        " not supported with `mp_mode_file",
        (struct string *code, struct string *name, value mflags),
        OP_LEAF | OP_NOESCAPE,
        "s[su]n.[vnk]")
{
  unsigned flags;
  CHECK_TYPES(code,   string,
              name,   CT_TYPES(null, string),
              mflags, CT_RANGE(flags, 0, mp_all_flags));

  enum parser_mode pmode;
  switch (flags & mp_mode_mask)
    {
    case mp_mode_file:
      pmode = parser_mode_file;
      if (flags & mp_allow_tail)
        RUNTIME_ERROR_ARG(
          2, error_bad_value,
          fmt_error_message("%s%s%s is not supported with %s%s%s",
                            CMARKUP(var, "mp_allow_tail"),
                            CMARKUP(var, "mp_mode_file")));
      break;
    case mp_mode_any_expr:     pmode = parser_mode_any_expr;     break;
    case mp_mode_primary_expr: pmode = parser_mode_primary_expr; break;
    case mp_mode_paren_expr:   pmode = parser_mode_paren_expr;   break;
    default:
      RUNTIME_ERROR_ARG(2, error_bad_value, "invalid mode");
    }

  value omuderr = muderr();
  if (pmode != parser_mode_file)
    {
      GCPRO(omuderr, code, name);
      session_context->ports.err = make_sink_oport();
      UNGCPRO();
    }

  ASSERT_NOALLOC_START();
  struct strbuf sbname = sb_initstr(name ? name->str : "<string>");
  ASSERT_NOALLOC();

  struct mfile *f = NULL;
  struct component *e = NULL;
  int end_pos = 0;
  const struct cstrlen lines[] = { cstrlen_from_mstr(code) };
  const struct parser_config pconfig = {
    .allow_empty = true,
    .filename    = {
      .filename = sb_str(&sbname),
      .nicename = sb_str(&sbname)
    },
    .pmode     = pmode,
    .comments  = flags & mp_pure_ast,
    .user_syms = flags & mp_user_symbols,
    .nstrs     = VLENGTH(lines),
    .strs      = lines
  };

  struct compiler_state cstate;
  push_compiler_state(&cstate, &pconfig);
  collect_compiler_messages();

  bool ok = (pmode == parser_mode_file
             ? parse(&f, &pconfig)
             : parse_expression(&e, &end_pos, flags & mp_allow_tail,
                                &pconfig));

  ASSERT_NOALLOC();
  send_compiler_messages();

  session_context->ports.err = omuderr;

  value parsed;
  if (!ok)
    parsed = makebool(false);
  else if (f != NULL)
    parsed = mudlle_parse(f, !(flags & mp_pure_ast));
  else if (e != NULL)
    {
      parsed = mudlle_parse_expr(e, !(flags & mp_pure_ast));
      if (flags & mp_allow_tail)
        parsed = alloc_list(makeint(end_pos), parsed);
    }
  else
    parsed = makebool(true);

  pop_compiler_state(&cstate);
  sb_free(&sbname);

  return parsed;
}

UNSAFEOP(mudlle_parse_file, ,
         "`s1 `s2 `s3 `b -> `v|true|false. Parse the file `s1, using the"
         " name `s2 for error messages, recording `s2 as its file name,"
         " and `s3 as its nice name.\n"
         "If `b, generate a pure AST.\n"
         "Return its parse tree `v, or false if unsuccessful.\n"
         "Returns true if the file is empty or starts with an asterisk.\n"
         "Causes an error if the file cannot be opened.",
         (struct string *fullname, struct string *filename,
          struct string *nicename, value mpure_ast_p),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "sssx.[vn]")
{
  ASSERT_NOALLOC_START();

  CHECK_TYPES(fullname,    string,
              filename,    string,
              nicename,    string,
              mpure_ast_p, any);

  FILE *f = fopen(fullname->str, "r");
  if (f == NULL)
    RUNTIME_ERROR(error_bad_value, errno_message(errno, "opening file"));

  int c = fgetc(f);
  if (c == '*' || c == EOF)
    {
      /* empty or commented-out file */
      fclose(f);
      return makebool(true);
    }
  ungetc(c, f);

  struct strbuf sbfname = sb_initstr(filename->str);
  struct strbuf sbnname = sb_initstr(nicename->str);

  ASSERT_NOALLOC();
  const struct parser_config pconfig = {
    .filename    = {
      .filename  = sb_str(&sbfname),
      .nicename  = sb_str(&sbnname),
    },
    .allow_empty = true,
    .pmode       = parser_mode_file,
    .f           = f,
  };

  struct compiler_state cstate;
  push_compiler_state(&cstate, &pconfig);
  collect_compiler_messages();

  struct mfile *mf;
  bool ok = parse(&mf, &pconfig);
  ASSERT_NOALLOC();
  send_compiler_messages();

  value parsed = (!ok
                  ? makebool(false)
                  : (mf == NULL
                     ? makebool(true)
                     : mudlle_parse(mf, isfalse(mpure_ast_p))));

  pop_compiler_state(&cstate);
  sb_free(&sbfname);
  sb_free(&sbnname);
  fclose(f);

  return parsed;
}

/* The machine language builtin ops */

#ifndef NOCOMPILER
#ifdef __x86_64__
  #define BUILTIN_ABSOLUTE true
#endif

#define is_alias_brglobal MARK
#define builtin_brglobal check_global_read
#define is_alias_bwglobal MARK
#define builtin_bwglobal check_global_write

#define DECL_BUILTIN(func) {                            \
  .name     = #func,                                    \
  .address  = (void *)IF(IS_MARK(is_alias_ ## func))(   \
    builtin_ ## func, func),                            \
  .absolute = BUILTIN_ABSOLUTE                          \
}
static const struct builtin {
  const char *name;
  void *address;
  bool absolute;
} builtins[] = {
  /* must be sorted; relies on all of these starting with "b" */
  BUILTINS_FOREACH(DECL_BUILTIN, SEP_COMMA),
  { "env_values",     &env_values,              true },
  { "max_loop_count", makeint(MAX_LOOP_COUNT),  true },
  { "maxseclevel",    &internal_maxseclevel,    true },
  { "xcount",         (void *)&internal_xcount, true },
};
#undef DECL_BUILTIN
#endif /* ! NOCOMPILER */

#ifndef NOCOMPILER
static int cmp_builtin(const void *k, const void *b)
{
  const char *key = k;
  const struct builtin *builtin = b;
  return strcmp(key, builtin->name);
}

static const struct builtin *builtin_find(struct string *name)
{
  return bsearch(name->str, builtins, VLENGTH(builtins), sizeof builtins[0],
                 cmp_builtin);
}
#endif /* ! NOCOMPILER */

#ifndef NOCOMPILER
static const struct prim_op *prim_op_find(struct string *name)
{
  ulong n = mglobal_lookup(name);
  struct primitive *p = GVAR(n);

  if (!(TYPE(p, primitive)
        || TYPE(p, varargs)))
    return NULL;

  return p->op;
}

static ulong primitive_find(struct string *name)
{
  const struct prim_op *op = prim_op_find(name);
  return op ? (ulong)op->op : 0;
}

static inline void set_cst(uint8_t *x, ulong n)
{
  memcpy(x, &n, sizeof n);
}

static void check_primitives(struct list *scan)
{
  while (scan != NULL)
    {
      TYPEIS(scan, pair);
      struct list *primitive = scan->car;
      TYPEIS(primitive, pair);
      TYPEIS(primitive->car, string);
      TYPEIS(primitive->cdr, integer);
      if (!primitive_find(primitive->car))
        runtime_error(error_bad_value);
      scan = scan->cdr;
    }
}

static inline value assert_immutable(value v)
{
  assert(immutablep(v));
  return v;
}

#endif /* ! NOCOMPILER */

UNSAFEOP(register_mcode_module, ,
         "`l -> . Register mcode objects in `l as a code module.",
         (struct list *l),
         OP_LEAF | OP_NOESCAPE | OP_NOALLOC,
         "l.")
{
  CHECK_TYPES(l, CT_TYPES(null, pair));

#ifndef NOCOMPILER
  struct mcode_array mcodes = ARRAY_NULL;
#endif
  for (; l != NULL; l = l->cdr)
    {
      TYPEIS(l, pair);
      if (TYPE(l->car, icode))
        continue;
#ifdef NOCOMPILER
      RUNTIME_ERROR(error_bad_value, "native module contains non-LLVM code");
#else
      if (!TYPE(l->car, mcode))
        RUNTIME_ERROR(error_bad_type, "code module contains invalid code");
      struct mcode *mcode = l->car;
      if (!mcode->dwarf_seen)
        ARRAY_ADD(mcodes, mcode);
#endif
    }
#ifndef NOCOMPILER
  register_dwarf_mcodes(0, &mcodes);
  ARRAY_FREE(mcodes);
#endif
  undefined();
}

TYPEDOP(dwarf_line_number_info, ,
        "`v -> `s. Returns DWARF line number information for locations"
        " in `v, a vector of (`address . `line). The addresses must be sorted,"
        " lowest first.\n"
        "Cf. `expand_line_number_info().",
        (struct vector *locs), OP_LEAF | OP_NOESCAPE, "v.s")
{
  CHECK_TYPES(locs, vector);

  size_t nstates = vector_len(locs);
  uint32_t last = 0;
  for (size_t l = 0; l < vector_len(locs); ++l)
    {
      struct list *loc = locs->data[l];
      TYPEIS(loc, pair);
      long adr = GETRANGE(loc->car, last, UINT32_MAX);
      last = adr;
      GETRANGE(loc->cdr, 1, INT32_MAX);
    }

  struct lni_state *states = nstates ? malloc(sizeof *states * nstates) : NULL;
  for (size_t l = 0; l < nstates; ++l)
    {
      struct list *loc = locs->data[l];
      states[l] = (struct lni_state){
        .addr = intval(loc->car),
        .line = intval(loc->cdr),
      };
    }

  struct string *lni = dwarf_line_number_info(states, nstates);
  free(states);
  return lni;
}

TYPEDOP(expand_line_number_info, ,
        "`x -> `v. Returns DWARF line number information in closure,"
        " code, or string `x.\n"
        "Each entry in `v is a cons(`address . `line).\n"
        "Cf. `dwarf_line_number_info().",
        (value x), OP_LEAF | OP_NOESCAPE, "f.v")
{
  CHECK_TYPES(x, CT_TYPES(closure, icode, mcode, string));
  struct string *lni;
  if (TYPE(x, string))
    lni = x;
  else if (TYPE(x, closure))
    lni = ((struct closure *)x)->code->linenos;
  else
    lni = ((struct code *)x)->linenos;
  return mudlle_line_number_info(lni);
}

VAROP(link, ,
      "`s1 `n1 `s2 `s3 `p `v `l1 `l2 `l3 `l4 `l5 `l6 `l7 `l8"
      " `n2 `n3 `s4 `s5|null `b `n4 -> `code. Builds a code object from:\n"
      "its machine code `s1,\n"
      "security level `n1, help string `s2, varname `s3, filenames `p,"
      " cons(filename, nicename), location `v, a cons(line, column),"
      " return typeset `n2, return itype `n3, line number info `s4,"
      " argument types `s5 (null for varargs), allocates vararg vector (`b),"
      " and closure flags `n4."
      "constants `l1=list of constant/offset pairs\n"
      "builtins `l2=list of name/offset pairs\n"
      "globals `l3=list of name/offset pairs\n"
      "absolute primitives `l4=list of name/offset pairs\n"
      "relative primitives `l5=list of name/offset pairs\n"
      "seclevs `l6=list of offsets",
      (struct vector *args),
      0, "snsskvllllllllnnssxn.o")
{
#ifdef NOCOMPILER
  runtime_error(error_bad_value);
#else  /* !NOCOMPILER */

#ifndef __x86_64__
#error Unsupported architecture
#endif

  enum lv_arg {
    lv_mcode,
    lv_seclev,
    lv_help,
    lv_varname,
    lv_filenames,
    lv_location,
    lv_consts,
    lv_code_entries,
    lv_builtins,
    lv_globals,
    lv_primitives,
    lv_primops,
    lv_npcrel,
    lv_seclevs,
    lv_return_typeset,
    lv_return_itype,
    lv_linenos,
    lv_arguments,
    lv_vararg_alloc,
    lv_flags,
    lv_number_of_fields
  };

  assert(strlen(THIS_OP->types[0]) == lv_number_of_fields + 2);


  if (vector_len(args) != lv_number_of_fields)
    runtime_error(error_wrong_parameters);

  GCPRO(args);

  TYPEIS(args->data[lv_mcode], string);
  size_t clen = string_len((struct string *)args->data[lv_mcode]);
  TYPEIS(args->data[lv_linenos], string);

  TYPESETIS(args->data[lv_help],    TSET(string) | TSET(null));
  TYPESETIS(args->data[lv_varname], TSET(string) | TSET(null));

  {
    struct list *l = args->data[lv_filenames];
    TYPEIS(l, pair);
    TYPEIS(l->car, string);
    TYPEIS(l->cdr, string);
  }

  {
    struct vector *argv = args->data[lv_arguments];
    TYPEIS(argv, vector);
    for (size_t i = 0; i < vector_len(argv); ++i)
      {
        struct list *e = argv->data[i];
        TYPEIS(e, pair);
        if (!isfalse(e->car))
          TYPEIS(e->car, string);
        TYPESETIS(e->cdr, TSET(null) | TSET(integer));
        if (e->cdr == NULL && i + 1 != vector_len(argv))
          runtime_error(error_bad_value);
      }
  }

  struct vector *mloc = args->data[lv_location];
  VALUE_IS_VECTOR_LEN(mloc, 3);

  long     alineno         = GETINT(mloc->data[0]);
  long     acolumn         = GETINT(mloc->data[1]);
  seclev_t seclev          = GETRANGE(args->data[lv_seclev], 0, MAX_SECLEVEL);
  typeset_t return_typeset = GETRANGE(args->data[lv_return_typeset],
                                      0, TYPESET_ANY | TYPESET_FALSE);
  ulong    return_itype    = GETRANGE(args->data[lv_return_itype],
                                      0, LONG_MAX);
  ulong    flags           = GETRANGE(args->data[lv_flags], 0, LONG_MAX);

  static const enum lv_arg const_lists[] = {
    [mcode_ct_const]      = lv_consts,
    [mcode_ct_code_entry] = lv_code_entries
  };
  CASSERT_VLEN(const_lists, mcode_const_types);
  ulong type_ncsts[VLENGTH(const_lists)] = { 0 };

  for (enum mcode_const_type ct = 0; ct < mcode_const_types; ++ct)
    {
      long prev_ofs = 0;
      for (struct list *scan_csts = args->data[const_lists[ct]];
           scan_csts != NULL;
           scan_csts = scan_csts->cdr)
        {
          TYPEIS(scan_csts, pair);

          struct list *cst = scan_csts->car;
          TYPEIS(cst, pair);

          if (ct == mcode_ct_code_entry)
            TYPESETIS(cst->car, TSET(icode) | TSET(mcode));
          TYPEIS(cst->cdr, integer);
          long ofs = GETINT(cst->cdr);
          if (ofs < prev_ofs)
            runtime_error(error_bad_value);
          prev_ofs = ofs + sizeof (value);

          ++type_ncsts[ct];
        }
    }

  struct strbuf sbcst = SBNULL;
  unsigned nzeros_to_add = 0;
  for (enum mcode_const_type ct = 0; ct < mcode_const_types; ++ct)
    {
      if (type_ncsts[ct] == 0)
        {
          ++nzeros_to_add;
          continue;
        }
      for (; nzeros_to_add > 0; --nzeros_to_add)
        sb_add_leb_u(&sbcst, 0);
      sb_add_leb_u(&sbcst, type_ncsts[ct]);
      long prev_ofs = 0;
      for (struct list *scan_csts = args->data[const_lists[ct]];
           scan_csts != NULL;
           scan_csts = scan_csts->cdr)
        {
          struct list *cst = scan_csts->car;
          long ofs = GETINT(cst->cdr);
          long dofs = ofs - prev_ofs;
          sb_add_leb_u(&sbcst, dofs);
          prev_ofs = ofs + sizeof (value);
        }
    }

  for (struct list *scan_builtins = args->data[lv_builtins];
       scan_builtins;
       scan_builtins = scan_builtins->cdr)
    {
      TYPEIS(scan_builtins, pair);
      struct list *builtin = scan_builtins->car;
      TYPEIS(builtin, pair);
      TYPEIS(builtin->car, string);
      TYPEIS(builtin->cdr, integer);
    }

  {
    struct list *scan_globals = args->data[lv_globals];
    struct gcpro gcprog;
    GCPROV(gcprog, scan_globals);
    while (scan_globals != NULL)
      {
        TYPEIS(scan_globals, pair);
        struct list *lglobal = scan_globals->car;
        TYPEIS(lglobal, pair);
        TYPEIS(lglobal->cdr, integer);
        struct string *gname;
        if (TYPE(lglobal->car, pair))
          {
            struct list *gtype = lglobal->car;
            gname = gtype->car;
            /* 0 means global index, 1 means gidx * 2 + 1 */
            (void)GETRANGE(gtype->cdr, 0, 1);
          }
        else
          gname = lglobal->car;
        TYPEIS(gname, string);
        mglobal_lookup(gname); /* don't want GC later! */
        scan_globals = scan_globals->cdr;
      }
    UNGCPROV(gcprog);
  }

  check_primitives(args->data[lv_primitives]);
  check_primitives(args->data[lv_primops]);

  const ulong npcrel = GETRANGE(args->data[lv_npcrel],
                                0, MAX_FIELD_VAL(struct mcode, npcrel));

  /* Count relocatable builtins */
  for (struct list *scan_builtins = args->data[lv_builtins];
       scan_builtins;
       scan_builtins = scan_builtins->cdr)
    {
      struct list *builtin = scan_builtins->car;

      const struct builtin *b = builtin_find(builtin->car);
      if (b == NULL)
	runtime_error(error_bad_value);

      assert(b->absolute);
    }

  ulong size = offsetof(struct mcode, mcode) + clen;
  ulong code_pad = 0;
  if (npcrel > 0)
    {
      code_pad = PADDING(size, sizeof (value));
      size += code_pad;
      size += npcrel * sizeof (value);
    }
  ulong cst_offset_start = size;
  size += sb_len(&sbcst);

  /* allocate extra space to ensure that gen1 will have space for
     this object even with the aligned forwarding */
  struct mcode *newp = (struct mcode *)gc_allocate(size + CODE_ALIGNMENT - 1);
#ifdef GCDEBUG
  ulong generation = newp->code.o.generation;
#endif
  {
    ulong diff = ((CODE_ALIGNMENT - (ulong)(&newp->mcode))
                  & (CODE_ALIGNMENT - 1));
    struct mcode *oldp = newp;
    newp = (struct mcode *)((char *)oldp + diff);
    assert(((ulong)(&newp->mcode) & (CODE_ALIGNMENT - 1)) == 0);
    memset(oldp, 0, diff);
  }
  UNGCPRO();
  /* No more GC from here on !!! */

  static uint32_t mcode_sequence;

  *newp = (struct mcode){
    .code = {
      .o = {
        .size         = size,
        .garbage_type = garbage_mcode,
        .type         = type_mcode,
        .flags        = 0,
#ifdef GCDEBUG
        .generation   = generation,
#endif
      },
      .varname        = assert_immutable(args->data[lv_varname]),
      .filenames      = assert_immutable(args->data[lv_filenames]),
      .help           = assert_immutable(args->data[lv_help]),
      .arguments      = assert_immutable(args->data[lv_arguments]),
      .vararg_alloc   = istrue(args->data[lv_vararg_alloc]),
      .linenos        = args->data[lv_linenos],
      .lineno         = ((alineno >= 1
                          && alineno <= MAX_FIELD_VAL(struct code, lineno))
                         ? alineno
                         : 1),
      .column         = ((acolumn >= 1
                          && acolumn <= MAX_FIELD_VAL(struct code, column))
                         ? acolumn
                         : 1),
      .seclevel       = seclev,
      .return_typeset = return_typeset
    },
#ifdef __x86_64__
    .npcrel        = npcrel,
#endif
    .code_length   = clen,
    .closure_flags = flags,
    .return_itype  = return_itype,
    .sequence      = ++mcode_sequence,
    .magic         = MCODE_MAGIC,
  };

  memcpy(newp->mcode, ((struct string *)args->data[lv_mcode])->str, clen);

  static const char *const nops[] =
    {
      "",
#define _NOP(n, arg) NOP ## n
      FORN(7, _NOP, SEP_COMMA, )
#undef _NOP
    };
  assert(code_pad <= VLENGTH(nops));

  /* align with nop of appropriate length (if applicable) */
  memcpy(newp->mcode + clen, nops[code_pad], code_pad);

  memcpy((char *)newp + cst_offset_start, sb_str(&sbcst), sb_len(&sbcst));
  sb_free(&sbcst);

  /* Copy constants and their offsets */
  for (struct list *seclevs = args->data[lv_seclevs];
       seclevs;
       seclevs = seclevs->cdr)
    {
      assert(TYPE(seclevs, pair));
      struct list *e = seclevs->car;
      assert(TYPE(e, pair));
      assert(integerp(e->car));
      assert(integerp(e->cdr));
      long ofs = intval(e->cdr);
      enum {
        sl_c      = 0,
        sl_mudlle = 1,
        sl_maxlev = 2
      } type = intval(e->car);
      switch (type)
        {
        case sl_c:
          {
            uint32_t l = seclev;
            memcpy(newp->mcode + ofs, &l, sizeof l);
            break;
          }
        case sl_mudlle:
          {
            uint32_t l = (ulong)makeint(seclev);
            memcpy(newp->mcode + ofs, &l, sizeof l);
            break;
          }
        case sl_maxlev:
          {
            uint32_t l = (ulong)seclevel_to_maxseclevel(seclev);
            memcpy(newp->mcode + ofs, &l, sizeof l);
            break;
          }
        default:
          abort();
        }
    }

  for (enum mcode_const_type ct = 0; ct < mcode_const_types; ++ct)
    for (struct list *scan_csts = args->data[const_lists[ct]];
         scan_csts != NULL;
         scan_csts = scan_csts->cdr)
      {
        assert(TYPE(scan_csts, pair));
        struct list *cst = scan_csts->car;
        assert(TYPE(cst, pair));
        assert(immutablep(cst->car));
        long offset = intval(cst->cdr);
        ulong u = (ulong)cst->car;
        if (ct == mcode_ct_code_entry)
          u += offsetof(struct mcode, mcode);
        set_cst(newp->mcode + offset, u);
      }

  /* Set builtin addresses */
  for (struct list *scan_builtins = args->data[lv_builtins];
       scan_builtins;
       scan_builtins = scan_builtins->cdr)
    {
      assert(TYPE(scan_builtins, pair));
      struct list *builtin = scan_builtins->car;
      const struct builtin *b = builtin_find(builtin->car);
      long offset = intval(builtin->cdr);
      uint8_t *callins = newp->mcode + offset;

      ulong adr = (ulong)b->address;
      if (!b->absolute)
        adr -= (ulong)callins + sizeof (ulong);
      set_cst(callins, adr);
    }

  /* Set primitive addresses */
  for (struct list *scan_primitives = args->data[lv_primitives];
       scan_primitives;
       scan_primitives = scan_primitives->cdr)
    {
      assert(TYPE(scan_primitives, pair));
      struct list *primitive = scan_primitives->car;
      long offset = intval(primitive->cdr);
      ulong paddress = primitive_find(primitive->car);
      set_cst(newp->mcode + offset, paddress);
    }

  for (struct list *scan_primops = args->data[lv_primops];
       scan_primops;
       scan_primops = scan_primops->cdr)
    {
      assert(TYPE(scan_primops, pair));
      struct list *primitive = scan_primops->car;
      long offset = intval(primitive->cdr);
      ulong paddress = (ulong)prim_op_find(primitive->car);
      set_cst(newp->mcode + offset, paddress);
    }

  /* Set global offsets */
  for (struct list *scan_globals = args->data[lv_globals];
       scan_globals;
       scan_globals = scan_globals->cdr)
    {
      assert(TYPE(scan_globals, pair));
      struct list *lglobal = scan_globals->car;
      long offset = intval(lglobal->cdr);

      ulong goffset;
      if (TYPE(lglobal->car, pair))
        {
          struct list *p = lglobal->car;
          struct string *name = p->car;
          goffset = mglobal_lookup(name);
          if (p->cdr == makeint(1))
            goffset = (ulong)makeint(goffset);
        }
      else
        {
          struct string *name = lglobal->car;
          goffset = mglobal_lookup(name);
          /* Compute byte offset from environment base */
          struct vector *genv = env_values;
          goffset = (uint8_t *)&genv->data[goffset] - (uint8_t *)genv;
        }

      assert(goffset <= UINT32_MAX);
      uint32_t u = goffset;
      memcpy(newp->mcode + offset, &u, sizeof u);
    }

#ifdef GCSTATS
  gcstats_add_alloc(type_mcode, MUDLLE_ALIGN(size + CODE_ALIGNMENT,
                                             sizeof (value)));
#endif

  newp->code.o.flags |= OBJ_IMMUTABLE;

  jitdump_load(newp);

  return newp;
#endif /* !NOCOMPILER */
}

UNSAFEOP(make_closure, , "`mcode -> `f. Makes a function with no closure"
         " vars from given `mcode object",
         (struct mcode *mmcode),
         OP_LEAF | OP_NOESCAPE, "o.f")
{
  CHECK_TYPES(mmcode, mcode);
  return alloc_closure0(&mmcode->code);
}

TYPEDOP(closurep, "closure?", "`x -> `b. True if `x is a closure.",
	(value x),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "x.n")
{
  return makebool(TYPE(x, closure));
}

TYPEDOP(securep, "secure?", "`x -> `b. True if `x is a secure primitive.",
	(value x),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "x.n")
{
  return makebool(TYPE(x, secure));
}

TYPEDOP(primitivep, "primitive?", "`x -> `b. True if `x is a primitive."
        " See also `any_primitive?().",
	(value x),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "x.n")
{
  return makebool(TYPE(x, primitive));
}

TYPEDOP(varargsp, "varargs?",
        "`x -> `b. True if `x is a variable argument primitive.",
	(value x),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "x.n")
{
  return makebool(TYPE(x, varargs));
}

TYPEDOP(any_primitivep, "any_primitive?", "`x -> `b. True if `x is either"
        " primitive, secure, or varargs.",
	(value x),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "x.n")
{
  return makebool(is_any_primitive(x));
}

TYPEDOP(primitive_nargs, ,
        "`primitive -> `n0. Returns number of arguments of primitive/secure;"
        " or ~`n1 for varargs with `n1 number of fixed arguments.",
	(struct primitive *prim),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "f.n")
{
  CHECK_TYPES(prim, CT_TYPESET(TYPESET_PRIMITIVE));
  return makeint(prim->op->nargs);
}

TYPEDOP(primitive_flags, , "`primitive -> `n. Returns flags of primitive.",
	(struct primitive *prim),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "f.n")
{
  CHECK_TYPES(prim, CT_TYPESET(TYPESET_PRIMITIVE));
  return makeint(prim->op->flags);
}

TYPEDOP(primitive_type, , "`primitive -> `l. Returns a list of type"
        " signatures for `primitive.\n"
        "Returns null if no type information is available.",
	(struct primitive *prim),
	OP_LEAF | OP_NOESCAPE, "f.l")
{
  CHECK_TYPES(prim, CT_TYPESET(TYPESET_PRIMITIVE));

  const char *const *types = prim->op->types;
  if (types == NULL)
    return NULL;

  struct list *l = NULL;
  GCPRO(l);
  for (; *types; ++types)
    {
      struct string *p = alloc_string(*types);
      l = alloc_list(p, l);
    }
  UNGCPRO();
  return l;
}

TYPEDOP(function_arguments, , "`f -> `v. Returns a"
        " vector(`name|false . `typeset|null) for `f's arguments.\n"
        "`name is a string; `typeset is a bitfield of 1 << `type_xxx or"
        " null for a variable-length argument.\n"
        "For non-vararg primitive arguments, `typeset is always"
        " `TYPESET_ANY.\n"
        "The `typeset flag `TYPESET_FLAG_OPTIONAL says that this argument"
        " is optional.",
        (struct closure *f), OP_LEAF | OP_NOESCAPE,
        "f.v")
{
  CHECK_TYPES(f, CT_FUNCTION);

  if (TYPE(f, closure))
    return ((struct closure *)f)->code->arguments;

  if (TYPE(f, mcode) || TYPE(f, icode))
    return ((struct code *)f)->arguments;

  assert(is_any_primitive(f));
  const struct prim_op *op = ((struct primitive *)f)->op;
  long nargs = op->nargs;
  if (nargs == 0)
    return empty_vector;
  if (nargs < 0)
    nargs = -nargs;

  struct vector *v = alloc_vector(nargs);
  GCPRO(v);
  for (int i = 0; i < nargs; ++i)
    {
      const char *suffix;
      size_t namelen;
      const char *name = (op->arglist != NULL
                          ? primop_argname(&namelen, &suffix, op->arglist[i])
                          : NULL);

      struct string *mname = NULL;
      if (name != NULL)
        {
          size_t suffixlen = suffix != NULL ? strlen(suffix) : 0;
          size_t totlen = namelen + suffixlen;
          mname = alloc_string_noinit(totlen);
          memcpy(mname->str, name, namelen);
          if (suffixlen > 0)
            memcpy(mname->str + namelen, suffix, suffixlen);
        }

      struct list *p = alloc_list(
        mname ? mname : makebool(false),
        op->nargs < 0 && i == nargs - 1 ? NULL : makeint(TYPESET_ANY));
      SET_VECTOR(v, i, p);
    }
  UNGCPRO();
  return v;
}

TYPEDOP(closure_return_typeset, , "`c -> `n. Returns possible return types of"
        " closure `c, a bitfield of 1 << `type_xxx.",
        (struct closure *c), OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "f.n")
{
  CHECK_TYPES(c, closure);
  return makeint(c->code->return_typeset);
}

TYPEDOP(closure_return_itype, , "`c -> `n. Returns possible return itypes of"
        " closure `c, a bitfield of `itype_xxx. Returns -1 for interpreted"
        " code.",
        (struct closure *c), OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "f.n")
{
  CHECK_TYPES(c, closure);
  if (c->code->o.type != type_mcode)
    return makeint(-1);
#ifdef NOCOMPILER
  abort();
#else
  return makeint(((struct mcode *)c->code)->return_itype);
#endif
}

TYPEDOP(closure_flags, , "`c -> `n. Returns closure flags for `c (closure,"
        " icode, or mcode), a bitset of `clf_xxx flags.",
        (value c), OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "[fo].n")
{
  CHECK_TYPES(c, CT_TYPES(closure, icode, mcode));

  if (TYPE(c, closure))
    c = ((struct closure *)c)->code;

  if (TYPE(c, icode))
    return makeint(0);

  if (TYPE(c, mcode))
    return makeint(((struct mcode *)c)->closure_flags);

  abort();
}

UNSAFEOP(closure_code, ,
         "`f -> `c. Returns the icode or mcode object of closure `f.",
         (struct closure *fn), OP_LEAF | OP_NOESCAPE, "f.o")
{
  CHECK_TYPES(fn, closure);
  return fn->code;
}

UNSAFEOP(global_table, , "-> `t. Returns global symbol table",
         (void),
         OP_LEAF | OP_NOALLOC | OP_NOESCAPE, ".t")
{
  return global;
}

TYPEDOP(global_name, , "`n -> `s. Returns the name of global `n"
        " for 0 <= `n < `global_names()",
        (value midx),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "n.s")
{
  long idx;
  CHECK_TYPES(midx, CT_RANGE(idx, 0, nglobals() - 1));
  return GNAME(idx);
}

SECOP(global_lookup, , "`s -> `n. Returns index of global variable `s."
      " Creates it if it doesn't exist already.",
      (struct string *name), SECLEVEL_GLOBALS,
      OP_LEAF | OP_NOESCAPE, "s.n")
{
  CHECK_TYPES(name, string);
  size_t nlen = string_len(name);
  if (nlen < 1 || nlen > MAX_VARIABLE_LENGTH)
    runtime_error(error_bad_value);
  return makeint(mglobal_lookup(name));
}

SECOP(global_value, , "`n -> `x. Returns value of global variable `n"
      " for 0 <= `n < `global_names()",
      (value midx), SECLEVEL_GLOBALS,
      OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "n.x")
{
  long idx;
  CHECK_TYPES(midx, CT_RANGE(idx, 0, nglobals() - 1));
  return GVAR(idx);
}

TYPEDOP(global_names, ,
        "-> `n. Returns the number of globals used. See also `global_name()"
        " and `global_value()",
	(void), OP_LEAF | OP_NOALLOC | OP_NOESCAPE, ".n")
{
  return environment->used;
}

UNSAFEOP(global_set, "global_set!",
         "`n `x -> `x. Sets global variable `n to `x."
         " Fails if global `n is readonly.",
         (value midx, value x),
         OP_LEAF | OP_NOALLOC, "nx.2")
{
  long idx;
  CHECK_TYPES(midx, CT_RANGE(idx, 0, nglobals() - 1),
              x,    any);
  if (GCONSTANT(idx))
    runtime_error(error_variable_read_only);
  GVAR(idx) = x;
  return x;
}

NOT_DEFINED(global_read);
TYPEDOP(global_read, , "", (value midx), OP_OPERATOR, "n.x")
{
  /* only used to print error messages */
  undefined();
}

NOT_DEFINED(global_write);
TYPEDOP(global_write, , "", (value midx, value x), OP_OPERATOR, "nx.2")
{
  /* only used to print error messages */
  undefined();
}

const struct prim_op *const global_read_ext = &op_global_read;
const struct prim_op *const global_write_ext = &op_global_write;

void global_runtime_error(enum runtime_error error, bool is_write,
                          ulong goffset, value val)
{
  primitive_runtime_error(error,
                          is_write ? &op_global_write : &op_global_read,
                          is_write ? 2 : 1, makeint(goffset), val);
}

TYPEDOP(all_modules, , "-> `v. Returns a vector of the names of all"
        " mudlle modules (libraries). Cf. `module_status().",
        (void),
        OP_LEAF | OP_NOESCAPE, ".v")
{
  struct vector *v = table_vector(module_data);
  for (size_t i = 0; i < vector_len(v); ++i)
    v->data[i] = ((struct symbol *)v->data[i])->name;
  return v;
}

TYPEDOP(module_status, , "`s -> `n. Returns status of module (library) `s,"
        " one of:\n"
        "  `module_unloaded   \thas not been loaded\n"
        "  `module_error      \tfailed to load\n"
        "  `module_loading    \tis currently loading\n"
        "  `module_loaded     \tloaded correctly\n"
        "  `module_protected  \tsystem module that cannot be unloaded",
	(struct string *name),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "s.n")
{
  CHECK_TYPES(name, string);
  return makeint(module_status(name->str));
}

TYPEDOP(module_seclevel, , "`s -> `n. Returns seclevel of module `s, or -1"
        " if unknown.",
	(struct string *name),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "s.n")
{
  CHECK_TYPES(name, string);
  return makeint(module_seclevel(name->str));
}

UNSAFEOP(module_set, "module_set!",
         "`s `n1 `n2 -> . Sets status of module `s to `n1, seclevel `n2",
         (struct string *name, value status, value seclev),
         OP_LEAF | OP_NOESCAPE, "snn.")
{
  CHECK_TYPES(name,   string,
              status, integer,
              seclev, integer);
  LOCAL_C_STR(tname, name, MAX_MODULE_NAME_LENGHT);
  module_set(tname, intval(status), intval(seclev));
  undefined();
}

SECOP(module_unload, , "`s -> `b. Unload module `s, making all its"
      " defined variables read-write and set them to null.\n"
      "You cannot unload system modules, nor modules with higher security"
      " level.\n"
      "Returns true if the module ended up unloaded.",
      (struct string *name), 1,
      OP_LEAF | OP_NOALLOC, "s.n")
{
  CHECK_TYPES(name, string);
  LOCAL_C_STR(tname, name, MAX_MODULE_NAME_LENGHT);
  if (get_effective_seclevel() < module_seclevel(tname))
    return makebool(false);
  return makebool(module_unload(tname));
}

TYPEDOP(module_require, ,
        "`s -> `n. Load module `s if needed, return its new status, one of"
        " the `module_xxx variables.",
	(struct string *name),
	0, "s.n")
{
  CHECK_TYPES(name, string);
  LOCAL_C_STR(tname, name, MAX_MODULE_NAME_LENGHT);
  return makeint(module_require(tname));
}

TYPEDOP(module_vstatus, ,
        "`n0 -> `s/`n1. Return status of global variable `n0; either the"
        " name of the defining library, or one of:\n"
        "  `var_normal          \tnormal variable\n"
        "  `var_write           \twritten by mudlle\n"
        "  `var_system_write    \tanyone can read, but mudlle cannot write\n"
        "  `var_system_mutable  \tanyone may read or write",
	(value goffset),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "n.[sn]")
{
  long idx;
  CHECK_TYPES(goffset, CT_RANGE(idx, 0, nglobals() - 1));

  struct string *mod;
  enum vstatus status = module_vstatus(idx, &mod);
  if (status == var_module)
    {
      assert(TYPE(mod, string));
      return mod;
    }

  return makeint(status);
}

UNSAFEOP(module_vset, "module_vset!",
         "`n0 `s/`n1 -> b. Sets status of global variable `n0 to either the"
         " name `s of the owning module, `var_normal, or `var_write.\n"
         "Returns true if successful.",
         (value goffset, value status),
         OP_LEAF | OP_NOALLOC, "n[ns].n")
{
  long idx;
  CHECK_TYPES(goffset, CT_RANGE(idx, 0, nglobals() - 1),
              status,  CT_TYPES(string, integer));
  struct string *mod = NULL;
  if (!integerp(status))
    {
      mod = status;
      status = makeint(var_module);
    }
  else if (status != makeint(var_normal) && status != makeint(var_write))
    RUNTIME_ERROR(error_bad_value, NULL);
  return makebool(module_vset(idx, intval(status), mod, false));
}

static struct string *mc_mudlle_markup(struct string *s, enum mudlle_markup mm,
                                       const struct prim_op *op)
{
  CHECK_TYPES_OP(op, s, string);
  const char *st = mudlle_markup(mm, true);
  const char *en = mudlle_markup(mm, false);
  size_t stlen = strlen(st);
  size_t enlen = strlen(en);
  if (stlen == 0 && enlen == 0)
    return s;
  GCPRO(s);
  struct string *res = alloc_string_noinit(string_len(s) + stlen + enlen);
  UNGCPRO();
  memcpy(res->str, st, stlen);
  memcpy(res->str + stlen, s->str, string_len(s));
  memcpy(res->str + stlen + string_len(s), en, enlen);
  return res;
}

#define DECL_MARKUP_FN(what)                                            \
TYPEDOP(mc_markup_str_ ## what, "mc:markup_str_" #what,                 \
        "`s0 -> `s1. Returns the appropriate escape code markup around" \
        " `s0 and returns the new string. May return `s0 unmodified.",  \
        (struct string *s), OP_LEAF, "s.s")                             \
{                                                                       \
  return mc_mudlle_markup(s, mudlle_markup_ ## what, THIS_OP);          \
}

FOR_MUDLLE_MARKUP(DECL_MARKUP_FN, SEP_EMPTY)

#undef DECL_MARKUP_FN

static void support_define_consts(void)
{
  /* Mudlle object flags */
  system_define("MUDLLE_READONLY",  makeint(OBJ_READONLY));
  system_define("MUDLLE_IMMUTABLE", makeint(OBJ_IMMUTABLE));

#define ___CDEF(name) system_define("mc:c_" #name, makeint(c_ ## name))
#define __CDEF(name, args)                              \
  IF_NO_ARGS args (                                     \
    (void)0,                                            \
    FOR_ARGS(___CDEF, SEP_SEMI,                         \
             name, EXPAND_ARGS args, name ## _fields))

  FOR_COMPONENT_CLASSES(__CDEF, SEP_SEMI);

  ___CDEF(class);
  ___CDEF(loc);
#undef __CDEF
#undef ___CDEF

#define ___PDEF(name) system_define("mc:pat_" #name, makeint(pat_ ## name))
#define __PDEF(name, args)                                              \
  FOR_ARGS(___PDEF, SEP_SEMI,                                           \
           name, IF_NO_ARGS args(, EXPAND_ARGS args,) name ## _fields)

  FOR_PATTERN_CLASSES(__PDEF, SEP_SEMI);

  ___PDEF(class);
  ___PDEF(loc);
#undef __PDEF
#undef ___PDEF

#define __MDEF(name) system_define("mc:m_" #name, makeint(m_ ## name))
  FOR_PARSER_MODULE_FIELDS(__MDEF, SEP_SEMI);
#undef __MDEF

  system_define("mc:max_local_vars", makeint(MAX_LOCAL_VARS));

#ifdef __x86_64__
  #define ARCHNAME "x64"
  #define ARCH 0x64
#elif defined __aarch64__
  #define ARCHNAME "arm64"
  #define ARCH 0x41
#elif defined __riscv && __riscv_xlen == 64
  #define ARCHNAME "riscv64"
  #define ARCH 0x52
#else
  #error Fix me
#endif

  system_define("mc:typeset_flag_return", makeint(TYPESET_FLAG_RETURN));

  system_define("mc:arch", makeint(ARCH));
  STATIC_STRING(sstr_archname, ARCHNAME);
  system_define("mc:archname", GET_STATIC_STRING(sstr_archname));
  system_define("mc:mcode_version", makeint(MCODE_VERSION));

  system_define("mc:garbage_primitive", makeint(garbage_primitive));

#define DEF_BUILTIN(b, str, lstr) system_define("mc:" #b, makeint(b))
  FOR_BUILTINS(DEF_BUILTIN, SEP_SEMI);
#undef DEF_BUILTIN
  system_define("mc:parser_builtins", makeint(parser_builtins));

#define DEF_CST(c) system_define("mc:cst_" #c, makeint(cst_ ## c))
  FOR_CONST_CLASSES(DEF_CST, SEP_SEMI);
#undef DEF_CST

#define DEF_ARITH(c, str) system_define("mc:arith_" #c, makeint(arith_ ## c))
  FOR_ARITH_MODES(DEF_ARITH, SEP_SEMI);
#undef DEF_ARITH

  system_define("mc:cstbase_char",       makeint(cstbase_char));
  system_define("mc:cstbase_named_char", makeint(cstbase_named_char));

#define PREFIX ARCHNAME ":"

  system_define(PREFIX "mcode_code_offset",
                makeint(offsetof(struct mcode, mcode)));

  value ccofs = NULL;
#ifdef PROFILE_CALL_COUNT
  ccofs = makeint(offsetof(struct code, call_count));
#endif
  system_define(PREFIX "code_call_count_offset", ccofs);

  system_define(PREFIX "object_offset", makeint(sizeof (struct obj)));
  system_define(PREFIX "object_size",   makeint(offsetof(struct obj, size)));
  system_define(PREFIX "object_info",
                makeint(offsetof(struct obj, size)
                        + sizeoffield(struct obj, size)));
  system_define(PREFIX "object_type",
                makeint(offsetof(struct obj, flags) - 1));
  system_define(PREFIX "object_flags",  makeint(offsetof(struct obj, flags)));

#ifndef NOCOMPILER
  system_define(PREFIX "cc_frame_end_sp",
                makeint(offsetof(struct ccontext, frame_end_sp)));
  system_define(PREFIX "cc_frame_end_bp",
                makeint(offsetof(struct ccontext, frame_end_bp)));
  system_define(PREFIX "cc_callee",
                makeint(offsetof(struct ccontext, callee)));
#endif /* ! NOCOMPILER */
}

void support_init(void)
{
  DEFINE(mudlle_parse);
  DEFINE(mudlle_parse_file);
  DEFINE(link);
  DEFINE(dwarf_line_number_info);
  DEFINE(expand_line_number_info);
  DEFINE(register_mcode_module);
  DEFINE(make_closure);
  DEFINE(closurep);
  DEFINE(securep);
  DEFINE(varargsp);
  DEFINE(primitivep);
  DEFINE(any_primitivep);
  DEFINE(primitive_nargs);
  DEFINE(primitive_flags);
  DEFINE(primitive_type);
  DEFINE(function_arguments);
  DEFINE(closure_return_typeset);
  DEFINE(closure_return_itype);
  DEFINE(closure_flags);
  DEFINE(closure_code);
  DEFINE(global_table);
  DEFINE(global_name);
  DEFINE(global_names);
  DEFINE(global_lookup);
  DEFINE(global_value);
  DEFINE(global_set);

#define DEF_MARKUP_FN(what) DEFINE(mc_markup_str_ ## what)
  FOR_MUDLLE_MARKUP(DEF_MARKUP_FN, SEP_SEMI);
#undef DEF_MARKUP_FN

  /* Module support */
  DEFINE(all_modules);
  DEFINE(module_status);
  DEFINE(module_seclevel);
  DEFINE(module_set);
  DEFINE(module_unload);
  DEFINE(module_require);
  DEFINE(module_vstatus);
  DEFINE(module_vset);

  support_define_consts();
}
