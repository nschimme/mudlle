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

#ifndef MVALUES_H
#define MVALUES_H

#include <stddef.h>

#ifdef __x86_64__
  #include "x64.h"
#endif

#include "types.h"

/* increase this as compiled mudlle suffers a backwards-incompatible change */
#define MCODE_VERSION 42

/* Objects are either null, integers or pointers to more complex things (like
   variables). Null is represented by NULL. Integers have the lowest bit set.
   Anything else is a pointer to an object (struct obj *). */

/* Make & unmake integers */
#define intval(obj)  (CASSERT_TYPE(obj, value), (long)(obj) >> 1)
#define uintval(obj) (CASSERT_TYPE(obj, value), (unsigned long)(obj) >> 1)

#define makeint(i)                                              \
  (value)(((((i) | 0UL) << 1) | 1) + static_assert_zero(        \
    _Generic((i) | 0UL, unsigned long: 1, default: 0),          \
    #i " cannot be made into a mudlle integer"))

/* return the sum of mudlle integer 'v' and 'l' */
static ALWAYS_INLINE value mudlle_iadd(value v, long l)
{
  return (value)((long)v + 2 * l);
}

/* 0 is false, everything else is true */
#define isfalse(v) (CHECK_MUDLLE_TYPE(v), (value)(v) == makebool(false))
#define istrue(v)  (!isfalse(v))
/* Make a mudlle boolean (true or false) from a C integer */
#define makebool(i) makeint(((i) | 0) != 0)

static inline bool is_any_primitive(value p)
{
  if (!pointerp(p))
    return false;
  return ((struct obj *)p)->garbage_type == garbage_primitive;
}

static ALWAYS_INLINE bool is_const_typeset(value v, typeset_t typeset)
{
  if (typeset == TYPESET_ANY)
    return true;
  if ((typeset & TYPESET_FALSE) && v == makebool(false))
    return true;
  if (typeset & (TSET(null) | TSET(integer)))
    {
      if ((typeset & TSET(null)) && v == NULL)
        return true;
      if (integerp(v))
        return typeset & TSET(integer);
      if (!(typeset & TSET(null)) && v == NULL)
        return false;
    }
  else if (!pointerp(v))
    return false;

  struct obj *obj = v;
  typeset &= TYPESET_ANY ^ (TSET(null) | TSET(integer));
  switch (typeset)
    {
    case 0:
      return false;
    case TYPESET_ANY ^ (TSET(null) | TSET(integer)):
      return true;
    case TYPESET_PRIMITIVE:
      return is_any_primitive(obj);
#define __ISTYPE(t, arg) case TSET(t): return obj->type == type_ ## t
      FOR_PLAIN_TYPES(__ISTYPE, , SEP_SEMI);
#undef __ISTYPE
    }
  return TSBIT(obj->type) & typeset;
}

static inline bool is_generic_typeset(value v, typeset_t typeset)
{
  if (v == NULL)
    return typeset & TSET(null);
  if (integerp(v))
    return ((typeset & TSET(integer))
            || ((typeset & TYPESET_FALSE) && v == makebool(false)));
  struct obj *obj = v;
  return TSBIT(obj->type) & typeset;
}

static ALWAYS_INLINE bool is_typeset(value v, typeset_t typeset)
{
  return (__builtin_constant_p(typeset)
          ? is_const_typeset(v, typeset)
          : is_generic_typeset(v, typeset));
}

static ALWAYS_INLINE bool is_function(value v)
{
  return is_const_typeset(v, TYPESET_FUNCTION);
}

enum {
  MAX_MUDLLE_OBJECT_SIZE = 16 * 1024 * 1024,
  MAX_VECTOR_SIZE   = ((MAX_MUDLLE_OBJECT_SIZE - sizeof (struct vector))
                       / sizeof (value)),
  MAX_STRING_SIZE   = (MAX_MUDLLE_OBJECT_SIZE - sizeof (struct string) - 1),
  MAX_TABLE_ENTRIES = ((MAX_MUDLLE_OBJECT_SIZE / sizeof (value) / 2)
                       * 3 / 4 - 1),
  MAX_FUNCTION_ARGS = 2048,
  MAX_LOCAL_VARS    = 4096
};

#define TAGGED_INT_BITS (CHAR_BIT * sizeof (long) - 1)
#define MAX_TAGGED_UINT (ULONG_MAX >> 1)
#define MAX_TAGGED_INT  (LONG_MAX >> 1)
#define MIN_TAGGED_INT  (-MAX_TAGGED_INT - 1)

#define MAX_RAW_STRING_HASHES 256

static inline long mudlle_sign_extend(long l)
{
  struct { long i : TAGGED_INT_BITS; } m = { .i = l };
  return m.i;
}

enum {
  OBJ_READONLY  = P(0),   /* Used for some values */
  OBJ_IMMUTABLE = P(1),   /* Contains only pointers to other immutable objects.
                             Its pointers are never modified after allocation/
                             initialisation. All initialisation must be
                             done before any other allocation. */
  OBJ_FLAG_0    = P(2),   /* Temporarily used to flag recursions  */
  OBJ_FLAG_1    = P(3)    /* Temporarily used to flag recursions  */
};

/* end mudlle const */

static ALWAYS_INLINE bool obj_readonlyp(struct obj *obj)
{
  return obj->flags & OBJ_READONLY;
}

/* True if x is immutable */
#define immutablep(x) \
  (!pointerp((x)) || (((struct obj *)(x))->flags & OBJ_IMMUTABLE) != 0)

/* True if x is readonly */
#define readonlyp(x) (!pointerp((x)) || obj_readonlyp((struct obj *)(x)))

static inline value make_readonly(value v)
{
  /* must not try to modify static strings, so check readonlyp() */
  if (!readonlyp(v))
    {
      struct obj *o = v;
      assert(o->type != type_oport);
      o->flags |= OBJ_READONLY;
    }
  return v;
}

#define STATIC_STRING(name, value)                              \
  static const struct {                                         \
    struct obj o;                                               \
    char str[sizeof value];                                     \
  } name = {                                                    \
    .o = {                                                      \
      .size         = sizeof (struct obj) + sizeof value,       \
      .garbage_type = garbage_static_string,                    \
      .type         = type_string,                              \
      .flags        = OBJ_IMMUTABLE | OBJ_READONLY              \
    },                                                          \
    .str = value                                                \
  }

#define GET_STATIC_STRING(name) ((struct string *)&(name).o)

#define _SSTR_EXPAND(...) __VA_ARGS__
#define _____DEF_SSTRS(vname, name, str) STATIC_STRING(vname ## name, str)
#define ____DEF_SSTRS(vname, name, str) _____DEF_SSTRS(vname, name, str)
#define ___DEF_SSTRS(vname, getname, getstr, this)     \
  ____DEF_SSTRS(vname, getname this, getstr this)
#define __DEF_SSTRS(...) ___DEF_SSTRS(__VA_ARGS__)
#define _DEF_SSTRS(n, args, this) __DEF_SSTRS(_SSTR_EXPAND args, this)

/* Defines mudlle static strings called 'sstr_<vname>_<name>'.
   'foreach(op, sep)' is a macro that expands to op(arg0) sep() op(arg1) ...
   <name> is what 'getname(arg<N>)' returns.
   The string is what 'getstr(arg<N>)' returns. */
#define DEF_SSTRS(vname, getname, getstr, foreach)      \
  FOR_NARGS(_DEF_SSTRS,                                 \
            (sstr_ ## vname ## _, getname, getstr),     \
            SEP_SEMI, foreach(, SEP_COMMA))

#define _____SSTR_MLIST(vname, name) GET_STATIC_STRING(vname ## name)
#define ____SSTR_MLIST(vname, name) _____SSTR_MLIST(vname, name)
#define ___SSTR_MLIST(vname, getname, field, this) \
  ____SSTR_MLIST(vname, getname this) field
#define __SSTR_MLIST(...) ___SSTR_MLIST(__VA_ARGS__)
#define _SSTR_MLIST(n, args, this) __SSTR_MLIST(_SSTR_EXPAND args, this)

/* Returns comma-separated list of mudlle (SSTR_MLIST) or C (SSTR_CLIST)
   strings. 'vname', 'getname', 'foreach' are as in DEF_SSTRS(), which must
   have been called. */
#define SSTR_MLIST(vname, getname, foreach)             \
  FOR_NARGS(_SSTR_MLIST,                                \
            (sstr_ ## vname ## _, getname, ),           \
            SEP_COMMA, foreach(, SEP_COMMA))
#define SSTR_CLIST(vname, getname, foreach)             \
  FOR_NARGS(_SSTR_MLIST,                                \
            (sstr_ ## vname ## _, getname, ->str),      \
            SEP_COMMA, foreach(, SEP_COMMA))

/* How each class of object is structured */

struct grecord
{
  struct obj o;
  value data[];
};

/* The code structures are somewhat machine-dependent */
struct code
{
  struct obj o;
  struct string *varname;
  struct list *filenames;       /* cons(name on disk, nice name) */
  struct string *help;
  struct vector *arguments;     /* vector(name|false . typeset|null)
                                   where null is for vararg arguments */
  struct string *linenos;       /* DWARF line number information */

  uint16_t lineno;
  seclev_t seclevel;
  uint8_t column;

  typeset_t return_typeset : mudlle_types;
  bool vararg_alloc        : 1;  /* true if the vararg argument is allocated */
  typeset_t unused         : 32 - mudlle_types - 1;

#ifdef PROFILE_CALL_COUNT
  uint32_t call_count;
#endif
};

static inline bool code_is_vararg(const struct code *code)
{
  size_t alen = vector_len(code->arguments);
  if (alen == 0)
    return false;
  struct list *arg = code->arguments->data[alen - 1];
  assert(TYPE(arg, pair));
  return arg->cdr == NULL;
}

static inline bool code_vararg_is_allocated(const struct code *code)
{
  assert(code_is_vararg(code));
  return code->vararg_alloc;
}

static inline struct string *code_filename(const struct code *code)
{
  return code->filenames->car;
}

static inline struct string *code_nicename(const struct code *code)
{
  return code->filenames->cdr;
}

#if defined __x86_64__ && !defined NOCOMPILER
struct icode
{
  struct code code;
  uint32_t instruction_count;
  uint16_t nb_constants;
  uint16_t nb_locals;
  uint16_t stkdepth;
  uint16_t dummy0;
  ulong dummy1;

  /* Machine code jump to interpreter. This is at the same offset as
     mcode in struct mcode */
#ifdef __x86_64__
  struct magic_dispatch {
    uint8_t movq_r11[2];
    void (*invoke)(void);
    uint8_t jmpq_r11[3];
    uint8_t nop3[3];
  } __attribute__((__packed__)) magic_dispatch;
#else
  #error Unsupported architecture
#endif
  value constants[/*nb_constants*/];
  /* instructions follow the constants array */
};

/* ordering of constant offsets as below */
enum mcode_const_type {
  mcode_ct_const,
  mcode_ct_code_entry,
  mcode_const_types
};

struct mcode /* machine-language code object */
{
  struct code code;

  uint32_t code_length;         /* Length of machine code in bytes */
  uint32_t sequence;            /* Unique sequence number for this function */

  uint16_t npcrel;              /* Number of PC-relative constants */
  uint16_t return_itype;

  uint8_t closure_flags;        /* CLF_xxx flags */
  bool dwarf_seen : 1;
  uint32_t unused1 : 32 - 8 - 1;

  uint64_t magic;               /* Magic pattern that doesn't occur in code */

  uint8_t mcode[];              /* Aligned on CODE_ALIGNMENT */
  /* 1. 'code_length' bytes of instructions
     2. padding to 8-byte boundary (if 'npcrel' > 0)
     3. PC-relative constants (count given by 'npcrel')
     4. # offsets to constants (ULEB128); cf. mcode_ct_const
     5. Offsets to constants (deltas as ULEB128)
     6. # offsets to code entry points (ULEB128); cf. mcode_ct_code_entry
     7. Offsets to code entry points (deltas as ULEB128) */
};

/* unlikely (?) pattern in code */
#define MCODE_MAGIC UINT64_MAX

CASSERT(offsetof(struct mcode, mcode)
        == offsetof(struct icode, magic_dispatch));

#endif  /* __x86_64__ && !NOCOMPILER */

#ifdef NOCOMPILER
struct icode
{
  struct code code;
  uint16_t nb_constants;
  uint16_t nb_locals;
  uint16_t stkdepth;
  uint16_t dummy;
  ulong call_count;             /* Profiling */
  struct string *lineno_data;
  ulong instruction_count;
  value constants[/*nb_constants*/];
  /* instructions follow the constants array */
};

struct mcode /* machine-language code object */
{
  struct code code;
  /* Not used when no compiler around ... */
  uint8_t closure_flags;          /* CLF_xxx flags */
  uint8_t mcode[];
};
#endif  /* NOCOMPILER */

#endif  /* MVALUES_H */
