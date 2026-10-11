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

#define AFTER_SKIP_FRAMES 16
#define BEFORE_SKIP_FRAMES 32

#include "alloc.h"
#include "builtins.h"
#include "context.h"
#include "dwarf.h"
#include "error.h"
#include "global.h"
#include "print.h"
#include "stack.h"
#include "strbuf.h"
#include "utils.h"

#include "runtime/arith.h"
#include "runtime/basic.h"
#include "runtime/mudlle-string.h"
#include "runtime/runtime.h"
#include "runtime/support.h"


const char *const mudlle_errors[] = {
  "bad function",
  "stack underflow",
  "bad type",
  "divide by zero",
  "bad index",
  "bad value",
  "variable is read-only",
  "loop limit reached",
  "recursion limit reached",
  "wrong number of parameters",
  "security violation",
  "value is read only",
  "user interrupt",
  "pattern not matched",
  "compilation error",
  "abort"
};
CASSERT_VLEN(mudlle_errors, last_runtime_error);

int suppress_extra_calltrace;

struct call_trace_target {
  struct call_trace_target *next;
  struct dynpro dst;            /* oport or character */
  void (*callback)(value dst, void *cbdata);
  void *cbdata;
  bool unhandled_only;
};

static struct call_trace_target *call_trace_targets;

static value get_tos(void);

#define markup_start(pinfo, what) ((void)0)
#define markup_end(pinfo, what)   ((void)0)

static void display_code_location(struct code *code, uint32_t lineno)
{
  GCPRO(code);

  if (!use_nicename
      && !string_equalp(code_nicename(code), code_filename(code)))
    {
      pputs(" [", muderr());
      pswrite(muderr(), code_nicename(code));
      pputc(']', muderr());
    }

  pputs(" at ", muderr());
  pputs(mudlle_markup(mudlle_markup_loc, true), muderr());
  pswrite(muderr(), (use_nicename ? code_nicename : code_filename)(code));
  pprintf(muderr(), ":%" PRIu32, lineno);
  pputs(mudlle_markup(mudlle_markup_loc, false), muderr());

  UNGCPRO();
}

struct print_info {
  int depth;                    /* total stack depth */
  int current;                  /* current depth */
  const struct prim_op *hide_tos; /* suppress if at top of stack */
};

static void output_arg(struct print_info *pinfo, value arg, bool is_predicate)
{
  if (is_predicate && (arg == makebool(false) || arg == makebool(true)))
    {
      markup_start(pinfo, code_const);
      pputs(istrue(arg) ? "true" : "false", muderr());
      markup_end(pinfo, code_const);
      return;
    }

  unsigned flags = fmt_write | fmt_flag_quote;
  if (mudout_wants_ascii())
    flags |= fmt_flag_ascii;
  output_value_cut(muderr(), arg, 80, flags);
}

static uint32_t get_icode_line(struct call_stack_mudlle *frame)
{
  struct icode *code = frame->code;
  uint32_t offset = (frame->offset - 1
                     - ((uint8_t *)(&code->constants[code->nb_constants])
                        - (uint8_t *)code));
  return dwarf_lookup_line_number(&code->code, offset);
}

static void print_arg_name(struct print_info *pinfo, struct vector *argv,
                           int i, bool *is_predicate)
{
  *is_predicate = false;
  assert(i >= 0);

  if (argv == NULL)
    return;

  if ((size_t)i >= vector_len(argv))
    return;

  struct list *e = argv->data[i];
  assert(TYPE(e, pair));

  if (e->cdr == NULL)
    return;                     /* variable-length argument */

  struct string *name = e->car;
  if (TYPE(name, string))
    {
      size_t slen = string_len(name);
      if (slen > 0 && name->str[slen - 1] == '?')
        *is_predicate = true;

      GCPRO(name);
      markup_start(pinfo, code_var);
      UNGCPRO();
      pswrite(muderr(), name);
      markup_end(pinfo, code_var);
      pputc('=', muderr());
    }
}

static struct vector *maybe_get_arguments(struct code *code, int nargs)
{
  struct vector *v = code->arguments;
  int nformalargs = vector_len(v);

  if (nargs == nformalargs)
    return v;

  if (nformalargs == 0)
    return NULL;

  if (nargs > nformalargs)
    {
      struct list *e = v->data[nformalargs - 1];
      assert(TYPE(e, pair));
      return e->cdr == NULL ? v : NULL;
    }

  struct list *e = v->data[nargs];
  assert(TYPE(e, pair));
  if (e->cdr == NULL)
    return v;                   /* variable-length argument */
  assert(integerp(e->cdr));
  typeset_t typeset = intval(e->cdr);
  if (typeset & TYPESET_FLAG_OPTIONAL)
    return v;

  return NULL;
}

static bool should_print(struct print_info *pinfo)
{
  ++pinfo->current;
  if (pinfo->current <= BEFORE_SKIP_FRAMES)
    return true;
  if (pinfo->current + AFTER_SKIP_FRAMES > pinfo->depth)
    return true;
  if (pinfo->current == BEFORE_SKIP_FRAMES + 1)
    {
      int i = pinfo->depth - BEFORE_SKIP_FRAMES - AFTER_SKIP_FRAMES;
      if (i == 1)
        return true;
      pprintf(muderr(), "   *** %d frame%s skipped ***\n", i,
              i == 1 ? "" : "s");
    }
  return false;
}

static void print_fn_name(struct print_info *pinfo, struct string *varname)
{
  if (varname != NULL)
    {
      GCPRO(varname);
      markup_start(pinfo, code_fn);
      UNGCPRO();
      pswrite(muderr(), varname);
      markup_end(pinfo, code_fn);
      return;
    }
  pputc('<', muderr());
  markup_start(pinfo, code_fn);
  pputs("fn", muderr());
  markup_end(pinfo, code_fn);
  pputc('>', muderr());
}

static bool print_bytecode_frame(struct call_stack_mudlle *mframe,
                                 bool onstack, void *cbdata)
{
  struct print_info *pinfo = cbdata;
  if (!should_print(pinfo))
    return false;

  struct icode *fcode = mframe->code;
  struct vector *arguments = NULL;
  GCPRO(fcode, arguments);

  print_fn_name(pinfo, fcode->code.varname);
  pputc('(', muderr());

  int nargs = mframe->nargs;
  int argvnum = -1;

  arguments = maybe_get_arguments(&fcode->code, nargs);
  bool native = mframe->s.type == call_llvm;
  bool is_vararg = !native && !onstack && code_is_vararg(&fcode->code);
  if (is_vararg)
    {
      assert(arguments != NULL);
      argvnum = vector_len(arguments);
      assert(argvnum > 0);
      --argvnum;
    }

  const char *prefix = "";
  for (int i = 0; i < mframe->nargs; i++)
    {
      value v;

      /* Warning: This is somewhat intimate with the implementation of
         the compiler */
      if (native)
        v = mframe->native_args[i];
      else if (onstack)
        v = stack_get(i);
      else
        {
          struct variable *argi = mframe->locals->data[i];
          v = argi->vvalue;

          if (is_vararg && i == argvnum)
            {
              if (!code_vararg_is_allocated(&fcode->code))
                {
                  /* not allocated */
                  pputs(prefix, muderr());
                  prefix = ", ";
                  pputs("...", muderr());
                  break;
                }
              struct vector *argv = v;
              assert(TYPE(argv, vector));
              struct gcpro gcpro1;
              GCPROV(gcpro1, argv);
              for (size_t vi = 0; vi < vector_len(argv); ++vi)
                {
                  pputs(prefix, muderr());
                  prefix = ", ";
                  output_arg(pinfo, argv->data[vi], false);
                }
              UNGCPROV(gcpro1);
              break;
            }
        }

      pputs(prefix, muderr());
      prefix = ", ";

      bool is_predicate;
      print_arg_name(pinfo, arguments, i, &is_predicate);
      output_arg(pinfo, v, is_predicate);
    }

  pputc(')', muderr());

  uint32_t lineno = get_icode_line(mframe);
  display_code_location(&fcode->code, lineno);
  pputc('\n', muderr());

  UNGCPRO();
  return false;
}

static void print_called_value(struct print_info *pinfo, value called)
{
  if (is_any_primitive(called))
    {
      assert(called != NULL);   /* silence clang-tidy warning */
      print_fn_name(pinfo, ((struct primitive *)called)->op->name);
    }
  else if (TYPE(called, closure))
    {
      struct code *code = ((struct closure *)called)->code;
      print_fn_name(pinfo, code->varname);
    }
  else
    output_arg(pinfo, called, false);
}

struct c_info {
  const struct prim_op *op;     /* can be null */
  const char *name;
  struct string *mstring;
  value *called;                /* set for invalid calls */
  int formal_args, actual_args;
  bool is_operator;
  const char *const *arglist;   /* can be null */
  int frame_args; /* args >= frame_args are in argp[frame_args] vector */
  value *argp;
  value (*getarg)(const struct c_info *info, int arg);
  void (*print_arg_name)(const struct c_info *info, struct print_info *pinfo,
                         int i, bool *is_predicate);
  struct call_stack_c_header *frame;
};

static value get_c_stack_arg(const struct c_info *info, int arg)
{
  return stack_get(arg);
}

static value get_c_arg(const struct c_info *info, int arg)
{
  if (arg < info->frame_args)
    return info->argp[arg];
  int varg = arg - info->frame_args;
  assert(varg >= 0);
  struct vector *argv = info->argp[info->frame_args];
  assert(TYPE(argv, vector));
  assert(vector_len(argv) > (size_t)varg);
  return argv->data[varg];
}

static void print_c_arg_name(
  const struct c_info *info, struct print_info *pinfo,
  int i, bool *is_predicate)
{
  *is_predicate = false;
  int nfixed = (info->formal_args >= 0
                ? info->formal_args
                : ~info->formal_args);
  if (i >= nfixed
      || (info->formal_args >= 0
          ? info->actual_args != nfixed
          : info->actual_args < nfixed))
    return;

  const char *suffix;
  size_t namelen;
  const char *name = primop_argname(&namelen, &suffix, info->arglist[i]);
  if (name == NULL)
    return;

  markup_start(pinfo, code_var);
  port_write(muderr(), name, namelen);
  if (suffix != NULL)
    {
      pputs(suffix, muderr());
      if (*suffix == '?')
        *is_predicate = true;
    }
  markup_end(pinfo, code_var);
  pputc('=', muderr());
}

static void print_code_arg_name(
  const struct c_info *info, struct print_info *pinfo,
  int i, bool *is_predicate)
{
  value called = *info->called;
  struct code *code;
  if (TYPE(called, closure))
    code = ((struct closure *)called)->code;
  else if (TYPE(called, icode) || TYPE(called, mcode))
    code = called;
  else
    return;

  struct vector *args = maybe_get_arguments(code, info->actual_args);
  if (args != NULL)
    print_arg_name(pinfo, args, i, is_predicate);
}

static void set_prim_c_info(struct c_info *dst, const struct prim_op *op)
{
  dst->op             = op;
  dst->name           = op->name->str;
  dst->is_operator    = op->flags & OP_OPERATOR;
  dst->formal_args    = op->nargs;
  dst->arglist        = op->arglist;
  if (!dst->is_operator)
    dst->print_arg_name = print_c_arg_name;
}

static void set_called_c_info(struct c_info *dst)
{
  value called = *dst->called;
  if (is_any_primitive(called))
    set_prim_c_info(dst, ((struct primitive *)called)->op);
  else if (TYPE(called, closure) || TYPE(called, icode)
           || TYPE(called, mcode))
    dst->print_arg_name = print_code_arg_name;
}

static void c_frame_info(struct c_info *dst,
                         struct call_stack_c_header *cframe,
                         bool onstack)
{
  bool is_vararg = false;

  const struct prim_op *op;
  switch (cframe->s.type)
    {
    case call_string_argv:
      is_vararg = true;
      FALLTHROUGH;
    case call_string_args:
      *dst = (struct c_info){ .name = cframe->u.name, };
      break;
    case call_mstring:
      *dst = (struct c_info){ .mstring = cframe->u.mstring };
      break;
    case call_c:
      op = cframe->u.prim->op;
      goto is_prim;
    case call_primop:
      op = cframe->u.op;
    is_prim:
      *dst = (struct c_info){ 0 };
      set_prim_c_info(dst, op);
      is_vararg = op->nargs < 0;
      break;
    case call_invalid_argp:
      *dst = (struct c_info){
        .called      = &cframe->u.value,
        .frame_args  = cframe->nargs,
        .actual_args = cframe->nargs,
        .getarg      = get_c_arg,
        .argp        = ((struct call_stack_c_argp *)cframe)->argp,
        .frame       = cframe,
      };
      set_called_c_info(dst);
      return;
    case call_invalid_argv:
      is_vararg = true;
      FALLTHROUGH;
    case call_invalid:
      *dst = (struct c_info){ .called = &cframe->u.value };
      set_called_c_info(dst);
      break;
    case call_bytecode:
    case call_llvm:
    case call_compiled:
    case call_session:
      abort();
    }

  if (is_vararg && !onstack)
    {
      int frame_args = cframe->nargs - 1;
      assert(frame_args >= 0);
      struct call_stack_c *vframe = (struct call_stack_c *)cframe;
      struct vector *argv = vframe->args[frame_args];
      assert(TYPE(argv, vector));
      dst->frame_args  = frame_args;
      dst->actual_args = frame_args + vector_len(argv);
      dst->argp        = vframe->args;
      dst->getarg      = get_c_arg;
    }
  else
    {
      dst->frame_args = dst->actual_args = cframe->nargs;
      if (onstack)
        dst->getarg = get_c_stack_arg;
      else
        {
          dst->getarg = get_c_arg;
          dst->argp   = ((struct call_stack_c *)cframe)->args;
        }
    }

  dst->frame = cframe;
}

static bool print_global_name(struct print_info *pinfo, value midx)
{
  if (!integerp(midx))
    return false;
  long gidx = intval(midx);
  if (gidx <= 0 || gidx >= nglobals())
    return false;
  markup_start(pinfo, code_var);
  pswrite(muderr(), GNAME(gidx));
  markup_end(pinfo, code_var);
  return true;
}

static bool print_c_frame(const struct c_info *info,
                          const struct session_context *next_session,
                          void *cbdata)
{
  struct print_info *pinfo = cbdata;

  if (pinfo->current == 0
      && pinfo->hide_tos != NULL
      && pinfo->hide_tos == info->op)
    {
      /* suppress printing of the top of stack */
      --pinfo->depth;
      pinfo->hide_tos = NULL;
      return false;
    }

  if (!should_print(cbdata))
    return false;

  if (info->actual_args == info->formal_args && info->is_operator)
    {
      bool is_set = false;
      switch (info->actual_args)
        {
        case 1:
          if (info->op == global_read_ext)
            {
              if (!print_global_name(pinfo, info->getarg(info, 0)))
                goto not_op;
              goto done;
            }
          pputs(info->op == negate_prim_ext ? "-" : info->name, muderr());
          output_arg(pinfo, info->getarg(info, 0), false);
          goto done;
        case 3:
          is_set = info->op == setb_prim_ext;
          assert(is_set);
          FALLTHROUGH;
        case 2: ;
          bool is_gset = info->op == global_write_ext;
          bool is_ref = info->op == ref_prim_ext;
          if (!is_gset)
            output_arg(pinfo, info->getarg(info, 0), false);
          else if (!print_global_name(pinfo, info->getarg(info, 0)))
            goto not_op;
          if (!is_gset)
            {
              if (is_ref || is_set)
                pputc('[', muderr());
              else
                pprintf(muderr(), " %s ", info->name);
              output_arg(pinfo, info->getarg(info, 1), false);
              if (is_ref || is_set)
                pputc(']', muderr());
            }
          if (is_set || is_gset)
            {
              pputs(" = ", muderr());
              output_arg(pinfo, info->getarg(info, is_set ? 2 : 1), false);
            }
          goto done;
        default:
          abort();
        }
    }

 not_op: ;
  bool show_loc = false;
  if (info->called)
    {
      print_called_value(pinfo, *info->called);
      if (TYPE(*info->called, closure))
        show_loc = true;
    }
  else if (info->name != NULL)
    {
      markup_start(pinfo, code_fn);
      pputs(info->name, muderr());
      markup_end(pinfo, code_fn);
    }
  else
    {
      assert(info->mstring != NULL);
      pswrite(muderr(), info->mstring);
      goto done;
    }

  pputc('(', muderr());
  if (info->actual_args >= 0)
    {
      unsigned actual_args = info->actual_args;
      for (unsigned i = 0; i < actual_args; ++i)
        {
          if (i > 0)
            pputs(", ", muderr());
          bool is_predicate = false;
          if (info->print_arg_name)
            info->print_arg_name(info, pinfo, i, &is_predicate);
          output_arg(pinfo, info->getarg(info, i), is_predicate);
        }
    }
  else
    pputs("<compiled>", muderr());
  pputc(')', muderr());
  if (show_loc)
    {
      struct closure *c = *info->called;
      assert(TYPE(c, closure));
      display_code_location(c->code, c->code->lineno);
    }

 done:
  pputc('\n', muderr());
  return false;
}

#ifndef NOCOMPILER
static void print_args(struct print_info *pinfo, value *args, int nargs,
                       struct vector *arguments)
{
  bool vararg = nargs < 0;
  if (vararg)
    {
      if (args == NULL)
        {
          pputs("(...)", muderr());
          return;
        }
      nargs = vector_len((struct vector *)*args);
    }

  GCPRO(arguments);
  pputc('(', muderr());
  const char *prefix = "";
  for (int n = 0; n < nargs; ++n)
    {
      pputs(prefix, muderr());
      bool is_predicate;
      print_arg_name(pinfo, arguments, n, &is_predicate);
      value arg = vararg ? ((struct vector *)*args)->data[n] : args[n];
      output_arg(pinfo, arg, is_predicate);
      prefix = ", ";
    }
  UNGCPRO();

  pputc(')', muderr());
}

/* nargs < 0 means *args points to a gc-protected argument vector */
static bool print_mcode(struct mcode *mcode, ulong ofs, value *args, int nargs,
                        void *cbdata)
{
  struct print_info *pinfo = cbdata;
  if (!should_print(pinfo))
    return false;

  /* address is the return address (or pc + 1 for segv) */
  if (ofs > 0)
    --ofs;
  uint32_t line = dwarf_lookup_line_number(&mcode->code, ofs);

  GCPRO(mcode);
  print_fn_name(pinfo, mcode->code.varname);

  size_t actual_nargs = (nargs < 0
                         ? vector_len((struct vector *)*args)
                         : (size_t)nargs);
  struct vector *arguments = maybe_get_arguments(&mcode->code, actual_nargs);
  print_args(pinfo, args, nargs, arguments);

  pputs(" [c]", muderr());
  display_code_location(&mcode->code, line);
  pputc('\n', muderr());
  UNGCPRO();
  return false;
}
#endif /* !NOCOMPILER */

typedef bool (*mcode_frame_fn)(struct mcode *mcode, ulong ofs, value *args,
                               int nargs, void *cbdata);

typedef bool (*bytecode_frame_fn)(struct call_stack_mudlle *frame,
                                  bool onstack, void *cbdata);

typedef bool (*c_frame_fn)(const struct c_info *info,
                           const struct session_context *next_session,
                           void *cbdata);

#if defined __x86_64__ && !defined(NOCOMPILER)

enum cpu_reg {
  x64_reg_rax = 0,
  x64_reg_rbx = 3,
  x64_reg_rcx = 1,
  x64_reg_rdx = 2,
  x64_reg_rsp = 4,
  x64_reg_rbp = 5,
  x64_reg_rsi = 6,
  x64_reg_rdi = 7,
  x64_reg_r8  = 8,
  x64_reg_r9  = 9,
  x64_reg_r10 = 10,
  x64_reg_r11 = 11,
  x64_reg_r12 = 12,
  x64_reg_r13 = 13,
  x64_reg_r14 = 14,
  x64_reg_r15 = 15,
  reg_argcount = x64_reg_rax,
  reg_arg0 = x64_reg_rdi,
  reg_arg1 = x64_reg_rsi,
  reg_arg2 = x64_reg_rdx,
  reg_closure_in = x64_reg_r10
};

/* finds mov $imm64,%reg or mov ofs(%rip),%reg preceding 'op'*/
static bool get_imm64_mov(const uint8_t *op, enum cpu_reg reg, int64_t *v)
{
  /* check for mov ofs(%rip),%reg */
  uint8_t rex_r = 0x48 | ((reg >> 1) & 4);
  if (op[-7] == rex_r && op[-6] == 0x8b && op[-5] == (0x05 | ((reg & 7) << 3)))
    {
      int32_t rip_ofs;
      memcpy(&rip_ofs, op - 4, sizeof rip_ofs);
      memcpy(v, op + rip_ofs, sizeof *v);
      return true;
    }

  /* check for mov $imm64,%reg */
  uint8_t rex_b = 0x48 | ((reg >> 3) & 1);
  if (op[-10] == rex_b && op[-9] == (0xb8 | (reg & 7)))
    {
      memcpy(v, op - 8, sizeof *v);
      return true;
    }

  abort();
}

static bool get_imm32_mov(const uint8_t *op, enum cpu_reg reg, int32_t *v)
{
  assert(reg <= 7); /* not supported (yet) */

  if (op[0] != (0xb8 | reg))
    {
      abort();
    }
  memcpy(v, op + 1, sizeof *v);
  return true;
}

enum {
  REX_RB = 0x45
};

/* bytes used for mov $imm,%reg or xor %reg,%reg */
static int mov_or_xor_before(const uint8_t *op, enum cpu_reg reg)
{
  bool rex = reg > 7;
  reg &= 7;
  uint16_t u16;
  memcpy(&u16, op - 2, sizeof u16);
  bool is_xor = u16 == (0xc031 | (reg << 8) | (reg << 11));
  if (is_xor && rex && op[-3] != REX_RB)
    is_xor = false;
  int bytes = (is_xor ? 2 : 5) + rex;
  return bytes;
}

static bool get_imm32_mov_or_xor_before(const uint8_t *op, enum cpu_reg reg,
                                        int *bytes, int32_t *v)
{
  *bytes = mov_or_xor_before(op, reg);
  switch (*bytes)
    {
    case 2: case 3:             /* xor %reg,%reg */
      *v = 0;
      return true;
    case 6:                     /* rex.RB mov $imm,%reg */
      if (op[-6] != REX_RB)
        {
          abort();
        }
      FALLTHROUGH;
    case 5:                     /* mov $imm,%reg */
      return get_imm32_mov(op - 5, reg, v);
    }
  abort();
}

static bool handle_primitive_frame(
  ulong pcadr,
  const struct prim_op *last_primop,
  const struct session_context *next_session,
  c_frame_fn c_frame, void *cbdata,
  ulong *last_sp)
{
  value *cargs = NULL;
  int cnargs = -1;
  const uint8_t *op;
  ulong primadr;

#ifdef __x86_64__
  /* check for %rip-relative call to primitive */
  op = (const uint8_t *)(pcadr - 6);
  if (op[0] != 0xff || op[1] != 0x15)
    return false;
  int32_t ofs;
  memcpy(&ofs, op + 2, sizeof ofs);
  memcpy(&primadr, (uint8_t *)pcadr + ofs, sizeof primadr);
#else
  #error Unsupported architecture
#endif

  const struct prim_op *prim = NULL;
  if (primadr == (ulong)bcall_secure)
    {
#ifdef __x86_64__
      const int seclev_bytes = 6; /* rex mov imm32 */

      /* mov $prim,closure_in
       * mov $nargs,argcount  or  xor argcount,argcount
       * mov $seclev,%r11
       * call bcall_secure */

      int argc_bytes = mov_or_xor_before(op - seclev_bytes, reg_argcount);

      int64_t i;
      if (!get_imm64_mov(op - seclev_bytes - argc_bytes,
                         reg_closure_in, &i))
        return false;
#else
  #error Unsupported architecture
#endif
      prim = ((struct primitive *)i)->op;
    }
#ifdef __x86_64__
  else if (primadr == (ulong)bcall_prim
           || primadr == (ulong)bcall_prim_noalloc)
    {
      /* mov callee,closure_in
       * call bcall_prim{,_noalloc} */
      int64_t i;
      if (!get_imm64_mov(op, reg_closure_in, &i))
        return false;
      primadr = i;
    }
#endif  /* __x86_64__ */
  else if (primadr == (ulong)bcall)
    {
      /* push args...
       * mov callee,closure_in
       * mov $nargs,argcount   or   xor argcount,argcount
       * call bcall */

      if (last_sp[-3] == (ulong)bcall_primitive_tail)
        {
          /* last_sp: [..0] mudlle args, [-1] mudlle pc, [-2] bp,
             [-3] bcall_primitive_tail, [-4] callee,
             [-5] argcount */
          primadr = last_sp[-4];
          cnargs = last_sp[-5];
          cargs = (value *)last_sp;
        }
    }
  else if (primadr == (ulong)bapply_varargs)
    {
#ifdef __x86_64__
      /* push argvector
         mov callee,arg0
         mov seclev,arg2d
         call bapply_varargs */
      const int seclev_bytes = 5; /* mov imm32 */
      int64_t i64;
      if (!get_imm64_mov(op - seclev_bytes, reg_arg0, &i64))
        return false;
      primadr = (ulong)((const struct prim_op *)i64)->op;
#else
  #error Unsupported architecture
#endif
      cnargs = -1;
      cargs = (value *)last_sp;
    }
  else if (primadr == (ulong)bcall_varargs)
    {
#ifdef __x86_64__
      /* push args
       * mov prim_op,arg0
       * mov $argcount,arg1  or  xor arg1,arg1
       * mov $seclev,arg2d
       * call bapply_varargs */
      const enum cpu_reg argreg = reg_arg1;
      const enum cpu_reg calleereg = reg_arg0;
      const int seclev_bytes = 5; /* mov imm32 */
#else
  #error Unsupported architecture
#endif

      /* note that argcount is > 1; argcount = 0 ends up as
         bapply_varargs */

      /* last_sp: [..0] args, [-1] mudlle pc, [-2] bp */

      cargs = (value *)last_sp;

      int argc_bytes;
      int32_t i;
      if (!get_imm32_mov_or_xor_before(op - seclev_bytes, argreg, &argc_bytes,
                                       &i))
        return false;
      cnargs = i;

#ifdef __x86_64__
      int64_t i64;
      if (!get_imm64_mov(op - seclev_bytes - argc_bytes, calleereg, &i64))
        return false;
      primadr = (ulong)((const struct prim_op *)i64)->op;
#else
  #error Unsupported architecture
#endif
    }

  if (prim == NULL)
    prim = lookup_primitive(primadr);

  if (prim && prim != last_primop)
    {
      struct c_info info = {
        .op          = prim,
        .name        = prim->name->str,
        .formal_args = prim->nargs,
        .actual_args = cnargs,
        .is_operator = prim->flags & OP_OPERATOR,
        .arglist     = prim->arglist,
        .frame_args  = cnargs,
        .argp        = cargs,
        .getarg      = cargs ? get_c_arg : NULL
      };
      return c_frame(&info, next_session, cbdata);
    }

  return false;
}

static bool mcode_has_nargs(const struct mcode *mcode)
{
  struct vector *arguments = mcode->code.arguments;
  size_t alen = vector_len(arguments);
  if (alen == 0)
    return false;
  struct list *arg = arguments->data[alen - 1];
  assert(TYPE(arg, pair));
  if (arg->cdr == NULL)
    return true;                /* vararg argument */
  assert(integerp(arg->cdr));
  return intval(arg->cdr) & TYPESET_FLAG_OPTIONAL;
}

static bool handle_mcode_frame(
  ulong pcadr,
  mcode_frame_fn mcode_func,
  c_frame_fn c_frame,
  const struct prim_op *last_primop,
  const struct session_context *next_session,
  ulong *last_sp, ulong *bp,
  int nargs,
  void *cbdata)
{
  struct mcode *mcode = find_pc_mcode(pcadr, (ulong)gcblock,
                                      (ulong)gcblock + gcblocksize);
  if (mcode == NULL)
    return false;

  if (c_frame)
    {
      GCPRO(mcode);
      bool found = handle_primitive_frame(pcadr, last_primop, next_session,
                                          c_frame, cbdata, last_sp);
      UNGCPRO();
      if (found)
        return true;
    }

  /* args..., pc, *bp  */
  value *args = (value *)bp + 2;
  if (nargs >= 0)
    ;
  else if (mcode_has_nargs(mcode))
    {
      value mnargs = (value *)bp[-1];
      assert(integerp(mnargs));
      nargs = intval(mnargs);
    }
  else
    nargs = vector_len(mcode->code.arguments);

  return mcode_func(mcode, pcadr - (ulong)&mcode->mcode[0], args, nargs,
                    cbdata);
}

static bool iterate_cc_frame(
  struct ccontext **cc,
  mcode_frame_fn mcode_func,
  c_frame_fn c_frame,
  const struct prim_op *last_primop,
  const struct session_context *next_session,
  int nargs,
  void *cbdata)
{
  assert((*cc)->frame_start);

  ulong *sp, *bp;
  ccontext_frame(*cc, &bp, &sp);

  /* The return address is at sp[-1] */
  if (handle_mcode_frame(sp[-1], mcode_func, c_frame, last_primop,
                         next_session, sp, bp, nargs, cbdata))
    return true;

  while (bp < (*cc)->frame_start)
    {
      /* bp[<=-1] are locals
       * bp[-1] is the vararg vector (if applicable)
       * bp[0] is previous bp
       * bp[1] is return address
       * bp[>=2] are arguments
       * sp[0] -> bp[-2] is mudlle values
       */
      /* Not using closure because plan on removing it in some cases */
      if (handle_mcode_frame(bp[1], mcode_func, NULL, NULL, NULL, NULL,
                             (ulong *)bp[0], -1, cbdata))
        return true;
      assert(bp[0] > (ulong)bp);
      bp = (ulong *)bp[0];
    }

  assert(bp == (*cc)->frame_start);

  *cc = next_ccontext(*cc);
  return false;
}
#endif /* __x86_64__ && !NOCOMPILER */

static void iterate_call_trace(enum runtime_error error, bool onstack,
                               int c_onstack_nargs,
                               c_frame_fn c_frame,
                               bytecode_frame_fn bytecode_frame,
                               mcode_frame_fn mcode_frame,
                               void *cbdata)
{
  struct session_context *session = session_context, *next_session = NULL;
  struct catch_context *catch_ctxt = catch_context;
#ifndef NOCOMPILER
  struct ccontext *cc = &ccontext;
#endif

  const struct prim_op *last_primop = NULL;

  for (struct call_stack *scan = call_stack; scan; scan = scan->next)
    {
      /* not sure if 'while' is necessary here... */
      while (catch_ctxt && scan == catch_ctxt->old_call_stack)
        {
          if (catch_ctxt->call_trace_mode == call_trace_barrier)
            return;
          catch_ctxt = catch_ctxt->parent;
        }

      const struct prim_op *this_primop = NULL;
      switch (scan->type)
        {
        case call_primop:
          this_primop = ((struct call_stack_c_header *)scan)->u.op;
          FALLTHROUGH;
        case call_string_args:
        case call_string_argv:
        case call_mstring:
        case call_c:
        case call_invalid:
        case call_invalid_argp:
        case call_invalid_argv:
          {
            struct call_stack_c_header *cframe
              = (struct call_stack_c_header *)scan;
            struct c_info info;
            c_frame_info(&info, cframe, onstack);
            if (last_primop != NULL && info.op == last_primop)
              break;

            this_primop = info.op;

            if (c_frame(&info, next_session, cbdata))
              return;
            break;
          }
        case call_bytecode:
        case call_llvm:
          if (bytecode_frame((struct call_stack_mudlle *)scan, onstack,
                             cbdata))
            return;
          break;
        case call_compiled:
#ifdef NOCOMPILER
          (void)c_onstack_nargs;
          abort();
#else
          if (iterate_cc_frame(&cc, mcode_frame, c_frame, last_primop,
                               next_session, c_onstack_nargs, cbdata))
            return;
          break;
#endif
        case call_session:
          next_session = session;
          session = ((struct session_context *)scan)->parent;
          break;
        }
      last_primop = this_primop;
      /* Only the first frame can be on the stack */
      onstack = false;
      c_onstack_nargs = -1;
    }
}

struct stack_depth {
  size_t maxdepth;
  size_t depth;
};

static bool count_mcode_frame(struct mcode *mcode, ulong ofs, value *args,
                              int nargs, void *cbdata)
{
  struct stack_depth *depth = cbdata;
  return ++depth->depth >= depth->maxdepth;
}

static bool count_c_frame(const struct c_info *cinfo,
                          const struct session_context *next_session,
                          void *cbdata)
{
  struct stack_depth *depth = cbdata;
  return ++depth->depth >= depth->maxdepth;
}

static bool count_bytecode_frame(struct call_stack_mudlle *mframe,
                                 bool onstack, void *cbdata)
{
  struct stack_depth *depth = cbdata;
  return ++depth->depth >= depth->maxdepth;
}

static int count_stack_depth(enum runtime_error error, bool onstack,
                             int c_onstack_nargs, size_t maxdepth)
{
  struct stack_depth depth = { .maxdepth = maxdepth };
  iterate_call_trace(error, onstack, c_onstack_nargs, count_c_frame,
                     count_bytecode_frame, count_mcode_frame, &depth);
  return depth.depth;
}

struct basic_error_info {
  enum runtime_error error;
  const struct prim_op *hide_tos;
  const char *msg;
  int c_onstack_nargs;
  bool onstack;
};

static void print_call_trace(struct basic_error_info *info)
{
  mcode_frame_fn mcode = NULL;
#ifndef NOCOMPILER
  mcode = print_mcode;
#endif

  struct print_info pinfo = {
    .depth      = count_stack_depth(info->error, info->onstack,
                                    info->c_onstack_nargs, SIZE_MAX),
    .hide_tos   = info->hide_tos,
  };

  pputs("Call trace is:\n", muderr());
  iterate_call_trace(info->error, info->onstack, info->c_onstack_nargs,
                     print_c_frame, print_bytecode_frame, mcode, &pinfo);
}

struct get_cc_stack_trace_data {
  struct vector *vec;
  size_t maxdepth;
  size_t idx;
  bool lines;
};

static bool get_stack_mcode(struct mcode *mcode, ulong ofs, value *args,
                            int nargs, void *data)
{
  struct get_cc_stack_trace_data *sdata = data;
  value v = mcode;
  if (sdata->lines)
    {
      /* address is the return address (or pc + 1 for segv) */
      if (ofs > 0)
        --ofs;
      v = alloc_list(v, makeint(dwarf_lookup_line_number(&mcode->code, ofs)));
    }
  sdata->vec->data[sdata->idx++] = v;
  return sdata->idx >= sdata->maxdepth;
}

static bool get_stack_c(const struct c_info *cinfo,
                        const struct session_context *next_session,
                        void *cbdata)
{
  struct get_cc_stack_trace_data *sdata = cbdata;
  value v = NULL;
  if (cinfo->op)
    {
      ulong n = mglobal_lookup(cinfo->op->name);
      v = GVAR(n);
      assert(is_any_primitive(v));
    }
  else if (cinfo->mstring)
    v = cinfo->mstring;
  else if (cinfo->name)
    v = alloc_string(cinfo->name);
  else
    {
      abort();
    }

  if (sdata->lines)
    v = alloc_list(v, NULL);    /* never any line numbers */
  sdata->vec->data[sdata->idx++] = v;
  return sdata->idx >= sdata->maxdepth;
}

static bool get_stack_bytecode(struct call_stack_mudlle *mframe, bool onstack,
                               void *cbdata)
{
  struct get_cc_stack_trace_data *sdata = cbdata;

  value v = mframe->fn;
  if (sdata->lines)
    v = alloc_list(v, makeint(get_icode_line(mframe)));
  sdata->vec->data[sdata->idx++] = v;
  return sdata->idx >= sdata->maxdepth;
}

struct vector *get_mudlle_call_trace(size_t maxdepth, bool lines)
{
  int depth = count_stack_depth(error_none, false, -1, maxdepth);
  struct get_cc_stack_trace_data sdata = {
    .vec      = alloc_vector(depth),
    .idx      = 0,
    .lines    = lines,
    .maxdepth = depth
  };
  GCPRO(sdata.vec);

  iterate_call_trace(error_none, false, -1, get_stack_c, get_stack_bytecode,
                     get_stack_mcode, &sdata);
  assert(sdata.idx == vector_len(sdata.vec));
  UNGCPRO();

  return sdata.vec;
}

static void add_trace_entry(struct c_call_trace *trace,
                            struct c_call_trace_entry *e)
{
  for (size_t d = 1; d < 4; ++d)
    {
      /* detect recursions with stride 'd' */
      if (trace->used < d * 2 - 1)
        break;

      if (!c_call_trace_entries_equal(&trace->data[trace->used - d], e))
        continue;

      for (size_t i = 1; i < d; ++i)
        if (!c_call_trace_entries_equal(&trace->data[trace->used - i],
                                        &trace->data[trace->used - d - i]))
          goto next;

      trace->used -= d;
      return;
    next: ;
    }

  if (trace->used >= trace->size)
    {
      trace->size = trace->size ? 2 * trace->size : 32;
      trace->data = realloc(trace->data, trace->size * sizeof trace->data[0]);
    }
  trace->data[trace->used++] = *e;
}

struct get_mc_stack_trace_data {
  struct c_call_trace *dst;
  struct call_stack_c_header *limit;
};

static bool get_mc_stack_mcode(struct mcode *mcode, ulong ofs, value *args,
                               int nargs, void *data)
{
  struct get_mc_stack_trace_data *sdata = data;
  value v = mcode;
  add_trace_entry(sdata->dst, &(struct c_call_trace_entry){
      .class    = ct_mudlle,
      .u.mudlle = v
    });
  return false;
}

static bool get_mc_stack_c(const struct c_info *cinfo,
                           const struct session_context *next_session,
                           void *cbdata)
{
  struct get_mc_stack_trace_data *sdata = cbdata;
  if (sdata->limit != NULL && cinfo->frame == sdata->limit)
    return true;

  struct c_call_trace_entry entry;
  if (cinfo->op != NULL)
    entry = (struct c_call_trace_entry){
      .class    = ct_prim,
      .u.primop = cinfo->op
    };
  else if (cinfo->name != NULL)
    entry = (struct c_call_trace_entry){
      .class    = ct_string,
      .u.string = cinfo->name
    };
  else if (cinfo->mstring != NULL)
    entry = (struct c_call_trace_entry){
      .class    = ct_mudlle,
      .u.mudlle = cinfo->mstring
    };
  else
    return false;

  add_trace_entry(sdata->dst, &entry);
  return false;
}

static bool get_mc_stack_bytecode(struct call_stack_mudlle *mframe,
                                  bool onstack, void *cbdata)
{
  struct get_mc_stack_trace_data *sdata = cbdata;

  value v = mframe->fn;
  if (TYPE(v, closure))
    v = ((struct closure *)v)->code;
  add_trace_entry(sdata->dst, &(struct c_call_trace_entry){
      .class = ct_mudlle, .u.mudlle = v });
  return false;
}

void get_c_call_trace(struct c_call_trace *dst,
                      struct call_stack_c_header *limit)
{
  struct get_mc_stack_trace_data sdata = {
    .dst   = dst,
    .limit = limit,
  };
  iterate_call_trace(error_none, false, -1, get_mc_stack_c,
                     get_mc_stack_bytecode, get_mc_stack_mcode, &sdata);
}

static void free_call_trace_target(struct call_trace_target **targetp)
{
  struct call_trace_target *target = *targetp;
  *targetp = target->next;

  undynpro(&target->dst);
  free(target);
}


static void basic_error_print(value e, void *data)
{
  struct basic_error_info *info = data;
  value omuderr = muderr();
  GCPRO(omuderr);

  pputs(info->error == error_none ? "warning" : mudlle_errors[info->error],
        muderr());

  if (info->msg)
    {
      if (info->msg[0] != ' ')
        pputs(": ", muderr());
      pputs(info->msg, muderr());
    }
  pputc('\n', muderr());

  print_call_trace(info);


  session_context->ports.err = omuderr;
  UNGCPRO();
}

static void basic_error(
  enum runtime_error error, const struct prim_op *hide_tos,
  bool onstack, int c_onstack_nargs, const char *msg)
{
  if (catch_context != NULL
      && catch_context->call_trace_mode == call_trace_off)
    return;

  struct basic_error_info info = {
    .error           = error,
    .onstack         = onstack,
    .c_onstack_nargs = c_onstack_nargs,
    .msg             = msg,
    .hide_tos        = hide_tos,
  };

  if (muderr())
    {
      pflush(mudout());
      basic_error_print(muderr(), &info);
      if (suppress_extra_calltrace)
        return;
    }

  struct call_trace_target **targets = &call_trace_targets;
  if (*targets == NULL)
    return;

  struct oport *omuderr = muderr();

  GCPRO(omuderr);

  for (;;)
    {
      struct call_trace_target *target = *targets;
      if (target == NULL)
        break;
      value dst = target->dst.obj;
      if (TYPE(dst, oport))
        {
          session_context->ports.err = dst;
        }
      else
        {
          free_call_trace_target(targets);
          continue;
        }

      targets = &(*targets)->next;


      /* ignore elem if elem has already seen the call trace */
      if (muderr() == omuderr)
        continue;

      if (target->unhandled_only && omuderr)
        continue;

      basic_error_print(dst, &info);
      pflush(muderr());
      if (target->callback)
        target->callback(target->dst.obj, target->cbdata);
    }

  session_context->ports.err = omuderr;
  UNGCPRO();
}

void runtime_warning(const char *msg, const struct prim_op *hide_tos)
{
  check_interrupt();
  basic_error(error_none, hide_tos, false, -1, msg);
}

void runtime_error(enum runtime_error error)
{
  runtime_error_message_hide_tos(error, NULL, NULL);
}

void runtime_error_message(enum runtime_error error, const char *msg)
{
  runtime_error_message_hide_tos(error, msg, NULL);
}

void runtime_error_message_hide_tos(enum runtime_error error, const char *msg,
                                    const struct prim_op *hide_tos)
/* Effects: Runtime error 'error' has occured. Dump the call_stack to
     mudout & throw back to the exception handler with SIGNAL_ERROR
     and the error code in exception_error.
   Note: Never returns
*/
{
  check_interrupt();
  basic_error(error, hide_tos, false, -1, msg);
  mthrow(SIGNAL_ERROR, error);
}

static bool get_mcode(struct mcode *mcode, ulong ofs, value *args,
                      int nargs, void *cbdata)
{
  struct mcode **dst = cbdata;
  assert(*dst == NULL);
  *dst = mcode;
  return true;
}

void compiled_early_runtime_error(enum runtime_error error, int nargs)
{
  const char *msg = NULL;

  if (error == error_wrong_parameters && nargs >= 0)
    {
      struct mcode *mcode = NULL;
      iterate_call_trace(error_none, true, nargs, NULL, NULL, get_mcode,
                         &mcode);
      assert(TYPE(mcode, mcode));
      struct vector *v = mcode->code.arguments;
      unsigned minargs = vector_len(v);
      unsigned maxargs = vector_len(v);
      for (; minargs > 0; --minargs)
        {
          struct list *e = v->data[minargs - 1];
          assert(TYPE(e, pair));
          if (e->cdr == NULL)
            {
              maxargs = UINT_MAX;
              continue;
            }
          assert(integerp(e->cdr));
          typeset_t typeset = intval(e->cdr);
          if (typeset & TYPESET_FLAG_OPTIONAL)
            continue;
          break;
        }

      msg = bad_nargs_message(nargs, minargs, maxargs);
    }

  basic_error(error, NULL, true, nargs, msg);
  mthrow(SIGNAL_ERROR, error);
}

void interpreted_early_runtime_error(enum runtime_error error, const char *msg)
/* Effects: Runtime error 'error' has occured in a primitive operation.
     Dump the call_stack (plus the primitive operation call) to
     mudout & throw back to the exception handler with SIGNAL_ERROR
     and the error code in exception_error.
     Call this function instead of runtime_error if the arguments of the
     function at the top of call_stack are still on the stack.
   Note: Never returns
*/
{
  basic_error(error, NULL, true, -1, msg);
  mthrow(SIGNAL_ERROR, error);
}

static void internal_primitive_runtime_error(enum runtime_error error,
                                             const char *msg,
                                             const struct prim_op *op,
                                             int nargs, va_list va)
{
  assert(nargs <= MAX_C_ARGS && nargs >= -MAX_VARARG_FIXED);
  unsigned nfixed = nargs < 0 ? varop_nfixed(op) : (unsigned)nargs;

  struct call_stack *ostack = call_stack;

  /* prevent duplicate entries */
  if (call_stack && call_stack->type == call_c
      && ((struct call_stack_c_header *)call_stack)->u.prim->op == op)
    goto done;

  struct {
    struct call_stack_c_header c;
    value args[MAX_C_ARGS];
  } me;
  me.c = (struct call_stack_c_header){
    .s = {
      .next = call_stack,
      .type = call_primop,
    },
    .u.op  = op,
    .nargs = nfixed + (nargs < 0)
  };

  for (unsigned i = 0; i < nfixed; ++i)
    me.args[i] = va_arg(va, value);
  if (nargs < 0)
    {
      struct vector *v = va_arg(va, struct vector *);
      assert(TYPE(v, vector));
      me.args[nfixed] = v;
    }

  call_stack = &me.c.s;

 done:
  if (error != error_none)
    runtime_error_message(error, msg);

  runtime_warning(msg, NULL);
  call_stack = ostack;
}

void primitive_runtime_error(enum runtime_error error,
                             const struct prim_op *op,
                             int nargs, ...)
{
  assert(error != error_none);
  va_list va;
  va_start(va, nargs);
  internal_primitive_runtime_error(error, NULL, op, nargs, va);
  /* not reached */
  abort();
}

static void add_c_argname(struct strbuf *sb, const struct prim_op *op,
                          unsigned argnum)
{
  if (op->flags & OP_OPERATOR)
    return;

  unsigned nfixed = op->nargs < 0 ? varop_nfixed(op) : (unsigned)op->nargs;
  if (op->arglist && argnum < nfixed)
    {
      const char *suffix;
      size_t namelen;
      const char *name = primop_argname(
        &namelen, &suffix, op->arglist[argnum]);
      if (name != NULL)
        {
          sb_addstr(sb, " in '");
          sb_addmem(sb, name, namelen);
          if (suffix)
            sb_addstr(sb, suffix);
          sb_addc(sb, '\'');
          return;
        }
    }

  sb_printf(sb, " in argument %d", argnum + 1);
}

static void add_mudlle_argname(struct strbuf *sb, value fn, unsigned argnum)
{
  struct code *code;
  if (TYPE(fn, closure))
    code = ((struct closure *)fn)->code;
  else
    {
      assert(TYPE(fn, icode) || TYPE(fn, mcode));
      code = fn;
    }
  struct vector *arguments = code->arguments;
  assert(argnum < vector_len(arguments));
  struct list *e = arguments->data[argnum];
  assert(TYPE(e, pair));
  struct string *name = e->car;
  if (e->cdr != NULL && TYPE(name, string))
    {
      sb_addstr(sb, " in '");
      sb_addstr(sb, name->str);
      sb_addc(sb, '\'');
    }
  else
    sb_printf(sb, " in argument %d", argnum + 1);
}

static struct strbuf sb_error_message = SBNULL;

void primitive_runtime_error_msg(enum runtime_error error,
                                 const char *msg,
                                 const struct prim_op *op,
                                 int argnum, int nargs, ...)
{
  assert(error != error_none);
  va_list va;
  va_start(va, nargs);
  if (argnum >= 0)
    {
      if (msg != sb_str(&sb_error_message))
        {
          sb_empty(&sb_error_message);
          if (msg != NULL)
            sb_addstr(&sb_error_message, msg);
        }
      add_c_argname(&sb_error_message, op, argnum);
      msg = sb_str(&sb_error_message);
    }

  internal_primitive_runtime_error(error, msg, op, nargs, va);
  /* not reached */
  abort();
}

void primitive_runtime_warning(const char *msg,
                               const struct prim_op *op,
                               int nargs, ...)
{
  va_list va;
  va_start(va, nargs);
  internal_primitive_runtime_error(error_none, msg, op, nargs, va);
  va_end(va);
}

const char *bad_type_message(value v, enum mudlle_type expected)
{
  return bad_typeset_message(v, type_typeset(expected));
}

void bad_call_error_1plus(enum runtime_error error, const char *errmsg,
                          value callee, value arg, struct vector *argv)
{
  struct {
    struct call_stack_c_header c;
    value args[2];
  } me = {
    .c = {
      .s = {
        .next = call_stack,
        .type = call_invalid_argv
      },
      .u.value = callee,
      .nargs = 2,
    },
    .args = { arg, argv }
  };
  call_stack = &me.c.s;
  runtime_error_message(error, errmsg);
}

void bad_call_error(enum runtime_error error, value callee,
                    int nargs, value *argp)
{
  struct call_stack_c_argp cs = {
    .c = {
      .s = {
        .next = call_stack,
        .type = call_invalid_argp
      },
      .u.value = callee,
      .nargs   = nargs
    },
    .argp = argp
  };
  call_stack = &cs.c.s;
  runtime_error(error);
}

void bad_type_error(value v, enum mudlle_type expected, int argnum)
{
  bad_type_message(v, expected);
  if (argnum >= 0)
    {
      value tos = get_tos();
      if (tos != NULL)
        add_mudlle_argname(&sb_error_message, tos, argnum);
    }
  runtime_error_message(error_bad_type, sb_str(&sb_error_message));
}

static void sb_add_one_type(struct strbuf *sb, enum mudlle_type t,
                            bool *first, unsigned left,
                            bool use_markup)
{
  if (*first)
    *first = false;
  else
    sb_addstr(sb, left == 0 ? " or " : ", ");
  sb_addstr(sb, mudlle_type_names[t]);
}

static void sb_add_typeset(struct strbuf *sb, typeset_t typeset,
                           bool use_markup)
{
  /* keep in sync with mc:itypeset_string() in inference.mud */
  static const enum mudlle_type order[] = {
    stype_none,
    stype_any,
    type_null,                 /* will not print if stype_list */
    type_integer,              /* will not print if stype_{bigint,float}like */
    stype_false,
    stype_list,
    type_string,
    type_vector,
    stype_function,
    stype_float_like,
    stype_bigint_like
  };
  CASSERT(mudlle_synthetic_types == 34);

  bool first = true;
  /* first loop through 'order' types; then through all the regular types */
  for (size_t i = 0; ; ++i)
    {
      assert(i < VLENGTH(order) + mudlle_types);
      enum mudlle_type t = i < VLENGTH(order) ? order[i] : i - VLENGTH(order);
      if (t == type_null && (typeset & TSET(pair)))
        continue;               /* special case for stype_list */
      if (t == type_integer
          && (typeset & TYPESET_BIGINT_LIKE) == TYPESET_BIGINT_LIKE)
        continue;              /* special case for stype_{bigint,float}_like */
      typeset_t tset = type_typeset(t);
      if (tset == 0 ? typeset == 0 : (typeset & tset) == tset)
        {
          typeset &= ~tset;
          sb_add_one_type(sb, t, &first, typeset, use_markup);
        }
      if (typeset == 0)
        return;
    }
}

void bad_vector_len_error(value v, size_t vlen)
{
  sb_empty(&sb_error_message);
  sb_printf(&sb_error_message,
            "expected %zu-element ", vlen);
  sb_add_typeset(&sb_error_message, TSET(vector), true);
  sb_addstr(&sb_error_message, "; got ");
  if (TYPE(v, vector))
    sb_printf(&sb_error_message, "%zu-element ",
              vector_len((struct vector *)v));

  GCPRO(v);
  struct oport *op = make_strbuf_oport(&sb_error_message);
  UNGCPRO();

  const int maxlen = 32;
  unsigned flags = fmt_write | fmt_flag_quote;
  output_value_cut(op, v, maxlen, flags);

  runtime_error_message(TYPE(v, vector) ? error_bad_value : error_bad_type,
                        sb_str(&sb_error_message));
}

const char *fmt_error_message(const char *fmt, ...)
{
  va_list va;
  va_start(va, fmt);
  sb_empty(&sb_error_message);
  sb_vprintf(&sb_error_message, fmt, va);
  va_end(va);
  return sb_str(&sb_error_message);
}

const char *bad_nargs_message(unsigned nargs, unsigned min, unsigned max)
{
  sb_empty(&sb_error_message);
  sb_addstr(&sb_error_message, "expected ");
  if (min == max)
    sb_addint(&sb_error_message, min);
  else if (min == 0)
    {
      sb_addstr(&sb_error_message, "at most ");
      sb_addint(&sb_error_message, max);
    }
  else
    {
      sb_addint(&sb_error_message, min);
      if (max == UINT_MAX)
        sb_addstr(&sb_error_message, " or more");
      else
        {
          sb_addstr(&sb_error_message, min + 1 == max ? " or " : " to ");
          sb_addint(&sb_error_message, max);
        }
    }
  sb_addstr(&sb_error_message, "; got ");
  sb_addint(&sb_error_message, nargs);
  return sb_str(&sb_error_message);
}

const char *bad_typeset_message(value v, typeset_t expected)
{
  sb_empty(&sb_error_message);
  sb_addstr(&sb_error_message, "expected ");
  sb_add_typeset(&sb_error_message, expected, true);
  sb_addstr(&sb_error_message, "; got ");

  GCPRO(v);
  struct oport *op = make_strbuf_oport(&sb_error_message);
  UNGCPRO();

  const int maxlen = 32;
  unsigned flags = fmt_write | fmt_flag_quote;
  output_value_cut(op, v, maxlen, flags);

  return sb_str(&sb_error_message);
}

#define sb_addint_markup sb_addint

const char *bad_value_message(value v, const char *prefix, const char *suffix)
{
  sb_empty(&sb_error_message);
  if (prefix != NULL)
    sb_addstr(&sb_error_message, prefix);

  GCPRO(v);
  struct oport *op = make_strbuf_oport(&sb_error_message);
  UNGCPRO();

  const int maxlen = 64;
  unsigned flags = fmt_write | fmt_flag_quote;
  output_value_cut(op, v, maxlen, flags);

  if (suffix != NULL)
    sb_addstr(&sb_error_message, suffix);

  return sb_str(&sb_error_message);
}

void no_match_error(value v)
{
  runtime_error_message_hide_tos(
    error_no_match, bad_value_message(v, "invalid value ", NULL), NULL);
}

const char *out_of_range_message(long v, long minval, long maxval)
{
  sb_empty(&sb_error_message);
  sb_addint_markup(&sb_error_message, v);
  sb_addc(&sb_error_message, ' ');
  if (minval <= MIN_TAGGED_INT)
    {
      sb_addstr(&sb_error_message, "> ");
      sb_addint_markup(&sb_error_message, maxval);
    }
  else if (maxval >= MAX_TAGGED_INT)
    {
      sb_addstr(&sb_error_message, "< ");
      sb_addint_markup(&sb_error_message, minval);
    }
  else
    {
      sb_addstr(&sb_error_message, "not in [");
      sb_addint_markup(&sb_error_message, minval);
      sb_addstr(&sb_error_message, "..");
      sb_addint_markup(&sb_error_message, maxval);
      sb_addc(&sb_error_message, ']');
    }
  return sb_str(&sb_error_message);
}

const char *not_callable_message(long nargs)
{
  sb_empty(&sb_error_message);
  sb_printf(&sb_error_message, "not callable with %ld argument%s",
            nargs, nargs == 1 ? "" : "s");
  return sb_str(&sb_error_message);
}

const char *errno_message(int eno, const char *prefix)
{
  sb_empty(&sb_error_message);

  /* if 'prefix' starts with "[a-z]+(", use function markup on the leading
     word */
  const char *scan = prefix;
  while (isalpha((unsigned char)*scan))
    ++scan;
  if (scan != prefix && *scan == '(')
    sb_printf(&sb_error_message, "%s%.*s%s%s: %s",
              mudlle_markup(mudlle_markup_fn, true),
              (int)(scan - prefix),
              prefix,
              mudlle_markup(mudlle_markup_fn, false),
              scan,
              strerror(eno));
  else
    sb_printf(&sb_error_message, "%s: %s", prefix, strerror(eno));
  return sb_str(&sb_error_message);
}

void primitive_bad_type_error(value v, enum mudlle_type expected,
                              const struct prim_op *op,
                              int nargs, ...)
{
  va_list va;
  va_start(va, nargs);
  internal_primitive_runtime_error(error_bad_type,
                                   bad_type_message(v, expected),
                                   op, nargs, va);
  /* not reached */
  abort();
}

void primitive_bad_typeset_error(value v, typeset_t expected,
                                 const struct prim_op *op,
                                 int argnum, int nargs, ...)
{
  va_list va;
  va_start(va, nargs);

  bad_typeset_message(v, expected);
  if (argnum >= 0)
    add_c_argname(&sb_error_message, op, argnum);
  internal_primitive_runtime_error(
    error_bad_type, sb_str(&sb_error_message), op, nargs, va);
  /* not reached */
  abort();
}

static bool get_tos_c(const struct c_info *cinfo,
                      const struct session_context *next_session,
                      void *cbdata)
{
  return true;
}

static bool get_tos_bytecode(struct call_stack_mudlle *mframe,
                             bool onstack, void *cbdata)
{
  value *dst = cbdata;
  *dst = mframe->fn;
  return true;
}

static bool get_tos_mcode(struct mcode *mcode, ulong ofs, value *args,
                          int nargs, void *cbdata)
{
  value *dst = cbdata;
  *dst = mcode;
  return true;
}

static value get_tos(void)
{
  value tos = NULL;
  iterate_call_trace(error_none, false, -1, get_tos_c, get_tos_bytecode,
                     get_tos_mcode, &tos);
  return tos;
}

void bad_typeset_error(value v, typeset_t expected, int argnum)
{
  bool is_return = expected & TYPESET_FLAG_RETURN;
  expected &= ~TYPESET_FLAG_RETURN;
  const char *emsg = bad_typeset_message(v, expected);
  if (is_return)
    emsg = message_when_returning(emsg);
  assert(emsg == sb_str(&sb_error_message));
  if (argnum >= 0)
    {
      value tos = get_tos();
      if (tos != NULL)
        add_mudlle_argname(&sb_error_message, tos, argnum);
    }
  runtime_error_message(error_bad_type, sb_str(&sb_error_message));
}

void out_of_range_error(long v, long minval, long maxval)
{
  runtime_error_message(error_bad_value,
                        out_of_range_message(v, minval, maxval));
}

const char *message_when_returning(const char *head)
{
  size_t eofs = 0;
  const char *estr = sb_str(&sb_error_message);
  if (head >= estr && head < estr + sb_len(&sb_error_message))
    eofs = head - estr; /* already points into sb_error_message; just append */
  else
    {
      sb_empty(&sb_error_message);
      sb_addstr(&sb_error_message, head);
    }
  sb_addstr(&sb_error_message, " when returning");
  return sb_str(&sb_error_message) + eofs;
}

void add_call_trace(value dst, bool unhandled_only, bool use_markup,
                    call_trace_callback_fn callback, void *cbdata)
{
  assert(TYPE(dst, oport) || TYPE(dst, character));

  struct call_trace_target *target = malloc(sizeof *target);
  *target = (struct call_trace_target){
    .next           = call_trace_targets,
    .callback       = callback,
    .cbdata         = cbdata,
    .unhandled_only = unhandled_only,
  };
  dynpro(&target->dst, dst);
  call_trace_targets = target;
}

void remove_call_trace(value dst)
{
  for (struct call_trace_target **targets = &call_trace_targets;
       *targets != NULL;
       targets = &(*targets)->next)
    if ((*targets)->dst.obj == dst)
      {
        free_call_trace_target(targets);
        break;
      }
}
