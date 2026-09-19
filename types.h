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

#ifndef TYPES_H
#define TYPES_H

#include "mudlle-macro.h"
#include "mudlle.h"

#ifdef USE_GMP
#endif

typedef unsigned long ulong;

typedef uint8_t seclev_t;

#define sizeoffield(type, field) (sizeof ((type *)0)->field)

struct strbuf;

/* end mudlle const */

/* The basic classes of all objects, as seen by the garbage collector */
enum garbage_type {
  garbage_string,               /* contains non-mudlle values     */
  garbage_record,               /* contains mudlle values         */
  garbage_icode,                /* special for icode              */
  garbage_forwarded,            /* temporarily used during GCs    */
  garbage_primitive,            /* primitives                     */
  garbage_ctemp,                /* non-saveable non-mudlle values */
  garbage_mcode,                /* special for mcode              */
  garbage_static_string,        /* statically allocated string    */
  garbage_mtemp,                /* non-saveable mudlle values     */
  /* insert new types here */
  garbage_free                  /* in the free lists              */
};

/* start mudlle const */

/* Values below MUST NEVER CHANGE. Stored data depends on them.
   Add new storable types just before 'null'; add non-storable
   types last. */
#define FOR_PLAIN_TYPES(op, arg, sep)                                   \
  op(icode, arg) sep() op(closure, arg) sep() op(variable, arg) sep()   \
  op(internal, arg) sep() op(primitive, arg) sep()                      \
  op(varargs, arg) sep() op(secure, arg) sep()                          \
                                                                        \
  op(integer, arg) sep() op(string, arg) sep() op(vector, arg) sep()    \
  op(pair, arg) sep() op(symbol, arg) sep() op(table, arg) sep()        \
  op(private, arg) sep()                                                \
                                                                        \
  op(object, arg) sep() op(character, arg) sep() op(gone, arg) sep()    \
                                                                        \
  op(oport, arg) sep() op(mcode, arg) sep() op(float, arg) sep()        \
  op(bigint, arg) sep()                                                 \
                                                                        \
  /* the following types must never be stored to disk */                \
  op(null, arg) sep() op(connection, arg) sep() op(cookie, arg)         \
  sep() op(file, arg) sep() op(weak_ref, arg) sep() op(regexp, arg)

#define FOR_MTYPE(name, op) op(type_ ## name)

#define FOR_MUDLLE_TYPES(op, sep)                                       \
  FOR_PLAIN_TYPES(FOR_MTYPE, op, sep) sep()                             \
  /* the following synthetic types can change values */                 \
  op(stype_none)        sep() /* no types */                            \
  op(stype_any)         sep() /* any types */                           \
  op(stype_function)    sep() /* closure, primitive, varargs, secure */ \
  op(stype_list)        sep() /* pair, null */                          \
  op(stype_bigint_like) sep() /* bigint, integer */                     \
  op(stype_float_like)  sep() /* float, bigint, integer */              \
  op(stype_false)             /* false; special case */

enum mudlle_type
{
  /* end mudlle const */
  FOR_MUDLLE_TYPES(EXPAND_ARGS, SEP_COMMA),
  /* start mudlle const */
  mudlle_synthetic_types,
  mudlle_types = stype_none,
};

#undef DEF_MTYPE
#undef DEF_STYPE

typedef uint32_t typeset_t;
#define TSBIT(t) ((typeset_t)1 << (t))
#define TSET(t)  TSBIT(type_ ## t)

#define TYPESET_ANY         (TSBIT(mudlle_types) - 1)
#define TYPESET_PRIMITIVE   (TSET(primitive) | TSET(varargs) | TSET(secure))
#define TYPESET_FUNCTION    (TSET(closure) | TYPESET_PRIMITIVE)
#define TYPESET_LIST        (TSET(pair) | TSET(null))
#define TYPESET_BIGINT_LIKE (TSET(bigint) | TSET(integer))
#define TYPESET_FLOAT_LIKE  (TSET(float) | TSET(bigint) | TSET(integer))

/* special case, not part of TYPESET_ANY */
#define TYPESET_FALSE         TSBIT(mudlle_types)

/* end mudlle const */
#define TYPESET_FLAG_RETURN   TSBIT(mudlle_types + 1)
/* start mudlle const */
#define TYPESET_FLAG_OPTIONAL TSBIT(mudlle_types + 2)
CASSERT(mudlle_types + 2 < sizeof (typeset_t) * CHAR_BIT);

static inline typeset_t type_typeset(enum mudlle_type type)
{
  if (type < mudlle_types)
    return TSBIT(type);

  switch (type)
    {
    case stype_none:
      return 0;
    case stype_any:
      return TYPESET_ANY;
    case stype_function:
      return TYPESET_FUNCTION;
    case stype_list:
      return TYPESET_LIST;
    case stype_float_like:
      return TYPESET_FLOAT_LIKE;
    case stype_bigint_like:
      return TYPESET_BIGINT_LIKE;
    case stype_false:
      return TYPESET_FALSE;
      CASSERT(mudlle_synthetic_types - mudlle_types == 7);
    default:
      return 0;
    }
}

extern const char *const mudlle_type_names[];

/* The basic structure of all values */
typedef void *value;

struct obj
{
  ulong size;                   /* total size in bytes */
  enum garbage_type garbage_type : 8;
  enum mudlle_type type : 8;
  uint16_t flags;               /* OBJ_xxx flags */
#ifdef __x86_64__
  uint32_t unused;
#endif
#ifdef GCDEBUG
  ulong generation;
#endif
};

#define pointerp(obj) ((obj) && !((long)(obj) & 1))
#define integerp(obj) ((long)(obj) & 1)

#define staticp(v) (!pointerp(v)                                \
                    || (((struct obj *)(v))->garbage_type       \
                        == garbage_static_string))

#define TYPEOF(v)                                               \
  (integerp(v) ? type_integer                                   \
   : (v) == NULL ? type_null                                    \
   : ((struct obj *)(v))->type)

/* end mudlle consts */
#define _TYPE_IS_NULL_null   MARK
#define _TYPE_IS_INT_integer MARK
/* start mudlle consts */

#define TYPE(v, want)                                                   \
  IF(IS_MARK(_TYPE_IS_NULL_ ## want))(                                  \
    ((v) == NULL),                                                      \
    IF(IS_MARK(_TYPE_IS_INT_ ## want))(                                 \
      integerp(v),                                                      \
      (pointerp(v) && type_ ## want == ((struct obj *)(v))->type)))

/* Code is defined in values (it is known to the gc) */

struct closure                  /* Is a record */
{
  struct obj o;
  struct code *code;            /* May be type_icode or type_mcode */
  struct variable *variables[]; /* May be other types */
};

struct string                   /* Is a string */
{
  struct obj o;
  char str[];                   /* Must be null terminated */
};

struct mudlle_float
{
  struct obj o;
  double     d;
};

#ifdef USE_GMP
struct bigint
{
  struct obj    o;
  mpz_t         mpz;
  mp_limb_t     limbs[];
};
#endif

struct variable                 /* Is a record */
{
  /* This is used for one-item type_variable and type_function */
  struct obj o;
  value vvalue;
};

struct symbol                   /* Is a record */
{
  struct obj o;
  struct string *name;          /* must be readonly */
  value data;
};

/* A primitive operation (eg +, -) */
struct primitive                /* Is a permanent external */
{
  struct obj o;
  const struct prim_op *op;
};

struct prim_op                  /* The primitive's definition */
{
  struct string *name;          /* Always points to a static string */
  struct string *help;          /* Always points to a static string */
  void *op;                     /* op<N>_fn or op<N>plus_fn */
#ifdef PROFILE_CALL_COUNT
  unsigned *call_count;
#endif
  int16_t nargs;
  uint16_t flags;               /* Helps compiler select calling sequence */
  const char *const *arglist;
  const char *const *types;     /* Pointer to type signature array */
  seclev_t seclevel;            /* Only for type_secure */
  const char *filename;
  int lineno;
};

enum {
  OP_LEAF        = P(0),   /* Operation is leaf (calls no other mudlle code) */
  OP_NOALLOC     = P(1),   /* Operation does not allocate anything */
  OP_NUL_STR     = P(2),   /* First argument is nul-terminated string; used in
                              stack traces */
  OP_NOESCAPE    = P(3),   /* Operation does not lead to any global or closure
                              variables being changed (~= calls no other mudlle
                              functions) */
  OP_STR_READONLY = P(4),  /* Any string arguments are only needed for their
                              contents. This means string concatenations may be
                              constant folded if they are used as arguments for
                              this primitive. */
  OP_CONST       = P(5),   /* May be evaluated at compile-time if all its
                              arguments are known constants.
                              try_make_immutable(result) must be immutable and
                              the result must be readonly. */
  OP_OPERATOR    = P(6),   /* Print as an operator (unary prefix, binary infix,
                              or ref/set!) in stack traces. */
  OP_APPLY       = P(7),   /* apply-like function, evaluating one argument,
                              returning its return value; must correspond
                              to an entry in mc:apply_functions */
  OP_FASTSEC     = P(8),   /* Forces a SECOP to be type_primitive. Only
                              useful for M-secure primitives, because the only
                              valid seclevel info will be maxseclevel. */
  OP_TRACE       = P(9),   /* Auto-creates a call stack entry with all the
                              arguments of the primitive, useful when called by
                              compiled mudlle. Needed (and allowed) for plain
                              primitives only. */
  OP_TRIVIAL     = P(10),  /* Skip sanity-checks in primitive wrapper. */
  OP_VARARG_COPY = P(11),  /* For varargs, the argument vector must be a fresh
                              copy. */

  ALL_OP_FLAGS   = P(12) - 1,

  /* flags that can change without requiring recompiling mudlle */
  COMPILER_SAFE_OP_FLAGS = (OP_OPERATOR | OP_TRACE | OP_TRIVIAL | OP_NUL_STR
                            | OP_VARARG_COPY)
};

enum {
  CLF_COMPILED  = P(0),         /* This is a compiled closure */
  CLF_NOESCAPE  = P(1),         /* Does not write global or closure vars */
  CLF_NOCLOSURE = P(2)          /* Does not have any closure variables */
};

struct vector                   /* Is a record */
{
  struct obj o;
  value data[];
};

struct list                     /* Is a record */
{
  struct obj o;
  value car, cdr;
};


struct table                    /* Is a record */
{
  struct obj o;
  value used;                   /* ~n for case/accent-sensitive tables */
  struct vector *buckets;       /* vector_len() must be power of 2 */
};

/* can be either a string or a record */
struct mprivate
{
  struct obj o;
  value ptype;                  /* makeint(enum mprivate_type) */
};

struct mjmpbuf                  /* a string */
{
  struct mprivate p;
  struct catch_context *context; /* set to NULL when cannot be used anymore */
  value *result;                /* where to store result on longjmp(); set to
                                   NULL while being jumped to */
};

struct mweak_ref
{
  struct obj o;
  value v;
};

struct closure *alloc_closure_noinit(ulong nb_variables);
struct closure *alloc_closure0(struct code *code);
struct string *alloc_string(const char *s);
struct string *mudlle_string_copy(struct string *s);
char *mudlle_string_dup(struct string *s);
struct string *alloc_string_noinit(size_t length);
struct string *alloc_string_length(const char *s, size_t length);
struct string *strbuf_to_mudlle(const struct strbuf *sb);
struct mudlle_float *alloc_float(double d);
struct string *safe_alloc_string(const char *s);
struct variable *alloc_variable(value val);
struct symbol *alloc_symbol(struct string *name, value data);
struct vector *alloc_vector(ulong size);
struct vector *make_vector(unsigned argc, value args[static argc]);
struct list *alloc_list(value car, value cdr);

#ifdef USE_GMP
void check_bigint(struct bigint *bi);
struct bigint *alloc_bigint(mpz_t mpz);
#endif


/* end mudlle consts */

/* Private types which are visible to the mudlle programmer must be
   records identified by their first element with one of the following
   constants. They cannot be stored to disk so can be renumbered. */
enum mprivate_type {
  PRIVATE_MJMPBUF = 1,
  PRIVATE_PROFILE,
  PRIVATE_MCALLBACK
};


/* redefine LOCAL_MUDLLE_TYPES in your .c files as necessary */
#define LOCAL_MUDLLE_TYPES
#define IS_MUDLLE_TYPE(x)                       \
  _Generic((x),                                 \
           value:                 true,         \
           struct obj *:          true,         \
           struct env *:          true,         \
           struct grecord *:      true,         \
           struct code *:         true,         \
           struct icode *:        true,         \
           struct closure *:      true,         \
           struct variable *:     true,         \
           struct primitive *:    true,         \
           struct string *:       true,         \
           struct vector *:       true,         \
           struct list *:         true,         \
           struct symbol *:       true,         \
           struct table *:        true,         \
           struct mconnection *:  true,         \
           struct mprivate *:     true,         \
           struct mjmpbuf *:      true,         \
           struct mweak_ref *:    true,         \
           struct object *:       true,         \
           struct character *:    true,         \
           struct oport *:        true,         \
           struct mcode *:        true,         \
           struct mudlle_float *: true,         \
           struct bigint *:       true,         \
           LOCAL_MUDLLE_TYPES                   \
           default: false)

#define CHECK_MUDLLE_TYPE(v) \
  static_assert_expr(IS_MUDLLE_TYPE(v), #v " is not a mudlle type")

#define string_len(str)                                         \
  (CASSERT_TYPE(str, struct string *),                          \
   ((str)->o.size - (sizeof (struct obj) + 1)))

#define grecord_len(rec)                                        \
  (CASSERT_TYPE(rec, struct grecord *),                         \
   ((rec)->o.size - sizeof (struct grecord)) / sizeof (value))
#define vector_len(vec)                                         \
  (CASSERT_TYPE(vec, struct vector *),                          \
   ((vec)->o.size - sizeof (struct vector)) / sizeof (value))

#define grecord_fields(rec)                                     \
  ((sizeof (rec) - sizeof (struct obj)) / sizeof (value))


#ifdef WORDS_BIGENDIAN
 /* MUDLLE_VALUE_UNION bitfield layouts assume little-endian */
 #error Unsupported endianness
#endif

/* MUDLLE_VALUE_UNION(name, <bitfields>) defines a union of bitfields that live
   inside a mudlle integer, accessed as 'x.v' if 'x' is the union <name> variable.
   The bitfields are accessed as 'x.i.<bitfield>'.
   <bitfields> must use TAGGED_INT_BITS bits to ensure correct zero-initialization.
   You _must_ set the 'isint' field to true when using this type. */
#define MUDLLE_VALUE_UNION(name, ...)           \
union name {                                    \
  struct {                                      \
    bool isint : 1;                             \
    __VA_ARGS__                                 \
  }  __attribute__((__packed__)) i;             \
  value v;                                      \
};                                              \
CASSERT_SIZEOF(union name, sizeof (value));     \
union name

/* used to disguise an aligned C pointer as a mudlle integer */
struct tagged_ptr {
  value v;
};

static inline void set_tagged_ptr(struct tagged_ptr *dst, void *src)
{
  ulong adr = (ulong)src;
  assert(adr % _Alignof (int) == 0);
  dst->v = (value)(adr | 1);
}

static inline void *get_tagged_ptr(const struct tagged_ptr *src)
{
  ulong n = (ulong)src->v;
  assert(n % _Alignof (int) == 1);
  return (void *)(n & ~1);
}

static inline void *get_tagged_value(value v)
{
  return get_tagged_ptr(&(struct tagged_ptr){ .v = v });
}

/* Safe vector assignment. 'v' must GCPROed, and 'val' is allowed to
   GC allocate. */
#define SET_VECTOR(v, idx, val)                 \
do {                                            \
  CASSERT_TYPE((v), struct vector *);           \
  CHECK_MUDLLE_TYPE(val);                       \
  value __tmp = (val);                          \
  (v)->data[idx] = __tmp;                       \
} while (0)

/* iterative over mudlle string; supports break/continue */
#define string_foreach(sval, var)                                       \
  for (struct string *__foreach_str = (sval); __foreach_str; )          \
    for (unsigned char var; __foreach_str; __foreach_str = NULL)        \
      for (size_t __end = string_len(__foreach_str), __idx = 0;         \
           (var = __foreach_str->str[__idx]), __idx < __end;            \
           ++__idx)                                                     \

/*
 * Converts the string sp into a long l and returns true.
 * On over/underflow or illegal characters, it returns false.
 */
bool mudlle_strtolong(const char *sp, size_t len, long *l, int base,
                      bool allow_one_overflow);
/* warning: sp[len] must be NUL */
bool mudlle_strtofloat(const char *sp, size_t len, double *d);

#define MAX_PRIMITIVE_ARGS 5
#define DOPRIMARGS(op, sep) \
  op(1) sep() op(2) sep() op(3) sep() op(4) sep() op(5)

#define MAX_VARARG_FIXED 8      /* counting the argv */
#define DOVAROPARGS(op, sep) \
  op(1) sep() op(2) sep() op(3) sep() op(4) sep() op(5) sep() op(6) \
  sep() op(7) sep() op(8)

#define MAX_C_ARGS (MAX_PRIMITIVE_ARGS > MAX_VARARG_FIXED       \
                    ? MAX_PRIMITIVE_ARGS                        \
                    : MAX_VARARG_FIXED)

#endif /* TYPES_H */
