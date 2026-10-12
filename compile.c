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

#include <errno.h>

#include "alloc.h"
#include "calloc.h"
#include "compile.h"
#include "context.h"
#include "global.h"
#include "ins.h"
#include "mcompile.h"
#include "module.h"
#include "mtree.h"
#include "strbuf.h"
#include "table.h"
#include "tree.h"

#include "runtime/mudlle-string.h"
#include "runtime/vector.h"

static ulong get_user_var_gidx, get_static_gidx;
static ulong symbol_set_gidx, symbol_get_gidx;
static ulong make_variable_ref_gidx, make_symbol_ref_gidx;

static ulong builtin_functions[parser_builtins];
static const uint8_t builtin_ops[parser_builtins] = {
  [b_add]         = op_builtin_add,
  [b_bitand]      = op_builtin_bitand,
  [b_bitor]       = op_builtin_bitor,
  [b_bitnot]      = op_builtin_bitnot,
  [b_eq]          = op_builtin_eq,
  [b_ge]          = op_builtin_ge,
  [b_gt]          = op_builtin_gt,
  [b_le]          = op_builtin_le,
  [b_lt]          = op_builtin_lt,
  [b_ne]          = op_builtin_neq,
  [b_logical_not] = op_builtin_not,
  [b_ref]         = op_builtin_ref,
  [b_set]         = op_builtin_set,
  [b_subtract]    = op_builtin_sub,
};
struct component *component_undefined, *component_true, *component_false;
struct constant *constant_null;

static struct string *last_filename;
static seclev_t compile_level; /* Security level for generated code */

typedef void (*gencond_fn)(struct label *lab, void *data, struct fncode *fn);

static struct icode *generate_function(struct function *f, bool toplevel,
                                       struct fncode *fn);
static void generate_component(struct component *comp, bool leave_result,
                               struct fncode *fn);
static void generate_condition(struct component *condition,
                               struct label *slab, gencond_fn scode,
                               void *sdata, struct label *flab,
                               gencond_fn fcode, void *fdata,
                               struct fncode *fn);

struct andordata
{
  struct label *lab, *slab, *flab;
  gencond_fn scode, fcode;
  void *sdata, *fdata;
  struct component *arg2;
};

static void andorcode(struct label *lab, void *_data, struct fncode *fn)
{
  struct andordata *data = _data;
  set_label(lab, fn);
  generate_condition(data->arg2,
                     data->slab, data->scode, data->sdata,
                     data->flab, data->fcode, data->fdata,
                     fn);
}

/*
 * Conceptually generates:
 *
 *   if (condition) goto slab; else goto flab;
 *   scode(slab, sdata);
 *   fcode(flab, fdata);
 */
static void generate_condition(struct component *condition,
                               struct label *slab, gencond_fn scode,
                               void *sdata, struct label *flab,
                               gencond_fn fcode, void *fdata,
                               struct fncode *fn)
{
  switch (condition->vclass)
    {
    case c_builtin:
      switch (condition->u.builtin.fn)
        {
        case b_logical_and:
        case b_logical_or:
          {
            struct component *arg1 = condition->u.builtin.args->c;

            struct andordata data = {
              .arg2  = condition->u.builtin.args->next->c,
              .slab  = slab,
              .scode = scode,
              .sdata = sdata,
              .flab  = flab,
              .fcode = fcode,
              .fdata = fdata
            };

            struct label *lab = new_label(fn);
            if (condition->u.builtin.fn == b_logical_and)
              generate_condition(arg1,
                                 lab, andorcode, &data,
                                 flab, NULL, NULL,
                                 fn);
            else
              generate_condition(arg1,
                                 slab, NULL, NULL,
                                 lab, andorcode, &data,
                                 fn);
            return;
          }
        case b_logical_not:
          /* Just swap conclusions */
          generate_condition(condition->u.builtin.args->c,
                             flab, fcode, fdata,
                             slab, scode, sdata,
                             fn);
          return;
        default:
          break;
        }
      FALLTHROUGH;
    default:
      generate_component(condition, true, fn);
      if (scode)
        {
          branch(op_branch_z1, flab, fn);
          scode(slab, sdata, fn);
          if (fcode) fcode(flab, fdata, fn);
        }
      else
        {
          branch(op_branch_nz1, slab, fn);
          if (fcode) fcode(flab, fdata, fn);
          else branch(op_branch1, flab, fn);
        }
      break;
    }
}

struct ifdata
{
  struct label *endlab;
  struct component *success, *failure;
  bool leave_result;
};

static void ifs_code(struct label *lab, void *_data, struct fncode *fn)
{
  struct ifdata *data = _data;

  set_label(lab, fn);
  if (data->success == NULL)
    assert(!data->leave_result);
  else
    generate_component(data->success, data->leave_result, fn);
  branch(op_branch1, data->endlab, fn);
  if (data->leave_result)
    adjust_depth(-1, fn);
}

static void iff_code(struct label *lab, void *_data, struct fncode *fn)
{
  struct ifdata *data = _data;

  set_label(lab, fn);
  if (data->failure == NULL)
    assert(!data->leave_result);
  else
    generate_component(data->failure, data->leave_result, fn);
  branch(op_branch1, data->endlab, fn);
  if (data->leave_result)
    adjust_depth(-1, fn);
}

static void generate_if(struct component *condition, struct component *success,
                        struct component *failure, bool leave_result,
                        struct fncode *fn)
{
  struct ifdata ifdata = {
    .endlab       = new_label(fn),
    .success      = success,
    .failure      = failure,
    .leave_result = leave_result
  };

  generate_condition(condition, new_label(fn), ifs_code, &ifdata,
                     new_label(fn), iff_code, &ifdata, fn);
  set_label(ifdata.endlab, fn);
  if (leave_result)
    adjust_depth(1, fn);
}

struct whiledata {
  struct label *looplab;
  struct component *code;
};

static void wmain_code(struct label *lab, void *_data, struct fncode *fn)
{
  struct whiledata *wdata = _data;
  set_label(lab, fn);
  generate_component(wdata->code, false, fn);
  branch(op_loop1, wdata->looplab, fn);
}

static void generate_while(struct component *condition,
                           struct component *iteration,
                           bool leave_result, struct fncode *fn)
{
  struct whiledata wdata = {
    .looplab = new_label(fn),
    .code    = iteration
  };

  env_start_loop();
  set_label(wdata.looplab, fn);
  start_block(NULL, leave_result, fn);
  struct label *endlab = new_label(fn);
  generate_condition(condition,
                     new_label(fn), wmain_code, &wdata,
                     endlab, NULL, NULL, fn);
  set_label(endlab, fn);
  if (leave_result)
    generate_component(component_undefined, true, fn);
  end_block(fn);
  env_end_loop();
}

/* return number of arguments */
static unsigned generate_args(struct clist *args, struct fncode *fn)
{
  args = reverse_clist(args);
  unsigned nargs = 0;
  for (struct clist *a = args; a; a = a->next)
    {
      assert(nargs < MAX_FUNCTION_ARGS);
      ++nargs;
      generate_component(a->c, true, fn);
    }
  args = reverse_clist(args);
  return nargs;
}

static void enter_block(struct vlist *vars, bool is_static,
                        const struct loc *loc)
{
  if (!env_block_push(vars, is_static))
    compile_error(loc, "too many local variables in function");
}

static void leave_block(void)
{
  for (struct vlist *vl = env_block_vlist(); vl; vl = vl->next)
    if (!vl->was_written)
      if (!vl->was_read)
        compile_warning(&vl->loc, "local variable %s%s%s is unused",
                        CMARKUP(var, vl->var));
      else
        compile_warning(&vl->loc, "local variable %s%s%s is never written",
                        CMARKUP(var, vl->var));
    else if (!vl->was_read)
      compile_warning(&vl->loc, "local variable %s%s%s is never read",
                      CMARKUP(var, vl->var));
  env_block_pop();
}

static void generate_block(struct block *b, bool leave_result,
                           struct fncode *fn)
{
  enter_block(b->locals, b->statics, &b->loc);
  if (erred)
    return;
  fncode_add_vlist(b->locals, fn);
  if (erred)
    return;

  if (b->statics)
    for (struct vlist *vl = b->locals; vl; vl = vl->next)
      {
        ulong offset;
        bool is_static;
        enum variable_class vclass = env_lookup(
          vl->var, &offset, false, true, &is_static);
        assert(is_static && vclass == vclass_local);
        ins_constant(scache_alloc_str(vl->var), fn);
        bool is_user = is_user_var_name(vl->var);
        mexecute(&vl->loc, is_user ? get_user_var_gidx : get_static_gidx,
                 NULL, 1, fn);
        ins_assign(vclass, offset, fn);
        ins0(op_discard, fn);

        if (erred)
          return;
      }

  /* Generate code for sequence */
  for (struct clist *cc = b->sequence; cc; cc = cc->next)
    {
      generate_component(cc->c, leave_result && cc->next == NULL, fn);
      if (erred)
        return;
    }

  fncode_remove_vlist(env_block_vlist(), fn);
  leave_block();
}

static void generate_execute(const struct loc *loc,
                             struct component *acall, int count,
                             struct fncode *fn)
{
  set_lineno(loc->line, fn);

  /* Optimise main case: calling a given global struct function **/
  if (acall->vclass == c_recall)
    {
      ulong offset;
      bool is_static;
      enum variable_class vclass = env_lookup(acall->u.recall, &offset,
                                              true, false, &is_static);

      if (vclass == vclass_global)
        {
          assert(!is_static);
          mexecute(loc, offset, acall->u.recall, count, fn);
          return;
        }
    }
  generate_component(acall, true, fn);
  if (count <= UINT8_MAX)
    ins1(op_execute, count, fn);
  else
    ins2(op_execute2, count, fn);
}

static void generate_builtin(struct component *comp,
                             bool leave_result, struct fncode *fn)
{
  struct clist *args = comp->u.builtin.args;

  switch (comp->u.builtin.fn)
    {
    case b_if:
      {
        generate_if(args->c, args->next->c, NULL, false, fn);
        if (leave_result)
          generate_component(component_undefined, true, fn);
        return;
      }
    case b_ifelse:
      generate_if(args->c, args->next->c, args->next->next->c,
                  leave_result, fn);
      return;
    case b_logical_and: case b_logical_or:
      generate_if(comp, component_true, component_false,
                  leave_result, fn);
      return;
    case b_while:
      generate_while(args->c, args->next->c, leave_result, fn);
      return;

    case b_loop:
      {
        struct label *loop = new_label(fn);
        env_start_loop();
        set_label(loop, fn);
        start_block(NULL, leave_result, fn);
        generate_component(args->c, false, fn);
        branch(op_loop1, loop, fn);
        end_block(fn);
        env_end_loop();

        /* only 'exit' can take us here; stack will be in order */
        if (leave_result)
          adjust_depth(1, fn);
        return;
      }

    case b_add: case b_subtract:
    case b_ref: case b_set:
    case b_bitor: case b_bitand: case b_bitnot:
    case b_logical_not:
    case b_eq: case b_ne:
    case b_lt: case b_le: case b_ge: case b_gt:
      {
        assert(comp->u.builtin.fn < parser_builtins);
        generate_args(args, fn);
        set_lineno(comp->loc.line, fn);
        ins0(builtin_ops[comp->u.builtin.fn], fn);
        break;
      }
    default:
      {
        assert(comp->u.builtin.fn < parser_builtins);
        unsigned count = generate_args(args, fn);
        mexecute(&comp->loc, builtin_functions[comp->u.builtin.fn],
                 NULL, count, fn);
        break;
      }
    }

  if (!leave_result)
    ins0(op_discard, fn);
}

static void generate_component(struct component *comp, bool leave_result,
                               struct fncode *fn)
{
  if (erred)
    return;

  parser_expand_component(&comp);

  set_lineno(comp->loc.line, fn);

  switch (comp->vclass)
    {
    case c_assign:
      {
        ulong offset;
        bool is_static;
        enum variable_class vclass = env_lookup(comp->u.assign.symbol, &offset,
                                                false, true, &is_static);
        struct component *val = comp->u.assign.value;

        /* Defining a function, give it a name */
        if (val->vclass == c_closure)
          val->u.closure->varname = comp->u.assign.symbol;

        if (is_static)
          {
            generate_component(comp->u.assign.value, true, fn);
            ins_recall(vclass, offset, fn);
            if (erred)
              return;
            mexecute(&comp->loc, symbol_set_gidx, NULL, 2, fn);
            break;
          }

        generate_component(comp->u.assign.value, true, fn);
        if (erred)
          return;

        set_lineno(comp->loc.line, fn);

        if (vclass == vclass_global)
          massign(&comp->loc, offset, comp->u.assign.symbol, fn);
        else
          ins_assign(vclass, offset, fn);
        /* Note: varname becomes a dangling pointer when fnmemory(fn) is
           deallocated, but it is never used again so this does not cause
           a problem. */
        break;
      }
    case c_recall:
      {
        ulong offset;
        bool is_static;
        enum variable_class vclass = env_lookup(comp->u.recall, &offset,
                                                true, false, &is_static);

        if (vclass != vclass_global && !leave_result)
          return;

        if (is_static)
          {
            assert(vclass != vclass_global);
            ins_recall(vclass, offset, fn);
            mexecute(&comp->loc, symbol_get_gidx, NULL, 1, fn);
            break;
          }
        if (vclass != vclass_global)
          ins_recall(vclass, offset, fn);
        else
          mrecall(&comp->loc, offset, comp->u.recall, fn);
        break;
      }
    case c_constant:
      if (!leave_result)
        return;
      ins_constant(constant_to_mudlle(comp->u.cst), fn);
      break;
    case c_closure:
      {
        uint16_t idx = add_constant(
          generate_function(comp->u.closure, false, fn), fn);
        if (idx <= UINT8_MAX)
          ins1(op_closure_code1, idx, fn);
        else
          ins2(op_closure_code2, idx, fn);
        break;
      }
    case c_block:
      generate_block(comp->u.blk, leave_result, fn);
      return;
    case c_labeled:
      start_block(comp->u.labeled.name, leave_result, fn);
      generate_component(comp->u.labeled.expression, leave_result, fn);
      if (erred)
        return;
      end_block(fn);
      return;
    case c_exit:
      {
        bool eresult;
        struct genblock *block = find_block(
          comp->u.labeled.name, fn, &eresult);
        if (block == NULL)
          {
            if (comp->u.labeled.name == NULL)
              compile_error(&comp->loc, "no loop to exit from");
            else
              compile_error(&comp->loc, "no block labeled %s",
                            comp->u.labeled.name);
            return;
          }

        generate_component(comp->u.labeled.expression, eresult, fn);
        if (erred)
          return;
        exit_block(block, fn);

        /* unreachable, so pretend the stack is in order */
        adjust_depth(leave_result - eresult, fn);
        return;
      }
    case c_execute:
      {
        unsigned count = generate_args(comp->u.execute->next, fn);
        generate_execute(&comp->loc, comp->u.execute->c, count, fn);
        break;
      }
    case c_builtin:
      generate_builtin(comp, leave_result, fn);
      return;
    case c_modify: case c_match: case c_pattern: case c_for_loop:
    case c_compound:
      abort();
    }

  if (!leave_result)
    ins0(op_discard, fn);
}

static struct vector *make_arguments(const struct function_args *args)
{
  if (args->nargs == 0)
    return empty_vector;

  struct vector *result = alloc_vector(args->nargs);
  GCPRO(result);
  int i = 0;
  for (struct function_arg *a = args->args; a; ++i, a = a->next)
    {
      typeset_t typeset = a->typeset;
      if (a->is_optional)
        typeset |= TYPESET_FLAG_OPTIONAL;
      value mtype = a->is_vararg ? NULL : makeint(typeset);

      struct list *e = make_immutable(
        alloc_list((a->name == NULL || a->name[0] == '%'
                    ? makebool(false)
                    : make_readonly(alloc_string(a->name))),
                   mtype));
      result->data[i] = e;
    }
  UNGCPRO();

  return make_immutable(result);
}

static void generate_typeset_check(typeset_t typeset, unsigned arg,
                                   struct fncode *newfn, bool is_return)
{
  assert(arg < P(8));

  assert((typeset & ~(TYPESET_ANY | TYPESET_FALSE)) == 0);
  if ((typeset & TYPESET_ANY) == TYPESET_ANY)
    return;

  union typecheck_arg targ = {
    .s = {
      .is_arg = !is_return,
      .argnum = arg
    }
  };
  assert(arg == targ.s.argnum);

  if (is_return)
    {
      typeset |= TYPESET_FLAG_RETURN;
      goto do_check;
    }
  enum mudlle_type t;
  if (typeset == TYPESET_FUNCTION)
    t = stype_function;
  else if (typeset == TYPESET_LIST)
    t = stype_list;
  else if (typeset == TYPESET_FLOAT_LIKE)
    t = stype_float_like;
  else if (typeset == TYPESET_BIGINT_LIKE)
    t = stype_bigint_like;
  else if (typeset == TYPESET_FALSE)
    t = stype_false;
  else if (typeset == 0)
    t = stype_none;
  else if ((typeset & (typeset - 1)) == 0)
    t = ffs(typeset) - 1;
  else
    {
    do_check:
      ins_constant(makeint(typeset), newfn);
      ins1(op_typeset_check, targ.u, newfn);
      return;
    }
  /* consider changing the above if this changes */
  CASSERT(mudlle_synthetic_types - mudlle_types == 7);
  ins1(op_typecheck + t, targ.u, newfn);
}

static struct icode *generate_function(struct function *f, bool toplevel,
                                       struct fncode *fn)
{
  /* make help string; must be allocated before code (immutability
     restriction) */
  struct string *help = NULL;
  if (f->help.len)
    help = scache_alloc_str_len(f->help.str, f->help.len);
  struct string *varname = NULL;
  struct vector *arguments = NULL;
  GCPRO(help, varname, arguments);

  /* Make variable name (if present) */
  if (f->varname)
    varname = scache_alloc_str(f->varname);

  arguments = make_arguments(f->args);

  struct fncode *newfn = new_fncode(toplevel, &f->loc);

  set_lineno(f->loc.line, newfn);

  /* First, generate code to check the argument types & count */
  /* Copies the arguments into the local variables, assuming that
     the last argument (on top of the stack) is local value 0, the next to
     last local value 1, and so on.
     It then discards all the parameters */

  int nargs = f->args->nargs;
  int noptargs = f->args->noptargs;
  bool vararg = noptargs > 0 && f->args->last_arg->is_vararg;

  if (noptargs == 0)
    ins1(op_args_fixed, nargs, newfn);
  else
    {
      ins_constant(makeint(nargs - noptargs), newfn);
      if (vararg)
        {
          ins_constant(makeint(noptargs - 1), newfn);
          ins0(op_args_vararg, newfn);
        }
      else
        {
          ins_constant(makeint(nargs), newfn);
          ins0(op_args_range, newfn);
        }
    }

  struct vlist *vlargs = NULL;
  struct vlist **vlargs_tail = &vlargs;

  for (struct function_arg *fargs = f->args->args;
       fargs;
       fargs = fargs->next)
    {
      /* temporarily create no-name arguments so they are invisible to
         evaluations for default arguments and pattern matching */
      struct vlist *vl = new_vlist("", fargs->typeset, &fargs->loc, NULL);
      *vlargs_tail = vl;
      vlargs_tail = &vl->next;
    }

  if (noptargs > 0)
    *vlargs_tail = new_vlist("%nargs", TSET(integer), &f->loc, NULL);

  env_push(vlargs, newfn);

  int blocks_created = 0;

  struct label *lab_next = NULL;
  int argn = 0;
  struct vlist *current_arg = vlargs;
  for (struct function_arg *fargs = f->args->args;
       fargs;
       fargs = fargs->next, ++argn)
    {
      if (fargs->is_optional)
        {
          /*  if (argn < nargs)
           *    goto typecheck;
           * prev-next:
           *  args[argn] = expr-or-[];
           *  goto next;
           * typecheck:
           *  typecheck(argn)
           *  pattern-expression */

          struct label *lab_typecheck = new_label(newfn);

          ins_recall(vclass_local, nargs, newfn); /* this is $nargs */
          ins_constant(makeint(argn), newfn);
          ins0(op_builtin_lt, newfn);
          branch(op_branch_nz1, lab_typecheck, newfn);

          if (lab_next != NULL)
            set_label(lab_next, newfn);

          if (fargs->default_val != NULL)
            generate_component(fargs->default_val, true, newfn);
          else
            {
              assert(vararg && fargs->next == NULL);
              ins_constant(empty_vector, newfn);
            }
          ins_assign(vclass_local, argn, newfn);
          ins0(op_discard, newfn);

          lab_next = new_label(newfn);
          branch(op_branch1, lab_next, newfn);

          set_label(lab_typecheck, newfn);
        }

      if (!fargs->is_vararg && fargs->typeset != TYPESET_ANY)
        generate_typeset_check(fargs->typeset, argn, newfn, false);

      if (fargs->is_vararg)
        {
          /* protect '$vararg' from modification by copying it to a correctly
             named user-accessible variable */
          current_arg->var = "%vararg";
          struct vlist *vvararg = new_vlist(fargs->name, fargs->typeset,
                                            &fargs->loc, NULL);
          vvararg->was_read = vvararg->was_written = true;

          ++blocks_created;
          enter_block(vvararg, false, &fargs->loc);

          generate_component(
            new_assign_component(
              &fargs->loc, NO_LOC, fargs->name,
              new_recall_component("%vararg", &fargs->loc)),
            false, newfn);
        }
      else
        current_arg->var = fargs->name;
      current_arg = current_arg->next;

      if (fargs->pat_vars != NULL)
        {
          ++blocks_created;
          enter_block(fargs->pat_vars, false, &fargs->loc);
        }

      if (fargs->pat_expr)
        generate_component(fargs->pat_expr, false, newfn);
    }

  fncode_add_vlist(vlargs, newfn);

  if (lab_next != NULL)
    set_label(lab_next, newfn);

  if (nargs > 0)
    ins0(op_pop_args, newfn);

  /* Generate code of struct function **/

  start_block(toplevel ? "" : "function", true, newfn);
  generate_component(f->value, true, newfn);

  for (; blocks_created > 0; --blocks_created)
    leave_block();

  if (erred)
    {
      uint16_t nlocals;
      env_pop(&nlocals);
      UNGCPRO();
      delete_fncode(newfn);
      return NULL;
    }

  end_block(newfn);

  set_lineno(f->endloc.line, newfn);
  if (f->return_typeset != TYPESET_ANY)
    generate_typeset_check(f->return_typeset, 0, newfn, true);

  ins0(op_return, newfn);
  /* we must have popped arguments and left one return value on the stack */
  assert(adjust_depth(0, newfn) == 1);
  peephole(newfn);

  struct icode *c = generate_fncode(
    newfn, help, varname, &f->loc, arguments,
    f->args->last_arg != NULL && f->args->last_arg->is_vararg,
    f->return_typeset, compile_level);
  struct variable_list *closure = env_pop(&c->nb_locals);

  UNGCPRO();

  /* Generate code for creating closure */

  /* Count length of closure */
  int clen = 0;
  for (struct variable_list *cvar = closure; cvar; cvar = cvar->next)
    clen++;

  /* Generate closure */
  ins1(op_closure, clen, fn);

  /* Add variables to it */
  for (struct variable_list *cvar = closure; cvar; cvar = cvar->next)
    ins_closure_var(cvar->vclass, cvar->offset, fn);

  delete_fncode(newfn);

  return c;
}

static struct block *new_toplevel_codeblock(struct vlist *statics,
                                            struct block *body)
{
  if (statics == NULL)
    return body;

  struct clist *cl = new_clist(new_block_component(body), NULL);
  body = new_codeblock(statics, cl, &body->loc);
  body->statics = true;
  return body;
}

/* Builds an interpreter closure that calls its C callback.  The varargs
   form passes all Mudlle arguments as a vector to op_c_callback. */
static struct closure *make_primitive_closure_internal(
  struct mcallback *cb, const char *funcname, struct string *help,
  const char *filename, int line, bool varargs,
  struct vector *captures, seclev_t seclev, struct icode **icode_slot,
  struct vector *arguments, typeset_t return_typeset)
{
  struct variable *cbvar = NULL;
  struct icode *icode = icode_slot ? *icode_slot : NULL;
  value callback = cb;
  GCPRO(callback, cbvar, icode, captures, arguments);

  assert(funcname != NULL);
  assert(help->o.garbage_type == garbage_static_string);

  cbvar = alloc_variable(callback);

  if (icode == NULL)
    {
      static struct table *scache = NULL;
      if (scache == NULL)
        {
          staticpro(&scache);
          scache = alloc_ctable(DEF_TABLE_SIZE);
        }
      init_string_cache(scache);

      const struct filename fname = {
        .filename = filename,
        .nicename = filename
      };
      const struct loc loc = {
        .fname = &fname,
        .line  = line,
        .col   = 0
      };
      struct function_arg vararg = {
        .typeset = TYPESET_ANY,
        .is_optional = true,
        .is_vararg = true
      };
      struct function_args fargs = { .nargs = 0 };
      unsigned nlocals = 0;
      if (varargs)
        {
          fargs.args = fargs.last_arg = &vararg;
          fargs.nargs = fargs.noptargs = 1;
          nlocals = 2;
        }

      struct fncode *newfn = new_fncode(false, &loc);
      if (varargs)
        {
          ins_constant(makeint(0), newfn);
          ins_constant(makeint(0), newfn);
          ins0(op_args_vararg, newfn);
        }
      else
        ins1(op_args_fixed, 0, newfn);
      ins0(op_pop_args, newfn);
      ins_recall(vclass_closure, 0, newfn);
      ins0(op_c_callback, newfn);
      ins0(op_return, newfn);
      assert(adjust_depth(0, newfn) == 1);

      icode = generate_fncode(
        newfn, help, NULL, &loc,
        arguments ? arguments : make_arguments(&fargs), varargs,
        arguments ? return_typeset : TYPESET_ANY, seclev);
      delete_fncode(newfn);
      icode->nb_locals = nlocals;
      free_string_cache();
    }

  ulong ncaptures = captures ? vector_len(captures) : 0;
  struct closure *cl = alloc_closure_noinit(1 + ncaptures);
  struct gcpro cl_root;
  GCPROV(cl_root, cl);
  cl->code = &icode->code;
  cl->variables[0] = cbvar;
  for (ulong i = 0; i < ncaptures; ++i)
    cl->variables[i + 1] = NULL;
  for (ulong i = 0; i < ncaptures; ++i)
    {
      struct variable *cell = alloc_variable(captures->data[i]);
      cl->variables[i + 1] = cell;
    }
  UNGCPROV(cl_root);
  UNGCPRO();

  if (icode_slot)
    *icode_slot = icode;
  return cl;
}

struct closure *make_primitive_closure(
  struct mcallback *cb, const char *funcname, struct string *help,
  const char *filename, int line)
{
  return make_primitive_closure_internal(
    cb, funcname, help, filename, line, false, NULL, MAX_SECLEVEL, NULL, NULL, TYPESET_ANY);
}

struct closure *make_primitive_closure_varargs(
  struct mcallback *cb, const char *funcname, struct string *help,
  const char *filename, int line)
{
  return make_primitive_closure_internal(
    cb, funcname, help, filename, line, true, NULL, MAX_SECLEVEL, NULL, NULL, TYPESET_ANY);
}

struct closure *make_primitive_closure_varargs_captured(
  struct mcallback *cb, const char *funcname, struct string *help,
  const char *filename, int line, struct vector *captures)
{
  return make_primitive_closure_internal(
    cb, funcname, help, filename, line, true, captures, MAX_SECLEVEL, NULL, NULL, TYPESET_ANY);
}

struct closure *make_primitive_closure_varargs_captured_sec(
  struct mcallback *cb, const char *funcname, struct string *help,
  const char *filename, int line, struct vector *captures, seclev_t seclev)
{
  return make_primitive_closure_internal(
    cb, funcname, help, filename, line, true, captures, seclev, NULL, NULL,
    TYPESET_ANY);
}

struct closure *make_primitive_closure_varargs_captured_sec_cached(
  struct mcallback *cb, const char *funcname, struct string *help,
  const char *filename, int line, struct vector *captures, seclev_t seclev,
  struct icode **icode_slot, struct vector *arguments,
  typeset_t return_typeset)
{
  return make_primitive_closure_internal(
    cb, funcname, help, filename, line, true, captures, seclev, icode_slot,
    arguments, return_typeset);
}

struct closure *compile_code(struct mfile *f, seclev_t seclev)
{
  init_string_cache(NULL);

  compile_level = seclev;
  erred = false;
  env_reset();
  struct fncode *top = new_fncode(true, &f->body->loc);
  env_push(NULL, top);          /* Environment must not be totally empty */
  struct block *body = new_toplevel_codeblock(f->statics, f->body);
  struct function *func = new_fn(
    new_block_component(body),
    new_function_args(),
    &body->loc, &f->endloc);
  func->varname = "top-level";
  struct icode *cc = generate_function(func, true, top);

  GCPRO(cc);
  generate_fncode(top, NULL, NULL, &f->loc, empty_vector, false,
                  TYPESET_ANY, seclev);
  uint16_t dummy;
  env_pop(&dummy);
  delete_fncode(top);
  UNGCPRO();

  free_string_cache();

  if (erred)
    return NULL;
  return alloc_closure0(&cc->code);
}

struct call_info {
  value f, *result;
};

static void docall0(void *_ci)
{
  struct call_info *ci = _ci;
  *ci->result = call0(ci->f);
}

static struct compiler_state *this_cstate;

bool should_suppress_compiler_messages(void)
{
  return this_cstate != NULL && this_cstate->pconfig->no_messages;
}

void push_compiler_state(struct compiler_state *cstate,
                         const struct parser_config *pconfig)
{
  assert(pconfig != NULL);
  *cstate = (struct compiler_state){
    .prev       = this_cstate,
    .block      = new_block(),
    .pconfig    = pconfig,
  };
  push_parser_heap(cstate->block);
  this_cstate = cstate;
}

void pop_compiler_state(struct compiler_state *cstate)
{
  pop_parser_heap(cstate->block);
  free_block(cstate->block);
  this_cstate = cstate->prev;
}

/* write line from 'f' starting at 'pos' to 'dst' */
static void get_file_line(struct strbuf *dst, size_t pos, FILE *f)
{
  off_t oldpos = ftello(f);
  if (oldpos < 0)
    {
      if (errno != ESPIPE)
        perror("ftello()");
      return;
    }
  if (fseeko(f, pos, SEEK_SET) < 0)
    {
      perror("fseeko()");
      return;
    }
  for (int c; (c = fgetc(f)) != EOF; )
    {
      if ((char)c == '\n')
        break;
      sb_addc(dst, c);
    }
  if (fseeko(f, oldpos, SEEK_SET) < 0)
    {
      perror("fseeko()");
      return;
    }
}

/* write line from 'strs' starting at 'pos' to 'dst' */
static void get_strings_line(struct strbuf *dst,
                             size_t pos, size_t nstrs,
                             const struct cstrlen strs[nstrs])
{
  /* find the 'strs[cstr]' where 'pos' points */
  size_t cstr = 0;
  while (pos > 0)
    {
      assert(cstr < nstrs);
      if (pos <= strs[cstr].len)
        break;
      pos -= strs[cstr].len;
      ++cstr;
    }

  /* emit text up to the next newline */
  while (cstr < nstrs)
    {
      const char *str = strs[cstr].str + pos;
      size_t len = strs[cstr].len - pos;
      const char *nl = memchr(str, '\n', len);
      if (nl != NULL)
        {
          sb_addmem(dst, str, nl - str);
          return;
        }
      sb_addmem(dst, str, len);
      ++cstr;
      pos = 0;
    }
}

void get_compiler_line(struct strbuf *dst, size_t pos)
{
  if (this_cstate == NULL)
    {
      return;
    }

  const struct parser_config *pconfig = this_cstate->pconfig;
  if (pconfig->f != NULL)
    get_file_line(dst, pos, pconfig->f);
  else
    get_strings_line(dst, pos, pconfig->nstrs, pconfig->strs);
}

bool interpret(value *result, seclev_t seclev, bool reload,
               const struct parser_config *pconfig)
{
  ASSERT_NOALLOC_START();

  struct compiler_state cstate;
  push_compiler_state(&cstate, pconfig);

  collect_compiler_messages();
  struct mfile *f;
  bool ok = parse(&f, pconfig);
  ASSERT_NOALLOC();
  send_compiler_messages();

  if (!ok)
    goto done;

  ok = false;
  if (f->name != NULL && !reload)
    {
      enum module_status status = module_status(f->name);
      ok = status == module_loaded;
      if (status != module_unloaded)
        goto done;
    }

  if (!mstart(cstate.block, f, seclev))
    goto done;

  struct closure *closure = compile_code(f, seclev);
  if (closure)
    mwarn_module(seclev, f->body);
  mstop(f);

  if (closure == NULL)
    goto done;

  if (!mprerun(f))
    goto done;

  if (f->name != NULL)
    module_set(f->name, module_loading, seclev);
  struct call_info ci = {
    .f      = closure,
    .result = result
  };
  ok = mcatch(docall0, &ci, call_trace_barrier);
  if (f->name != NULL)
    module_set(f->name, ok ? module_loaded : module_error, seclev);

 done:
  pop_compiler_state(&cstate);

  return ok;
}

static const char *loading_file_name;

const char *loading_file(void)
{
  return loading_file_name;
}

bool load_file(const char *fullname, seclev_t seclev, bool throw_errors,
               bool reload)
{
  FILE *f = fopen(fullname, "r");
  if (f == NULL)
    {
      if (throw_errors)
        runtime_error_message(error_bad_value, strerror(errno));
      fprintf(stderr, "Failed opening file '%s': %s\n", fullname,
              strerror(errno));
      return false;
    }

  const char *prevfile = loading_file_name;
  loading_file_name = fullname;

  value result;
  const struct parser_config pconfig = {
    .filename = { .filename = fullname, .nicename = fullname },
    .pmode    = parser_mode_file,
    .f        = f
  };
  bool ok = interpret(&result, seclev, reload, &pconfig);
  fclose(f);

  loading_file_name = prevfile;

  return ok;
}

void compile_init(void)
{
  /* retain pointer to avoid valgrind complaining about lost memory */
  static struct alloc_block *compile_block;
  compile_block = new_block();
  push_parser_heap(compile_block);

  /* Note: These definitions actually depend on those in types.h and
     runtime.c */
  component_undefined = new_const_component(
    new_int_constant(42, cstbase_decimal, NO_LOC));
  component_true = new_const_component(
    new_int_constant(true, cstbase_decimal, NO_LOC));
  component_false = new_const_component(
    new_int_constant(false, cstbase_decimal, NO_LOC));

  constant_null = new_null_constant(NO_LOC);

  builtin_functions[b_bitxor]      = global_lookup("^");
  builtin_functions[b_cons]        = global_lookup("cons");
  builtin_functions[b_divide]      = global_lookup("/");
  builtin_functions[b_multiply]    = global_lookup("*");
  builtin_functions[b_negate]      = global_lookup("negate");
  builtin_functions[b_remainder]   = global_lookup("%");
  builtin_functions[b_shift_left]  = global_lookup("<<");
  builtin_functions[b_shift_right] = global_lookup(">>");
  builtin_functions[b_logical_xor] = global_lookup("^^");

  get_user_var_gidx      = global_lookup("c:get_user_var");
  get_static_gidx        = global_lookup("c:get_static");
  symbol_get_gidx        = global_lookup("symbol_get");
  symbol_set_gidx        = global_lookup("symbol_set!");
  make_variable_ref_gidx = global_lookup("make_variable_ref");
  make_symbol_ref_gidx   = global_lookup("make_symbol_ref");

  staticpro(&last_filename);
  last_filename = static_empty_string;
}
