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

%{
#include "mudlle-config.h"

#include <math.h>
#include <string.h>

#include "alloc.h"
#include "array.h"
#include "calloc.h"
#include "compile.h"
#include "global.h"
#include "mparser.h"
#include "print.h"
#include "strbuf.h"
#include "tree.h"
#include "types.h"
#include "utils.h"


#ifdef __clang__
/* generated code doesn't handle this  */
#pragma clang diagnostic ignored "-Wmissing-variable-declarations"
#endif

/* needed to copy the fname field */
#define YYLLOC_DEFAULT(cur, rhs, n) do {                        \
    (cur) = YYRHSLOC(rhs, n);                                   \
    if (n > 1)                                                  \
      (cur).first = YYRHSLOC(rhs, 1).first;                     \
  } while (0)

%}

%define api.pure full
%define parse.error custom

%parse-param {const struct parser_config *pconfig}

%initial-action {
  @$ = (YYLTYPE){
    .first = {
      .col   = 1,
      .line  = 1,
      .fname = &pconfig->filename
    },
    .last_column = 1,
    .last_line   = 1
  };
  (void)yynerrs;                /* silence unused-variable warning */
}

%union {
  struct cstrlen string;
  const char *symbol;
  struct int_and_base integer;
  enum builtin_op operator;
  struct float_and_base mudlle_float;
  struct bigint_const *bigint;
  struct constant *tconstant;
  enum constant_class cstclass;
  struct block *tblock;
  struct function *tfunction;
  struct function_args *tfnargs;
  struct function_arg *tfnarg;
  struct clist *tclist;
  struct vlist *tvlist;
  struct cstlist *tcstlist;
  struct cstpair *tcstpair;
  struct component *tcomponent;
  enum mudlle_type tmtype;
  unsigned tmtypeset;           /* bitset of 1 << type_xxx */
  struct mfile *tfile;
  struct pattern *tpattern;
  struct pattern_list *tpatternlist;
  struct match_node *tmatchnode;
  struct match_node_list *tmatchnodelist;
  enum builtin_op bop;
  struct module_head {
    enum file_class fclass;
    const char *name;
    struct vlist *defines, *requires;
  } *tmodule_head;
  struct {
    bool space_suffix;
  } tcomma;
  bool force_match;
  bool boolean;
  enum arith_mode arith_mode;
  enum rwmode rwmode;
}

%locations

%token END 0          "end of input"

%token START_CONSTANT
%token START_STORABLE
%token START_ANY_EXPR
%token START_PRIMARY_EXPR
%token START_PAREN_EXPR

%token EQ             "'=='"
%token GE             "'>='"
%token LE             "'<='"
%token NE             "'!='"

%token DECREMENT      "'--'"
%token INCREMENT      "'++'"

%token LOGICAL_OR     "'||'"
%token LOGICAL_XOR    "'^^'"
%token LOGICAL_AND    "'&&'"

%token SHIFT_LEFT     "'<<'"
%token SHIFT_RIGHT    "'>>'"

%token PATTERN_MATCH  "'=>'"
%token ELLIPSIS       "'...'"

%token ASSIGN_OP      "assignment operator"

%token ELSE           "'else'"
%token FOR            "'for'"
%token FUNCTION       "'fn'"
%token IF_KEYWORD     "'if'"
%token LOOP           "'loop'"
%token LOOP_EXIT      "'exit'"
%token MATCH          "'match'"
%token MATCH_FORCE    "'match!'"
%token WHILE          "'while'"

%token DEFINES        "'defines'"
%token LIBRARY        "'library'"
%token MODULE         "'module'"
%token READS          "'reads'"
%token REQUIRES       "'requires'"
%token STATIC         "'static'"
%token WRITES         "'writes'"

%token BIGINT         "bigint constant"
%token FLOAT          "floating-point constant"
%token INTEGER        "integer constant" /* warning: can be -MIN_TAGGED_INT */
%token COMMA          "','"
%token STRING         "string constant"
%token SYMBOL         "variable name"

%token ARITH          "'#arith'"
%token HASH_GONE      "'#gone'"
%token HASH_RO        "'#ro'"
%token HASH_RW        "'#rw'"
%token HASH_IM        "'#im'"

%token '\''           "apostrophe (')"

%precedence NOT_ELSE
%right '.'
%left LOGICAL_OR
%left LOGICAL_XOR
%left LOGICAL_AND
%left EQ NE '<' LE '>' GE
%left '|'
%left '^'
%left '&'
%left SHIFT_LEFT SHIFT_RIGHT
%left '+' '-'
%left '*' '/' '%'
%precedence ELSE

%type <tclist> expr_list simple_expr_list opt_call_list call_list
%type <tcomponent> expr e0 e1 e2 e3 e4 e4_safe primary_expr loop exit match for
%type <tcomponent> unary_expr assign_expr logical_and_expr
%type <tcomponent> control_expr opt_expr paren_expr variable_recall
%type <tcomponent> if while one_expression
%type <tvlist> variable_list
%type <tvlist> opt_local_vars local_vars
%type <tvlist> requires defines reads writes statics
%type <tmtype> type
%type <tmtypeset> typeset typelist typeset_braced opt_typeset_braced
%type <string> help STRING
%type <symbol> variable label opt_label opt_symbol plain_symbol
%type <symbol> SYMBOL
%type <integer> INTEGER
%type <mudlle_float> FLOAT
%type <bigint> BIGINT
%type <cstclass> table_class
%type <force_match> match_type
%type <tconstant> constant constant_container constant_expr constant_expr_tail
%type <tconstant> constant_no_prefix
%type <tconstant> constant_symbol constant_symbol_name constant_table_entry
%type <tconstant> constant_table_entry_no_prefix opt_constant_list_tail
%type <tconstant> force_constant
%type <tconstant> simple_constant unary_constant
%type <tconstant> float_constant int_constant string_constant
%type <tconstant> special_float_constant
%type <tblock> maybe_arith_code_block code_block opt_implicit_code_block
%type <tfunction> function_expr f0 f1
%type <tfnargs> opt_arglist arglist
%type <tfnarg> arg argname
%type <tcstlist> constant_list opt_constant_list constant_table_entry_list
%type <tfile> file simple module
%type <tmodule_head> module_head;
%type <tpattern> pattern pattern_list pattern_array pattern_atom pattern_cdr
%type <tpattern> pattern_atom_expr pattern_symbol pattern_and
%type <tpattern> pattern_or opt_pattern_or
%type <tpatternlist> opt_pattern_sequence
%type <tmatchnode> match_node
%type <tmatchnodelist> match_list
%type <operator> incrementer
%type <bop> ASSIGN_OP
%type <tcomma> COMMA
%type <boolean> opt_ellipsis
%type <rwmode> HASH_IM HASH_RO HASH_RW constant_string_rwmode_prefix
%type <rwmode> im_ro_rwmode_prefix constant_container_rwmode_prefix

%{

#include "lexer.h"

/* here to catch accidental increase of the size; it's not really harmful to
   change the size */
CASSERT_SIZEOF(YYSTYPE, sizeof (struct cstrlen));

#define BINOP(dst, op, loc, e0, l0, e1, l1) do {        \
  struct component *__c = make_binary(                  \
    b_ ## op, &(loc), (e0), &(l0), (e1), &(l1));        \
  if (__c == NULL)                                      \
      YYABORT;                                          \
  dst = __c;                                            \
} while (0)

#define UNOP(dst, op, loc, e) do {                              \
  struct component *__c = make_unary(b_ ## op, &(loc), (e));    \
  if (__c == NULL)                                              \
    YYABORT;                                                    \
  dst = __c;                                                    \
} while (0)

static enum arith_mode cur_arith_mode;
static enum rwmode cur_rwmode;

static struct mfile *parsed_code;
static struct constant *parsed_constant;
static struct component *parsed_expr;
static int parsed_expr_end_pos;

static enum parser_mode parser_mode;

bool const_rwmode_is_dynamic(void)
{
  assert(parser_mode != parser_mode_undefined);
  return parser_mode != parser_mode_storable;
}

static const char *varlist_name;

static struct vlist *seen_user_vars;

static void add_user_var(const char *vname)
{
  for (struct vlist **varp = &seen_user_vars; ; varp = &(*varp)->next)
    {
      struct vlist *var = *varp;
      if (var == NULL)
        {
          var = new_vlist(vname, TYPESET_ANY, NO_LOC, NULL);
          var->was_read = var->was_written = true;
          *varp = var;
          return;
        }
      if (strcasecmp(vname, var->var) == 0)
        return;
    }
}

static void maybe_compile_error(const YYLTYPE *loc, const char *s)
{
  if (!erred)
    compile_error(LLOC_LOC(*loc), "%s", s);
}

static void yyerror(YYLTYPE *locp, const struct parser_config *pconfig,
                    const char *s)
{
  maybe_compile_error(locp, s);
}

struct bracket {
  char c;
  YYLTYPE loc;
};

static ARRAY_T(struct bracket) bracket_stack;

static void push_bracket(char c, const YYLTYPE *loc)
{
  ARRAY_ADD(bracket_stack, ((struct bracket){ .c = c, .loc = *loc }));
}

static void pop_bracket(char c)
{
  assert(!ARRAY_IS_EMPTY(bracket_stack));
  struct bracket b = ARRAY_POP(bracket_stack);
  assert(b.c == c);
}

static bool lookup_arith_mode(enum arith_mode *dst, const char *src,
                              const YYLTYPE *loc)
{
  static const char *const mode_names[] = {
#define AM(name, lname) #name
    FOR_ARITH_MODES(AM, SEP_COMMA)
#undef AM
  };

  size_t slen = strlen(src);
  for (enum arith_mode am = 0; am < VLENGTH(mode_names); ++am)
    if (strncmp(mode_names[am], src, slen) == 0)
      {
#ifndef USE_GMP
        if (am == arith_bigint)
          {
            compile_error(LLOC_LOC(*loc), "#arith(%s) is unsupported", src);
            return false;
          }
#endif
        *dst = am;
        return true;
      }

  compile_error(LLOC_LOC(*loc), "unknown arithmetic mode");
  return false;
}

static void check_constant_expr(const YYLTYPE *loc)
{
  if (!allow_comma_expression())
    maybe_compile_error(loc, "comma-prefixed expression not allowed");
}

static void check_space(const YYLTYPE *loc, bool warn, const char *where)
{
  if (warn && !erred)
    compile_error(LLOC_LOC(*loc),
                  "comma must not be followed by whitespace in %s",
                  where);
}

static struct constant *parse_special_float(const YYLTYPE *loc,
                                            bool neg, const char *s)
{
  double d;
  if (strcasecmp(s, "inf") == 0 || strcasecmp(s, "infinity") == 0)
    d = neg ? -INFINITY : INFINITY;
  else if (!neg && strcasecmp(s, "nan") == 0)
    d = nan("");
  else
    {
      compile_error(LLOC_LOC(*loc), "syntax error, unexpected variable name");
      return NULL;
    }
  return new_float_constant(d, cstbase_decimal, LLOC_LOC(*loc));
}

/* true if c is a string constant */
static bool is_string(struct component *c)
{
  return c->vclass == c_constant && c->u.cst->vclass == cst_string;
}

/* true if c is an addition of two strings */
static bool is_string_add(struct component *c)
{
  return (c->vclass == c_builtin && c->u.builtin.fn == b_add
          && is_string(c->u.builtin.args->c)
          && is_string(c->u.builtin.args->next->c));
}

/* collapse the string addition in c into a string constant */
static struct component *perform_string_add(struct component *c)
{
  assert(is_string_add(c));
  const struct cstrlen *a = &c->u.builtin.args->c->u.cst->u.string;
  const struct cstrlen *b = &c->u.builtin.args->next->c->u.cst->u.string;
  size_t len = a->len + b->len;
  char *nbuf = allocate(parser_heap(), len);
  if (a->len > 0)
    memcpy(nbuf, a->str, a->len);
  if (b->len > 0)
    memcpy(nbuf + a->len, b->str, b->len);
  struct cstrlen s = {
    .len = len,
    .str = nbuf,
  };
  return new_const_component(
    new_string_constant(&s, &c->u.builtin.args->c->loc));
}

static struct component *make_binary(
  enum builtin_op op, const YYLTYPE *locop,
  struct component *arg1, const YYLTYPE *locarg1,
  struct component *arg2, const YYLTYPE *locarg2)
{
  if (op == b_add && cur_arith_mode == arith_default)
    {
      /* check if this is a collapsible string addition */
      if (is_string_add(arg1))
        {
          if (is_string(arg2))
            arg1 = perform_string_add(arg1);
          else if (is_string_add(arg2))
            {
              arg1 = perform_string_add(arg1);
              arg2 = perform_string_add(arg2);
            }
        }
      else if (is_string(arg1) && is_string_add(arg2))
        arg2 = perform_string_add(arg2);
    }

  enum prio_class {
    pc_undefined,
    pc_logical_or,
    pc_logical_xor,
    pc_logical_and,
    pc_relation,
    pc_bitor,
    pc_bitxor,
    pc_bitand,
    pc_bitshift,
    pc_arith,
    pc_arith_unary,
    prio_class_types
  };
  static const enum prio_class prio_classes[] = {
    [b_logical_or]  = pc_logical_or,
    [b_logical_xor] = pc_logical_xor,
    [b_logical_and] = pc_logical_and,
    [b_lt]          = pc_relation,
    [b_le]          = pc_relation,
    [b_ge]          = pc_relation,
    [b_gt]          = pc_relation,
    [b_bitor]       = pc_bitor,
    [b_bitxor]      = pc_bitxor,
    [b_bitand]      = pc_bitand,
    [b_shift_left]  = pc_bitshift,
    [b_shift_right] = pc_bitshift,
    [b_add]         = pc_arith,
    [b_subtract]    = pc_arith,
    [b_multiply]    = pc_arith,
    [b_divide]      = pc_arith,
    [b_remainder]   = pc_arith,
    [b_negate]      = pc_arith_unary,
    [b_bitnot]      = pc_arith_unary,
    [b_assign]      = pc_undefined
  };
  CASSERT_VLEN(prio_classes, parser_builtins);
  enum {
    pc_logical_warnings = (P(pc_bitor) | P(pc_bitxor) | P(pc_bitshift)
                           | P(pc_arith) | P(pc_arith_unary))
  };
  /* warn if either argument is of a class in these bitsets */
  static const unsigned prio_class_warnings[] = {
    /* do not warn for _a && b_ || c; too commonly used */
    [pc_logical_or]  = P(pc_logical_xor) | pc_logical_warnings,
    [pc_logical_xor] = P(pc_logical_and) | pc_logical_warnings,
    [pc_logical_and] = pc_logical_warnings,
    /* do not warn for _a & b_ == c */
    [pc_relation]    = P(pc_bitor) | P(pc_bitxor) | P(pc_bitshift),
    [pc_bitor]       = (P(pc_bitxor) | P(pc_bitand) | P(pc_bitshift)
                        | P(pc_arith)),
    [pc_bitxor]      = P(pc_bitand) | P(pc_bitshift) | P(pc_arith),
    [pc_bitand]      = P(pc_bitshift) | P(pc_arith),
    [pc_bitshift]    = P(pc_bitshift) | P(pc_arith),
    [pc_arith_unary] = 0
  };
  CASSERT_VLEN(prio_class_warnings, prio_class_types);

  unsigned warn = prio_class_warnings[prio_classes[op]];
  for (struct component *arg = arg1; arg; arg = arg == arg2 ? NULL : arg2)
    if (arg->vclass == c_builtin
        && (warn & P(prio_classes[arg->u.builtin.fn])))
      compile_warning(
        LLOC_LOC(*(arg == arg1 ? locarg1 : locarg2)),
        "suggest parentheses around %s in argument to %s",
        builtin_op_long_names[arg->u.builtin.fn],
        builtin_op_long_names[op]);

  return new_binop_component(LLOC_LOC(*locop), cur_arith_mode, op, arg1, arg2);
}

static bool check_int_range(long l, const struct loc *loc)
{
  if (l == -MIN_TAGGED_INT)
    {
      compile_error(loc, "integer constant out of range");
      return false;
    }
  return true;
}

static bool check_comp_int_range(struct component *c)
{
  if (c->vclass == c_constant && c->u.cst->vclass == cst_int)
    return check_int_range(c->u.cst->u.integer.i, &c->loc);

  return true;
}

static bool is_const_unop(enum builtin_op op, struct component *arg)
{
  if (arg->vclass != c_constant)
    return false;
  struct constant *cst = arg->u.cst;
  if (cst->vclass == cst_int)
    return op == b_negate || op == b_logical_not || op == b_bitnot;
  return cst->vclass == cst_float && op == b_negate;
}

static struct component *make_unary(enum builtin_op op,
                                    const YYLTYPE *loc,
                                    struct component *arg)
{
  if (is_const_unop(op, arg))
    return new_const_component(
      new_unary_constant(op, arg->u.cst, LLOC_LOC(*loc)));
  return new_unop_component(LLOC_LOC(*loc), cur_arith_mode, op, arg);
}

static bool check_opt_arg(struct function_args *args,
                          const struct loc *loc)
{
  if (args->noptargs == 0 || args->last_arg->default_val != NULL)
    return true;

  compile_error(loc, "default value required");
  return false;
}

static bool find_type(const YYLTYPE *loc, const char *name,
                      enum mudlle_type *type)
{
  if (strcasecmp(name, "int") == 0)
    {
      *type = type_integer;
      return true;
    }
  for (enum mudlle_type t = 0; t < mudlle_synthetic_types; ++t)
    if (strcasecmp(name, mudlle_type_names[t]) == 0)
      {
        *type = t;
        return true;
      }

  compile_error(LLOC_LOC(*loc), "unknown type %s", name);
  return false;
}

static struct module_head *make_module(
  enum file_class fclass, const char *name,
  struct vlist *requires, struct vlist *defines)
{
  struct module_head *m = allocate(parser_heap(), sizeof *m);
  *m = (struct module_head){
    .fclass = fclass, .name = name, .defines = defines, .requires = requires
  };
  return m;
}

%}

%%

start:
  file { parsed_code = $1; } |
  force_constant { parsed_constant = $1; } |
  one_expression {
    parsed_expr = $1;
    parsed_expr_end_pos = @1.last_pos;
  } |
  %empty {
    if (!pconfig->allow_empty)
      {
        maybe_compile_error(&yylloc, "does not contain code");
        return false;
      }
  } ;

file:
  simple |
  module ;

simple:
  opt_local_vars expr_list {
    const struct loc *loc = $1 ? LLOC_LOC(@1) : LLOC_LOC(@2);
    $$ = new_file(f_plain, NULL, NULL, NULL, NULL, NULL, NULL, seen_user_vars,
                  new_codeblock($1, $2, loc), loc, LLOC_LAST_LOC(@2));
  } ;

module:
  module_head reads writes statics code_block opt_semi {
    $$ = new_file($1->fclass, $1->name, $1->requires,
                  $1->defines, $2, $3, $4, seen_user_vars, $5, LLOC_LOC(@5),
                  LLOC_LAST_LOC(@5));
  } ;

module_head:
  MODULE opt_symbol requires {
    $$ = make_module(f_module, $2, $3, NULL);
  } |
  LIBRARY plain_symbol requires defines {
    $$ = make_module(f_library, $2, $3, $4);
  } ;

opt_symbol:
  plain_symbol |
  %empty { $$ = NULL; } ;

requires:
  REQUIRES { varlist_name = "required module"; } variable_list { $$ = $3; } |
  %empty { $$ = NULL; } ;

defines:
  DEFINES { varlist_name = "defined variable"; } variable_list { $$ = $3; } ;

reads:
  READS { varlist_name = "read variable"; } variable_list { $$ = $3; } |
  %empty { $$ = NULL; } ;

writes:
  WRITES { varlist_name = "written variable"; } variable_list { $$ = $3; } |
  %empty { $$ = NULL; } ;

statics:
  STATIC { varlist_name = "static variable"; } variable_list { $$ = $3; } |
  %empty { $$ = NULL; } ;

open_brace:
  '{' { push_bracket('{', &@1); } ;

close_brace:
  '}' { pop_bracket('{'); } ;

open_lt:
  '<' { push_bracket('<', &@1); } ;

close_lt:
  '>' { pop_bracket('<'); } ;

open_paren:
  '(' { push_bracket('(', &@1); } ;

close_paren:
  ')' { pop_bracket('('); } ;

open_sq_bracket:
  '[' { push_bracket('[', &@1); } ;

close_sq_bracket:
  ']' { pop_bracket('['); } ;

open_vbar:
  '|' { push_bracket('|', &@1); } ;

close_vbar:
  '|' { pop_bracket('|'); } ;

expr_list:
  simple_expr_list ';' opt_implicit_code_block {
    struct clist *cl = $1;
    if ($3 != NULL) {
      struct component *comp = new_block_component($3);
      cl = new_clist(comp, cl);
    }
    $$ = reverse_clist(cl);
  } |
  simple_expr_list {
    $$ = reverse_clist($1);
  } ;

opt_implicit_code_block:
  %empty { $$ = NULL; } |
  local_vars expr_list {
      $$ = new_codeblock($1, $2, LLOC_LOC(@1));
  } ;

simple_expr_list:
  simple_expr_list ';' expr {
    $$ = new_clist($3, $1);
  } |
  simple_expr_list ';' ELSE {
    maybe_compile_error(&@2, "there must be no semicolon before 'else'");
    YYABORT;
  } |
  expr {
    $$ = new_clist($1, NULL);
  } ;

opt_semi: %empty | ';' ;

opt_expr:
  expr |
  %empty { $$ = NULL; } ;

one_expression:
  START_ANY_EXPR e0 { $$ = $2; } |
  START_PRIMARY_EXPR primary_expr { $$ = $2; } |
  START_PAREN_EXPR paren_expr { $$ = $2; } ;

expr:
  label expr {
    $$ = new_labeled_component(LLOC_LOC(@1), $1, $2);
  } |
  e0 ;

label: open_lt plain_symbol close_lt { $$ = $2; } ;

e0:
  control_expr |
  function_expr {
    $$ = new_closure_component(LLOC_LOC(@1), $1);
  } |
  assign_expr |
  e1 ;

control_expr: if | while | loop | exit | match | for ;

if:
  IF_KEYWORD open_paren expr close_paren expr ELSE expr {
    $$ = new_ternop_component(LLOC_LOC(@1), b_ifelse, $3, $5, $7);
  } |
  IF_KEYWORD open_paren expr close_paren expr %prec NOT_ELSE {
    $$ = new_binop_component(LLOC_LOC(@1), arith_default, b_if, $3, $5);
  } ;

while:
  WHILE open_paren expr close_paren expr {
    $$ = new_binop_component(LLOC_LOC(@1), arith_default, b_while, $3, $5);
  } ;

loop:
  LOOP expr {
    $$ = new_unop_component(LLOC_LOC(@1), arith_default, b_loop, $2);
  } ;

for:
  FOR open_paren opt_local_vars opt_expr ';' opt_expr ';' opt_expr
  close_paren expr {
    $$ = new_for_component($3, $4, $6, $8, $10, LLOC_LOC(@1));
  } ;

match:
  match_type open_paren expr close_paren
  open_sq_bracket match_list opt_semi close_sq_bracket {
    $$ = new_match_component($1, $3, $6, LLOC_LOC(@1));
  } ;

match_type:
  MATCH { $$ = false; } |
  MATCH_FORCE { $$ = true; } ;

match_list:
  match_node { $$ = new_match_list($1, NULL); } |
  match_list ';' match_node { $$ = new_match_list($3, $1); } ;

match_node:
  pattern_or PATTERN_MATCH expr {
    struct vlist *vl = NULL;
    if (pattern_has_collisions($1, &vl, NULL))
      YYABORT;
    $$ = new_match_node($1, $3, vl, LLOC_LOC(@1));
  } ;

pattern_or:
  pattern_and opt_pattern_or {
    $$ = $1;
    if ($2 != NULL)
      $$ = new_pattern_or($1, $2, LLOC_LOC(@1));
  } ;

pattern_and:
  pattern_atom LOGICAL_AND logical_and_expr {
    $$ = new_pattern_and_expr($1, $3);
  } |
  pattern_atom ;

opt_label:
  label { $$ = $1; } |
  %empty { $$ = NULL; } ;

exit:
  LOOP_EXIT opt_label e0 {
    $$ = new_exit_component(LLOC_LOC(@1), $2, $3);
  } ;

function_expr:
  typeset FUNCTION f0 {
    @$ = @2;
    $$ = $3;
    $$->loc = *LLOC_LOC(@2);
    $$->return_typeset = $1;
  } |
  FUNCTION f0 {
    $$ = $2;
    $$->loc = *LLOC_LOC(@1);
  } ;

f0:
  help f1 {
    $$ = $2;
    $$->help = $1;
  } |
  f1 ;

f1:
  open_paren opt_arglist close_paren expr {
    $$ = new_fn($4, $2, LLOC_LOC(@4), LLOC_LAST_LOC(@4));
    if (!check_function_arguments($$))
      YYABORT;
  } ;

help:
  help '+' STRING {
    $$.len = $1.len + $3.len;
    char *nbuf = allocate(parser_heap(), $$.len);
    memcpy(nbuf, $1.str, $1.len);
    memcpy(nbuf + $1.len, $3.str, $3.len);
    $$.str = nbuf;
  } | STRING ;

opt_arglist:
  %empty { $$ = new_function_args(); } |
  arglist opt_ellipsis {
    $$ = $1;
    if ($2)
      {
        ++$$->noptargs;

        $$->last_arg->is_vararg = true;

        if ($$->last_arg->typeset != TYPESET_ANY)
          {
            compile_error(
              &$$->last_arg->loc,
              "variable-length argument cannot have a type specified");
            YYABORT;
          }

        if ($$->last_arg->default_val != NULL)
          {
            compile_error(
              &$$->last_arg->default_val->loc,
              "variable-length argument cannot have a default value");
            YYABORT;
          }
      }
    else if (!check_opt_arg($1, LLOC_LAST_LOC(@1)))
      YYABORT;
  };

opt_ellipsis:
  %empty { $$ = false; } |
  ELLIPSIS { $$ = true; } ;

arglist:
  arglist COMMA arg {
    if (!check_opt_arg($1, LLOC_LOC(@2)))
      YYABORT;

    $1->last_arg->next = $3;
    $1->last_arg = $3;
    ++$1->nargs;
    if ($3->default_val)
      ++$1->noptargs;
    if ($1->nargs > MAX_FUNCTION_ARGS)
      {
        compile_error(LLOC_LOC(@3),
                      "functions can have at most %d formal arguments",
                      MAX_FUNCTION_ARGS);
        YYABORT;
      }
    $$ = $1;
  } |
  arg {
    $$ = new_function_args();
    $$->args = $$->last_arg = $1;
    $$->nargs = 1;
    if ($1->default_val)
      $$->noptargs = 1;
  };

arg:
  argname |
  argname '=' expr {
    $1->default_val = $3;
    $1->is_optional = true;
    $$ = $1;
  };

argname:
  typeset plain_symbol {
    $$ = new_function_arg($2, $1, NULL, LLOC_LOC(@2));
  } |
  plain_symbol {
    $$ = new_function_arg($1, TYPESET_ANY, NULL, LLOC_LOC(@1));
  } |
  '@' pattern_or {
    $$ = new_function_arg(NULL, TYPESET_ANY, NULL, LLOC_LOC(@1));
    $$->pat = $2;
  } ;

typeset:
  type { $$ = type_typeset($1); } |
  typeset_braced ;

opt_typeset_braced:
  %empty { $$ = TYPESET_ANY; } |
  typeset_braced;

typeset_braced:
  open_brace typelist close_brace { $$ = $2; } ;

typelist:
  typelist COMMA type {
    typeset_t tset = type_typeset($3);
    if (($$ & tset) == tset)
      compile_warning(
        LLOC_LOC(@3),
        "redundant type %s%s%s",
        CMARKUP(type, mudlle_type_names[$3]));
    else if (($$ & tset) == $$)
      compile_warning(
        LLOC_LOC(@3),
        "type %s%s%s makes previous types redundant",
        CMARKUP(type, mudlle_type_names[$3]));

    $$ = $1 | tset;
    typeset_t mask = TSET(integer) | TYPESET_FALSE;
    if (($$ & mask) == mask)
      {
        compile_error(
          LLOC_LOC(@3),
          "specifying types false and int together is invalid");
        YYABORT;
      }
  } |
  type { $$ = type_typeset($1); } ;

type:
  plain_symbol { if (!find_type(&@1, $1, &$$)) YYABORT; } ;

assign_expr:
  unary_expr ASSIGN_OP expr {
    $$ = new_assign_modify_expr(cur_arith_mode, $2, $1, $3, LLOC_LOC(@2));
    if ($$ == NULL)
      YYABORT;
  } |
  unary_expr '=' expr {
    $$ = new_assign_expression($1, $3, LLOC_LOC(@2), LLOC_LOC(@1));
    if ($$ == NULL)
      YYABORT;
  } |
  '@' pattern {
    if (pattern_has_collisions($2, NULL, NULL))
      YYABORT;
  } '=' expr {
    $$ = new_pattern_component($2, $5);
  } ;

e1:
  e1 '.' e1         { BINOP($$, cons,        @2, $1, @1, $3, @3); } |
  e1 LOGICAL_OR e1  { BINOP($$, logical_or,  @2, $1, @1, $3, @3); } |
  e1 LOGICAL_XOR e1 { BINOP($$, logical_xor, @2, $1, @1, $3, @3); } |
  logical_and_expr ;

logical_and_expr:
  logical_and_expr LOGICAL_AND e2 {
    BINOP($$, logical_and, @2, $1, @1, $3, @3);
  } |
  e2 ;

e2:
  e2 EQ e2          { BINOP($$, eq,          @2, $1, @1, $3, @3); } |
  e2 NE e2          { BINOP($$, ne,          @2, $1, @1, $3, @3); } |
  e2 '<' e2         { BINOP($$, lt,          @2, $1, @1, $3, @3); } |
  e2 LE e2          { BINOP($$, le,          @2, $1, @1, $3, @3); } |
  e2 '>' e2         { BINOP($$, gt,          @2, $1, @1, $3, @3); } |
  e2 GE e2          { BINOP($$, ge,          @2, $1, @1, $3, @3); } |
  e2 '|' e2         { BINOP($$, bitor,       @2, $1, @1, $3, @3); } |
  e2 '^' e2         { BINOP($$, bitxor,      @2, $1, @1, $3, @3); } |
  e2 '&' e2         { BINOP($$, bitand,      @2, $1, @1, $3, @3); } |
  e2 SHIFT_LEFT e2  { BINOP($$, shift_left,  @2, $1, @1, $3, @3); } |
  e2 SHIFT_RIGHT e2 { BINOP($$, shift_right, @2, $1, @1, $3, @3); } |
  e2 '+' e2         { BINOP($$, add,         @2, $1, @1, $3, @3); } |
  e2 '-' e2         { BINOP($$, subtract,    @2, $1, @1, $3, @3); } |
  e2 '*' e2         { BINOP($$, multiply,    @2, $1, @1, $3, @3); } |
  e2 '/' e2         { BINOP($$, divide,      @2, $1, @1, $3, @3); } |
  e2 '%' e2         { BINOP($$, remainder,   @2, $1, @1, $3, @3); } |
  unary_expr ;

unary_expr:
  e3 {
    if (!check_comp_int_range($1))
      YYABORT;
    $$ = $1;
  };

/* may return out-of-range integer; cf. unary_expr */
e3:
  '-' e3         { UNOP($$, negate,      @1, $2); } |
  '!' unary_expr { UNOP($$, logical_not, @1, $2); } |
  '~' unary_expr { UNOP($$, bitnot,      @1, $2); } |
  incrementer unary_expr {
    $$ = new_increment_expr(cur_arith_mode, $1, $2, false, LLOC_LOC(@1));
    if ($$ == NULL)
      YYABORT;
  } |
  e4 ;

e4_safe:
  e4 {
    if (!check_comp_int_range($1))
      YYABORT;
    $$ = $1;
  };

/* may return out-of-range integer; cf. e4_safe */
e4:
  e4_safe open_paren opt_call_list close_paren {
    int nargs = 0;
    for (struct clist *l = $3; l; l = l->next)
      if (++nargs > MAX_FUNCTION_ARGS)
        {
          compile_error(
            &l->c->loc,
            "functions can be called with at most %d arguments",
            MAX_FUNCTION_ARGS);
          YYABORT;
        }
    $$ = new_execute_component(LLOC_LOC(@2), new_clist($1, $3));
  } |
  e4_safe open_sq_bracket expr close_sq_bracket {
    $$ = new_binop_component(LLOC_LOC(@2), arith_default, b_ref, $1, $3);
  } |
  e4_safe incrementer {
    $$ = new_increment_expr(cur_arith_mode, $2, $1, true, LLOC_LOC(@1));
    if ($$ == NULL)
      YYABORT;
  } |
  primary_expr ;

incrementer:
  INCREMENT { $$ = b_add; } |
  DECREMENT { $$ = b_subtract; } ;

paren_expr:
  open_paren expr close_paren { UNOP($$, paren, @1, $2); } ;

/* may return out-of-range integer */
primary_expr:
  variable_recall |
  simple_constant {
    $$ = new_const_component($1);
  } |
  '\'' constant {
    $$ = new_const_component($2);
  } |
  maybe_arith_code_block {
    $$ = new_block_component($1);
  } |
  paren_expr ;

opt_call_list:
  %empty { $$ = NULL; } |
  call_list { $$ = reverse_clist($1); } ;

call_list:
  call_list COMMA expr { $$ = new_clist($3, $1); } |
  expr { $$ = new_clist($1, NULL); } ;

int_constant:
  INTEGER { $$ = new_int_constant($1.i, $1.base, LLOC_LOC(@1)); } ;

float_constant:
  FLOAT { $$ = new_float_constant($1.d, $1.base, LLOC_LOC(@1)); } ;

unary_constant:
  '-' float_constant { $$ = new_unary_constant(b_negate, $2, LLOC_LOC(@1)); } |
  '-' int_constant { $$ = new_unary_constant(b_negate, $2, LLOC_LOC(@1)); } |
  '~' int_constant {
    if (!check_int_range($2->u.integer.i, LLOC_LOC(@2)))
      YYABORT;
    $$ = new_unary_constant(b_bitnot, $2, LLOC_LOC(@1));
  } |
  '!' int_constant {
    if (!check_int_range($2->u.integer.i, LLOC_LOC(@2)))
      YYABORT;
    $$ = new_unary_constant(b_logical_not, $2, LLOC_LOC(@1));
  } |
  simple_constant {
    if ($1->vclass == cst_int
        && !check_int_range($1->u.integer.i, LLOC_LOC(@1)))
      YYABORT;
    $$ = $1;
  };

force_constant:
  START_CONSTANT { cur_rwmode = rwmode_im; } constant { $$ = $3; } |
  START_STORABLE { cur_rwmode = rwmode_rw; } constant { $$ = $3; } ;

table_class:
  plain_symbol {
    if (strcasecmp($1, "c") != 0)
      {
        compile_error(LLOC_LOC(@1), "unexpected symbol %s", $1);
        YYABORT;
      }
    $$ = cst_ctable;
  } |
  %empty { $$ = cst_table; }

im_ro_rwmode_prefix: HASH_IM | HASH_RO | HASH_RW ;

constant_container_rwmode_prefix:
  im_ro_rwmode_prefix {
    if (cur_rwmode == rwmode_im)
      {
        compile_error(
          LLOC_LOC(@1),
          "invalid %s inside immutable block",
          rwmode_names[$1]);
        YYABORT;
      }
    $$ = cur_rwmode;
    cur_rwmode = $1;
  } ;

constant_string_rwmode_prefix: HASH_RO | HASH_RW ;

constant:
  constant_container_rwmode_prefix constant_container {
    $$ = $2;
    cur_rwmode = $1;
  } |
  constant_string_rwmode_prefix string_constant {
    $2->rwmode = $1;
    if ($1 == rwmode_rw && const_rwmode_is_dynamic())
      $2->is_dynamic = true;
    $$ = $2;
  } |
  constant_no_prefix ;

constant_container:
  open_brace table_class constant_table_entry_list close_brace {
    if (cstlist_has_len($3, MAX_TABLE_ENTRIES + 1))
      {
        compile_error(LLOC_LOC(@1),
                      "constant table size exceeds %ld elements",
                      (long)MAX_TABLE_ENTRIES);
        YYABORT;
      }
    struct cstrlen *s0, *s1;
    if (cstlist_find_symbol_clash($3, $2 == cst_ctable, &s0, &s1))
      {
        struct strbuf sb0 = SBNULL, sb1 = SBNULL;
        bool use_ascii = mudout_wants_ascii();
        sb_write_string(&sb0, s0->str, s0->len, use_ascii);
        sb_write_string(&sb1, s1->str, s1->len, use_ascii);
        compile_error(LLOC_LOC(@1),
                      "%stable entry %s conflicts with entry %s",
                      $2 == cst_ctable ? "c" : "",
                      sb_str(&sb0), sb_str(&sb1));
        sb_free(&sb0);
        sb_free(&sb1);
        YYABORT;
      }
    $$ = new_table_constant($2, $3, cur_rwmode, LLOC_LOC(@1));
  } |
  open_brace table_class close_brace {
    $$ = new_table_constant($2, NULL, cur_rwmode, LLOC_LOC(@1));
  } |
  open_sq_bracket opt_constant_list close_sq_bracket {
    if (cstlist_has_len($2, MAX_VECTOR_SIZE + 1))
      {
        compile_error(LLOC_LOC(@1),
                      "constant vector length exceeds %ld elements",
                      (long)MAX_VECTOR_SIZE);
        YYABORT;
      }
    $$ = new_array_constant($2, cur_rwmode, LLOC_LOC(@1));
  } |
  open_paren constant_list opt_constant_list_tail close_paren {
    $$ = new_list_constant(new_cstlist($3, $2), cur_rwmode, LLOC_LOC(@1));
  } |
  open_paren close_paren { $$ = new_null_constant(LLOC_LOC(@1)); } |
  constant_symbol ;

constant_no_prefix:
  unary_constant |
  special_float_constant |
  constant_container |
  constant_expr |
  HASH_GONE { $$ = new_gone_constant(LLOC_LOC(@1)); } ;

opt_constant_list_tail:
  %empty { $$ = constant_null; } |
  '.' constant { $$ = $2; } ;

constant_symbol:
  open_lt constant_table_entry_no_prefix close_lt { $$ = $2; } ;

special_float_constant:
  plain_symbol {
    $$ = parse_special_float(&@1, false, $1);
    if ($$ == NULL)
      YYABORT;
  } |
  '-' plain_symbol {
    $$ = parse_special_float(&@2, true, $2);
    if ($$ == NULL)
      YYABORT;
  } ;

simple_constant:
  string_constant |
  int_constant |
  float_constant |
  BIGINT { $$ = new_bigint_constant($1, LLOC_LOC(@1)); } ;

string_constant:
  STRING { $$ = new_string_constant(&$1, LLOC_LOC(@1)); } ;

opt_constant_list:
  %empty { $$ = NULL; } |
  constant_list;

constant_list:
  constant { $$ = new_cstlist($1, NULL); } |
  constant_list constant { $$ = new_cstlist($2, $1); } ;

constant_expr:
  COMMA {
    check_constant_expr(&@1);
    check_space(&@1, $1.space_suffix, "constants");
  } constant_expr_tail { $$ = $3; } ;

constant_expr_tail:
  variable_recall {
    $$ = new_expr_constant($1);
  } |
  paren_expr { $$ = new_expr_constant($1); } ;

constant_table_entry_list:
  constant_table_entry {
    $$ = new_cstlist($1, NULL);
  } |
  constant_table_entry_list constant_table_entry {
    $$ = new_cstlist($2, $1);
  } ;

constant_table_entry:
  constant_container_rwmode_prefix constant_table_entry_no_prefix {
    $$ = $2;
    cur_rwmode = $1;
  } |
  constant_table_entry_no_prefix ;

constant_table_entry_no_prefix:
  constant_symbol_name '=' constant {
    $$ = new_symbol_constant(new_cstpair($1, $3), cur_rwmode, LLOC_LOC(@1));
  } ;

constant_symbol_name:
  string_constant | constant_expr ;

pattern:
  pattern_list |
  pattern_array |
  pattern_symbol |
  opt_typeset_braced '_' {
    $$ = new_pattern_sink($1, LLOC_LOC(@2));
  } |
  opt_typeset_braced variable {
    $$ = new_pattern_variable($2, $1, LLOC_LOC(@2));
  } ;

pattern_atom:
  pattern |
  unary_constant {
    $$ = new_pattern_constant($1, LLOC_LOC(@1));
  } |
  COMMA {
    check_space(&@1, $1.space_suffix, "patterns");
  } pattern_atom_expr {
    $$ = $3;
  } ;

pattern_atom_expr:
  variable_recall {
    $$ = new_pattern_expression($1);
  } |
  paren_expr { $$ = new_pattern_expression($1); } ;

pattern_symbol:
  open_lt pattern_atom '=' pattern_atom close_lt {
    $$ = new_pattern_symbol($2, $4, LLOC_LOC(@1));
    if ($$ == NULL)
      YYABORT;
  } ;

opt_pattern_sequence:
  %empty { $$ = NULL; } |
  opt_pattern_sequence pattern_atom {
    $$ = new_pattern_list($2, $1);
  } ;

opt_pattern_or:
  LOGICAL_OR pattern_or { $$ = $2; } |
  %empty { $$ = NULL; } ;

/* Complicated grammar below to special-case (p0 || p1), (p0 && e),
   and (p0 && e || p1)*/
pattern_list:
  open_paren pattern_atom LOGICAL_AND logical_and_expr opt_pattern_or
  close_paren {
    $$ = new_pattern_and_expr($2, $4);
    if ($5)
      $$ = new_pattern_or($$, $5, LLOC_LOC(@1));
  } |
  open_paren pattern_atom LOGICAL_OR pattern_or close_paren {
    $$ = new_pattern_or($2, $4, LLOC_LOC(@1));
  } |
  open_paren pattern_atom opt_pattern_sequence pattern_cdr close_paren {
    struct pattern_list *tail = new_pattern_list($4, $3);
    struct pattern_list *pl = tail;
    while (pl->next != NULL)
      pl = pl->next;
    pl->next = new_pattern_list($2, NULL);
    $$ = new_list_pattern(tail, LLOC_LOC(@1));
  } |
  open_paren close_paren {
    $$ = new_pattern_constant(constant_null, LLOC_LOC(@1));
  } ;

pattern_cdr:
  %empty { $$ = NULL; } |
  '.' pattern_atom { $$ = $2; } ;

pattern_array:
  open_sq_bracket opt_pattern_sequence ELLIPSIS opt_pattern_sequence
  close_sq_bracket {
    $$ = new_array_pattern($2, true, $4, LLOC_LOC(@1));
  } |
  open_sq_bracket opt_pattern_sequence close_sq_bracket {
    $$ = new_array_pattern($2, false, NULL, LLOC_LOC(@1));
  } ;

variable:
  SYMBOL {
    if (is_user_var_name($1))
      add_user_var($1);
  };

variable_recall:
  variable {
    $$ = new_recall_component($1, LLOC_LOC(@1));
  };

plain_symbol:
  SYMBOL {
    if (is_user_var_name($1) || is_global_var_name($1))
      {
        compile_error(LLOC_LOC(@1), "syntax error, expected a variable name");
        YYABORT;
      }
  } ;

maybe_arith_code_block:
  ARITH open_paren plain_symbol close_paren {
    $<arith_mode>$ = cur_arith_mode;
    if (!lookup_arith_mode(&cur_arith_mode, $3, &@3))
      YYABORT;
  } code_block {
    $$ = $6;
    $$->is_arith = true;
    $$->arith_mode = cur_arith_mode;
    cur_arith_mode = $<arith_mode>5;
  } |
  code_block ;

code_block:
  open_sq_bracket opt_local_vars expr_list close_sq_bracket {
    $$ = new_codeblock($2, $3, LLOC_LOC(@1));
  } ;

opt_local_vars:
  %empty { $$ = NULL; } |
  local_vars ;

local_vars:
  open_vbar { varlist_name = "variable name"; } variable_list
    close_vbar { $$ = $3; } ;

/* requires varlist_name to be set */
variable_list:
  variable_list COMMA plain_symbol {
    if (vlist_length($1) >= MAX_LOCAL_VARS)
      {
        compile_error(LLOC_LOC(@3), "too many local variables");
        YYABORT;
      }
    if (vlist_find($1, $3))
      {
        compile_error(LLOC_LOC(@3), "duplicate %s %s", varlist_name, $3);
        YYABORT;
      }
    $$ = new_vlist($3, TYPESET_ANY, LLOC_LOC(@3), $1);
  } |
  plain_symbol {
    $$ = new_vlist($1, TYPESET_ANY, LLOC_LOC(@1), NULL);
  } ;

%%

static bool do_parse(const struct parser_config *pconfig)
{
  assert(pconfig->pmode != parser_mode_undefined);
  assert(parser_mode == parser_mode_undefined);
  assert(ARRAY_IS_EMPTY(bracket_stack));

  parser_mode = pconfig->pmode;
  set_lex_config(pconfig);

  cur_arith_mode = arith_default;
  cur_rwmode = rwmode_ro;

  seen_user_vars = NULL;
  erred = false;
  parsed_code = NULL;
  parsed_constant = NULL;
  parsed_expr = NULL;
  int result = yyparse(pconfig);

  if (result == 0 && !ARRAY_IS_EMPTY(bracket_stack))
    {
      abort();
    }
  ARRAY_FREE(bracket_stack);

  parser_mode = parser_mode_undefined;
  set_lex_config(NULL);

  return result == 0 && !erred;
}

bool parse(struct mfile **f, const struct parser_config *pconfig)
{
  if (!do_parse(pconfig))
    return false;
  *f = parsed_code;
  if (parsed_code != NULL)
    (*f)->comments = lexer_comments();
  else
    assert(pconfig->allow_empty);
  return true;
}

bool parse_constant(struct constant **c, const struct parser_config *pconfig)
{
  if (!do_parse(pconfig) || parsed_constant == NULL)
    return false;
  *c = parsed_constant;
  return true;
}

bool parse_expression(struct component **e, int *end_pos, bool allow_tail,
                      const struct parser_config *pconfig)
{
  if (!do_parse(pconfig) && !allow_tail)
    return false;
  if (parsed_expr == NULL)
    return false;
  *e = parsed_expr;
  *end_pos = parsed_expr_end_pos;
  return true;
}

static struct bracket *find_sname_bracket(const char *sname, char *rbracketp)
{
  if (sname[0] != '\''
      || sname[1] == 0
      || sname[2] != '\''
      || sname[3] != 0)
    return NULL;

  size_t nbrackets = ARRAY_ENTRIES(bracket_stack);
  if (nbrackets == 0)
    return NULL;

  char rbracket = sname[1];

  static const char lbrackets[] = "({[<|";
  static const char rbrackets[] = ")}]>|";
  const char *rbpos = strchr(rbrackets, rbracket);
  if (rbpos == NULL)
    return NULL;

  struct bracket *b = &ARRAY_GET(bracket_stack, nbrackets - 1);
  if (b->c != lbrackets[rbpos - rbrackets])
    return NULL;

  *rbracketp = rbracket;
  return b;
}

static int yyreport_syntax_error(
  const yypcontext_t *ctx, const struct parser_config *pconfig)
{
  if (erred)
    return 0;

  yysymbol_kind_t lookahead = yypcontext_token(ctx);
  struct strbuf sb = sb_initf("syntax error, unexpected %s",
                              yysymbol_name(lookahead));

  struct bracket *brack = NULL;
  char rbracket = 0;

  yysymbol_kind_t expected[4];
  int n = yypcontext_expected_tokens(ctx, expected, VLENGTH(expected));
  if (n >= 1 && n <= 3)
    {
      sb_addstr(&sb, ", expecting ");
      for (int i = 0; i < n; ++i)
        {
          if (i > 0)
            sb_addstr(&sb, " or ");
          const char *sname = yysymbol_name(expected[i]);
          sb_addstr(&sb, sname);

          if (brack == NULL)
            brack = find_sname_bracket(sname, &rbracket);
        }
    }

  const struct loc *loc = LLOC_LOC(*yypcontext_location(ctx));
  compile_error(loc, "%s", sb_str(&sb));
  sb_free(&sb);

  if (brack != NULL)
    compile_note(LLOC_LOC(brack->loc),
                 "missing closing '%c' from here", rbracket);
  return n >= 0 ? 0 : n;
}
