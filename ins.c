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

#include "alloc.h"
#include "assoc.h"
#include "builtins.h"
#include "calloc.h"
#include "dwarf.h"
#include "ins.h"
#include "mtree.h"
#include "mvalues.h"
#include "tree.h"


#include "runtime/mudlle-string.h"

#define assert_compiler(what, fn) assert(what)

/* Instruction lists are stored in reverse order, to simplify creation.
   They are reversed before use ...
*/

struct ilist			/* Instruction list */
{
  struct ilist *next;
  union instruction ins;
  struct label *lab;	       /* The main label for this instruction.
				  All other labels are aliases of this one. */
  struct label *to;		/* Destination of branches */
  ulong offset;			/* Offset from end of code ... */
  int lineno;
};

struct genblock
{
  struct genblock *next;
  const char *name;
  struct label *exitlab;        /* Label for block exit */
  int stack_depth;              /* Stack depth at block entry */
  bool leave_result;
};

struct fncode {
  struct loc loc;
  struct ilist *instructions;
  int current_depth, max_depth; /* This tracks the stack depth as
                                   determined by the instructions */
  struct label *next_label;	/* For the 'label' function */
  union dynpro_list csts;       /* Mudlle list of constants */
  uint16_t cstindex;		/* Index of next constant */
  struct genblock *blks;        /* Stack of named blocks */
  bool toplevel;
  struct alloc_block *memory;
  struct assoc_array locals;
};

struct label			/* A pointer to an instruction */
{
  struct ilist *ins;		/* The instruction this label points to */
  struct label *alias;		/* This label is actually an alias for
				   another label ... */
};

static void add_ins(uint8_t ins, struct fncode *fn)
{
  struct ilist *newp = allocate(fnmemory(fn), sizeof *newp);
  *newp = (struct ilist){
    .next   = fn->instructions,
    .ins.u  = ins,
    .lab    = fn->next_label,
    .lineno = fn->loc.line
  };
  fn->instructions = newp;
  if (fn->next_label)
    {
      fn->next_label->ins = newp;
      fn->next_label = NULL;
    }
}

void set_lineno(int line, struct fncode *fn)
{
  if (line > 0)
    fn->loc.line = line;
}

int adjust_depth(int by, struct fncode *fn)
/* Effects: Adjusts the current static stack depth of fn by the given
     amount. This is necessary for structures such as 'if' (which have
     code to compute 2 values, but which leave one on the stack).
   Modifies: fn
*/
{
  fn->current_depth += by;
  if (by > 0 && fn->current_depth > fn->max_depth)
    fn->max_depth = fn->current_depth;
  return fn->current_depth;
}

struct fncode *new_fncode(bool toplevel, const struct loc *loc)
/* Returns: A new function code structure (in which code for functions
     may be generated).
*/
{
  struct alloc_block *afnmemory = new_block();
  struct fncode *newp = allocate(afnmemory, sizeof *newp);
  *newp = (struct fncode){
    .toplevel = toplevel,
    .memory   = afnmemory,
    .loc      = *loc,
    .locals.type = &const_icharp_to_voidp_assoc_array_type
  };
  dynpro(&newp->csts, (struct list *)NULL);

  return newp;
}

bool fncode_add_vlist(struct vlist *vlist, struct fncode *fn)
{
  for (; vlist != NULL; vlist = vlist->next)
    {
      if (vlist->var[0] == '%')
        continue;
      struct vlist *prev = assoc_array_lookup(&fn->locals, vlist->var);
      if (prev != NULL)
        {
          compile_warning(&vlist->loc, "redefinition of '%s%s%s'",
                          CMARKUP(var, vlist->var));
          compile_note(&prev->loc, "the previous declaration is here");
          return false;
        }
      assoc_array_set(&fn->locals, vlist->var, vlist);
    }
  return true;
}

void fncode_remove_vlist(struct vlist *vlist, struct fncode *fn)
{
  for (; vlist != NULL; vlist = vlist->next)
    if (vlist->var[0] != '%')
      assoc_array_remove(&fn->locals, vlist->var);
}

void delete_fncode(struct fncode *fn)
/* Effects: deletes struct fncode *'fn'
 */
{
  assoc_array_free(&fn->locals);
  undynpro(&fn->csts);
  free_block(fn->memory);
}

struct alloc_block *fnmemory(struct fncode *fn)
/* Returns: memory block for fn
 */
{
  return fn->memory;
}

bool fntoplevel(struct fncode *fn)
/* Returns: true if 'fn' is the toplevel function
 */
{
  return fn->toplevel;
}

long add_constant(value cst, struct fncode *fn)
/* Effects: Adds a constant to code of 'fn'.
   Returns: The index where this constant is stored.
*/
{
  /* first, check for duplicates; mainly for strings */
  long idx = fn->cstindex - 1;
  for (struct list *l = fn->csts.l; l != NULL; l = l->cdr, --idx)
    if (l->car == cst)
      return idx;

  fn->csts.l = alloc_list(cst, fn->csts.l);
  assert_compiler(fn->cstindex < MAX_VALUE(fn->cstindex), fn);
  return fn->cstindex++;
}

void ins_constant(value cst, struct fncode *fn)
/* Effects: Adds code to push cst onto the stack in 'fn'
   Modifies: fn
*/
{
  if (cst == NULL)
    {
      ins0(op_null, fn);
      return;
    }

  if (integerp(cst))
    {
      long i = intval(cst);

      if (i >= INT8_MIN && i <= INT8_MAX)
	{
	  ins1(op_integer1, (uint8_t)i, fn);
	  return;
	}
      if (i >= INT16_MIN && i <= INT16_MAX)
	{
	  ins2(op_integer2, (uint16_t)i, fn);
	  return;
	}
    }

  long aindex = add_constant(cst, fn);
  if (aindex <= UINT8_MAX)
    ins1(op_constant1, aindex, fn);
  else
    ins2(op_constant2, aindex, fn);
}

void ins0(enum operator op, struct fncode *fn)
/* Effects: Adds instruction ins to code of 'fn'.
   Modifies: fn
*/
{
  switch (op)
    {
    case op_null:
      adjust_depth(1, fn);
      break;
    case op_discard: case op_builtin_eq: case op_builtin_neq:
    case op_builtin_le: case op_builtin_lt: case op_builtin_ge:
    case op_builtin_gt: case op_builtin_ref: case op_builtin_add:
    case op_builtin_sub: case op_builtin_bitand: case op_builtin_bitor:
      adjust_depth(-1, fn);
      break;
    case op_builtin_set:
    case op_args_range:
    case op_args_vararg:
      adjust_depth(-2, fn);
      break;
    case op_c_callback:         /* pops one, pushes one */
    case op_return:
    case op_builtin_bitnot: case op_builtin_not:
    case op_builtin_car: case op_builtin_cdr:
    case op_pop_args:
      break;
    default:
      abort();
    }
  add_ins(op, fn);
}

void ins1(enum operator op, long arg1, struct fncode *fn)
/* Effects: Adds instruction ins to code of 'fn'.
     The instruction has one argument, arg1.
   Modifies: fn
*/
{
  assert_compiler(arg1 >= 0 && arg1 <= UINT8_MAX, fn);

  switch (op)
    {
    case op_recall_local: case op_recall_closure:
    case op_integer1: case op_constant1:
    case op_closure:
      adjust_depth(1, fn);
      break;
    case op_typeset_check:
      adjust_depth(-1, fn);
      break;
    case op_execute: case op_execute_primitive:
    case op_execute_secure: case op_execute_varargs:
      adjust_depth(-arg1, fn);
      break;
    case op_args_fixed:
    case op_assign_closure:
    case op_assign_local:
    case op_clear_local:
    case op_closure_code1:
    case op_closure_var_closure:
    case op_closure_var_local:
    case op_exit_discard_n:     /* special handling */
    case op_exit_n:             /* special handling */
      break;
    default:
      if (op >= op_typecheck && op < op_typecheck + mudlle_synthetic_types)
        break;
      abort();
    }
  add_ins(op, fn);
  add_ins(arg1, fn);
}

void ins2(enum operator op, long arg2, struct fncode *fn)
/* Effects: Adds instruction ins to code of 'fn'.
     The instruction has a two byte argument (arg2), stored in big-endian
     format.
   Modifies: fn
*/
{
  assert_compiler(arg2 >= 0 && arg2 <= UINT16_MAX, fn);

  switch (op)
    {
    case op_recall_global:
    case op_integer2: case op_constant2:
      adjust_depth(1, fn);
      break;
    case op_execute_global_2arg: case op_execute_primitive_2arg:
      adjust_depth(-1, fn);
      break;
    case op_execute2: case op_execute_primitive2:
    case op_execute_secure2: case op_execute_varargs2:
      adjust_depth(-arg2, fn);
      break;
    case op_execute_primitive_1arg:
    case op_execute_global_1arg:
    case op_closure_code1:
    case op_closure_code2:
    case op_assign_global:
    case op_define:
      break;
    default:
      abort();
    }
  add_ins(op, fn);
  add_ins(arg2 >> 8, fn);
  add_ins(arg2 & 0xff, fn);
}

static void ins_access(enum operator base, enum variable_class vclass,
                       long ofs, struct fncode *fn)
{
  if (vclass == vclass_global)
    ins2(base + vclass, ofs, fn);
  else
    ins1(base + vclass, ofs, fn);
}

void ins_assign(enum variable_class vclass, long ofs, struct fncode *fn)
{
  ins_access(op_assign, vclass, ofs, fn);
}

void ins_recall(enum variable_class vclass, long ofs, struct fncode *fn)
{
  ins_access(op_recall, vclass, ofs, fn);
}

void ins_closure_var(enum variable_class vclass, long ofs, struct fncode *fn)
{
  ins_access(op_closure_var, vclass, ofs, fn);
}

void branch(enum operator abranch, struct label *to, struct fncode *fn)
/* Effects: Adds a branch instruction to lavel 'to' to instruction
     list 'next'.
     A 1 byte offset is added at this stage.
   Requires: 'branch' be a 1 byte branch instruction.
   Modifies: fn
*/
{
  switch (abranch)
    {
    case op_loop1: case op_branch1: break;
    case op_branch_nz1: case op_branch_z1:
      adjust_depth(-1, fn);
      break;
    default: abort();
    }
  add_ins(abranch, fn);
  fn->instructions->to = to;
  add_ins(0, fn); /* Reserve a 1 byte offset */
}

static void resolve_labels(struct fncode *fn)
/* Effects: Removes all references in branches to labels that are aliases
     (replaces them with the 'real' label.
     Also removes unconditional branches to the next instruction.
   Modifies: fn
   Requires: The code only contain 1 byte branches.
*/
{
  struct ilist *prev1 = NULL, *prev2 = NULL;
  for (struct ilist *scan = fn->instructions; scan; scan = scan->next)
    {
      if (scan->to)
	{
	  if (scan->to->alias) scan->to = scan->to->alias;
	  assert(scan->to->ins);

	  /* prev1 is the (reserved) offset, prev2 is the next instruction */
	  if (scan->ins.op == op_branch1 && scan->to->ins == prev2)
	    {
	      /* Remove branch to next instruction */
	      prev2->next = scan->next;
	      if (scan->lab)
		/* If removed instruction had a label, make it point
                   to prev2 */
		/* NOTE: This can lead to there being more than one unaliased
		   label pointing to a particular instruction !!! */
		scan->lab->ins = prev2;

	      /* Needed to handle consecutive branches to the next ins */
	      scan = prev2;
	      /* prev1 is junk here (deleted ins) */
	    }
	}

      prev2 = prev1;
      prev1 = scan;
    }
}

static void number_instructions(struct fncode *fn)
/* Effects: Numbers the instructions in fn (starting from the end)
   Modifies: fn
*/
{
  ulong offset = 0;
  for (struct ilist *scan = fn->instructions;
       scan;
       scan = scan->next, offset++)
    scan->offset = offset;
}

static bool resolve_offsets(struct fncode *fn)
/* Effects: Resolves all branch offsets in fn. Increases the size of
     the branches if necessary.
   Returns: true if all branches could be resolved without increasing
     the size of any branches
*/
{
  bool ok = true;

  struct ilist *prev1 = NULL, *prev2 = NULL;

  for (struct ilist *scan = fn->instructions; scan; scan = scan->next)
    {
      if (scan->to)		/* This is a branch */
	{
	  long offset = scan->offset - scan->to->ins->offset;

	  if ((scan->ins.op - op_branch1) & 1)
	    {
	      /* Two byte branch */
	      assert(prev1); assert(prev2);
	      offset -= 3;

	      if (offset >= INT16_MIN && offset <= INT16_MAX)
		{
		  prev1->ins.u = offset >> 8;
		  prev2->ins.u = offset & 0xff;
		}
	      else
		{
		  /* Branch doesn't fit. TBD. */
                  abort();
		}
	    }
	  else
	    {
	      /* One byte */
	      assert(prev1);
	      offset -= 2;

	      if (offset >= INT8_MIN && offset <= INT8_MAX)
		prev1->ins.u = offset;
	      else
		{
		  /* Make a 2 byte branch */
		  struct ilist *newp = allocate(fn->memory, sizeof *newp);
                  *newp = (struct ilist){
                    .next = scan
                  };
		  prev1->next = newp;
		  scan->ins.u++;

		  ok = false;
		}
	    }
	}

      prev2 = prev1;
      prev1 = scan;
    }
  return ok;
}

void peephole(struct fncode *fn)
/* Effects: Does some peephole optimisation on instructions of 'fn'
     Currently this only includes branch size optimisation (1 vs 2 bytes)
     and removal of unconditional branches to the next instruction.
     Also resolves branches...
   Modifies: fn
   Requires: All labels be defined
*/
{
  resolve_labels(fn);

  do
    number_instructions(fn);
  while (!resolve_offsets(fn));
}

static inline struct ilist *reverse_ilist(struct ilist *l)
{
  return reverse_list(l, struct ilist);
}

static struct string *build_lineno_data(struct ilist *ins)
{
  if (ins == NULL)
    return static_empty_string;

  ulong nins = 1;

  int last_line = -1;
  for (struct ilist *i = ins; i; i = i->next)
    if (i->lineno != last_line)
      {
        last_line = i->lineno;
        ++nins;
      }

  /* instructions offsets are numbered backwards here */
  const ulong last_ofs = ins->offset;

  struct lni_state *states = malloc(sizeof *states * nins);
  ulong i = 0;
  last_line = -1;
  for (; ins; ins = ins->next)
    if (ins->lineno != last_line)
      {
        last_line = ins->lineno;
        states[i] = (struct lni_state){
          .addr = last_ofs - ins->offset,
          .line = ins->lineno
        };
        ++i;
      }
  assert(i == nins - 1);
  states[i] = (struct lni_state){
    .addr = last_ofs + 1,
    .line = last_line
  };

  struct string *lni = dwarf_line_number_info(states, nins);
  free(states);
  return lni;
}

struct icode *generate_fncode(struct fncode *fn,
                              struct string *help,
                              struct string *varname,
                              const struct loc *loc,
                              struct vector *arguments,
                              bool is_vararg,
                              typeset_t return_typeset,
                              seclev_t seclev)
/* Returns: A code structure with the instructions and constants in 'fn'.
   Requires: generate_fncode may only be called on the result of the most
     recent call to new_fncode. That call is then deemed to never have
     occured :-) (this means that new_fncode/generate_fncode must be paired
     in reverse temporal order)
*/
{
  assert(loc->fname->filename != NULL && loc->fname->nicename != NULL);

  struct string *lineno_data = NULL;

  fn->instructions = reverse_ilist(fn->instructions);

  /* Count # of instructions */
  ulong sequence_length = 0;
  for (struct ilist *scanins = fn->instructions;
       scanins;
       scanins = scanins->next)
    ++sequence_length;

  assert(TYPE(arguments, vector));
  assert(immutablep(arguments));

  struct list *mfilenames = NULL;
  GCPRO(help, varname, mfilenames, arguments, lineno_data);

  mfilenames = scache_alloc_pair(loc->fname->filename, loc->fname->nicename);

  lineno_data = build_lineno_data(fn->instructions);

  /* Warning: Portability */
  ulong size = (offsetof(struct icode, constants)
                + fn->cstindex * sizeof (value)
                + sequence_length * sizeof (union instruction));
  struct icode *gencode = (struct icode *)gc_allocate(size);
  UNGCPRO();

  *gencode = (struct icode){
    .code = {
      .o = {
        .size         = size,
        .garbage_type = garbage_icode,
        .type         = type_icode,
        .flags        = OBJ_IMMUTABLE, /* code is immutable */
#ifdef GCDEBUG
        .generation = gencode->code.o.generation,
#endif
      },
      .varname        = varname,
      .filenames      = mfilenames,
      .help           = help,
      .vararg_alloc   = is_vararg,
      .arguments      = arguments,
      .linenos        = lineno_data,
      .lineno         = (loc->line > 0 && loc->line <= UINT16_MAX
                         ? loc->line
                         : 1),
      .column         = (loc->col > 0 && loc->col < (int)P(8)
                         ? loc->col
                         : 1),
      .seclevel       = seclev,
      .return_typeset = return_typeset,
    },
    .nb_constants      = fn->cstindex,
    .nb_locals         = 0,     /* initialized later */
    .stkdepth          = fn->max_depth,
    .instruction_count = 0,
  };

  assert(gencode->stkdepth == fn->max_depth); /* check in-range */

  /* Copy the sequence (which is reversed) */
  union instruction *codeins
    = (union instruction *)(gencode->constants + fn->cstindex);
  for (struct ilist *scanins = fn->instructions;
       scanins;
       scanins = scanins->next)
    *codeins++ = scanins->ins;

  /* Copy the constants */
  {
    struct list *csts = fn->csts.l;
    for (int i = fn->cstindex; i-- > 0; )
      {
        GCCHECK(csts);
        assert(TYPE(csts, pair));
        GCCHECK(csts->car);
        gencode->constants[i] = csts->car;
        csts = csts->cdr;
      }
    assert(csts == NULL);
  }

  /* Jump to interpreter to execute interpreted code - machine specific */

#ifndef NOCOMPILER
#ifdef __x86_64__
  static const struct magic_dispatch magic_dispatch = {
    .movq_r11 = { 0x49, 0xbb },
    .invoke   = 0,
    .jmpq_r11 = { 0x41, 0xff, 0xe3 },
    .nop3     = NOP3,
  };
  CASSERT_SIZEOF(magic_dispatch, 2 + 8 + 3 + 3);
  gencode->magic_dispatch = magic_dispatch;
  void (*invoke)(void) = interpreter_invoke;
  memcpy(&gencode->magic_dispatch.invoke, &invoke, sizeof invoke);
#else
  #error Unsupported architecture
#endif
#endif

#ifdef GCSTATS
  gcstats_add_alloc(type_icode, MUDLLE_ALIGN(size, sizeof (long)));
#endif

  return gencode;
}

struct label *new_label(struct fncode *fn)
/* Returns: A new label which points to nothing. Use label() to make it
     point at a particular instruction.
*/
{
  struct label *newp = allocate(fn->memory, sizeof *newp);
  *newp = (struct label){ .ins = NULL, .alias = NULL };
  return newp;
}

void set_label(struct label *lab, struct fncode *fn)
/* Effects: lab will point at the next instruction generated with ins0,
     ins1, ins2 or branch.
   Modifies: lab
*/
{
  if (fn->next_label) lab->alias = fn->next_label;
  else fn->next_label = lab;
}

void start_block(const char *name, bool leave_result, struct fncode *fn)
/* Effects: Starts a block called name (may be NULL), which can be
     exited with exit_block()
*/
{
  struct genblock *newp = allocate(fn->memory, sizeof *newp);

  *newp = (struct genblock){
    .next         = fn->blks,
    .name         = name,
    .exitlab      = new_label(fn),
    .stack_depth  = fn->current_depth,
    .leave_result = leave_result
  };

  fn->blks = newp;
}

void end_block(struct fncode *fn)
/* Effects: End of named block. Generate exit label
*/
{
  set_label(fn->blks->exitlab, fn);
  fn->blks = fn->blks->next;
}

/* find block by name 'name' (NULL for no-name loop); '*leave_result' is set to
   whether this block has a return value; NULL if not found */
struct genblock *find_block(const char *name, struct fncode *fn,
                            bool *leave_result)
{
  for (struct genblock *find = fn->blks; find != NULL; find = find->next)
    if (name == NULL
        ? find->name == NULL
        : find->name != NULL && strcasecmp(name, find->name) == 0)
      {
        *leave_result = find->leave_result;
        return find;
      }
  return NULL;
}

/* pops stack, jumps to 'block' */
void exit_block(struct genblock *block, struct fncode *fn)
{
  int npop = fn->current_depth - block->stack_depth;
  if (block->leave_result)
    --npop;
  assert(npop >= 0);
  if (npop > 0)
    ins1(block->leave_result ? op_exit_n : op_exit_discard_n, npop, fn);
  branch(op_branch1, block->exitlab, fn);
}
