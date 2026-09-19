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

#include "mudlle-string.h"
#include "prims.h"
#include "symbol.h"

#include "../table.h"


TYPEDOP(symbolp, "symbol?", "`x -> `b. True if `x is a symbol.", (value v),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY, "x.n")
{
  return makebool(TYPE(v, symbol));
}

static struct symbol *make_symbol(struct string *s, value v,
                                  const struct prim_op *op)
{
  CHECK_TYPES_OP(op,
                 s, string,
                 v, any);
  if (!obj_readonlyp(&s->o))
    {
      /* technically, symbol names do not have to be readonly, but as
         they always are in tables, we make them so anyway */
      GCPRO(v);
      s = make_readonly(mudlle_string_copy(s));
      UNGCPRO();
    }
  return alloc_symbol(s, v);
}

/* not OP_STR_READONLY as it would only apply to the name */
TYPEDOP(make_symbol, , "`s `x -> `sym. Creates a symbol with name `s and"
        " value `x.\nIf `s is not read-only, a read-only copy will be used.",
        (struct string *s, value x),
        OP_LEAF | OP_NOESCAPE, "sx.y")
{
  return make_symbol(s, x, THIS_OP);
}

/* not OP_STR_READONLY as it would only apply to the name */
TYPEDOP(make_psymbol, , "`s `x -> `sym. Creates a read-only symbol with"
        " name `s and value `x.\n"
        "If `s is not read-only, a read-only copy will be used.",
        (struct string *s, value x),
        OP_LEAF | OP_NOESCAPE | OP_CONST, "sx.y")
{
  bool imm = immutablep(x);
  struct symbol *sym = make_symbol(s, x, THIS_OP);
  sym->o.flags |= OBJ_READONLY | (imm ? OBJ_IMMUTABLE : 0);
  return sym;
}

TYPEDOP(symbol_name, , "`sym -> `s. Returns the name of a symbol",
	(struct symbol *msym),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "y.s")
{
  CHECK_TYPES(msym, symbol);
  return msym->name;
}

TYPEDOP(symbol_get, , "`sym -> `x. Returns the value of a symbol",
	(struct symbol *msym),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "y.x")
{
  CHECK_TYPES(msym, symbol);
  return msym->data;
}

EXT_TYPEDOP(symbol_set, "symbol_set!",
            "`sym `x -> `x. Sets the value of symbol `sym to `x",
            (struct symbol *s, value val), (s, val),
            OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "yx.2")
{
  CHECK_TYPES(s,   symbol,
              val, any);
  if (obj_readonlyp(&s->o))
    runtime_error(error_value_read_only);
  s->data = val;
  return val;
}

TYPEDOP(tablep, "table?", "`x -> `b. True if `x is a symbol table, including"
        " case- and accent-sensitive tables. Cf. `ctable?().",
        (value x),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "x.n")
{
  return makebool(TYPE(x, table));
}

TYPEDOP(ctablep, "ctable?", "`x -> `b. True if `x is a case- and accent-"
        " sensitive table. Cf. `table?().",
        (struct table *t),
	OP_LEAF | OP_NOALLOC | OP_NOESCAPE, "x.n")
{
  return makebool(TYPE(t, table) && is_ctable(t));
}

TYPEDOP(make_table, , "-> `table. Create a new (empty) case- and accent-"
        "insensitive symbol table. Cf. `make_ctable().",
        (void), OP_LEAF | OP_NOESCAPE, ".t")
{
  return alloc_table(DEF_TABLE_SIZE);
}

TYPEDOP(make_ctable, , "-> `table. Create a new (empty) case- and accent-"
        "sensitive symbol table. Cf. `make_table().",
        (void), OP_LEAF | OP_NOESCAPE, ".t")
{
  return alloc_ctable(DEF_TABLE_SIZE);
}

static struct table *vector_to_table(struct vector *v,
                                     const struct prim_op *op,
                                     bool readonly, bool ctable)
{
  CHECK_TYPES_OP(op, v, vector);

  size_t vlen = vector_len(v);
  int immutable = OBJ_IMMUTABLE;
  for (size_t i = 0; i < vlen; ++i)
    {
      struct symbol *sym = v->data[i];
      if (!TYPE(sym, symbol))
        RUNTIME_ERROR(error_bad_type, "table entry is not a symbol");
      immutable &= sym->o.flags;
    }

  ulong tsize = table_good_size(vlen);
  if (tsize > MAX_VECTOR_SIZE)
    runtime_error(error_bad_value);

  struct table *table = NULL;
  GCPRO(v, table);
  table = (ctable ? alloc_ctable : alloc_table)(tsize);
  for (size_t i = 0; i < vlen; ++i)
    {
      struct symbol *sym = v->data[i];
      if (table_mlookup(table, sym->name) != NULL)
        RUNTIME_ERROR(error_bad_value, "conflicting table entries");
      table_add_sym_fast(table, sym);
    }
  UNGCPRO();

  if (readonly)
    (immutable ? immutable_table : protect_table)(table);

  return table;
}

TYPEDOP(vector_to_table, , "`v -> `table. Create a new table from the symbols"
        " in `v. There will be a runtime error if any symbols collide.",
        (struct vector *v), OP_LEAF | OP_NOESCAPE, "v.t")
{
  return vector_to_table(v, THIS_OP, false, false);
}

TYPEDOP(vector_to_ptable, , "`v -> `table. Create a new read-only table from"
        " the symbols in `v.\n"
        "If all symbols are immutable, the table will also be immutable.\n"
        "There will be a runtime error if any symbols collide.",
        (struct vector *v), OP_LEAF | OP_NOESCAPE | OP_CONST, "v.t")
{
  return vector_to_table(v, THIS_OP, true, false);
}

TYPEDOP(vector_to_ctable, , "`v -> `table. Create a new case- and"
        " accentuation-sensitive table from the symbols in `v.\n"
        "There will be a runtime error if any symbols collide.",
        (struct vector *v), OP_LEAF | OP_NOESCAPE, "v.t")
{
  return vector_to_table(v, THIS_OP, false, true);
}

TYPEDOP(vector_to_pctable, , "`v -> `table. Create a new read-only case- and"
        " accentuation-sensitive table from the symbols in `v.\n"
        "If all symbols are immutable, the table will also be immutable.\n"
        "There will be a runtime error if any symbols collide.",
        (struct vector *v), OP_LEAF | OP_NOESCAPE | OP_CONST, "v.t")
{
  return vector_to_table(v, THIS_OP, true, true);
}

TYPEDOP(table_list, ,
	"`table -> `l. Returns list of symbols in `table whose value non-null",
	(struct table *table),
	OP_LEAF | OP_NOESCAPE, "t.l")
{
  CHECK_TYPES(table, table);
  return table_list(table);
}

TYPEDOP(table_foreach, ,
        "`c `table -> . Runs `c(`sym) for each non-null symbol `sym in `table."
        " It is safe to modify `table from `c().",
	(value f, struct table *table),
	0, "ft.")
{
  CHECK_TYPES(f,     CT_CALLABLE(1),
              table, table);

  struct vector *buckets = NULL;

  GCPRO(f, buckets);
  buckets = table_vector(table);

  size_t used = vector_len(buckets);
  for (size_t i = 0; i < used; ++i)
    call1(f, buckets->data[i]);

  UNGCPRO();

  undefined();
}

TYPEDOP(table_reduce, , "`f `x0 `t -> `x. Reduces table `t with function"
        " `x = `f(`s, `x) for each non-null symbol `s and initial value `x0.",
	(value f, value x, struct table *table),
	0, "fxt.x")
{
  CHECK_TYPES(f,     CT_CALLABLE(2),
              x,     any,
              table, table);

  struct vector *buckets = NULL;
  GCPRO(f, x, buckets);
  buckets = table_vector(table);

  size_t used = vector_len(buckets);
  for (size_t i = 0; i < used; ++i)
    x = call2(f, buckets->data[i], x);

  UNGCPRO();

  return x;
}

TYPEDOP(table_existsp, "table_exists?",
        "`c `table -> `sym|false. Returns the first non-null symbol `sym in"
        " `table for which `c(`sym) is true.\n"
        "Returns false if none found.",
	(value f, struct table *table),
	0, "ft.[yz]")
{
  CHECK_TYPES(f,     CT_CALLABLE(1),
              table, table);

  struct vector *buckets = NULL;
  value res = makebool(false);

  GCPRO(f, buckets);
  buckets = table_vector(table);

  size_t used = vector_len(buckets);
  for (size_t i = 0; i < used; ++i)
    if (istrue(call1(f, buckets->data[i])))
      {
	res = buckets->data[i];
	break;
      }

  UNGCPRO();

  return res;
}

TYPEDOP(table_vector, ,
        "`table -> `v. Returns a vector of the non-null entries in `table.",
	(struct table *table),
	OP_LEAF | OP_NOESCAPE, "t.v")
{
  CHECK_TYPES(table, table);
  return table_vector(table);
}

TYPEDOP(sorted_table_vector, ,
        "`table -> `v. Returns a vector of the non-null entries in `table, "
        "sorted by name (case-sensitive for ctables).",
	(struct table *table),
	OP_LEAF | OP_NOESCAPE, "t.v")
{
  CHECK_TYPES(table, table);
  return sorted_table_vector(table);
}

TYPEDOP(table_prefix, , "`table `s -> `l. Returns list of all symbols in"
        " `table whose value is non-null and whose name starts with `s.\n"
        "For non-ctables, case and accentuation are ignored.",
        (struct table *table, struct string *prefix),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "ts.l")
{
  CHECK_TYPES(table,  table,
              prefix, string);
  return table_prefix(table, prefix);
}

value table_ref(struct table *table, struct string *s,
                const struct prim_op *op)
{
  CHECK_TYPES_OP(op,
                 table, table,
                 s,     string);
  struct symbol *sym = table_mlookup(table, s);
  return sym == NULL ? NULL : sym->data;
}

TYPEDOP(table_ref, ,
        "`table `s -> `x. Returns the value of `s in `table, or null.",
        (struct table *table, struct string *s),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY, "ts.x")
{
  return table_ref(table, s, THIS_OP);
}

TYPEDOP(table_lookup, , "`table `s -> `sym|false. Returns the symbol for `s in"
        " `table, or false if none. Cf. `table_symbol_ref().\n"
        "Will also return symbols whose value is null.",
        (struct table *table, struct string *s),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY, "ts.[yz]")
{
  CHECK_TYPES(table, table,
              s,     string);
  struct symbol *sym = table_mlookup(table, s);
  return sym ? sym : makebool(false);
}

TYPEDOP(table_lookup_substring, , "`table `s `n0 `n1 -> `sym|false. Returns"
        " the symbol for the substring of `n1 characters in `s starting"
        " at index `n0 in `table, or false if not found.\n"
        "Will also return symbols whose value is null.\n"
        "Cf. `table_lookup().",
        (struct table *table, struct string *s, value midx, value mlen),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY, "tsnn.[yz]")
{
  long idx, len;
  CHECK_TYPES(table, table,
              s,     string,
              midx,  CT_STR_IDX(idx, s, true),
              mlen,  CT_RANGE(len, 0, LONG_MAX));
  if ((size_t)(idx + len) > string_len(s))
    RUNTIME_ERROR(error_bad_index, NULL);
  struct symbol *sym = table_mlookup_substring(table, s, idx, len);
  return sym ? sym : makebool(false);
}

struct symbol *table_symbol_ref(struct table *table, struct string *s, value x)
{
  struct symbol *sym = table_mlookup(table, s);
  if (sym != NULL)
    return sym;

  if (obj_readonlyp(&table->o))
    runtime_error(error_value_read_only);
  GCPRO(table, x);
  if (!obj_readonlyp(&s->o))
    s = make_readonly(mudlle_string_copy(s));
  sym = alloc_symbol(s, x);
  UNGCPRO();
  return table_add_sym_fast(table, sym);
}

TYPEDOP(table_symbol_ref, , "`table `s `x -> `sym. Returns the symbol for `s"
        " in `table, creating it with value `x if necessary.\n"
        "Will also return symbols whose value is null.\n"
        "Cf. `table_lookup().",
        (struct table *table, struct string *s, value x),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "tsx.y")
{
  CHECK_TYPES(table, table,
              s,     string,
              x,     any);
  return table_symbol_ref(table, s, x);
}

static value mudlle_table_set(value container, struct table *table,
                              struct string *s, value x,
                              const struct prim_op *op)
{
  enum runtime_error error = safe_table_mset(table, s, &x);
  if (error != error_none)
    primitive_runtime_error(error, op, 3, container, s, x);
  return x;
}

value do_table_set(struct table *table, struct string *s, value x,
                   const struct prim_op *op)
{
  CHECK_TYPES_OP(op,
                 table, table,
                 s,     string,
                 x,     any);
  return mudlle_table_set(table, table, s, x, op);
}

TYPEDOP(table_set, "table_set!",
        "`table `s `x -> `x. Sets the value of entry `s in"
        " `table to `x",
        (struct table *table, struct string *s, value x),
        OP_LEAF | OP_NOESCAPE, "tsx.3")
{
  return do_table_set(table, s, x, THIS_OP);
}

const struct prim_op *const table_set_ext = &op_table_set;

TYPEDOP(table_remove, "table_remove!",
        "`table `s -> `b. Removes the entry for `s in `table.\n"
        "This is a costly operation as it may need to partially rehash"
        " the table.\n"
	"Returns true if such an entry was found, even if it had value null.",
	(struct table *table, struct string *s),
	OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "ts.n")
{
  CHECK_TYPES(table, table,
              s,     string);
  if (obj_readonlyp(&table->o))
    runtime_error(error_value_read_only);
  return makebool(table_remove_len(table, s->str, string_len(s)) != NULL);
}

TYPEDOP(table_add_symbol, "table_add_symbol!",
        "`table `sym -> `sym. Adds the symbol `sym to table `table.\n"
        "Causes an error if there is a key conflict.",
        (struct table *table, struct symbol *sym),
        OP_LEAF | OP_NOESCAPE, "ty.2")
{
  CHECK_TYPES(table, table,
              sym,   symbol);
  if (table_mlookup(table, sym->name) != NULL)
    RUNTIME_ERROR(error_bad_value, "conflicting table entries");
  if (obj_readonlyp(&table->o))
    runtime_error(error_value_read_only);
  return table_add_sym_fast(table, sym);
}

TYPEDOP(table_copy, ,
        "`t0 -> `t1. Make a copy of table `t0, leaving out any null symbols.",
        (struct table *table),
        OP_LEAF | OP_NOESCAPE, "t.t")
{
  CHECK_TYPES(table, table);
  return table_copy(table);
}

TYPEDOP(table_shallow_copy, ,
        "`t0 -> `t1. Make a copy of table `t0, reusing its symbols.\n"
        "Will also copy symbols with value null.",
        (struct table *table), OP_LEAF | OP_NOESCAPE, "t.t")
{
  CHECK_TYPES(table, table);
  return table_shallow_copy(table);
}


void symbol_init(void)
{
  DEFINE(tablep);
  DEFINE(ctablep);
  DEFINE(make_table);
  DEFINE(make_ctable);
  DEFINE(table_ref);
  DEFINE(table_lookup);
  DEFINE(table_lookup_substring);
  DEFINE(table_symbol_ref);
  DEFINE(table_set);
  DEFINE(table_remove);
  DEFINE(table_add_symbol);
  DEFINE(table_copy);
  DEFINE(table_shallow_copy);

  DEFINE(table_list);
  DEFINE(table_vector);
  DEFINE(sorted_table_vector);
  DEFINE(table_prefix);
  DEFINE(table_foreach);
  DEFINE(table_reduce);
  DEFINE(table_existsp);

  DEFINE(vector_to_table);
  DEFINE(vector_to_ptable);
  DEFINE(vector_to_ctable);
  DEFINE(vector_to_pctable);

  DEFINE(make_symbol);
  DEFINE(make_psymbol);
  DEFINE(symbolp);
  DEFINE(symbol_name);
  DEFINE(symbol_get);
  DEFINE(symbol_set);


  DEFINE_INT(MAX_TABLE_ENTRIES);
}
