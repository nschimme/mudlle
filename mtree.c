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

#include "alloc.h"
#include "compile.h"
#include "context.h"
#include "mtree.h"
#include "table.h"
#include "tree.h"

#include "runtime/bigint.h"
#include "runtime/list.h"

static value mudlle_parse_component(struct component *c, bool expand_inline);

static struct list *make_list(enum rwmode rwmode, const struct cstlist *csts)
{
  if (csts == NULL)
    return NULL;

  assert(csts->next != NULL);

  struct list *res = NULL;
  value tail = NULL;
  GCPRO(res, tail);
  for (; csts != NULL; csts = csts->next)
    {
      value this = constant_to_mudlle(csts->cst);
      /* the last entry is the tail element */
      if (csts->next == NULL)
        tail = this;
      else
        res = alloc_list(this, res);
    }
  UNGCPRO();

  assert(res != NULL);          /* silence clang-tidy warning */

  unsigned flags = rwmode == rwmode_rw ? 0 : OBJ_READONLY | OBJ_IMMUTABLE;
  if ((flags & OBJ_IMMUTABLE) && !immutablep(tail))
    flags &= ~OBJ_IMMUTABLE;

  for (struct list *l = res; l != NULL && flags != 0; l = l->cdr)
    {
      value e = l->car;
      if ((flags & OBJ_IMMUTABLE) && !immutablep(e))
        flags &= ~OBJ_IMMUTABLE;
      l->o.flags |= flags;
    }

  struct list *last_pair = res;
  res = mudlle_reverse_list(res);

  assert(last_pair->cdr == NULL);
  last_pair->cdr = tail;

  return res;
}

#ifdef USE_GMP
static struct bigint *make_bigint(const struct bigint_const *bc)
{
  start_mudlle_gmp();
  mpz_t m;
  if (mpz_init_set_str(m, bc->str, bc->base))
    abort();
  if (bc->neg)
    mpz_neg(m, m);
  struct bigint *bi = alloc_bigint(m);
  end_mudlle_gmp();
  return bi;
}
#endif  /* USE_GMP */

static struct vector *make_array(enum rwmode rwmode,
                                 const struct cstlist *csts)
{
  ulong size = 0;
  for (const struct cstlist *scan = csts; scan; scan = scan->next)
    ++size;

  unsigned flags = (rwmode == rwmode_rw && size > 0
                    ? 0
                    : OBJ_READONLY | OBJ_IMMUTABLE);

  struct vector *v = alloc_vector(size);
  GCPRO(v);
  ulong i = 0;
  for (const struct cstlist *scan = csts; scan; scan = scan->next, ++i)
    {
      value val = constant_to_mudlle(scan->cst);
      if ((flags & OBJ_IMMUTABLE) && !immutablep(val))
        flags &= ~OBJ_IMMUTABLE;
      v->data[i] = val;
    }
  UNGCPRO();

  if (rwmode == rwmode_im)
    assert(flags & OBJ_IMMUTABLE);
  v->o.flags |= flags;
  return v;
}

static value unary_cst_to_mudlle(enum builtin_op op, const struct constant *c)
{
  if (c->vclass == cst_float)
    {
      assert(op == b_negate);
      return alloc_float(-c->u.flt.d);
    }
  assert(c->vclass == cst_int);
  long i = c->u.integer.i;
  switch (op)
    {
    case b_negate:      return makeint(-i);
    case b_bitnot:      return makeint(~i);
    case b_logical_not: return makeint(!i);
    default: abort();
    }
}

static struct table *string_cache = NULL;

static void set_string_cache(struct table *t)
{
  assert(string_cache == NULL);
  string_cache = t;
}

void init_string_cache(struct table *tab)
{
  set_string_cache(tab == NULL ? alloc_ctable(DEF_TABLE_SIZE) : tab);
}

void free_string_cache(void)
{
  assert(string_cache != NULL);
  string_cache = NULL;
}

static struct string *internal_scache_alloc_str_len(
  const char *str, size_t len, struct symbol **sym)
{
  *sym = NULL;
  if (string_cache != NULL)
    {
      *sym = table_lookup_len(string_cache, str, len);
      if (*sym != NULL)
        return (*sym)->name;
    }

  struct string *s = make_readonly(alloc_string_length(str, len));
  if (obj_readonlyp(&string_cache->o))
    return s;
  *sym = table_add_fast(string_cache, s, makebool(true));
  return (*sym)->name;
}

struct list *scache_alloc_pair(const char *car, const char *cdr)
{
  assert(string_cache != NULL);

  struct symbol *sym;
  internal_scache_alloc_str_len(car, strlen(car), &sym);
  assert(sym != NULL && !obj_readonlyp(&sym->o));

  if (TYPE(sym->data, pair))
    return sym->data;

  GCPRO(sym);
  struct string *mcdr = scache_alloc_str(cdr);
  struct list *l = make_immutable(alloc_list(sym->name, mcdr));
  UNGCPRO();
  sym->data = l;
  return l;
}

struct string *scache_alloc_str_len(const char *str, size_t len)
{
  if (string_cache == NULL)
    return make_readonly(alloc_string_length(str, len));
  struct symbol *sym;
  return internal_scache_alloc_str_len(str, len, &sym);
}

struct string *scache_alloc_str(const char *str)
{
  return scache_alloc_str_len(str, strlen(str));
}

static struct string *make_string(enum rwmode rwmode,
                                  const struct cstrlen *str)
{
  switch (rwmode)
    {
    case rwmode_im:
    case rwmode_ro:
      return scache_alloc_str_len(str->str, str->len);
    case rwmode_rw:
      return alloc_string_length(str->str, str->len);
    }
  abort();
}

static struct symbol *make_symbol(enum rwmode rwmode, const struct cstpair *p)
{
  /* symbols must have read-only names */
  struct string *s = make_string(rwmode_ro, &p->cst1->u.string);
  GCPRO(s);
  value cst = constant_to_mudlle(p->cst2);
  UNGCPRO();
  unsigned flags = rwmode == rwmode_rw ? 0 : OBJ_READONLY | OBJ_IMMUTABLE;
  if ((flags & OBJ_IMMUTABLE) && !immutablep(cst))
    {
      flags &= ~OBJ_IMMUTABLE;
      assert(rwmode != rwmode_im);
    }
  struct symbol *sym = alloc_symbol(s, cst);
  sym->o.flags |= flags;
  return sym;
}

static struct table *make_table(
  enum rwmode rwmode, const struct cstlist *csts, bool ctable)
{
  ulong l = 0;
  for (const struct cstlist *c = csts; c; c = c->next)
    ++l;
  struct table *t = (ctable ? alloc_ctable : alloc_table)(table_good_size(l));

  unsigned flags = rwmode == rwmode_rw ? 0 : OBJ_READONLY | OBJ_IMMUTABLE;

  GCPRO(t);
  for (; csts; csts = csts->next)
    {
      struct constant *csym = csts->cst;
      assert(csym->vclass == cst_symbol);
      struct symbol *sym = make_symbol(csym->rwmode, csym->u.constpair);
      if ((flags & OBJ_IMMUTABLE) && !immutablep(sym))
        {
          flags &= ~OBJ_IMMUTABLE;
          assert(rwmode != rwmode_im);
        }
      if (table_mlookup(t, sym->name) != NULL)
        abort();
      table_add_sym_fast(t, sym);
    }
  UNGCPRO();

  if (flags & OBJ_IMMUTABLE)
    immutable_table(t);
  else if (flags & OBJ_READONLY)
    protect_table(t);
  return t;
}

value make_shared_string_constant(const struct constant *c,
                                  struct table *cache)
{
  set_string_cache(cache);
  value r = constant_to_mudlle(c);
  if (cache != NULL)
    free_string_cache();
  return r;
}

value constant_to_mudlle(const struct constant *c)
{
  assert(!c->is_dynamic);
  switch (c->vclass)
    {
    case cst_null:   return NULL;
    case cst_string: return make_string(c->rwmode, &c->u.string);
    case cst_list:   return make_list(c->rwmode, c->u.constants);
    case cst_array:  return make_array(c->rwmode, c->u.constants);
    case cst_int:    return makeint(c->u.integer.i);
    case cst_float:  return alloc_float(c->u.flt.d);
    case cst_gone:   return static_gone;
#ifdef USE_GMP
    case cst_bigint: return make_bigint(c->u.bigint);
#else
    case cst_bigint: abort();
#endif
    case cst_ctable: return make_table(c->rwmode, c->u.constants, true);
    case cst_table:  return make_table(c->rwmode, c->u.constants, false);
    case cst_symbol: return make_symbol(c->rwmode, c->u.constpair);
    case cst_unary:  return unary_cst_to_mudlle(c->u.unary.op, c->u.unary.cst);
    case cst_expression: abort();
    }
  abort();
}

static struct vector *mudlle_loc(const struct loc *loc)
{
  struct vector *v = alloc_vector(3);
  v->data[0] = makeint(loc->line);
  v->data[1] = makeint(loc->col);
  v->data[2] = makeint(loc->pos);
  return v;
}

static value mudlle_vlist(struct vlist *vars)
{
  value l = NULL;
  struct list *tail = NULL;
  struct vector *v = NULL;

  GCPRO(l, v, tail);
  for (; vars; vars = vars->next)
    {
      v = alloc_vector(mudlle_vlist_entries);
      struct string *s = vars->var ? scache_alloc_str(vars->var) : NULL;
      SET_VECTOR(v, vl_var,     s);
      SET_VECTOR(v, vl_typeset, makeint(vars->typeset));
      SET_VECTOR(v, vl_loc,     mudlle_loc(&vars->loc));
      struct list *p = alloc_list(v, NULL);
      if (tail == NULL)
        l = p;
      else
        tail->cdr = p;
      tail = p;
    }
  UNGCPRO();
  return l;
}

static value mudlle_clist(struct clist *exprs, bool expand_inline)
{
  struct list *l = NULL, *tail = NULL;
  GCPRO(l, tail);
  for (; exprs; exprs = exprs->next)
    {
      value c = mudlle_parse_component(exprs->c, expand_inline);
      struct list *this = alloc_list(c, NULL);
      if (tail == NULL)
        l = this;
      else
        tail->cdr = this;
      tail = this;
    }
  UNGCPRO();
  return l;
}

static value mopt_component(struct component *c, bool expand_inline)
{
  if (c == NULL)
    return NULL;
  return mudlle_parse_component(c, expand_inline);
}

static value mudlle_parse_pattern(struct pattern *pat, bool expand_inline);

static struct list *mudlle_pattern_list(struct pattern_list *lst,
                                        bool expand_inline)
{
  /* 'lst' should be reverse order already */
  struct list *result = NULL;
  GCPRO(result);
  for (; lst != NULL; lst = lst->next)
    {
      value p = NULL;
      if (lst->pat != NULL)
        p = mudlle_parse_pattern(lst->pat, expand_inline);
      result = alloc_list(p, result);
    }
  UNGCPRO();
  return result;
}

static value mudlle_parse_pattern(struct pattern *pat, bool expand_inline)
{
  static const uint8_t msize[] = {
#define __SDEF(name, args) [pat_ ## name] = pat_ ## name ## _fields
    FOR_PATTERN_CLASSES(__SDEF, SEP_COMMA)
#undef __SDEF
  };

  const uint8_t size = msize[pat->vclass];
  struct vector *mc = alloc_vector(size);

  GCPRO(mc);

#define SET(n, value) do {                      \
  assert((n) < size);                           \
  SET_VECTOR(mc, (n), (value));                 \
} while (0)

  SET(pat_class, makeint(pat->vclass));
  SET(pat_loc,   mudlle_loc(&pat->loc));

  switch (pat->vclass)
    {
    case pat_const:
      SET(pat_cvalue, constant_to_mudlle(pat->u.constval));
      break;
    case pat_list:
      SET(pat_llist, mudlle_pattern_list(pat->u.lst, expand_inline));
      break;
    case pat_array:
      SET(pat_alist, mudlle_pattern_list(pat->u.ary.patlist, expand_inline));
      SET(pat_aellipsis, makebool(pat->u.ary.ellipsis));
      SET(pat_atail, mudlle_pattern_list(pat->u.ary.pattail, expand_inline));
      break;
    case pat_symbol:
      SET(pat_sname,  mudlle_parse_pattern(pat->u.sym.name, expand_inline));
      SET(pat_svalue, mudlle_parse_pattern(pat->u.sym.val, expand_inline));
      break;
    case pat_variable:
      SET(pat_vname,    scache_alloc_str(pat->u.var.name));
      SET(pat_vtypeset, makeint(pat->u.var.typeset));
      break;
    case pat_sink:
      SET(pat_sink_typeset, makeint(pat->u.var.typeset));
      break;
    case pat_expr:
      SET(pat_eexpr, mudlle_parse_component(pat->u.expr, expand_inline));
      break;
    case pat_and:
      SET(pat_and_pat, mudlle_parse_pattern(pat->u.and.pat, expand_inline));
      SET(pat_and_cond, mudlle_parse_component(
            pat->u.and.cond, expand_inline));
      break;
    case pat_or:
      SET(pat_olhs, mudlle_parse_pattern(pat->u.or.lhs, expand_inline));
      SET(pat_orhs, mudlle_parse_pattern(pat->u.or.rhs, expand_inline));
      break;
    }

  UNGCPRO();

  return mc;
}

static struct list *mudlle_match_list(struct match_node_list *lst,
                                      bool expand_inline)
{
  struct list *result = NULL;
  struct vector *v = NULL;
  GCPRO(result, v);
  for (; lst; lst = lst->next)
    {
      struct match_node *node = lst->match;
      v = alloc_vector(3);
      SET_VECTOR(v, 0, mudlle_loc(&node->loc));
      SET_VECTOR(v, 1, mudlle_parse_pattern(node->pattern, expand_inline));
      SET_VECTOR(v, 2, mudlle_parse_component(
                   node->expression, expand_inline));
      result = alloc_list(v, result);
    }
  UNGCPRO();
  return result;
}

static value compound_to_mudlle(const struct constant *c);

static struct list *make_compound_list(const struct cstlist *csts)
{
  if (csts == NULL)
    return compound_to_mudlle(constant_null);

  struct list *head = NULL, *prev = NULL;
  GCPRO(head, prev);
  while (csts != NULL)
    {
      value v = compound_to_mudlle(csts->cst);
      csts = csts->next;
      /* the last element is the tail cdr */
      if (csts != NULL)
        v = alloc_list(v, NULL);
      if (prev == NULL)
        head = v;
      else
        prev->cdr = v;
      prev = v;
    }
  UNGCPRO();

  return head;
}

static struct vector *make_compound_array(const struct cstlist *csts)
{
  ulong size = 0;
  for (const struct cstlist *scan = csts; scan; scan = scan->next)
    ++size;

  struct vector *v = alloc_vector(size);
  GCPRO(v);
  ulong i = 0;
  for (const struct cstlist *scan = csts; scan; scan = scan->next, ++i)
    SET_VECTOR(v, i, compound_to_mudlle(scan->cst));
  UNGCPRO();
  return v;
}

static struct list *make_compound_pair(const struct cstpair *p)
{
  value n = compound_to_mudlle(p->cst1);
  GCPRO(n);
  value v = compound_to_mudlle(p->cst2);
  UNGCPRO();
  return alloc_list(n, v);
}

static struct vector *make_compound_table(const struct cstlist *csts,
                                          bool ctable)
{
  ulong l = 0;
  for (const struct cstlist *c = csts; c; c = c->next)
    ++l;
  struct vector *v = alloc_vector(l);

  GCPRO(v);
  for (long i = 0; csts; csts = csts->next, ++i)
    {
      assert(csts->cst->vclass == cst_symbol);
      SET_VECTOR(v, i, make_compound_pair(csts->cst->u.constpair));
    }
  UNGCPRO();

  return v;
}

static enum const_base constant_base(const struct constant *c)
{
  switch (c->vclass)
    {
    case cst_int: return c->u.integer.base;
    case cst_float: return c->u.flt.base;
    case cst_bigint: return c->u.bigint->base;
    default: abort();
    }
}

static value compound_to_mudlle(const struct constant *c)
{
  struct vector *v = alloc_vector(mudlle_compound_fields);
  GCPRO(v);

  SET_VECTOR(v, mcompound_loc,    mudlle_loc(&c->loc));
  SET_VECTOR(v, mcompound_class,  makeint(c->vclass));
  SET_VECTOR(v, mcompound_rwmode, makeint(c->rwmode));

  value val;
  switch (c->vclass)
    {
    case cst_string:
      SET_VECTOR(v, mcompound_class, NULL);
      /* constant_to_mudlle() fails if is_dynamic */
      val = make_string(rwmode_ro, &c->u.string);
      goto out;
    case cst_int:
    case cst_float:
    case cst_bigint:
      SET_VECTOR(v, mcompound_base, makeint(constant_base(c)));
      FALLTHROUGH;
    case cst_null:
    case cst_gone:
      SET_VECTOR(v, mcompound_class, NULL);
      val = constant_to_mudlle(c);
      goto out;
    case cst_list:
      val = make_compound_list(c->u.constants);
      goto out;
    case cst_array:
      val = make_compound_array(c->u.constants);
      goto out;
    case cst_ctable:
      val = make_compound_table(c->u.constants, true);
      goto out;
    case cst_table:
      val = make_compound_table(c->u.constants, false);
      goto out;
    case cst_symbol:
      val = make_compound_pair(c->u.constpair);
      goto out;
    case cst_unary:
      val = alloc_list(makeint(c->u.unary.op),
                       compound_to_mudlle(c->u.unary.cst));
      goto out;
    case cst_expression:
      val = mudlle_parse_component(c->u.expression, false);
      goto out;
    }
  abort();

 out:
  SET_VECTOR(v, mcompound_value, val);
  UNGCPRO();
  return v;
}

static struct vector *mudlle_func_arginfo(struct function_args *args)
{
  struct vector *v = alloc_vector(c_arginfo_fields);
  SET_VECTOR(v, c_arginfo_nargs,    makeint(args->nargs));
  SET_VECTOR(v, c_arginfo_noptargs, makeint(args->noptargs));
  SET_VECTOR(v, c_arginfo_vararg,
             makebool(args->noptargs > 0 && args->last_arg->is_vararg));
  return v;
}

static struct list *mudlle_func_fullargs(struct function_arg *arg,
                                         bool expand_inline)
{
  struct list *res = NULL, *tail = NULL;
  struct vector *v = NULL, *var = NULL;
  GCPRO(res, tail, v, var);
  for (; arg; arg = arg->next)
    {
      v = alloc_vector(c_fullarg_fields);
      struct list *l = alloc_list(v, NULL);
      if (tail == NULL)
        res = l;
      else
        tail->cdr = l;
      tail = l;

      var = alloc_vector(3);
      SET_VECTOR(var, 0, (arg->name
                          ? scache_alloc_str(arg->name)
                          : makebool(false)));
      value mtypeset = NULL;
      if (!arg->is_vararg)
        {
          typeset_t typeset = arg->typeset;
          if (arg->is_optional)
            typeset |= TYPESET_FLAG_OPTIONAL;
          mtypeset = makeint(typeset);
        }
      SET_VECTOR(var, 1, mtypeset);
      SET_VECTOR(var, 2, mudlle_loc(&arg->loc));

      SET_VECTOR(v, c_fullarg_arg, var);

      if (arg->pat != NULL)
        SET_VECTOR(v, c_fullarg_pat,
                   mudlle_parse_pattern(arg->pat, false));
      if (arg->pat_expr != NULL)
        SET_VECTOR(v, c_fullarg_pat_expr,
                   mudlle_parse_component(arg->pat_expr, expand_inline));
      SET_VECTOR(v, c_fullarg_pat_vars, mudlle_vlist(arg->pat_vars));
      if (arg->default_val != NULL)
        SET_VECTOR(v, c_fullarg_default_val,
                   mudlle_parse_component(arg->default_val, expand_inline));
    }
  UNGCPRO();
  return res;
}

static value mudlle_parse_component(struct component *c, bool expand_inline)
{
  if (get_stack_pointer() < hard_mudlle_stack_limit)
    {
      compile_error(&c->loc, "compiler error: stack limit reached");
      return NULL;
    }

  if (expand_inline)
    parser_expand_component(&c);

  enum component_class class = c->vclass;
  if (class == c_constant && !expand_inline)
    class = c_compound;

  static const uint8_t msize[] = {
#define __SDEF(name, args) [c_ ## name] = c_ ## name ## _fields
    FOR_COMPONENT_CLASSES(__SDEF, SEP_COMMA)
#undef __SDEF
  };

  const uint8_t size = msize[class];
  struct vector *mc = alloc_vector(size);

  GCPRO(mc);

#define SET(n, value) do {                      \
  assert((n) < size);                           \
  SET_VECTOR(mc, (n), (value));                 \
} while (0)

  SET(c_class, makeint(class));
  SET(c_loc,   mudlle_loc(&c->loc));

  switch (class)
    {
    case c_assign:
      SET(c_asymbol, scache_alloc_str(c->u.assign.symbol));
      SET(c_asymloc, mudlle_loc(&c->u.assign.symloc));
      SET(c_avalue,  mudlle_parse_component(c->u.assign.value, expand_inline));
      goto done;

    case c_recall: ;
      SET(c_rsymbol, scache_alloc_str(c->u.recall));
      goto done;

    case c_constant:
      SET(c_cvalue, constant_to_mudlle(c->u.cst));
      goto done;

    case c_compound:
      SET(c_compound_value, compound_to_mudlle(c->u.cst));
      goto done;

    case c_closure: {
      struct function *f = c->u.closure;
      SET(c_freturn_typeset, makeint(f->return_typeset));
      SET(c_fendloc,         mudlle_loc(&f->endloc));
      SET(c_fhelp,           (f->help.len
                              ? scache_alloc_str_len(f->help.str, f->help.len)
                              : NULL));
      SET(c_ffullargs,       mudlle_func_fullargs(f->args->args,
                                                  expand_inline));

      SET(c_farginfo,        mudlle_func_arginfo(f->args));
      SET(c_fvalue,          mudlle_parse_component(f->value, expand_inline));
      SET(c_ffilename,       scache_alloc_str(f->loc.fname->filename));
      SET(c_fnicename,       scache_alloc_str(f->loc.fname->nicename));
      goto done;
    }

    case c_execute:
      SET(c_efnargs, mudlle_clist(c->u.execute, expand_inline));
      goto done;

    case c_builtin:
      SET(c_bfn,   makeint(c->u.builtin.fn));
      SET(c_bargs, mudlle_clist(c->u.builtin.args, expand_inline));
      goto done;

    case c_block:
      SET(c_klocals,   mudlle_vlist(c->u.blk->locals));
      SET(c_ksequence, mudlle_clist(c->u.blk->sequence, expand_inline));
      if (c->u.blk->is_arith)
        SET(c_karith_mode, makeint(c->u.blk->arith_mode));
      goto done;

    case c_labeled:
    case c_exit: ;
      CASSERT((int)c_labeled_fields == (int)c_exit_fields);
      CASSERT((int)c_lname          == (int)c_ename);
      CASSERT((int)c_lexpression    == (int)c_eexpression);
      SET(c_lname, (c->u.labeled.name
                    ? scache_alloc_str(c->u.labeled.name)
                    : NULL));
      SET(c_lexpression, mudlle_parse_component(
            c->u.labeled.expression, expand_inline));
      goto done;

    case c_for_loop:
      SET(c_for_vars,      mudlle_vlist(c->u.for_loop->vars));
      SET(c_for_init,      mopt_component(c->u.for_loop->init, expand_inline));
      SET(c_for_exit,      mopt_component(c->u.for_loop->exit, expand_inline));
      SET(c_for_loop_expr, mopt_component(c->u.for_loop->loop, expand_inline));
      SET(c_for_body,      mudlle_parse_component(
            c->u.for_loop->expr, expand_inline));
      goto done;

    case c_modify:
      SET(c_mfn,  makeint(c->u.modify->fn));
      SET(c_mdst, mudlle_parse_component(c->u.modify->dst, expand_inline));
      SET(c_mmod, mopt_component(c->u.modify->mod, expand_inline));
      SET(c_mpostfix, makebool(c->u.modify->postfix));
      goto done;

    case c_pattern:
      SET(c_ppattern,    mudlle_parse_pattern(
            c->u.pattern.pattern, expand_inline));
      SET(c_pexpression, mudlle_parse_component(
            c->u.pattern.expression, expand_inline));
      goto done;

    case c_match:
      SET(c_mforce,      makebool(c->u.match->force));
      SET(c_mexpression, mudlle_parse_component(
            c->u.match->expression, expand_inline));
      SET(c_mmatches,    mudlle_match_list(
            c->u.match->matches, expand_inline));
      goto done;

    }
  abort();

 done:
  UNGCPRO();
  return mc;

#undef SET
}

value mudlle_parse_expr(struct component *e, bool expand_inline)
{
  init_string_cache(NULL);
  value r = mudlle_parse_component(e, expand_inline);
  free_string_cache();
  return r;
}

value mudlle_parse(struct mfile *f, bool expand_inline)
{
  init_string_cache(NULL);

  struct vector *file = alloc_vector(parser_module_fields);
  GCPRO(file);

  struct component *cbody = new_block_component(f->body);

  SET_VECTOR(file, m_class,    makeint(f->vclass));
  SET_VECTOR(file, m_name,     (f->name
                                ? scache_alloc_str(f->name)
                                : makebool(false)));
  SET_VECTOR(file, m_requires, mudlle_vlist(f->requires));
  SET_VECTOR(file, m_defines,  mudlle_vlist(f->defines));
  SET_VECTOR(file, m_reads,    mudlle_vlist(f->reads));
  SET_VECTOR(file, m_writes,   mudlle_vlist(f->writes));
  SET_VECTOR(file, m_statics,  mudlle_vlist(f->statics));
  SET_VECTOR(file, m_body,     mudlle_parse_component(cbody, expand_inline));
  SET_VECTOR(file, m_filename, scache_alloc_str(f->body->loc.fname->filename));
  SET_VECTOR(file, m_nicename, scache_alloc_str(f->body->loc.fname->nicename));
  SET_VECTOR(file, m_loc,      mudlle_loc(&f->loc));
  SET_VECTOR(file, m_endloc,   mudlle_loc(&f->endloc));

  struct list *comments = NULL;
  if (f->comments != NULL)
    {
      struct vector *loc = NULL;
      struct gcpro gp[2];
      GCPROV(gp[0], comments);
      GCPROV(gp[1], loc);
      for (struct comment_list *c = f->comments; c; c = c->next)
        {
          loc = mudlle_loc(&c->start);
          struct vector *lend = mudlle_loc(&c->end);
          struct list *l = alloc_list(loc, lend);
          comments = alloc_list(l, comments);
        }
      UNGCPROV(gp[0]);
    }
  SET_VECTOR(file, m_comments, comments);

  UNGCPRO();

  free_string_cache();

  return file;
}

void mtree_init(void)
{
  staticpro(&string_cache);
}
