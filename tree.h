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

#ifndef TREE_H
#define TREE_H

#include "mparser.h"
#include "types.h"
#include "utils.h"

/* end mudlle const */

struct alloc_block;

void push_parser_heap(struct alloc_block *heap);
/* pop the heap, asserting that it's at 'heap' */
void pop_parser_heap(struct alloc_block *heap);

struct alloc_block *parser_heap(void);

/* op(name, optional-long-name) */
#define FOR_ARITH_MODES(op, sep)                \
  op(default,)                sep()             \
  op(integer,)                sep()             \
  op(float, "floating-point") sep()             \
  op(bigint,)                 sep()             \
  op(overflow,)
enum arith_mode {
  PREFIX_MAP(arith_, ARGN1, FOR_ARITH_MODES)
};

struct vlist {
  struct vlist *next;
  const char *var;
  typeset_t typeset;
  bool was_read, was_written;
  struct loc loc;
};

struct clist {
  struct clist *next;
  struct component *c;
};

struct cstlist {
  struct cstlist *next;
  struct constant *cst;
  bool is_dynamic;
};

struct cstpair {
  struct constant *cst1, *cst2;
};

struct function_arg {
  struct function_arg *next;

  const char *name;
  typeset_t typeset;
  struct loc loc;

  struct pattern *pat;          /* exactly one of pat and name is non-NULL */
  struct component *pat_expr;   /* filled in by inline expansion */
  struct vlist *pat_vars;

  struct component *default_val; /* default value */

  bool is_optional;
  bool is_vararg;
};

struct function_args {
  struct function_arg *args;
  struct function_arg *last_arg; /* Last element of 'args' */
  unsigned nargs;                /* Fixed arguments */
  unsigned noptargs;             /* Optional and varargs */
};

struct function {
  typeset_t return_typeset;      /* Return type(s) */
  struct cstrlen help;
  struct function_args *args;

  struct component *value;
  struct loc loc;               /* Location of "fn" keyword */
  struct loc endloc;            /* Last location; for return type checks */
  const char *varname;          /* Name of variable in which function is
                                   stored */
};

struct block {
  struct vlist *locals;
  struct clist *sequence;
  struct loc loc;
  bool statics;                 /* true if 'locals' are in fact statics */
  bool is_arith;                /* true if actually an #arith */
  enum arith_mode arith_mode;   /* set iff is_arith */
};

#define FOR_BUILTINS(op, sep)                                           \
  op(b_logical_or,  "||", "logical OR (||)")               sep()        \
  op(b_logical_and, "&&", "logical AND (&&)")              sep()        \
  /* following 6 invert logic using ^= 1 */                             \
  op(b_eq,          "==", "equal to (==)")                 sep()        \
  op(b_ne,          "!=", "not equal to (!=)")             sep()        \
  op(b_lt,          "<",  "less than (<)")                 sep()        \
  op(b_ge,          "<=", "less than or equal to (<=)")    sep()        \
  op(b_le,          ">",  "greater than (>)")              sep()        \
  op(b_gt,          ">=", "greater than or equal to (>=)") sep()        \
  op(b_bitor,       "|",  "bitwise inclusive OR (|)")      sep()        \
  op(b_bitxor,      "^",  "bitwise exclusive OR (^)")      sep()        \
  op(b_bitand,      "&",  "bitwise AND (&)")               sep()        \
  op(b_shift_left,  "<<", "bitwise shift left (<<)")       sep()        \
  op(b_shift_right, ">>", "bitwise shift right (>>)")      sep()        \
  op(b_add,         "+",  "addition (+)")                  sep()        \
  op(b_subtract,    "-",  "subtraction (-)")               sep()        \
  op(b_multiply,    "*",  "multiplication (*)")            sep()        \
  op(b_divide,      "/",  "division (/)")                  sep()        \
  op(b_remainder,   "%",  "remainder (%)")                 sep()        \
  op(b_negate,      "-",  "negation (-)")                  sep()        \
  op(b_logical_not, "!",  "logical NOT (!)")               sep()        \
  op(b_bitnot,      "~",  "bitwise NOT (~)")               sep()        \
  op(b_ifelse,      "if-else",)                            sep()        \
  op(b_if,          "if",)                                 sep()        \
  op(b_while,       "while",)                              sep()        \
  op(b_loop,        "loop",)                               sep()        \
  op(b_ref,         "ref", "dereference ([...])")          sep()        \
  op(b_set,         "set", "assign to reference")          sep()        \
  op(b_cons,        "cons",)                               sep()        \
  op(b_logical_xor, "^^", "logical exclusive OR (^^)")     sep()        \
  op(b_paren,       "paren", "parentheses")                sep()        \
  op(b_assign,      "=",  "assignment (=)")

enum builtin_op {
  FOR_BUILTINS(ARGN1, SEP_COMMA),
  parser_builtins
};

CASSERT((b_eq ^ 1) == b_ne);

extern const char *const builtin_op_names[];
extern const char *const builtin_op_long_names[];

/* start mudlle const ; mudlle subst s/^/mc:/ */
enum rwmode {
  rwmode_im,                    /* immutable */
  rwmode_ro,                    /* readonly */
  rwmode_rw,                    /* read-write */
};
/* end mudlle const */

extern const char *const rwmode_names[];

#define FOR_CONST_CLASSES(op, sep)              \
  op(null)       sep()                          \
  op(int)        sep()                          \
  op(gone)       sep()                          \
  op(string)     sep()                          \
  op(list)       sep()                          \
  op(array)      sep()                          \
  op(float)      sep()                          \
  op(bigint)     sep()                          \
  op(table)      sep()                          \
  op(ctable)     sep()                          \
  op(symbol)     sep()                          \
  op(expression) sep()                          \
  op(unary)

enum constant_class {
  PREFIX_MAP(cst_, EXPAND_ARGS, FOR_CONST_CLASSES)
};

enum const_base {
  cstbase_named_char  = -2,     /* ?\N{...} format */
  cstbase_char        = -1,     /* ?X format */
  cstbase_binary      = 2,
  cstbase_octal       = 8,
  cstbase_decimal     = 10,
  cstbase_hexadecimal = 16,
};

struct bigint_const {
  enum const_base base;
  bool neg;
  char str[];
};

struct int_and_base {
  enum const_base base;
  long i;
};

struct float_and_base {
  enum const_base base;
  double d;
};

struct constant {
  enum constant_class vclass : 8;
  /* is_dynamic is true if has cst_expression; or #rw inside code */
  bool is_dynamic : 1;
  enum rwmode rwmode : 2;
  struct loc loc;
  union {
    struct int_and_base integer;
    struct cstrlen string;
    struct float_and_base flt;
    struct bigint_const *bigint;
    /* the last 'constants' entry is the tail element for cst_list */
    struct cstlist *constants;
    struct cstpair *constpair;
    struct component *expression; /* not an actual constant at all */
    struct {
      enum builtin_op op;
      struct constant *cst;
    } unary;
  } u;
};

struct pattern_list {
  struct pattern_list *next;
  struct pattern *pat;
};

#define FOR_PATTERN_CLASSES(op, sep)            \
  op(const,    (cvalue))                  sep() \
  op(list,     (llist))                   sep() \
  op(array,    (alist, aellipsis, atail)) sep() \
  op(symbol,   (sname, svalue))           sep() \
  op(variable, (vname, vtypeset))         sep() \
  op(sink,     (sink_typeset))            sep() \
  op(expr,     (eexpr))                   sep() \
  op(and,      (and_pat, and_cond))       sep() \
  op(or,       (olhs, orhs))

enum pattern_class {
#define __PDEF(name, args) pat_ ## name
  FOR_PATTERN_CLASSES(__PDEF, SEP_COMMA)
#undef __PDEF
};

enum parser_pattern_field {
  pat_class,
  pat_loc
};

#define ___FDEF(name) pat_ ## name
#define __FDEF(name, args)                                      \
  enum pat_ ## name ## _fields {                                \
    __pat_ ## name ## _start = pat_loc,                         \
      IF_NO_ARGS args (                                         \
        , FOR_ARGS(___FDEF, SEP_COMMA, EXPAND_ARGS args) ,)     \
      pat_ ## name ## _fields                                   \
  }
FOR_PATTERN_CLASSES(__FDEF, SEP_SEMI);
#undef __FDEF
#undef ___FDEF

struct pattern {
  enum pattern_class vclass;
  struct loc loc;
  union {
    struct constant *constval;
    struct component *expr;
    struct {
      struct pattern_list *patlist, *pattail;
      bool ellipsis;
    } ary;
    struct pattern_list *lst;
    struct {
      const char *name;
      typeset_t typeset;
    } var;                      /* also used by pat_sink */
    struct {
      struct pattern *name;
      struct pattern *val;
    } sym;
    struct {
      struct pattern *lhs;
      struct pattern *rhs;
    } or;
    struct {
      struct pattern *pat;
      struct component *cond;
    } and;
  } u;
};

struct match_node {
  struct loc loc;
  struct pattern *pattern;
  struct component *expression;
  struct vlist *locals;
};

struct match_node_list {
  struct match_node_list *next;
  struct match_node *match;
};

enum parser_component_field {
  c_class,
  c_loc
};

/* Calls op(name, mudlle-args). Documented in compiler.mud */
#define FOR_COMPONENT_CLASSES(op, sep)                          \
  op(assign,   (asymbol, avalue, asymloc))              sep()   \
  op(recall,   (rsymbol))                               sep()   \
  op(constant, (cvalue))                                sep()   \
  op(compound, (compound_value))                        sep()   \
  op(closure,  (freturn_typeset, fhelp, ffullargs,              \
                farginfo, fvalue, ffilename,                    \
                fnicename, fendloc))                    sep()   \
  op(execute,  (efnargs))                               sep()   \
  op(builtin,  (bfn, bargs))                            sep()   \
  op(modify,   (mfn, mdst, mmod, mpostfix))             sep()   \
  op(block,    (klocals, ksequence, karith_mode))       sep()   \
  op(labeled,  (lname, lexpression))                    sep()   \
  op(exit,     (ename, eexpression))                    sep()   \
  op(match,    (mforce, mexpression, mmatches))         sep()   \
  op(pattern,  (ppattern, pexpression))                 sep()   \
  op(for_loop, (for_vars, for_init, for_exit,                   \
                for_loop_expr, for_body))

/* start mudlle const ; mudlle subst s/^c_/mc:/ */
enum {
  c_fullarg_arg,
  c_fullarg_pat,
  c_fullarg_pat_expr,
  c_fullarg_pat_vars,
  c_fullarg_default_val,
  c_fullarg_fields
};

enum {
  c_arginfo_nargs,
  c_arginfo_noptargs,
  c_arginfo_vararg,
  c_arginfo_fields
};
/* end mudlle const */

enum component_class {
#define __CDEF(name, args) c_ ## name
  FOR_COMPONENT_CLASSES(__CDEF, SEP_COMMA)
#undef __CDEF
};

#define ___FDEF(name) c_ ## name
#define __FDEF(name, args)                                      \
  enum c_ ## name ## _fields {                                  \
    __c_ ## name ## _start = c_loc,                             \
      IF_NO_ARGS args (                                         \
        , FOR_ARGS(___FDEF, SEP_COMMA, EXPAND_ARGS args) ,)     \
      c_ ## name ## _fields                                     \
  }
FOR_COMPONENT_CLASSES(__FDEF, SEP_SEMI);
#undef __FDEF
#undef ___FDEF

#define FOR_PARSER_MODULE_FIELDS(op, sep)                       \
  op(class)    sep() op(name)     sep() op(requires) sep()      \
  op(defines)  sep() op(reads)    sep() op(writes)   sep()      \
  op(statics)  sep() op(body)     sep() op(filename) sep()      \
  op(nicename) sep() op(comments) sep() op(loc)      sep()      \
  op(endloc)

enum parser_module_field {
#define __MDEF(name) m_ ## name
  FOR_PARSER_MODULE_FIELDS(__MDEF, SEP_COMMA),
#undef __MDEF
  parser_module_fields
};

struct modify_component {
  enum builtin_op fn;
  enum arith_mode arith_mode;
  bool postfix;
  struct component *dst;
  struct component *mod;    /* NULL for ++/-- */
};

struct for_component {
  struct vlist *vars;
  struct component *init, *exit, *loop, *expr;
};

struct match_component {
  bool force;                   /* true for "match!" */
  struct component *expression;
  struct match_node_list *matches;
};

struct component {
  enum component_class vclass;
  struct loc loc;
  union {
    struct {
      const char *symbol;
      struct loc symloc;
      struct component *value;
    } assign;
    struct modify_component *modify;
    const char *recall;
    struct constant *cst;
    struct function *closure;
    struct clist *execute;              /* 1st element is fn, rest are args */
    struct {
      enum builtin_op fn : 8;
      enum arith_mode arith_mode : 8;
      struct clist *args;
    } builtin;
    struct block *blk;
    struct {
      const char *name;
      struct component *expression;
    } labeled; /* also for exit */
    struct {
      struct pattern *pattern;
      struct component *expression;
    } pattern;
    struct match_component *match;
    struct for_component *for_loop;
  } u;
};

/* start mudlle const ; mudlle subst s/^f_/mc:m_/ */
enum file_class { f_plain, f_module, f_library };
/* end mudlle const */

struct mfile {
  enum file_class vclass;
  const char *name;
  struct vlist *requires, *defines, *reads, *writes, *statics;
  struct block *body;
  struct loc loc, endloc;
  struct comment_list *comments;
};

struct comment_list {
  struct comment_list *next;
  struct loc start, end;
};

struct mfile *new_file(enum file_class vclass,
                       const char *name,
                       struct vlist *requires, struct vlist *defines,
                       struct vlist *reads, struct vlist *writes,
                       struct vlist *statics, struct vlist *user_vars,
                       struct block *body,
                       const struct loc *loc, const struct loc *endloc);
struct function *new_fn(struct component *avalue,
                        struct function_args *fargs,
                        const struct loc *loc, const struct loc *endloc);
struct block *new_codeblock(struct vlist *locals,
                            struct clist *sequence, const struct loc *loc);
struct clist *new_clist(struct component *c,
                        struct clist *next);
struct cstpair *new_cstpair(struct constant *cst1,
                            struct constant *cst2);
struct cstlist *new_cstlist(struct constant *cst,
                            struct cstlist *next);
bool cstlist_find_symbol_clash(struct cstlist *list, bool ctable,
                               struct cstrlen **s0,
                               struct cstrlen **s1);
bool cstlist_has_len(struct cstlist *list, ulong len);
struct vlist *new_vlist(const char *var,
                        typeset_t typeset, const struct loc *loc,
                        struct vlist *next);
struct vlist *vlist_find(struct vlist *l, const char *s);
unsigned vlist_length(struct vlist *l);

struct function_args *new_function_args(void);
struct function_arg *new_function_arg(const char *var,
                                      typeset_t typeset,
                                      struct function_arg *next,
                                      const struct loc *loc);

struct constant *new_expr_constant(struct component *e);
struct constant *new_unary_constant(enum builtin_op op, struct constant *cst,
                                    const struct loc *loc);
struct constant *new_gone_constant(const struct loc *loc);
struct constant *new_int_constant(long l, enum const_base base,
                                  const struct loc *loc);
struct constant *new_string_constant(const struct cstrlen *str,
                                     const struct loc *loc);
struct constant *new_symbol_constant(struct cstpair *pair,
                                     enum rwmode rwmode,
                                     const struct loc *loc);
struct constant *new_float_constant(double d, enum const_base base,
                                    const struct loc *loc);
struct constant *new_bigint_constant(struct bigint_const *bi,
                                     const struct loc *loc);
struct constant *new_null_constant(const struct loc *loc);
struct constant *new_list_constant(struct cstlist *lst,
                                   enum rwmode rwmode,
                                   const struct loc *loc);
struct constant *new_array_constant(struct cstlist *lst,
                                    enum rwmode rwmode,
                                    const struct loc *loc);
struct constant *new_table_constant(enum constant_class vclass,
                                    struct cstlist *lst,
                                    enum rwmode rwmode,
                                    const struct loc *loc);
struct component *new_const_component(struct constant *cst);
struct component *new_recall_component(const char *sym, const struct loc *loc);
struct component *new_closure_component(
  const struct loc *loc, struct function *f);
struct component *new_block_component(struct block *blk);
struct component *new_execute_component(
  const struct loc *loc, struct clist *clist);

struct component *new_labeled_component(
  const struct loc *loc, const char *name,
  struct component *comp);
struct component *new_exit_component(
  const struct loc *loc, const char *name,
  struct component *comp);

struct component *new_unop_component(
  const struct loc *loc, enum arith_mode arith_mode,
  enum builtin_op op, struct component *e);
struct component *new_binop_component(
  const struct loc *loc, enum arith_mode arith_mode,
  enum builtin_op op, struct component *e1, struct component *e2);
struct component *new_ternop_component(
  const struct loc *loc, enum builtin_op op,
  struct component *e1, struct component *e2, struct component *e3);

bool check_function_arguments(struct function *f);
bool pattern_has_collisions(struct pattern *pat, struct vlist **vl,
                            bool *has_expr);

enum builtin_type {
  btype_normal,                 /* normal builtin_op */
  btype_func,                   /* replaced with function call fname() */
  btype_invalid,                /* invalid in this #arith mode */
  btype_cmp,                    /* replaced with fname() <op> 0 */
};

enum builtin_type builtin_type(const char **fname,
                               enum builtin_op op,
                               enum arith_mode arith_mode,
                               const char *op_suffix,
                               const struct loc *loc);

typeset_t pattern_typeset(struct pattern *pat);

struct component *new_pattern_component(struct pattern *pat,
                                        struct component *e);
struct pattern *new_pattern_or(struct pattern *lhs,
                               struct pattern *rhs,
                               const struct loc *loc);
struct pattern *new_pattern_constant(struct constant *c,
                                     const struct loc *loc);
struct pattern *new_pattern_expression(struct component *c);
struct pattern *new_pattern_and_expr(struct pattern *p,
                                     struct component *c);
struct pattern *new_pattern_variable(const char *sym,
                                     typeset_t typeset, const struct loc *loc);
struct pattern *new_pattern_symbol(struct pattern *sym, struct pattern *val,
                                   const struct loc *loc);
struct pattern *new_array_pattern(struct pattern_list *list,
                                  bool ellipsis,
                                  struct pattern_list *tail,
                                  const struct loc *loc);
struct pattern *new_list_pattern(struct pattern_list *list,
                                 const struct loc *loc);
struct pattern *new_pattern_sink(typeset_t typeset, const struct loc *loc);
struct pattern_list *new_pattern_list(struct pattern *pat,
                                      struct pattern_list *tail);

struct component *new_match_component(bool force,
                                      struct component *e,
                                      struct match_node_list *matches,
                                      const struct loc *loc);
struct component *new_for_component(struct vlist *vars,
                                    struct component *einit,
                                    struct component *eexit,
                                    struct component *eloop,
                                    struct component *e,
                                    const struct loc *loc);
struct match_node_list *new_match_list(struct match_node *node,
                                       struct match_node_list *tail);
struct match_node *new_match_node(struct pattern *pat, struct component *e,
                                  struct vlist *locals, const struct loc *loc);

struct component *new_set_ref_component(struct component *e0,
                                        struct component *e1);

/* return dereferenced value or NULL */
struct component *is_dereference(struct component *e);

struct component *new_increment_expr(enum arith_mode arith_mode,
                                     enum builtin_op op,
                                     struct component *dst,
                                     bool postfix,
                                     const struct loc *loc);
struct component *new_assign_modify_expr(enum arith_mode arith_mode,
                                         enum builtin_op op,
                                         struct component *dst,
                                         struct component *mod,
                                         const struct loc *loc);
struct component *new_assign_expression(struct component *e0,
                                        struct component *e1,
                                        const struct loc *loc,
                                        const struct loc *dstloc);
struct component *new_assign_component(
  const struct loc *loc, const struct loc *symloc, const char *sym,
  struct component *e);

bool set_function_args(struct function *func,
                       struct pattern_list *args);

void parser_expand_component(struct component **cp);

enum mudlle_type constant_type(struct constant *c);

bool is_global_var_name(const char *name);
bool is_user_var_name(const char *name);

#ifdef PRINT_CODE
void print_mudlle_file(FILE *out, struct mfile *f);
#endif

static inline struct clist *reverse_clist(struct clist *l)
{
  return reverse_list(l, struct clist);
}

static inline struct cstlist *reverse_cstlist(struct cstlist *l)
{
  return reverse_list(l, struct cstlist);
}

static inline struct vlist *reverse_vlist(struct vlist *l)
{
  return reverse_list(l, struct vlist);
}

#endif /* TREE_H */
