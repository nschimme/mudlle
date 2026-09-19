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

#include "calloc.h"
#include "charset.h"
#include "compile.h"
#include "global.h"
#include "hash.h"
#include "table.h"
#include "tree.h"

#define GEP GLOBAL_ENV_PREFIX

const char *const rwmode_names[] = {
  [rwmode_im] = "#im",
  [rwmode_ro] = "#ro",
  [rwmode_rw] = "#rw"
};

struct alloc_block_node {
  struct alloc_block_node *prev;
  struct alloc_block *block;
};
static struct alloc_block_node *alloc_block_stack;

static inline struct alloc_block *build_heap(void)
{
  return alloc_block_stack->block;
}

struct alloc_block *parser_heap(void)
{
  return build_heap();
}

void push_parser_heap(struct alloc_block *heap)
{
  struct alloc_block_node *node = allocate(heap, sizeof *node);
  *node = (struct alloc_block_node){
    .prev  = alloc_block_stack,
    .block = heap
  };
  alloc_block_stack = node;
}

/* pop the heap, asserting that it's at 'heap' */
void pop_parser_heap(struct alloc_block *heap)
{
  assert(build_heap() == heap);
  alloc_block_stack = alloc_block_stack->prev;
}

const char *const builtin_op_names[] = {
  FOR_BUILTINS(ARGN2, SEP_COMMA)
};
const char *const builtin_op_long_names[] = {
#define _DLN(op, str, lstr) IF_EMPTY(lstr)(str, lstr)
  FOR_BUILTINS(_DLN, SEP_COMMA)
#undef _DLN
};

#define BF(op, n, overflow, nofloat, cmp) [ b_ ## op ] = {      \
    .oflow   = IF_EMPTY(overflow)(NULL, GEP "overflow:" #n),    \
    .bi      = GEP "bi" #n,                                     \
    .bitype  = IF_EMPTY(cmp)(btype_func, btype_cmp),            \
    .flt     = IF_EMPTY(nofloat)(GEP "f" #n, NULL),             \
    .flttype = IF_EMPTY(nofloat)(                               \
      IF_EMPTY(cmp)(btype_func, btype_cmp),                     \
      btype_invalid)                                            \
  }
static struct {
  const char *oflow, *flt, *bi;
  enum builtin_type flttype, bitype;
} builtin_types[] = {
  BF(bitor,       or,  , t, ),
  BF(bitxor,      xor, , t, ),
  BF(bitand,      and, , t, ),
  BF(shift_left,  shl, t, t, ),
  BF(shift_right, shr, t, t, ),
  BF(add,         add, t, , ),
  BF(subtract,    sub, t, , ),
  BF(multiply,    mul, t, , ),
  BF(divide,      div, t, , ),
  BF(remainder,   mod, , , ),
  BF(negate,      neg, t, , ),
  BF(bitnot,      not, , t, ),
  BF(eq,          cmp, , , t),
  BF(ne,          cmp, , , t),
  BF(lt,          cmp, , , t),
  BF(ge,          cmp, , , t),
  BF(le,          cmp, , , t),
  BF(gt,          cmp, , , t)
};

static const char *const arith_mode_names[] = {
#define AM_LNAME(name, lname) IF_EMPTY(lname)(#name, lname)
  FOR_ARITH_MODES(AM_LNAME, SEP_COMMA)
#undef AM_LNAME
};

enum builtin_type builtin_type(const char **fname,
                               enum builtin_op op,
                               enum arith_mode arith_mode,
                               const char *op_suffix,
                               const struct loc *loc)
{
  if (op < 0 || op >= VLENGTH(builtin_types))
    return btype_normal;

  const char *n = NULL;
  enum builtin_type btype;
  switch (arith_mode)
    {
    case arith_float:
      btype = builtin_types[op].flttype;
      n = builtin_types[op].flt;
      goto fname;
    case arith_bigint:
      btype = builtin_types[op].bitype;
      n = builtin_types[op].bi;
      goto fname;
    case arith_overflow:
      n = builtin_types[op].oflow;
      if (n != NULL)
        {
          *fname = n;
          return btype_func;
        }
      return btype_normal;
    case arith_integer:
      if (op == b_add)
        {
          *fname = GEP "iadd";
          return btype_func;
        }
      FALLTHROUGH;
    case arith_default:
      return btype_normal;
    }
  abort();

 fname:
  if (btype == btype_invalid)
    compile_error(loc, "%s%s is not supported in %s mode",
                  builtin_op_names[op], op_suffix,
                  arith_mode_names[arith_mode]);
  else
    *fname = n;
  return btype;
}

bool is_global_var_name(const char *name)
{
  return strncmp(name, GEP, strlen(GEP)) == 0;
}

bool is_user_var_name(const char *name)
{
  return strncmp(name, USER_ENV_PREFIX, strlen(USER_ENV_PREFIX)) == 0;
}

struct mfile *new_file(enum file_class vclass,
                       const char *name,
                       struct vlist *requires, struct vlist *defines,
                       struct vlist *reads, struct vlist *writes,
                       struct vlist *statics, struct vlist *user_vars,
                       struct block *body,
                       const struct loc *loc, const struct loc *endloc)
{
  if (user_vars != NULL)
    for (struct vlist **varp = &statics; ; varp = &(*varp)->next)
      if (*varp == NULL)
        {
          *varp = user_vars;
          break;
        }

  struct mfile *newp = allocate(parser_heap(), sizeof *newp);
  *newp = (struct mfile){
    .vclass   = vclass,
    .name     = name,
    .requires = requires,
    .defines  = defines,
    .reads    = reads,
    .writes   = writes,
    .statics  = statics,
    .body     = body,
    .loc      = *loc,
    .endloc   = *endloc,
  };

  return newp;
}

struct function *new_fn(struct component *avalue,
                        struct function_args *fargs,
                        const struct loc *loc, const struct loc *endloc)
{
  struct function *newp = allocate(parser_heap(), sizeof *newp);
  *newp = (struct function){
    .return_typeset = TYPESET_ANY,
    .value          = avalue,
    .args           = fargs,
    .loc            = *loc,
    .endloc         = *endloc,
  };
  return newp;
}

struct block *new_codeblock(struct vlist *locals,
                            struct clist *sequence, const struct loc *loc)
{
  struct block *newp = allocate(parser_heap(), sizeof *newp);
  *newp = (struct block){
    .locals   = locals,
    .sequence = sequence,
    .loc      = *loc,
    .statics  = false
  };

  return newp;
}

struct clist *new_clist(struct component *c, struct clist *next)
{
  assert(c != NULL);

  struct clist *newp = allocate(parser_heap(), sizeof *newp);
  *newp = (struct clist){
    .next = next,
    .c    = c
  };
  return newp;
}

struct cstlist *new_cstlist(struct constant *cst, struct cstlist *next)
{
  struct cstlist *newp = allocate(parser_heap(), sizeof *newp);
  *newp = (struct cstlist){
    .next       = next,
    .cst        = cst,
    .is_dynamic = (next && next->is_dynamic) || (cst && cst->is_dynamic)
  };
  return newp;
}

bool cstlist_has_len(struct cstlist *list, ulong l)
{
  for (;; list = list->next, --l)
    {
      if (l == 0)
        return true;
      if (list == NULL)
        return false;
    }
}

struct function_args *new_function_args(void)
{
  struct function_args *args = allocate(parser_heap(), sizeof *args);
  *args = (struct function_args){ 0 };
  return args;
}

struct function_arg *new_function_arg(const char *var,
                                      typeset_t typeset,
                                      struct function_arg *next,
                                      const struct loc *loc)
{
  struct function_arg *arg = allocate(parser_heap(), sizeof *arg);
  *arg = (struct function_arg){
    .next    = next,
    .name    = var,
    .typeset = typeset,
    .loc     = *loc
  };
  return arg;
}

struct vlist *new_vlist(const char *var,
                        typeset_t typeset, const struct loc *loc,
                        struct vlist *next)
{
  struct vlist *newp = allocate(parser_heap(), sizeof *newp);
  *newp = (struct vlist){
    .next        = next,
    .var         = var,
    .typeset     = typeset,
    .was_read    = false,
    .was_written = false,
    .loc         = *loc
  };
  return newp;
}

struct vlist *vlist_find(struct vlist *l, const char *s)
{
  for (; l; l = l->next)
    if (strcasecmp(l->var, s) == 0)
      return l;
  return NULL;
}

unsigned vlist_length(struct vlist *l)
{
  unsigned n = 0;
  for (; l; l = l->next)
    ++n;
  return n;
}

static struct constant *alloc_const(enum constant_class vclass,
                                    bool is_dynamic, enum rwmode rwmode,
                                    const struct loc *loc)
{
  struct constant *newp = allocate(parser_heap(), sizeof *newp);
  *newp = (struct constant){
    .vclass     = vclass,
    .is_dynamic = is_dynamic,
    .rwmode        = rwmode,
    .loc        = *loc
  };
  return newp;
}

struct cstpair *new_cstpair(struct constant *cst1,
                            struct constant *cst2)
{
  struct cstpair *newp = allocate(parser_heap(), sizeof *newp);
  *newp = (struct cstpair){ .cst1 = cst1, .cst2 = cst2 };
  return newp;
}

struct constant *new_expr_constant(struct component *e)
{
  struct constant *newp = alloc_const(
    cst_expression, true, rwmode_rw, &e->loc);
  newp->u.expression = e;
  return newp;
}

struct constant *new_unary_constant(enum builtin_op op, struct constant *cst,
                                    const struct loc *loc)
{
  struct constant *newp = alloc_const(
    cst_unary, cst->is_dynamic, rwmode_im, loc);
  newp->u.unary.op = op;
  newp->u.unary.cst = cst;
  return newp;
}

struct constant *new_int_constant(long l, enum const_base base,
                                  const struct loc *loc)
{
  assert(base != 0);
  struct constant *newp = alloc_const(cst_int, false, rwmode_im, loc);
  newp->u.integer = (struct int_and_base){ .i = l, .base = base };
  return newp;
}

struct constant *new_gone_constant(const struct loc *loc)
{
  return alloc_const(cst_gone, false, rwmode_im, loc);
}

struct constant *new_string_constant(const struct cstrlen *str,
                                     const struct loc *loc)
{
  struct constant *newp = alloc_const(cst_string, false, rwmode_ro, loc);
  newp->u.string = *str;
  return newp;
}

static bool rwmode_is_dynamic(enum rwmode rwmode)
{
  return rwmode == rwmode_rw && const_rwmode_is_dynamic();
}

struct constant *new_symbol_constant(struct cstpair *pair,
                                     enum rwmode rwmode,
                                     const struct loc *loc)
{
  bool is_dynamic = (pair->cst1->is_dynamic || pair->cst2->is_dynamic
                     || rwmode_is_dynamic(rwmode));
  struct constant *newp = alloc_const(cst_symbol, is_dynamic, rwmode, loc);
  newp->u.constpair = pair;
  return newp;
}

struct constant *new_float_constant(double d, enum const_base base,
                                    const struct loc *loc)
{
  assert(base != 0);
  struct constant *newp = alloc_const(cst_float, false, rwmode_im, loc);
  newp->u.flt = (struct float_and_base){ .d = d, .base = base };
  return newp;
}

struct constant *new_bigint_constant(struct bigint_const *bi,
                                     const struct loc *loc)
{
  assert(bi->base != 0);
  struct constant *newp = alloc_const(cst_bigint, false, rwmode_im, loc);
  newp->u.bigint = bi;
  return newp;
}

struct constant *new_list_constant(struct cstlist *lst, 
                                   enum rwmode rwmode,
                                   const struct loc *loc)
{
  assert(lst != NULL);
  struct constant *newp = alloc_const(
    cst_list, lst->is_dynamic || rwmode_is_dynamic(rwmode), rwmode, loc);
  newp->u.constants = reverse_cstlist(lst);
  return newp;
}

struct constant *new_null_constant(const struct loc *loc)
{
  return alloc_const(cst_null, false, rwmode_im, loc);
}

static struct constant *new_sequence_constant(
  enum constant_class vclass, struct cstlist *lst,
  enum rwmode rwmode, const struct loc *loc)
{
  assert(vclass == cst_array || vclass == cst_table || vclass == cst_ctable);
  struct constant *newp = alloc_const(
    vclass,
    (lst != NULL && lst->is_dynamic) || rwmode_is_dynamic(rwmode),
    rwmode, loc);
  newp->u.constants = reverse_cstlist(lst);
  return newp;
}

struct constant *new_array_constant(struct cstlist *lst,
                                    enum rwmode rwmode,
                                    const struct loc *loc)
{
  return new_sequence_constant(cst_array, lst, rwmode, loc);
}

struct constant *new_table_constant(enum constant_class vclass,
                                    struct cstlist *lst,
                                    enum rwmode rwmode,
                                    const struct loc *loc)
{
  assert(vclass == cst_table || vclass == cst_ctable);
  return new_sequence_constant(vclass, lst, rwmode, loc);
}

bool cstlist_find_symbol_clash(struct cstlist *list, bool ctable,
                               struct cstrlen **s0,
                               struct cstrlen **s1)
{
  ulong cnt = 0;
  for (struct cstlist *l = list; l; l = l->next)
    {
      struct constant *car = list->cst;
      if (car->vclass == cst_expression)
        continue;
      ++cnt;
    }
  if (cnt < 2)
    return false;

  const ulong hsize = table_good_size(cnt);
  assert((hsize & (hsize - 1)) == 0);
  assert(hsize <= UINT_MAX);
  const int hsize_bits = ffsl(hsize) - 1;

  struct hnode {
    struct hnode *next;
    struct cstrlen *e;
  } **hash = calloc(hsize, sizeof *hash);

  ulong (*hashfn)(const char *name, size_t len, int bits)
    = ctable ? symbol_nhash : symbol_7inhash;
  int (*compare)(const void *a, const void *b, size_t n)
    = ctable ? memcmp : mem7icmp;

  bool result = false;
  for (; list; list = list->next)
    {
      struct constant *car = list->cst;
      if (car->vclass == cst_expression)
        continue;
      assert(car->vclass == cst_symbol);
      struct constant *str = car->u.constpair->cst1;
      if (str->vclass == cst_expression)
        continue;
      assert(str->vclass == cst_string);
      ulong hent = hashfn(str->u.string.str, str->u.string.len, hsize_bits);
      ulong slen = str->u.string.len;
      for (struct hnode *n = hash[hent]; n; n = n->next)
        if (n->e->len == slen
            && compare(n->e->str, str->u.string.str, slen) == 0)
          {
            *s0 = &str->u.string;
            *s1 = n->e;
            result = true;
            goto done;
          }
      struct hnode *n = malloc(sizeof *n);
      *n = (struct hnode){ .next = hash[hent], .e = &str->u.string };
      hash[hent] = n;
    }

 done:
  for (ulong l = 0; l < hsize; ++l)
    for (struct hnode *n = hash[l], *next; n; n = next)
      {
        next = n->next;
        free(n);
      }
  free(hash);
  return result;
}

static struct component *alloc_component(const struct loc *loc,
                                         enum component_class vclass)
{
  struct component *newp = allocate(parser_heap(), sizeof *newp);
  *newp = (struct component){
    .vclass = vclass,
    .loc    = *loc
  };
  return newp;
}

struct component *new_assign_component(
  const struct loc *loc, const struct loc *symloc, const char *sym,
  struct component *e)
{
  assert(sym != NULL);
  struct component *c = alloc_component(loc, c_assign);
  c->u.assign.symloc = *symloc;
  c->u.assign.symbol = sym;
  c->u.assign.value = e;
  return c;
}

static bool can_assign_to(struct component *dst)
{
  switch (dst->vclass)
    {
    case c_builtin:
      switch (dst->u.builtin.fn)
        {
        case b_paren: return can_assign_to(dst->u.builtin.args->c);
        case b_ref: return true;
        default: return false;
        }
    case c_recall:
      return true;
    default:
      return false;
    }
}

static struct component *new_modify_component(const struct loc *loc,
                                              enum arith_mode arith_mode,
                                              enum builtin_op op,
                                              struct component *dst,
                                              struct component *mod,
                                              bool postfix,
                                              const char *what)
{
  const char *fname;
  enum builtin_type btype = builtin_type(
    &fname, op, arith_mode,
    mod != NULL ? "=" : op == b_add ? "+" : "-", loc);
  switch (btype)
    {
    case btype_invalid: return NULL;
    case btype_normal:  arith_mode = arith_default; break;
    case btype_cmp:     abort();
    case btype_func:    break;
    }

  if (!can_assign_to(dst))
    {
      compile_error(&dst->loc, "can only %s variables or references", what);
      return NULL;
    }

  struct component *c = alloc_component(loc, c_modify);
  c->u.modify = allocate(parser_heap(), sizeof *c->u.modify);
  *c->u.modify = (struct modify_component){
    .arith_mode = arith_mode,
    .fn         = op,
    .dst        = dst,
    .mod        = mod,
    .postfix    = postfix
  };
  return c;
}

struct component *new_recall_component(const char *sym, const struct loc *loc)
{
  assert(sym != NULL);
  struct component *c = alloc_component(loc, c_recall);
  c->u.recall = sym;
  return c;
}

struct component *new_const_component(struct constant *cst)
{
  struct component *c = alloc_component(&cst->loc, c_constant);
  c->u.cst = cst;
  return c;
}

struct component *new_closure_component(
  const struct loc *loc, struct function *f)
{
  struct component *c = alloc_component(loc, c_closure);
  c->u.closure = f;
  return c;
}

struct component *new_block_component(struct block *blk)
{
  struct component *c = alloc_component(&blk->loc, c_block);
  c->u.blk = blk;
  return c;
}

struct component *new_labeled_component(
  const struct loc *loc, const char *name,
  struct component *comp)
{
  struct component *c = alloc_component(loc, c_labeled);
  c->u.labeled.name = name;
  c->u.labeled.expression = comp;
  return c;
}

struct component *new_exit_component(
  const struct loc *loc, const char *name,
  struct component *comp)
{
  struct component *c = alloc_component(loc, c_exit);
  c->u.labeled.name = name;
  c->u.labeled.expression = comp;
  return c;
}

struct component *new_execute_component(
  const struct loc *loc, struct clist *clist)
{
  struct component *c = alloc_component(loc, c_execute);
  c->u.execute = clist;
  return c;
}

struct component *new_unop_component(
  const struct loc *loc, enum arith_mode arith_mode,
  enum builtin_op op, struct component *e)
{
  const char *fname;
  enum builtin_type btype = builtin_type(
    &fname, op, arith_mode, "", loc);
  switch (btype)
    {
    case btype_invalid: return NULL;
    case btype_normal:  arith_mode = arith_default; break;
    case btype_cmp:     abort();
    case btype_func:    break;
    }

  struct component *newp = alloc_component(loc, c_builtin);
  newp->u.builtin.fn = op;
  newp->u.builtin.arith_mode = arith_mode;
  newp->u.builtin.args = new_clist(e, NULL);
  return newp;
}

struct pattern *new_pattern_constant(struct constant *c, const struct loc *loc)
{
  struct pattern *ap = allocate(parser_heap(), sizeof *ap);
  *ap = (struct pattern){
    .vclass = pat_const,
    .loc    = *loc,
    .u.constval = c
  };
  return ap;
}

struct pattern *new_pattern_symbol(struct pattern *sym,
                                   struct pattern *val, const struct loc *loc)
{
  if ((pattern_typeset(sym) & TSET(string)) == 0)
    {
      compile_error(&sym->loc, "symbol names must be strings");
      return NULL;
    }

  struct pattern *ap = allocate(parser_heap(), sizeof *ap);
  *ap = (struct pattern){
    .vclass = pat_symbol,
    .loc    = *loc,
    .u.sym = {
      .name = sym,
      .val  = val
    }
  };
  return ap;
}

struct pattern *new_pattern_or(struct pattern *lhs,
                               struct pattern *rhs,
                               const struct loc *loc)
{
  struct pattern *ap = allocate(parser_heap(), sizeof *ap);
  *ap = (struct pattern){
    .vclass = pat_or,
    .loc    = *loc,
    .u.or = {
      .lhs = lhs,
      .rhs = rhs
    }
  };
  return ap;
}

struct pattern *new_pattern_and_expr(struct pattern *p,
                                     struct component *c)
{
  struct pattern *ap = allocate(parser_heap(), sizeof *ap);
  *ap = (struct pattern){
    .vclass = pat_and,
    .loc    = c->loc,
    .u.and = {
      .pat  = p,
      .cond = c
    }
  };
  return ap;
}

struct pattern *new_pattern_expression(struct component *c)
{
  struct pattern *ap = allocate(parser_heap(), sizeof *ap);
  *ap = (struct pattern){
    .vclass = pat_expr,
    .loc    = c->loc,
    .u.expr = c
  };
  return ap;
}

struct pattern *new_pattern_sink(typeset_t typeset, const struct loc *loc)
{
  struct pattern *ap = allocate(parser_heap(), sizeof *ap);
  *ap = (struct pattern){
    .vclass        = pat_sink,
    .loc           = *loc,
    .u.var.typeset = typeset,
  };
  return ap;
}

struct pattern *new_pattern_variable(const char *sym, typeset_t typeset,
                                     const struct loc *loc)
{
  struct pattern *ap = allocate(parser_heap(), sizeof *ap);
  *ap = (struct pattern){
    .vclass = pat_variable,
    .loc    = *loc,
    .u.var = {
      .name    = sym,
      .typeset = typeset
    }
  };
  return ap;
}

static bool patlist_is_const(struct pattern_list *list)
{
  for (struct pattern_list *p = list; p != NULL; p = p->next)
    if (p->pat && p->pat->vclass != pat_const)
      return false;
  return true;
}

static struct cstlist *patlist_to_cstlist(struct pattern_list *list)
{
  struct cstlist *cl = NULL;
  for (struct pattern_list *p = list; p != NULL; p = p->next)
    cl = new_cstlist(p->pat ? p->pat->u.constval : constant_null, cl);
  return reverse_cstlist(cl);
}

struct pattern *new_array_pattern(struct pattern_list *list,
                                  bool ellipsis,
                                  struct pattern_list *tail,
                                  const struct loc *loc)
{
  if (tail != NULL)
    assert(ellipsis);

  if (!ellipsis && patlist_is_const(list))
    {
      struct cstlist *cl = patlist_to_cstlist(list);
      return new_pattern_constant(new_array_constant(cl, rwmode_im, loc), loc);
    }

  struct pattern *ap = allocate(parser_heap(), sizeof *ap);
  *ap = (struct pattern){
    .vclass = pat_array,
    .loc    = *loc,
    .u.ary = {
      .patlist  = list,
      .pattail  = tail,
      .ellipsis = ellipsis
    }
  };
  return ap;
}

struct pattern *new_list_pattern(struct pattern_list *list,
                                 const struct loc *loc)
{
  assert(list != NULL);

  if (patlist_is_const(list))
    {
      struct cstlist *cl = patlist_to_cstlist(list);
      return new_pattern_constant(new_list_constant(cl, rwmode_im, loc), loc);
    }

  struct pattern *ap = allocate(parser_heap(), sizeof *ap);
  *ap = (struct pattern){
    .vclass = pat_list,
    .loc    = *loc,
    .u.lst  = list,
  };
  return ap;
}

struct pattern_list *new_pattern_list(struct pattern *pat,
                                      struct pattern_list *tail)
{
  struct pattern_list *apl = allocate(parser_heap(), sizeof *apl);
  *apl = (struct pattern_list){
    .next = tail,
    .pat  = pat
  };
  return apl;
}

struct match_node_list *new_match_list(struct match_node *node,
                                       struct match_node_list *tail)
{
  struct match_node_list *ml = allocate(parser_heap(), sizeof *ml);
  *ml = (struct match_node_list){
    .next  = tail,
    .match = node
  };
  return ml;
}

struct match_node *new_match_node(struct pattern *pat, struct component *e,
                                  struct vlist *locals, const struct loc *loc)
{
  struct match_node *nd = allocate(parser_heap(), sizeof *nd);
  *nd = (struct match_node){
    .loc        = *loc,
    .pattern    = pat,
    .expression = e,
    .locals     = locals
  };
  return nd;
}

#ifdef PRINT_CODE
static void print_constant(FILE *f, struct constant *c);

static void print_list(FILE *f, struct cstlist *head, bool is_list)
{
  const char *prefix = "";
  for (struct cstlist *l = head; l; l = l->next)
    {
      fputs(prefix, f);
      if (is_list && l->next == NULL)
        {
          if (l->cst == NULL)
            break;
          fputs(". ", f);
        }
      print_constant(f, l->cst);
      prefix = " ";
    }
}

static void print_vlist(FILE *f, struct vlist *l)
{
  int first = true;

  while (l)
    {
      if (!first) fprintf(f, ", ");
      first = false;
      typeset_t t = l->typeset;
      if (t != TYPESET_ANY)
	{
	  fputc('{', f);
	  const char *prefix = "";
	  for (unsigned n = 0; t; ++n, t >>= 1)
	    if (t & 1)
	      {
		fputs(prefix, f);
		prefix = ",";
		fputs(mudlle_type_names[n], f);
	      }
	  fputs("} ", f);
	}
      fputs(l->var, f);
      l = l->next;
    }
}

static void print_component(FILE *f, struct component *c);

static void print_constant(FILE *f, struct constant *c)
{
  switch (c->vclass)
    {
    case cst_null:
      fputs("()", f);
      return;
    case cst_int:
      fprintf(f, "%ld", c->u.integer.i);
      return;
    case cst_gone:
      fputs("#gone", f);
      return;
    case cst_unary:
      fputs(builtin_op_names[c->u.unary.op], f);
      print_constant(f, c->u.unary.cst);
      return;
    case cst_bigint:
      fprintf(f, "#b%s", c->u.bigint->str);
      return;
    case cst_string:
      fprintf(f, "\"%.*s\"" , (int)c->u.string.len, c->u.string.str);
      return;
    case cst_float:
      fprintf(f, "%f", c->u.flt.d);
      return;
    case cst_list:
      fprintf(f, "(");
      if (c->u.constants)
        print_list(f, c->u.constants, true);
      fprintf(f, ")");
      return;
    case cst_array:
      fprintf(f, "[");
      print_list(f, c->u.constants, false);
      fprintf(f, "]");
      return;
    case cst_table:
    case cst_ctable:
      fprintf(f, "{%s", c->vclass == cst_table ? "" : "c ");
      print_list(f, c->u.constants, false);
      fprintf(f, "}");
      return;
    case cst_symbol:
      fputs("<", f);
      print_constant(f, c->u.constpair->cst1);
      fputs("=", f);
      print_constant(f, c->u.constpair->cst2);
      fputs(">", f);
      return;
    case cst_expression:
      fprintf(f, ",(");
      print_component(f, c->u.expression);
      fprintf(f, ")");
      return;
    }
  abort();
}

static void print_block(FILE *f, struct block *c)
{
  struct vlist *vars = c->locals;
  struct clist *sequence = c->sequence;

  fputs("[", f);
  if (vars)
    {
      fputs("|", f);
      print_vlist(f, vars);
      fputs("| ", f);
    }
  const char *prefix = "";
  while (sequence)
    {
      fputs(prefix, f);
      print_component(f, sequence->c);
      prefix = "; ";
      sequence = sequence->next;
    }
  fputc(']', f);
}

static void print_clist(FILE *f, struct clist *sequence)
{
  const char *prefix = "";
  while (sequence)
    {
      fputs(prefix, f);
      print_component(f, sequence->c);
      sequence = sequence->next;
      prefix = ", ";
    }
}

static void print_function(FILE *f, struct function *fn)
{
  fputs("fn ", f);
  if (fn->help.len > 0)
    fprintf(f, "\"%.*s\" ", (int)fn->help.len, fn->help.str);
  fputs("(", f);
  const char *prefix = "";
  for (struct function_arg *args = fn->args->args; args; args = args->next)
    {
      fputs(prefix, f);
      assert((args->name == NULL) != (args->pat == NULL));
      if (args->name != NULL)
        fputs(args->name, f);
      else
        fputs("@...", f);
      prefix = ",";
    }
  fputs(") ", f);
  print_component(f, fn->value);
}

static void print_component(FILE *f, struct component *c)
{
  switch (c->vclass)
    {
    case c_assign:
      fprintf(f, "%s=", c->u.assign.symbol);
      print_component(f, c->u.assign.value);
      return;
    case c_recall:
      fprintf(f, "%s", c->u.recall);
      return;
    case c_pattern:
      fputs("@...=", f);
      print_component(f, c->u.pattern.expression);
      return;
    case c_execute:
      fprintf(f, "exec(");
      print_component(f, c->u.execute->c);
      fputs(", ", f);
      print_clist(f, c->u.execute->next);
      fprintf(f, ")");
      return;
    case c_builtin:
      fprintf(f, "%s(", builtin_op_names[c->u.builtin.fn]);
      print_clist(f, c->u.builtin.args);
      fprintf(f, ")");
      return;
    case c_modify:
      {
        struct component *mod = c->u.modify->mod;
        bool prefix = (mod == NULL && !c->u.modify->postfix);
        const char *op = builtin_op_names[c->u.modify->fn];
        if (prefix)
          fprintf(f, "%s%s", op, op);
        print_component(f, c->u.modify->dst);
        if (!prefix)
          fprintf(f, "%s%s", op, mod == NULL ? op : "=");
        if (mod)
          print_component(f, mod);
        return;
      }
    case c_constant:
    case c_compound:
      print_constant(f, c->u.cst);
      return;
    case c_closure:
      print_function(f, c->u.closure);
      return;
    case c_block:
      print_block(f, c->u.blk);
      return;
    case c_labeled:
      fprintf(f, "<%s>", c->u.labeled.name);
      print_component(f, c->u.labeled.expression);
      return;
    case c_match:
      fprintf(f, "match%s(", c->u.match->force ? "!" : "");
      print_component(f, c->u.match->expression);
      fputs(",...)", f);
      return;
    case c_exit:
      if (c->u.labeled.name) fprintf(f, "exit(<%s>,", c->u.labeled.name);
      else fprintf(f, "exit(");
      print_component(f, c->u.labeled.expression);
      fprintf(f, ")");
      return;
    case c_for_loop:
      fputs("for-loop", f);
      return;
    }
  abort();
}

void print_mudlle_file(FILE *out, struct mfile *f)
{
  static const char *const fnames[] = {
    [f_plain] = "", [f_module] = "module", [f_library] = "library"
  };

  fputs(fnames[f->vclass], out);
  if (f->name) fprintf(out, " %s\n", f->name);
  if (f->requires)
    {
      fprintf(out, "requires ");
      print_vlist(out, f->requires);
      fprintf(out, "\n");
    }
  if (f->defines)
    {
      fprintf(out, "defines ");
      print_vlist(out, f->defines);
      fprintf(out, "\n");
    }
  if (f->reads)
    {
      fprintf(out, "reads ");
      print_vlist(out, f->reads);
      fprintf(out, "\n");
    }
  if (f->writes)
    {
      fprintf(out, "writes ");
      print_vlist(out, f->writes);
      fprintf(out, "\n");
    }
  {
    struct alloc_block *oops = new_block();
    push_parser_heap(oops);
    print_component(out, new_block_component(f->body));
    pop_parser_heap(oops);
    free_block(oops);
  }
}

#endif

struct component *new_binop_component(
  const struct loc *loc,
  enum arith_mode arith_mode, enum builtin_op op,
  struct component *e1, struct component *e2)
{
  const char *fname;
  enum builtin_type btype = builtin_type(
    &fname, op, arith_mode, "", loc);
  switch (btype)
    {
    case btype_invalid: return NULL;
    case btype_normal:  arith_mode = arith_default; break;
    case btype_cmp:     break;
    case btype_func:    break;
    }

  struct component *newp = alloc_component(loc, c_builtin);
  newp->u.builtin.fn = op;
  newp->u.builtin.arith_mode = arith_mode;
  newp->u.builtin.args = new_clist(e1, new_clist(e2, NULL));
  return newp;
}

struct component *new_ternop_component(const struct loc *loc,
                                       enum builtin_op op,
                                       struct component *e1,
                                       struct component *e2,
                                       struct component *e3)
{
  struct component *newp = alloc_component(loc, c_builtin);
  newp->u.builtin.fn = op;
  newp->u.builtin.arith_mode = arith_default;
  newp->u.builtin.args = new_clist(
    e1, new_clist(e2, new_clist(e3, NULL)));
  return newp;
}

struct collision_info {
  struct vlist *vlist;
  const char *what;
  bool has_expr;
};

static bool pat_has_collisions(struct pattern *pat,
                               struct collision_info *info);

static bool pat_list_has_collisions(struct pattern_list *pl,
                                    struct collision_info *info)
{
  if (pl == NULL)
    return false;

  if (pat_list_has_collisions(pl->next, info))
    return true;

  return pl->pat != NULL && pat_has_collisions(pl->pat, info);
}

static bool pat_or_has_collisions(struct pattern *pat,
                                  struct collision_info *info)
{
  struct vlist *orig_vl = info->vlist;

  if (pat_has_collisions(pat->u.or.lhs, info))
    return true;

  struct vlist *lhs_vl = info->vlist;
  info->vlist = orig_vl;

  if (pat_has_collisions(pat->u.or.rhs, info))
    return true;

  /* make vlist_find() cheaper below */
  struct vlist *orig_vl_next = NULL;
  if (orig_vl)
    {
      orig_vl_next = orig_vl->next;
      orig_vl->next = NULL;
    }

  struct vlist *rhs = info->vlist;
  info->vlist = lhs_vl;

  /* add elements from 'rhs' not already present in 'lhs' */
  for (struct vlist *next; rhs != orig_vl; rhs = next)
    {
      next = rhs->next;
      if (!vlist_find(info->vlist, rhs->var))
        {
          rhs->next = info->vlist;
          info->vlist = rhs;
        }
    }

  if (orig_vl)
    orig_vl->next = orig_vl_next;
  return false;
}

static bool var_has_collision(const char *name, const struct loc *loc,
                              struct collision_info *info)
{
  if (vlist_find(info->vlist, name))
    {
      compile_error(loc, "duplicate %s name %s%s%s", info->what,
                    CMARKUP(var, name));
      return true;
    }

  info->vlist = new_vlist(name, TYPESET_ANY, loc, info->vlist);
  return false;
}

static bool pat_has_collisions(struct pattern *pat,
                               struct collision_info *info)
{
  switch (pat->vclass)
    {
    case pat_and:
      info->has_expr = true;
      return pat_has_collisions(pat->u.and.pat, info);
    case pat_expr:
      info->has_expr = true;
      return false;
    case pat_sink:
    case pat_const:
      return false;
    case pat_symbol:
      return (pat_has_collisions(pat->u.sym.name, info)
              || pat_has_collisions(pat->u.sym.val, info));
    case pat_list:
      return pat_list_has_collisions(pat->u.lst, info);
    case pat_array:
      return (pat_list_has_collisions(pat->u.ary.patlist, info)
              || pat_list_has_collisions(pat->u.ary.pattail, info));
    case pat_variable:
      return (!is_global_var_name(pat->u.var.name)
              && !is_user_var_name(pat->u.var.name)
              && var_has_collision(pat->u.var.name, &pat->loc, info));
    case pat_or:
      return pat_or_has_collisions(pat, info);
    }
  abort();
}

bool pattern_has_collisions(struct pattern *pat, struct vlist **vl,
                            bool *has_expr)
{
  struct collision_info info = { .what = "match pattern" };
  bool result = pat_has_collisions(pat, &info);
  if (vl != NULL)
    *vl = info.vlist;
  if (has_expr != NULL)
    *has_expr = info.has_expr;
  return result;
}

bool check_function_arguments(struct function *func)
{
  struct collision_info cinfo = {
    .what = "argument"
  };

  for (struct function_arg *args = func->args->args; args; args = args->next)
    {
      assert((args->name == NULL) != (args->pat == NULL));
      if (args->pat != NULL
          ? pat_has_collisions(args->pat, &cinfo)
          : var_has_collision(args->name, &args->loc, &cinfo))
        return false;
    }

  return true;
}

enum mudlle_type constant_type(struct constant *c)
{
  switch (c->vclass)
    {
    case cst_null:       return type_null;
    case cst_gone:       return type_gone;
    case cst_string:     return type_string;
    case cst_list:       return type_pair;
    case cst_array:      return type_vector;
    case cst_int:        return type_integer;
    case cst_float:      return type_float;
    case cst_bigint:     return type_bigint;
    case cst_ctable:     return type_table;
    case cst_table:      return type_table;
    case cst_symbol:     return type_symbol;
    case cst_expression: return stype_any;
    case cst_unary:      return constant_type(c->u.unary.cst);
    }
  abort();
}

typeset_t pattern_typeset(struct pattern *pat)
{
  switch (pat->vclass)
    {
    case pat_const:
      return TSBIT(constant_type(pat->u.constval));
    case pat_list:
      return TSET(pair);
    case pat_array:
      return TSET(vector);
    case pat_symbol:
      return TSET(symbol);
    case pat_and:
      return pattern_typeset(pat->u.and.pat);
    case pat_or:
      return (pattern_typeset(pat->u.or.lhs)
              | pattern_typeset(pat->u.or.rhs));
    case pat_variable:
    case pat_sink:
      return pat->u.var.typeset;
    case pat_expr:
      return TYPESET_ANY;
    }
  abort();
}

struct component *new_pattern_component(struct pattern *pat,
                                        struct component *e)
{
  struct component *c = alloc_component(&pat->loc, c_pattern);
  c->u.pattern.pattern    = pat;
  c->u.pattern.expression = e;
  return c;
}

struct component *new_for_component(struct vlist *vars,
                                    struct component *einit,
                                    struct component *eexit,
                                    struct component *eloop,
                                    struct component *e,
                                    const struct loc *loc)
{
  struct component *c = alloc_component(loc, c_for_loop);
  c->u.for_loop = allocate(parser_heap(), sizeof *c->u.for_loop);
  *c->u.for_loop = (struct for_component){
    .vars = vars,
    .init = einit,
    .exit = eexit,
    .loop = eloop,
    .expr = e
  };
  return c;
}

struct component *new_match_component(bool force,
                                      struct component *e,
                                      struct match_node_list *matches,
                                      const struct loc *loc)
{
  struct component *c = alloc_component(loc, c_match);
  c->u.match = allocate(parser_heap(), sizeof *c->u.match);
  *c->u.match = (struct match_component){
    .force      = force,
    .expression = e,
    .matches    = matches
  };
  return c;
}

struct component *new_increment_expr(enum arith_mode arith_mode,
                                     enum builtin_op op,
                                     struct component *dst,
                                     bool postfix,
                                     const struct loc *loc)
{
  assert(op == b_add || op == b_subtract);
  return new_modify_component(loc, arith_mode, op, dst, NULL, postfix,
                              op == b_add ? "increment" : "decrement");
}

/* for +=, |=, ++, etc. */
struct component *new_assign_modify_expr(enum arith_mode arith_mode,
                                         enum builtin_op op,
                                         struct component *dst,
                                         struct component *mod,
                                         const struct loc *loc)
{
  return new_modify_component(loc, arith_mode, op, dst, mod, false,
                              "assign to");
}

struct component *new_assign_expression(struct component *e0,
                                        struct component *e1,
                                        const struct loc *loc,
                                        const struct loc *dstloc)
{
  if (!((e0->vclass == c_builtin && e0->u.builtin.fn == b_ref)
        || e0->vclass == c_recall))
    {
      compile_error(&e0->loc, "can only assign to variables or references");
      return NULL;
    }
  return new_binop_component(loc, arith_default, b_assign, e0, e1);
}
