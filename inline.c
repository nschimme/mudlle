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
#include "compile.h"
#include "global.h"
#include "inline.h"
#include "tree.h"

#define GEP GLOBAL_ENV_PREFIX

/* helper structure for building a sequence of components and variables */
struct code_state {
  struct component *top;        /* topmost component; the final result */
  struct component **dst;       /* where to add new components */
  struct clist *clist;          /* pending clist */
  struct vlist *vlist;          /* pending vlist */
};

#define CODE_STATE_UNSET ((struct component *)5L)

static void code_state_flush_block(struct code_state *state)
{
  if (state->vlist == NULL && state->clist == NULL)
    return;
  assert(*state->dst == CODE_STATE_UNSET);
  struct clist *tail_clist = new_clist(CODE_STATE_UNSET, state->clist);
  *state->dst = new_block_component(
    new_codeblock(reverse_vlist(state->vlist),
                  reverse_clist(tail_clist),
                  NO_LOC));
  state->dst = &tail_clist->c;
  state->clist = NULL;
  state->vlist = NULL;
}

/* call this first */
UNUSED static void code_state_init(struct code_state *state)
{
  *state = (struct code_state){
    .top = CODE_STATE_UNSET,
    .dst = &state->top
  };
}

UNUSED static void code_state_add_comp(struct code_state *state,
                                       struct component *comp)
{
  state->clist = new_clist(comp, state->clist);
}

UNUSED static void code_state_add_var(
  struct code_state *state, const char *var, typeset_t typeset,
  const struct loc *loc)
{
  if (state->clist != NULL)
    code_state_flush_block(state);
  state->vlist = new_vlist(var, typeset, loc, state->vlist);
}

UNUSED static void code_state_add_vlist(struct code_state *state,
                                        struct vlist *vlist)
{
  if (vlist == NULL)
    return;

  if (state->clist != NULL)
    code_state_flush_block(state);
  while (vlist != NULL)
    {
      struct vlist *next = vlist->next;
      vlist->next = state->vlist;
      state->vlist = vlist;
      vlist = next;
    }
}

/* call this last; returns the result */
UNUSED static struct component *code_state_close(
  struct code_state *state, struct component *expr)
{
  code_state_flush_block(state);
  assert(*state->dst == CODE_STATE_UNSET);
  *state->dst = expr;
  struct component *result = state->top;
  code_state_init(state);
  return result;
}

typedef struct component *(*match_err_fn)(void *data);

struct mvar {
  const char *name;
  const struct loc *loc;
};

#define MVAR(n, l) &(const struct mvar){ .name = (n), .loc = (l) }

/* ... are pointers to const struct mvar */
static struct vlist *build_vlist(size_t n, ...)
{
  va_list args;
  va_start(args, n);
  struct vlist *res = NULL;
  for (size_t i = 0; i < n; ++i)
    {
      const struct mvar *mvar = va_arg(args, const struct mvar *);
      if (mvar->name == NULL)
        continue;
      res = new_vlist(mvar->name, TYPESET_ANY, mvar->loc, res);
    }
  va_end(args);
  return res;
}

static struct clist *build_clist(int n, ...)
{
  va_list args;
  struct clist *res = NULL;

  va_start(args, n);
  while (n-- > 0)
    {
      struct component *c = va_arg(args, struct component *);
      if (c == NULL)
        continue;
      res = new_clist(c, res);
    }
  va_end(args);

  return reverse_clist(res);
}

static struct component *new_int_component(long n)
{
  return new_const_component(new_int_constant(n, cstbase_decimal, NO_LOC));
}

static struct component *build_codeblock(struct vlist *vl, struct clist *code)
{
  return new_block_component(new_codeblock(vl, code, NO_LOC));
}

static struct component *build_unop(enum builtin_op op, struct component *e)
{
  return new_unop_component(NO_LOC, arith_default, op, e);
}

static struct component *build_if(struct component *cond,
                                  struct component *ctrue)
{
  return new_binop_component(NO_LOC, arith_default, b_if, cond, ctrue);
}

static struct component *build_unless(struct component *cond,
                                      struct component *otherwise)
{
  return build_if(build_unop(b_logical_not, cond), otherwise);
}

static struct component *build_exit(const char *name, struct component *c)
{
  return new_exit_component(NO_LOC, name, c);
}

static struct component *build_exec(struct component *f, const struct loc *loc,
                                    int n, ...)
{
  va_list args;
  struct clist *res = new_clist(f, NULL);

  va_start(args, n);
  while (n--)
    res = new_clist(va_arg(args, struct component *), res);
  va_end(args);

  return new_execute_component(loc, reverse_clist(res));
}

static inline struct component *set_loc(
  const struct loc *loc, struct component *c)
{
  c->loc = *loc;
  return c;
}

static struct component *build_const_not_equal(const struct loc *loc,
                                               struct constant *cst,
                                               struct component *e)
{
  switch (constant_type(cst))
    {
    case type_null:
    case type_integer:
      return new_binop_component(loc, arith_default, b_ne, e,
                                 new_const_component(cst));
    default:
      return set_loc(
        loc,
        build_unop(b_logical_not,
                   set_loc(loc,
                           build_exec(new_recall_component(GEP "equal?", loc),
                                      loc, 2, new_const_component(cst), e))));
    }
}

static struct component *build_typecheck(const struct loc *loc,
                                         struct component *e,
                                         enum mudlle_type type)
{
  const char *f = NULL;

  switch (type)
    {
    case type_icode:
    case type_variable:
    case type_internal:
    case type_private:
    case type_mcode:
    case type_weak_ref:
      return new_binop_component(
        loc, arith_default, b_eq,
        build_exec(new_recall_component(GEP "typeof", loc), loc, 1, e),
        new_int_component(type));

    case type_closure:      f = GEP "closure?";      break;
    case type_primitive:    f = GEP "primitive?";    break;
    case type_varargs:      f = GEP "varargs?";      break;
    case type_secure:       f = GEP "secure?";       break;
    case type_integer:      f = GEP "integer?";      break;
    case type_string:       f = GEP "string?";       break;
    case type_vector:       f = GEP "vector?";       break;
    case type_pair:         f = GEP "pair?";         break;
    case type_symbol:       f = GEP "symbol?";       break;
    case type_table:        f = GEP "table?";        break;
    case type_object:       f = GEP "object?";       break;
    case type_character:    f = GEP "character?";    break;
    case type_gone:         f = GEP "gone?";         break;
    case type_oport:        f = GEP "port?";         break;
    case type_float:        f = GEP "float?";        break;
    case type_bigint:       f = GEP "bigint?";       break;
    case type_connection:   f = GEP "connection?";   break;
    case type_cookie:       f = GEP "magic_cookie?"; break;
    case type_regexp:       f = GEP "regexp?";       break;
    case type_file:         f = GEP "file?";         break;

    case stype_list:        f = GEP "list?";         break;
    case stype_function:    f = GEP "function?";     break;
    case stype_float_like:  f = GEP "float_like?";   break;
    case stype_bigint_like: f = GEP "bigint_like?";  break;

    case type_null:
      return new_binop_component(
        loc, arith_default, b_eq, e,
        new_const_component(constant_null));

    case stype_none:
      return component_false;
    case stype_any:
      return component_true;

    case stype_false:
      return new_binop_component(
        loc, arith_default, b_eq, e,
        component_false);

    case mudlle_synthetic_types:
      abort();
    }

  assert(f != NULL);

  return build_exec(new_recall_component(f, loc), loc, 1, e);
}

/* true if 'c' is a recall of a single-assignment variable */
static bool is_safe_recall(struct component *c)
{
  return c->vclass == c_recall && c->u.recall[0] == '%';
}

static struct component *make_local_var(struct vlist **locals, int level,
                                        const struct loc *loc)
{
  /* room for '%' '-' <digits> '\0' */
  char buf[1 + 1 + BITS_DECIMAL_DIG(CHAR_BIT * sizeof level - 1) + 1];
  int r = snprintf(buf, sizeof buf, "%%%d", level);
  assert(r >= 0 && (unsigned)r < sizeof buf);
  const char *tmpname = heap_allocate_string(parser_heap(), buf);
  *locals = new_vlist(tmpname, TYPESET_ANY, loc, *locals);
  return new_recall_component(tmpname, loc);
}

static bool parser_expand_paren(struct component **cp)
{
  bool result = false;
  while ((*cp)->vclass == c_builtin && (*cp)->u.builtin.fn == b_paren)
    {
      *cp = (*cp)->u.builtin.args->c;
      result = true;
    }
  return result;
}

static struct component *comp_id(struct component *e)
{
  return e;
}

static struct component *comp_set_tmp(struct component *e)
{
  return new_assign_component(NO_LOC, NO_LOC, "%tmp", e);
}

static struct component *parser_expand_assign(struct component *c)
{
  assert(c->vclass == c_builtin && c->u.builtin.fn == b_assign);

  struct component *dst = c->u.builtin.args->c;
  struct component *val = c->u.builtin.args->next->c;

  if (dst->vclass == c_builtin && dst->u.builtin.fn == b_ref)
    {
      struct clist *args = dst->u.builtin.args;
      return new_ternop_component(&c->loc, b_set,
                                  args->c, args->next->c, val);
    }

  if (dst->vclass == c_recall)
    {
      if (val->vclass == c_closure)
        val->loc = dst->loc;
      return new_assign_component(&c->loc, &dst->loc, dst->u.recall, val);
    }

  abort();
}

static struct component *parser_expand_modify(struct component *c)
{
  assert(c->vclass == c_modify);

  /* needed for the destination type checks below */
  parser_expand_paren(&c->u.modify->dst);

  const struct loc *loc = &c->loc;

  struct component *(*set_tmp)(struct component *) = comp_id;
  struct component *ret = NULL;
  const char *tmp_name = NULL;
  if (c->u.modify->postfix)
    {
      set_tmp = comp_set_tmp;
      tmp_name = "%tmp";
      ret = new_recall_component(tmp_name, loc);
    }

  struct component *dst = c->u.modify->dst;
  bool is_incrementer = c->u.modify->mod == NULL;
  struct component *mod = is_incrementer ? component_one : c->u.modify->mod;
  enum arith_mode arith_mode = c->u.modify->arith_mode;
  enum builtin_op op = c->u.modify->fn;

  if (dst->vclass == c_builtin && dst->u.builtin.fn == b_ref)
    {
      struct clist *args = dst->u.builtin.args;
      struct component *lexp = args->c, *lref = args->next->c;
      struct vlist *vl;
      struct clist *cl;
      if (lref->vclass == c_constant && lref->u.cst->vclass == cst_string)
        {
          vl = build_vlist(
            2,
            MVAR(tmp_name, &dst->loc),
            MVAR("%sym", &lref->loc));
          cl = build_clist(
            3,
            new_assign_component(
              loc, NO_LOC, "%sym",
              build_exec(new_recall_component(GEP "symbol_ref", &dst->loc),
                         &dst->loc, 2, lexp, lref)),
            build_exec(
              new_recall_component(GEP "symbol_set!", loc), loc, 2,
              new_recall_component("%sym", loc),
              new_binop_component(
                loc, arith_mode, op,
                set_tmp(build_exec(
                          new_recall_component(GEP "symbol_get", &dst->loc),
                          &dst->loc, 1,
                          new_recall_component("%sym", &dst->loc))),
                mod)),
            ret);
        }
      else
        {
          vl = build_vlist(
            3,
            MVAR(tmp_name, &dst->loc),
            MVAR("%ref", &lref->loc),
            MVAR("%exp", &lexp->loc));
          cl = build_clist(
            4,
            new_assign_component(loc, NO_LOC, "%exp", lexp),
            new_assign_component(loc, NO_LOC, "%ref", lref),
            new_ternop_component(
              loc, b_set,
              new_recall_component("%exp", loc),
              new_recall_component("%ref", loc),
              new_binop_component(
                loc, arith_mode, op,
                set_tmp(new_binop_component(
                          loc, arith_default, b_ref,
                          new_recall_component("%exp", loc),
                          new_recall_component("%ref", loc))),
                mod)),
            ret);
        }
      return build_codeblock(vl, cl);
    }

  if (dst->vclass == c_recall)
    {
      struct vlist *vl = build_vlist(
        1, MVAR(tmp_name, &dst->loc));
      struct clist *cl = build_clist(
        2,
        new_assign_component(
          loc, &dst->loc, dst->u.recall,
          new_binop_component(loc, arith_mode, op, set_tmp(dst), mod)),
        ret);
      /* optimize for common case */
      if (vl == NULL && cl->next == NULL)
        return cl->c;
      return build_codeblock(vl, cl);
    }

  abort();
}

static struct component *make_safe_copy(struct component *e,
                                        struct vlist **locals,
                                        struct component **aexpr,
                                        int level, const struct loc *loc)
{
  if (is_safe_recall(e))
    return e;

  struct component *recall = make_local_var(locals, level, loc);
  assert(recall->vclass == c_recall);
  *aexpr = new_assign_component(loc, &recall->loc, recall->u.recall, e);
  return recall;
}

static struct component *build_match_block(
  struct pattern *pat, struct component *e, int level,
  match_err_fn err, void *err_data);

static struct component *build_symbol_name_check(
  struct pattern *pat, struct component *e, int level,
  match_err_fn err, void *err_data)
{
  switch (pat->vclass)
    {
    case pat_sink:
      if (pat->u.var.typeset == TYPESET_ANY)
        return NULL;
      FALLTHROUGH;
    case pat_and:
    case pat_or:
    case pat_variable:
      return build_match_block(pat, e, level, err, err_data);
    case pat_expr:
      {
        struct vlist *locals = NULL;
        struct component *lassign = NULL;
        struct component *nexp = make_safe_copy(pat->u.expr, &locals, &lassign,
                                                level, &pat->loc);
        return build_codeblock(
          locals,
          build_clist(
            2,
            lassign,
            build_unless(
              new_binop_component(
                &pat->loc, arith_default, b_logical_and,
                build_typecheck(&pat->loc, nexp, type_string),
                build_exec(new_recall_component(
                             GEP "string_iequal?", &pat->loc),
                           &pat->loc, 2, nexp, e)),
              err(err_data))));
      }
    case pat_const:
      {
        struct constant *cst = pat->u.constval;
        if (cst->vclass == cst_string)
          return build_unless(
            build_exec(new_recall_component(GEP "string_iequal?", &pat->loc),
                       &pat->loc, 2, new_const_component(cst), e),
            err(err_data));
      }
      FALLTHROUGH;
    case pat_list:
    case pat_array:
    case pat_symbol:
      abort();
    }
  abort();
}

static struct component *next_error(void *count)
{
  ++*(int *)count;
  return build_exit("%next", component_undefined);
}

static struct component *cause_no_match_error(void *data)
{
  struct component *val = data;
  const struct loc *loc = &val->loc;
  return build_exec(new_recall_component(GEP "fail_no_match", loc),
                    loc, 1, val);
}

static struct component *parser_expand_match(struct component *c)
{
  assert(c->vclass == c_match);

  /*
   *   <$match> [
   *     | $exp |
   *
   *     $exp = <match-expression>
   *     <$next> [                               \
   *       | <pattern-variables> |                |
   *       if (<pattern-match>)                   +- repeat for each match node
   *         exit<$match> <pattern-expression>;   |
   *     ]                                       /
   *     false
   *   ]
   */

  struct vlist *vl = build_vlist(
    1, MVAR("%exp", &c->u.match->expression->loc));
  struct clist *code = build_clist(1, component_false);
  bool force = c->u.match->force;
  for (struct match_node_list *matches = c->u.match->matches;
       matches;
       matches = matches->next)
    {
      int next_count = 0;
      match_err_fn err = next_error;
      void *err_data = &next_count;
      if (force)
        {
          err = cause_no_match_error;
          err_data = new_recall_component("%exp", &c->loc);
          force = false;
        }
      struct component *matchcode = build_match_block(
        matches->match->pattern,
        new_recall_component("%exp", &matches->match->pattern->loc),
        0, err, err_data);
      struct component *cexit = set_loc(
        &matches->match->loc,
        build_exit("%match", matches->match->expression));

      struct clist *cl = build_clist(2, matchcode, cexit);

      struct component *cblock = build_codeblock(matches->match->locals, cl);
      cblock->u.blk->loc = matches->match->loc;

      if (next_count)
        cblock = new_labeled_component(NO_LOC, "%next", cblock);

      code = new_clist(cblock, code);
    }

  code = new_clist(
    new_assign_component(NO_LOC, NO_LOC, "%exp", c->u.match->expression),
    code);

  return new_labeled_component(
    NO_LOC, "%match", build_codeblock(vl, code));
}

static struct component *parser_expand_pattern(struct component *c)
{
  assert(c->vclass == c_pattern);

  /* Warning: if the match fails, this might leave only some of the variables
   * in the pattern filled. But it's a feature, right? */
  struct vlist *locals = NULL;
  struct component *aexpr = NULL;
  struct component *val = make_safe_copy(
    c->u.pattern.expression, &locals, &aexpr, 0, &c->loc);
  return build_codeblock(
    locals,
    build_clist(
      3,
      aexpr,
      build_match_block(c->u.pattern.pattern, val,
                        0, cause_no_match_error, val),
      component_undefined));
}

static int patlist_len(struct pattern_list *l)
{
  int n = 0;
  for (; l != NULL; l = l->next)
    ++n;
  return n;
}

static struct clist *build_patarray_match(
  struct clist *code, struct component *elocal,
  struct pattern_list *l, int idx, int level,
  match_err_fn err, void *err_data)
{
  for (; l != NULL; l = l->next)
    {
      --idx;
      struct component *c = build_match_block(
        l->pat, new_binop_component(&l->pat->loc, arith_default, b_ref,
                                    elocal, new_int_component(idx)),
        level + 1, err, err_data);
      if (c != NULL)
        code = new_clist(c, code);
    }
  return code;
}

static struct component *build_vlength(struct component *v,
                                       const struct loc *loc)
{
  return build_exec(new_recall_component(GEP "vlength", loc), loc, 1, v);
}

static struct component *build_match_array_block(
  struct pattern *pat, struct component *e, int level,
  match_err_fn err, void *err_data)
{
  /*
   *  [
   *    | tmp |
   *    tmp = <expression>;
   *    (vector?(tmp) &&
   *     vlength(tmp) == vlength(<pattern>) &&
   *     tmp[0] == <pattern>[0] &&
   *          :
   *     tmp[N] == <pattern>[N])
   *  ]
   */

  struct component *eassign = NULL;
  struct vlist *vlocals = NULL;
  struct component *elocal = make_safe_copy(e, &vlocals, &eassign, level,
                                            &pat->loc);

  int vlen = patlist_len(pat->u.ary.patlist);
  int tlen = patlist_len(pat->u.ary.pattail);

  struct component *lc = NULL;
  if (!pat->u.ary.ellipsis || (vlen + tlen) > 0)
    lc = set_loc(
      &pat->loc,
      build_if(
        new_binop_component(
          &pat->loc, arith_default, pat->u.ary.ellipsis ? b_lt : b_ne,
          build_vlength(elocal, &pat->loc),
          new_int_component(vlen + tlen)),
        err(err_data)));

  struct component *tc = set_loc(
    &pat->loc,
    build_unless(
      build_exec(new_recall_component(GEP "vector?", &pat->loc),
                 &pat->loc, 1, elocal),
      err(err_data)));

  struct clist *code = build_patarray_match(
    NULL, elocal, pat->u.ary.pattail, 0, level, err, err_data);
  code = build_patarray_match(
    code, elocal, pat->u.ary.patlist, vlen, level, err,
    err_data);

  if (lc != NULL)
    code = new_clist(lc, code);
  code = new_clist(tc, code);
  if (eassign != NULL)
    code = new_clist(eassign, code);

  return build_codeblock(vlocals, code);
}

static struct component *build_match_list_block(
  struct pattern *pat, struct component *e, int level,
  match_err_fn err, void *err_data)
{
  /*
   *  [
   *    | tmp |
   *    tmp = <expression>;
   *    pair?(tmp) &&
   *    car(tmp) == car(<pattern>) &&
   *      [
   *        tmp = cdr(tmp); <pattern> = cdr(<pattern>);
   *        pair?(tmp) &&
   *        car(tmp) == car(<pattern>) &&
   *          :
   *          [                              \  this is done at
   *            cdr(tmp) == cdr(<pattern>);  +- the last pair
   *          ]                              /
   *      ]
   *  ]
   */

  /* the last pair has both car/cdr entries */
  for (struct pattern_list *apl = pat->u.lst->next; apl; apl = apl->next)
    ++level;
  int nlevel = level;

  struct clist *code = NULL;
  struct vlist *locals = NULL;
  struct component *exp = NULL;
  for (struct pattern_list *apl = pat->u.lst->next; ; )
    {
      assert(apl != NULL);      /* silence clang-tidy warning */
      struct component *texp = (apl->next == NULL && is_safe_recall(e)
                                ? e
                                : make_local_var(&locals, --level,
                                                 &pat->loc));

      if (exp == NULL)
        {
          struct component *getcdr = build_exec(
            new_recall_component(GEP "cdr", &pat->loc), &pat->loc, 1, texp);
          struct component *c =
            (pat->u.lst->pat == NULL
             ? build_if(build_const_not_equal(
                          &pat->loc, constant_null, getcdr),
                        err(err_data))
             : build_match_block(pat->u.lst->pat, getcdr,
                                 nlevel, err, err_data));
          if (c)
            code = new_clist(c, code);
        }
      else
        {
          code = new_clist(
            new_assign_component(
              &apl->pat->loc, &exp->loc, exp->u.recall,
              build_exec(new_recall_component(GEP "cdr", &apl->pat->loc),
                         &apl->pat->loc, 1, texp)),
            code);
        }
      exp = texp;

      struct component *mc = build_match_block(
        apl->pat,
        build_exec(new_recall_component(GEP "car", &apl->pat->loc),
                   &apl->pat->loc, 1, exp),
        nlevel, err, err_data);
      if (mc != NULL)
        code = new_clist(mc, code);

      struct component *pc = set_loc(
        &apl->pat->loc,
        build_unless(
          build_exec(new_recall_component(GEP "pair?", &apl->pat->loc),
                     &apl->pat->loc, 1, exp),
          err(err_data)));
      code = new_clist(pc, code);

      apl = apl->next;
      if (apl == NULL)
        break;
    }

  if (!is_safe_recall(e))
    code = new_clist(
      new_assign_component(NO_LOC, &exp->loc, exp->u.recall, e),
      code);

  return build_codeblock(reverse_vlist(locals), code);
}

static struct component *build_typeset_check(struct component *e,
                                             typeset_t typeset,
                                             const struct loc *loc)
{
  if (typeset == 0)
    return component_false;

  struct component *tc = NULL;
  for (typeset_t i = stype_none; typeset; ++i)
    {
      enum mudlle_type t;
      /* convoluted to test null/integer early */
      switch (i)
        {
        case stype_none: t = type_integer; break;
        case mudlle_synthetic_types: t = type_null; break;
        case mudlle_synthetic_types + 1: t = i = 0; break;
        default: t = i; break;
        }
      typeset_t tset = type_typeset(t);
      if ((typeset & tset) == tset)
        {
          typeset &= ~tset;
          struct component *this = build_typecheck(loc, e, t);
          if (tc != NULL)
            this = new_binop_component(loc, arith_default, b_logical_or,
                                       tc, this);
          tc = this;
        }
    }
  return tc;
}

static struct component *build_match_variable_block(
  struct pattern *pat, struct component *e, int level,
  match_err_fn err, void *err_data)
{
  typeset_t typeset = pat->u.var.typeset;
  if (typeset == TYPESET_ANY)
    {
      if (pat->u.var.name == NULL)
        return NULL;
      return new_assign_component(&pat->loc, &pat->loc, pat->u.var.name, e);
    }

  struct vlist *locals = NULL;
  struct component *aexp = NULL;
  e = make_safe_copy(e, &locals, &aexp, level, &pat->loc);

  struct component *tc = build_unless(
    build_typeset_check(e, typeset, &pat->loc),
    err(err_data));

  e = (pat->u.var.name == NULL
       ? NULL                   /* sink; do nothing */
       : new_assign_component(&pat->loc, &pat->loc, pat->u.var.name, e));
  return build_codeblock(locals, build_clist(3, aexp, tc, e));
}

static struct component *build_match_symbol_block(
  struct pattern *pat, struct component *e, int level,
  match_err_fn err, void *err_data)
{
  struct vlist *locals = NULL;
  struct component *aexp = NULL;
  e = make_safe_copy(e, &locals, &aexp, level, &pat->loc);
  return build_codeblock(
    locals,
    build_clist(
      4,
      aexp,
      build_unless(build_typecheck(&pat->loc, e, type_symbol),
                   err(err_data)),
      build_symbol_name_check(
        pat->u.sym.name,
        build_exec(new_recall_component(GEP "symbol_name", &pat->loc),
                   &pat->loc, 1, e),
        level + 1,
        err, err_data),
      build_match_block(
        pat->u.sym.val,
        build_exec(new_recall_component(GEP "symbol_get", &pat->loc),
                   &pat->loc, 1, e),
        level + 2,
        err, err_data)));
}

static struct component *build_match_or_block(
  struct pattern *pat, struct component *e, int level,
  match_err_fn err, void *err_data)
{
  struct vlist *locals = NULL;
  struct component *aexp = NULL;
  e = make_safe_copy(e, &locals, &aexp, level, &pat->loc);

  int lhs_count = 0;
  struct component *lhs_comp = build_match_block(
    pat->u.or.lhs, e, level + 1, next_error, &lhs_count);

  struct component *rhs_comp = NULL;
  if (lhs_count == 0)
    {
      /* lhs always succeeds */
      compile_warning(&pat->u.or.rhs->loc, "pattern not reachable");
    }
  else
    rhs_comp = build_match_block(pat->u.or.rhs, e, level + 1, err, err_data);

  return new_labeled_component(
    &pat->loc,
    "%found", build_codeblock(
      locals,
      build_clist(
        3,
        aexp,
        new_labeled_component(
          &pat->loc,
          "%next", build_codeblock(
            NULL,
            build_clist(
              2,
              lhs_comp,
              build_exit("%found", new_const_component(constant_null))))),
        rhs_comp)));
}

static struct component *build_match_expr_block(
  struct pattern *pat, struct component *e, int level,
  match_err_fn err, void *err_data)
{
  return set_loc(
    &pat->loc,
    build_unless(
      set_loc(&pat->loc,
              build_exec(new_recall_component(GEP "equal?", &pat->loc),
                         &pat->loc, 2, pat->u.expr, e)),
      err(err_data)));
}

static struct component *build_match_and_block(
  struct pattern *pat, struct component *e, int level,
  match_err_fn err, void *err_data)
{
  return build_codeblock(
    NULL,
    build_clist(
      2,
      build_match_block(pat->u.and.pat, e, level, err, err_data),
      build_unless(pat->u.and.cond, err(err_data))));
}

static struct component *build_match_const_block(
  struct pattern *pat, struct component *e, int level,
  match_err_fn err, void *err_data)
{
  return set_loc(
    &pat->loc,
    build_if(build_const_not_equal(&pat->loc, pat->u.constval, e),
             err(err_data)));
}

typedef struct component *(*build_match_block_fn)(
  struct pattern *pat, struct component *e, int level,
  match_err_fn err, void *err_data);

static struct component *build_match_block(
  struct pattern *pat, struct component *e, int level,
  match_err_fn err, void *err_data)
{
  static const build_match_block_fn fns[] = {
    [pat_const]    = &build_match_const_block,
    [pat_list]     = &build_match_list_block,
    [pat_array]    = &build_match_array_block,
    [pat_symbol]   = &build_match_symbol_block,
    [pat_variable] = &build_match_variable_block,
    [pat_sink]     = &build_match_variable_block,
    [pat_expr]     = &build_match_expr_block,
    [pat_and]      = &build_match_and_block,
    [pat_or]       = &build_match_or_block,
  };
  return fns[pat->vclass](pat, e, level, err, err_data);
}

static struct component *parser_expand_const_list(struct constant *c)
{
  assert(c->vclass == cst_list);

  struct cstlist *const clhead = c->u.constants;
  assert(clhead != NULL);

  struct cstlist *last_dynamic = NULL;
  for (struct cstlist *cl = clhead; cl != NULL; cl = cl->next)
    if (cl->cst->is_dynamic)
      last_dynamic = cl;

  struct component *result = NULL;
  struct component **dst = &result;

  for (struct cstlist *cl = clhead; ; cl = cl->next)
    {
      struct component *cthis = new_const_component(cl->cst);
      const struct loc *lloc = &cthis->loc;
      if (cl->next == NULL)
        {
          /* the last cdr was dynamic (expression or #rw) */
          *dst = cthis;
          return result;
        }
      struct component *cpair = build_exec(
        new_recall_component(
          c->rwmode == rwmode_rw ? GEP "cons" : GEP "pcons", lloc),
        lloc, 2, cthis, cthis /* placeholder */);
      *dst = cpair;
      dst = &cpair->u.execute->next->next->c;
      if (cl == last_dynamic)
        break;
    }

  struct cstlist *tail = last_dynamic->next;
  assert(tail != NULL);         /* silence clang-tidy warning */
  if (tail->next == NULL)
    {
      /* the constant tail is just the last cdr */
      *dst = new_const_component(tail->cst);
    }
  else
    {
      c->u.constants = tail;
      c->is_dynamic = false;
      *dst = new_const_component(c);
    }
  return result;
}

static struct component *parser_expand_const_sequence(struct constant *cst)
{
  const struct loc *loc = &cst->loc;
  struct cstlist *lst = cst->u.constants;
  struct clist *cargs = NULL;
  for (struct cstlist *cl = lst; cl; cl = cl->next)
    cargs = new_clist(new_const_component(cl->cst), cargs);
  cargs = reverse_clist(cargs);
  bool is_table = false;
  if (cst->vclass == cst_table || cst->vclass == cst_ctable)
    is_table = true;
  else
    assert(cst->vclass == cst_array);
  bool is_rw = cst->rwmode == rwmode_rw;
  cargs = new_clist(
    new_recall_component(
      is_rw && !is_table ? GEP "vector" : GEP "sequence", loc),
    cargs);
  struct component *c = new_execute_component(loc, cargs);
  if (is_table)
    {
      const char *builder = (cst->vclass == cst_table
                             ? (is_rw
                                ? GEP "vector_to_table"
                                : GEP "vector_to_ptable")
                             : (is_rw
                                ? GEP "vector_to_ctable"
                                : GEP "vector_to_pctable"));
      c = build_exec(new_recall_component(builder, loc), loc, 1, c);
    }
  return c;
}

static bool parser_expand_const(struct component **cp)
{
  struct component *c = *cp;
  assert(c->vclass == c_constant);
  struct constant *cst = c->u.cst;
  if (!cst->is_dynamic)
    return false;

  switch (cst->vclass)
    {
    case cst_symbol:
      {
        struct cstpair *pair = cst->u.constpair;
        *cp = build_exec(
          new_recall_component(
            cst->rwmode == rwmode_rw ? GEP "make_symbol" : GEP "make_psymbol",
            &cst->loc),
          &cst->loc, 2,
          new_const_component(pair->cst1),
          new_const_component(pair->cst2));
        return true;
      }
    case cst_list: *cp = parser_expand_const_list(cst);
      return true;
    case cst_array:
    case cst_table:
    case cst_ctable:
      *cp = parser_expand_const_sequence(cst);
      return true;
    case cst_expression:
      *cp = cst->u.expression;
      return true;
    case cst_string:
      assert(cst->rwmode == rwmode_rw);
      /* create a read-write string using addition */
      *cp = new_binop_component(
        &cst->loc, arith_default, b_add,
        new_const_component(new_string_constant(&cst->u.string, &cst->loc)),
        new_const_component(new_string_constant(&CSTRLEN(""), &cst->loc)));
      return true;
    case cst_null: case cst_int: case cst_float:
    case cst_bigint: case cst_unary: case cst_gone:
      abort();
    }

  abort();
}

static bool parser_expand_builtin(struct component **cp)
{
  struct component *c = *cp;
  assert(c->vclass == c_builtin);
  if (parser_expand_paren(cp))
    return true;

  const struct loc *loc = &c->loc;

  if (c->u.builtin.fn == b_assign)
    {
      *cp = parser_expand_assign(c);
      return true;
    }

  if (c->u.builtin.arith_mode == arith_default)
    return false;

  const char *fname;
  enum builtin_type btype = builtin_type(
    &fname, c->u.builtin.fn, c->u.builtin.arith_mode, "", loc);
  assert(btype == btype_func || btype == btype_cmp);
  *cp = new_execute_component(
    loc,
    new_clist(new_recall_component(fname, loc),
              c->u.builtin.args));
  if (btype == btype_cmp)
    *cp = new_binop_component(loc, arith_default, c->u.builtin.fn,
                              *cp, component_false);
  return true;
}

static struct component *parser_expand_for_loop(struct component *c)
{
  assert(c->vclass == c_for_loop);

  /*
   *  <break> [
   *    <vars>
   *    <einit>
   *    loop
   *      [
   *        if (!<eexit>) exit<break> 42;
   *        <continue> <e>;
   *        <eloop>;
   *      ]
   *  ]
   */
  struct clist *code = NULL;

  if (c->u.for_loop->loop)
    code = new_clist(c->u.for_loop->loop, code);

  code = new_clist(new_labeled_component(&c->u.for_loop->expr->loc,
                                         "continue", c->u.for_loop->expr),
                   code);

  if (c->u.for_loop->exit)
    code = new_clist(
      build_if(build_unop(b_logical_not, c->u.for_loop->exit),
               build_exit("break", component_undefined)),
      code);

  struct component *cloop = new_unop_component(
    &c->loc, arith_default, b_loop, build_codeblock(NULL, code));

  code = new_clist(cloop, NULL);
  if (c->u.for_loop->init)
    code = new_clist(c->u.for_loop->init, code);

  c = build_codeblock(c->u.for_loop->vars, code);
  c->u.blk->loc = c->loc;

  return new_labeled_component(&c->loc, "break", c);
}

static const char *make_argn_name(unsigned n)
{
  /* room for "%arg" <digits> '\0' */
  char buf[4 + BITS_DECIMAL_DIG(CHAR_BIT * sizeof n) + 1];
  int r = snprintf(buf, sizeof buf, "%%arg%u", n);
  assert(r < (int)sizeof buf);
  return heap_allocate_string(parser_heap(), buf);
}

static void parser_expand_func_args(struct function *func)
{
  /* fn (a, @b, c = e0, d...) e1
   *
   * becomes
   *
   * fn $argv
   *   [
   *     | $nargs |
   *     $nargs = vlength($argv);
   *     if ($nargs < 2) error(error_wrong_parameters);
   *     | a |
   *     a = $argv[0];
   *     $arg1 = $argv[1];
   *     | b |
   *     @b = $arg1;
   *     $arg2 = if ($nargs > 2)
   *       argv[2]
   *     else
   *       e0;
   *     | c |
   *     c = $arg2;
   *     d = if ($nargs > 3)
   *       vector_tail($argv, 3)
   *     else
   *       '[];
   *     e1
   *   ]
   */
  int argn = 0;
  for (struct function_arg *fargs = func->args->args;
       fargs;
       fargs = fargs->next, ++argn)
    {
      if (fargs->default_val != NULL)
        parser_expand_component(&fargs->default_val);

      assert((fargs->pat == NULL) != (fargs->name == NULL));

      if (fargs->pat == NULL)
        continue;

      assert(fargs->name == NULL);

      fargs->name = make_argn_name(argn);
      fargs->typeset = pattern_typeset(fargs->pat);
      fargs->loc = fargs->pat->loc;

      if (pattern_has_collisions(fargs->pat, &fargs->pat_vars, NULL))
        abort();

      struct component *fval = new_recall_component(
        fargs->name, &fargs->pat->loc);
      fargs->pat_expr = build_match_block(
        fargs->pat, fval, 0, cause_no_match_error, fval);
      if (fargs->pat_expr != NULL)
        parser_expand_component(&fargs->pat_expr);

      assert(!erred);
    }
}

void parser_expand_component(struct component **cp)
{
  for (;;)
    switch ((*cp)->vclass)
      {
      case c_builtin:
        if (!parser_expand_builtin(cp))
          return;
        break;
      case c_modify:
        *cp = parser_expand_modify(*cp);
        break;
      case c_constant:
        if (!parser_expand_const(cp))
          return;
        break;
      case c_match:
        *cp = parser_expand_match(*cp);
        break;
      case c_pattern:
        *cp = parser_expand_pattern(*cp);
        break;
      case c_for_loop:
        *cp = parser_expand_for_loop(*cp);
        break;
      case c_closure:
        parser_expand_func_args((*cp)->u.closure);
        return;
      default:
        return;
      }
}
