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

#ifdef __linux__
  /* needed for REG_xxx constants for signal contexts */
  #define _GNU_SOURCE
#endif

#include "../mudlle-config.h"

#include <ctype.h>
#include <signal.h>

#include <sys/mman.h>

#include "../array.h"
#include "../context.h"
#include "../global.h"
#include "../module.h"
#include "../strbuf.h"

#include "arith.h"
#include "basic.h"
#include "bigint.h"
#include "bitset.h"
#include "bool.h"
#include "debug.h"
#include "files.h"
#include "io.h"
#include "list.h"
#include "mudlle-float.h"
#include "mudlle-string.h"
#include "mudlle-xml.h"
#include "pattern.h"
#include "runtime.h"
#include "support.h"
#include "symbol.h"
#include "vector.h"


unsigned mudlle_forbid;

static void system_set(ulong idx, value val, const char *filename, int lineno)
{
  /* Technically this is not required, but you should think hard about whether
     adding a mutable or writable global is the right thing to do. */
  assert(readonlyp(val));
  make_immutable(val);

  if (GCONSTANT(idx))
    {
      fprintf(stderr, "%s:%d: %s%s is already defined\n",
              filename, lineno,
              GNAME(idx)->str, is_function(GVAR(idx)) ? "()" : "");
      abort();
    }

  GVAR(idx) = val;
  STATIC_STRING(sstr_system, "system");
  module_vset(idx, var_module, GET_STATIC_STRING(sstr_system), false);
}

void system_string_define(struct string *name, value val)
{
  GCPRO(val);
  ulong idx = mglobal_lookup(name);
  UNGCPRO();
  system_set(idx, val, __FILE__, __LINE__);
}

void system_write(struct string *name, value val)
/* Modifies: environment
   Requires: name not already exist in environment.
   Effects: Adds name to environment, with value val for the variable,
     as a 'define' of the system module.
*/
{
  GCPRO(val);
  ulong aindex = mglobal_lookup(name);
  UNGCPRO();

  if (!module_vset(aindex, var_system_write, NULL, false))
    abort();
  GVAR(aindex) = val;
}

struct vector *define_strvec(struct string *name,
                             const char *const *cvec,
                             struct string *const *mvec,
                             const struct strvec_config *config)
{
  assert((cvec == NULL) != (mvec == NULL));
  if (name != NULL)
    assert(name->o.garbage_type == garbage_static_string);

  int count = config->count;
  if (count < 0)
    for (count = 0; cvec ? cvec[count] != NULL : mvec[count] != NULL; ++count)
      ;

  if (config->len != NULL)
    *config->len = count;

  struct vector *v = alloc_vector(count);
  GCPRO(v);
  for (int n = 0; n < count; ++n)
    {
      value val = NULL;
      if (cvec ? cvec[n] == NULL : mvec[n] == NULL)
        assert(config->null_allowed);
      else if (mvec)
        {
          assert(staticp(mvec[n]) && TYPE(mvec[n], string));
          if (string_len(mvec[n]) != 0 || !config->empty_is_null)
            val = mvec[n];
        }
      else if (cvec[n][0] != 0 || !config->empty_is_null)
        val = make_readonly(alloc_string(cvec[n]));
      SET_VECTOR(v, n, val);
    }
  make_immutable(v);
  if (name != NULL)
    {
      ulong idx = mglobal_lookup(name);
      if (config->gvaridx != NULL)
        *config->gvaridx = idx;
      system_set(idx, v, __FILE__, __LINE__);
    }
  UNGCPRO();
  return v;
}

void define_int_vector(struct string *name, const int *vec, int count)
{
  assert(name->o.garbage_type == garbage_static_string);

  struct vector *v = alloc_vector(count);
  GCPRO(v);
  for (int n = 0; n < count; ++n)
    v->data[n] = makeint(vec[n]);
  UNGCPRO();
  system_string_define(name, make_immutable(v));
}

const char *primop_argname(size_t *namelen, const char **suffix,
                           const char *from)
{
  if (from == NULL)
    return NULL;

  *suffix = NULL;

  size_t argend = strlen(from);
  if (argend > 2
      && from[argend - 2] == '_'
      && from[argend - 1] == 'p')
    {
      *suffix = "?";
      argend -= 2;
    }
  size_t argstart = argend;
  while (argstart > 0
         && (isalnum((unsigned char)from[argstart - 1])
             || from[argstart - 1] == '_'))
    --argstart;

  if (argstart >= argend)
    return NULL;

  /* skip any leading 'm' */
  if (argstart < argend - 1 && from[argstart] == 'm')
    ++argstart;

  *namelen = argend - argstart;
  return from + argstart;
}

static void validate_prim_types(const struct prim_op *op)
{
#define tassert(what) do {                                      \
  if (!(what))                                                  \
    {                                                           \
      fprintf(stderr, "%s:%d: %s: Assertion `%s' failed.\n",    \
              op->filename, op->lineno, op->name->str, #what);  \
      abort();                                                  \
    }                                                           \
} while (0)

#define ARG_ALLOWED "fnzZsvluktyxodDbB"
#define DST_ALLOWED ARG_ALLOWED "123456789"

  for (const char *const *types = op->types; *types; ++types)
    {
      const char *allowed = ARG_ALLOWED;
      const char *this = *types;
      int argc = 0;
      bool saw_period = false;
      for (const char *s = this; *s; ++s)
        {
          if (*s == '.')
            {
              saw_period = true;
              allowed = DST_ALLOWED;
              ++s;
              if (*s == 0)
                break;
            }
          if (*s == '[')
            {
              for (;;)
                {
                  ++s;
                  tassert(*s);
                  if (*s == ']')
                    break;
                  tassert(strchr(allowed, *s));
                }
            }
          else if (*s == '*')
            {
              tassert(s > this && s[1] == '.' && !saw_period);
              tassert(s[-1] != ']'); /* not supported by primitive_types() */
              continue;
            }
          else
            tassert(strchr(allowed, *s));
          if (saw_period)
            {
              tassert(!s[1]);
              break;
            }
          ++argc;
        }

      tassert(saw_period);

      if (op->nargs >= 0)
        tassert(op->nargs == argc);
    }

#undef tassert
#undef ARG_ALLOWED
#undef DST_ALLOWED
}

static struct {
  ARRAY_T(const struct prim_op *) ops;
  bool locked;
} primitives;

struct primitive *runtime_define(const struct prim_op *op)
{
  const char *err = NULL, *pname = NULL;
  if (!TYPE(op->name, string)
      || (pname = op->name->str, !staticp(op->name))
      || string_len(op->name) < 1)
    {
      pname = NULL;
      err = "name is not a non-empty static string";
    }
  else if (op->nargs > MAX_PRIMITIVE_ARGS)
    err = "too many arguments";
  else if (op->help == NULL || op->help->str[0] == 0)
    err = "no help string";
  else if (op->help->str[strlen(op->help->str) - 1] == '\n')
    err = "help string ends in newline";
  else if (primitives.locked)
    err = "cannot define primitives after runtime_init()";

  if (err != NULL)
    {
      fprintf(stderr, "%s:%d: %s%s: %s\n",
              op->filename, op->lineno,
              pname ? pname : "", pname ? "()" : "invalid primitive", err);
      abort();
    }

  ulong idx = mglobal_lookup(op->name);

  validate_prim_types(op);

  ARRAY_ADD(primitives.ops, op);

  struct primitive *prim = allocate_primitive(op);
  system_set(idx, prim, op->filename, op->lineno);
  return prim;
}

static int cmp_ops(const void *a, const void *b)
{
  const struct prim_op *const *ap = a;
  const struct prim_op *const *bp = b;
  return CMP((ulong)(*ap)->op, (ulong)(*bp)->op);
}

static void sort_primitives(void)
{
  assert(!primitives.locked);
  ARRAY_TRIM(primitives.ops);
  ARRAY_QSORT(primitives.ops, cmp_ops);
  primitives.locked = true;
}

const struct prim_op *lookup_primitive(ulong adr)
{
  assert(primitives.locked);
  struct prim_op key;
  key.op = (value (*)())adr;
  void *keyptr = &key;
  const struct prim_op **res = ARRAY_BSEARCH(
    &keyptr, primitives.ops, cmp_ops);
  return res == NULL ? NULL : *res;
}

#ifdef MUDLLE_INTERRUPT
static volatile sig_atomic_t interrupted = false;

void check_interrupt(void)
/* Effects: Causes a user_interrupt runtime error if interrupted is true
     (user caused SIGINT or SIGQUIT)
*/
{
  if (interrupted)
    {
      interrupted = false;
      runtime_error(error_user_interrupt);
    }
}

static void catchint(int sig)
{
  set_xcount(1);                /* actually unnecessary in signal handler */
  interrupted = true;
}
#endif  /* MUDLLE_INTERRUPT */

#if defined __x86_64__ && !defined NOCOMPILER

#undef USE_SYS_UCONTEXT
#if __GLIBC__ == 2 && (defined REG_EIP || __GLIBC_MINOR__ >= 3)
#  include <sys/ucontext.h>
#  define USE_SYS_UCONTEXT
#elif defined __MACH__
#  include <sys/ucontext.h>
#elif defined SA_SIGINFO
#  include <asm/ucontext.h>
#elif __GLIBC__ < 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ <= 1)
#  define sigcontext sigcontext_struct
#  include <asm/sigcontext.h>
#elif __GLIBC__ != 2 && __GLIBC_MINOR__ != 2
#  include <sigcontext.h>
#endif

#ifdef __MACH__
  #define REG_CONTEXT_T mcontext_t
  #define GETREG(ctx, reg, REG) (*(ctx))->__ss.__ ## reg
  #define UCONTEXT_T ucontext_t
#elif defined USE_SYS_UCONTEXT
  #define REG_CONTEXT_T mcontext_t
  #define GETREG(ctx, reg, REG) (ctx)->gregs[REG_ ## REG]
  #if __GLIBC__ > 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ >= 27)
    #define UCONTEXT_T struct ucontext_t
  #else
    #define UCONTEXT_T struct ucontext
  #endif
#else
  #define REG_CONTEXT_T struct sigcontext
  #define GETREG(ctx, reg, REG) (ctx)->reg
  #define UCONTEXT_T struct ucontext
#endif

#include "../builtins.h"

static struct sigaction oldsegact;
#ifdef __MACH__
static struct sigaction oldbusact;
#endif

/* export for gdb */
void got_real_segv(int sig);
void got_real_segv(int sig)
{
  /* reinstall the default handler; this will cause a real crash */
  if (sig == SIGSEGV)
    {
      if (sigaction(sig, &oldsegact, NULL) < 0)
        abort();
      return;
    }
#ifdef __MACH__
  if (sig == SIGBUS)
    {
      if (sigaction(sig, &oldbusact, NULL) < 0)
        abort();
      return;
    }
#endif
  abort();
}

#define USE_ALTSTACK 1
static char *my_signal_stack;
static size_t my_signal_stack_size;

static bool is_valid_address(uintptr_t adr)
{
  /* convoluted way to check if an address range is valid */
  return (posix_madvise((void *)(adr & ~(pagesize - 1)),
                        (adr & (pagesize - 1)) + 1,
                        POSIX_MADV_NORMAL)
          == 0);
}

/* true is 'pc' is an instruction that is allowed to cause SIGSEGV on NULL
   pointer dereference */
static bool is_valid_segv_instr(const uint8_t *pc)
{
  for (const uint8_t *data = valid_segvs; ; )
    {
      unsigned bytes = *data++;
      if (bytes == 0)
        return false;

      for (unsigned i = 0; i < bytes; ++i)
        {
          /* 'mask' are the must-match bits */
          uint8_t mask = ~(data[i] ^ data[bytes + i]);

          /* fail if pc differs from pattern in any must-match bits */
          if (((data[i] ^ pc[i]) & mask) != 0)
            goto next;
        }
      return true;

    next:
      data += 2 * bytes;
    }
}

static void check_segv(int sig, REG_CONTEXT_T *scp)
{
#ifdef USE_ALTSTACK
  unsigned long sp = get_stack_pointer();
  if (sp >= (unsigned long)my_signal_stack
      && sp < (unsigned long)my_signal_stack + my_signal_stack_size)
    {
      /* will be restored by safe_mcatch() */
      hard_mudlle_stack_limit = mudlle_stack_limit
        = (unsigned long)my_signal_stack + 1024;
    }
#endif  /* USE_ALTSTACK */

#ifdef __x86_64__
  #define GET_PC(scp) GETREG(scp, rip, RIP)
  #define GET_SP(scp) GETREG(scp, rsp, RSP)
  #define GET_BP(scp) GETREG(scp, rbp, RBP)
  #define GET_ARG0(scp) GETREG(scp, rdi, RDI)
  #define GET_ARG1(scp) GETREG(scp, rsi, RSI)
  #define GET_ARG2(scp) GETREG(scp, rdx, RDX)
#else
  #error Unsupported architecture
#endif
  const uint8_t *pc = (const uint8_t *)GET_PC(scp);

  if (!is_valid_address((uintptr_t)pc))
    goto real_segv;

  if (!is_valid_segv_instr(pc))
    goto real_segv;

  /* mudlle code */
  if (pc >= gcblock && pc < gcblock + gcblocksize)
    {
      ccontext.frame_end_sp = (ulong *)GET_SP(scp);
      ccontext.frame_end_bp = (ulong *)GET_BP(scp);
      /* Make stack trace printing start from the right place.
         1 is subtracted in error.c as other PCs are return addresses */
      ccontext.frame_end_sp[-1] = (ulong)pc + 1;
      runtime_error(error_bad_type);
    }
  /* bref */
  if (pc >= (uint8_t *)bref && pc < (uint8_t *)bref_end)
    {
      ccontext.frame_end_sp = (ulong *)GET_SP(scp) + 1;
      ccontext.frame_end_bp = (ulong *)GET_BP(scp);
      ref_bad_type_error((value)GET_ARG0(scp), (value)GET_ARG1(scp));
    }
  /* bset */
  if (pc >= (uint8_t *)bset && pc < (uint8_t *)bset_end)
    {
      ccontext.frame_end_sp = (ulong *)GET_SP(scp) + 1;
      ccontext.frame_end_bp = (ulong *)GET_BP(scp);
      set_bad_type_error((value)GET_ARG0(scp),
                         (value)GET_ARG1(scp),
                         (value)GET_ARG2(scp));
    }

 real_segv:
  got_real_segv(sig);
}

static void catchsegv(int sig, siginfo_t *siginfo, void *_sigcontext)
{
  UCONTEXT_T *sigcontext = _sigcontext;
  check_segv(sig, &sigcontext->uc_mcontext);
}

/* basic sanity check on 'valid_segvs' */
static void check_valid_segvs(void)
{
  for (const uint8_t *data = valid_segvs; ; )
    {
      unsigned bytes = *data++;
      if (bytes == 0)
        break;

#if 0
      for (uint8_t mask = 0; ; mask = 0xff)
        {
          const char *prefix = ".byte ";
          for (int i = 0; i < bytes; ++i)
            {
              fprintf(stderr, "%s0x%x", prefix,
                      ((data[i] & data[bytes + i])
                       | (mask & (data[i] ^ data[bytes + i]))));
              prefix = ", ";
            }
          fputc('\n', stderr);
          if (mask != 0)
            break;
        }
#endif
      data += 2 * bytes;
    }
}

#endif  /* __x86_64__ && !NOCOMPILER */

noreturn
void flag_check_failed(const struct prim_op *op, const char *name)
{
  abort();
}

long get_range(value v, long minval, long maxval, const char *what,
               enum runtime_error *error, const char **errmsg)
{
  enum runtime_error err;
  const char *msg = NULL;

  if (!integerp(v))
    {
      msg = bad_typeset_message(v, TSET(integer));
      err = error_bad_type;
      goto error;
    }
  long l = intval(v);
  if (l < minval || l > maxval)
    {
      msg = out_of_range_message(l, minval, maxval);
      err = error_bad_value;
      goto error;
    }
  *error = error_none;
  *errmsg = NULL;
  return l;

 error:
  if (what != NULL)
    {
      static struct strbuf sb = SBNULL;
      sb_empty(&sb);
      sb_printf(&sb, "invalid %s: %s", what, msg);
      msg = sb_str(&sb);
    }
  *errmsg = msg;
  *error = err;
  return 0;
}

void runtime_init(void)
{
#ifdef USE_ALTSTACK
  /* MINSIGSTKSZ is not constant in glibc 2.34 */
  my_signal_stack_size = MINSIGSTKSZ + 8 * 1024;
  my_signal_stack = malloc(my_signal_stack_size);
#endif

#ifdef MUDLLE_INTERRUPT
  signal(SIGINT, catchint);
#ifdef SIGQUIT
  signal(SIGQUIT, catchint);
#endif
#endif

#if defined __x86_64__ && !defined NOCOMPILER
  {
    stack_t my_stack = {
      .ss_sp    = my_signal_stack,
      .ss_flags = 0,
      .ss_size  = my_signal_stack_size,
    };
    if (sigaltstack(&my_stack, NULL) < 0)
      {
        perror("sigaltstack()");
        abort();
      }

    struct sigaction sact = {
      .sa_sigaction = catchsegv,
      .sa_flags     = SA_SIGINFO | SA_RESTART | SA_NODEFER | SA_ONSTACK
    };
    sigemptyset(&sact.sa_mask);
    if (sigaction(SIGSEGV, &sact, &oldsegact) < 0)
      {
        perror("sigaction()");
        abort();
      }
#ifdef __MACH__
    if (sigaction(SIGBUS, &sact, &oldbusact) < 0)
      {
        perror("sigaction()");
        abort();
      }
#endif
  }

  check_valid_segvs();
#endif  /* __x86_64__ && !NOCOMPILER */

  basic_init();
  debug_init();
  arith_init();
  bool_init();
  io_init();
  symbol_init();
  string_init();
  list_init();
  vector_init();
  support_init();
  bitset_init();
  files_init();
  float_init();
  bigint_init();
  pattern_init();
  mudlle_consts_init();
  xml_init();
  module_set("system", module_protected, 0);

  sort_primitives();
}
