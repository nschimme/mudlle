/*
 * Copyright (c) 1993-2012 David Gay
 * All rights reserved.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose, without fee, and without written agreement is hereby granted,
 * provided that the above copyright notice and the following two paragraphs
 * appear in all copies of this software.
 *
 * IN NO EVENT SHALL DAVID GAY BE LIABLE TO ANY PARTY FOR DIRECT, INDIRECT,
 * SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OF
 * THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF DAVID GAY HAVE BEEN ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 *
 * DAVID GAY SPECIFICALLY DISCLAIM ANY WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS" BASIS, AND DAVID
 * GAY HAVE NO OBLIGATION TO PROVIDE MAINTENANCE, SUPPORT, UPDATES,
 * ENHANCEMENTS, OR MODIFICATIONS.
 */

/* Simple type inference for mudlle

  Based on a "constraint model":
    - a first pass deduces the constraints on the types of variables induced
      by each intermediate instruction
    - a second pass solves these constraints, using standard data-flow
      techniques (the constraints are such that this is possible)
      this produces possible types for each variable at the start of each
      block, this can then easily be used in the code generation phase to
      generate better code for the intermediate instructions

  A constraint expresses the idea that if the arguments of an instruction
  follow certain type relations, the result will follow some (possibly
  distinct) relation.

  Types
  -----

  This simple type inference scheme has a simple notion of the "possible type"
  of a variable: a subset of the base mudlle types. To simplify things,
  some types that are considered distinct by the implementation are merged
  into a single type. So the possible type is actually a subset of:

   { function (= { closure, primitive, varargs, secure })
     integer
     string
     vector
     null
     symbol
     table
     pair
     other (= { object, character, gone, private })
   }

  'function' is a group as the differences between these types are
  supposed to be invisible (hmm).

  'other' represents types that are both not usefully inferred (see below),
  and which can not be distinguished anyway (values of type character or
  object can mutate into values of type gone, invisibly)

  So for example, the possible type of variable x after:

    if (a) x = 3
    else x = "fun";

  is: { integer, string }

  If a variable is used as an argument and has an empty type set then the
  function contains a type error. One special type set is important:
  "any", ie all the above types.

  The inferred types serve only to improve the code for branch and
  compute operations:
    - primitives are written in C, making specialised versions without
      (some) type-checking would be prohibitive
    - global mudlle variables may change at anytime after compile & link,
      thus nothing useful can be done with calls to their contents
    - the compiler does no inter-procedural analysis


  Constraints
  -----------

  Back to constraints: for each instruction, a set of constraints is
  generated, the instruction will produce no type error if any of them
  is satisfied (this reflects the fact that operators and functions may
  be dynamically overloaded). All constraints are of the following form:

    condition1 & condition2 & ... => consequence

  where a condition is:

    var1 /\ var2 /\ ... /\ constant-set

  and a consequence:

    destvar contains (var1 /\ var2 /\ ... /\ constant-set)

  /\ is set-intersection. The conditions are a test that the
  result of the intersection is not the empty set, thus the
  two common conditions:

    var /\ { integer }: means var can be an integer
    var1 /\ var2: means var1 can be the same type as var2

  The number of conditions can be 0, the consequence can be absent
  (for branches).

  An example should help:

    a = b + c

  generates:

    b /\ { integer } & c /\ { integer } => a contains { integer }
    b /\ { string } & c /\ { string } => a contains { string }

  (with /\ = set intersection, and an implicit comparison to the
  empty set in each test). This means that if b can be an integer
  and c can be an integer, then after this instruction a can be an
  integer (and the same for 'string'). But, importantly it also
  implies: if before the instriuction b and c could be integers then
  after the instruction, b and c can also be integers (the main
  consequence of this apparent tautology is that if before the +
  b could be an integer or a string, and c just a string, then
  afterwards b can only be a string).

  The semantics of the set of constraints for an instruction is thus
  the following:

    let f be a function which uses variables v1, ..., vn,
    containing instruction i with constraints c1, ..., ck.

    let type_before(i, v) represent the possible type for v
    before instruction i, and type_after(i, v) the possible
    type afterwards.

    the contraints specify the relation between type_before and
    type_after, as follows:

      a) forall v not mentioned in c1, ..., ck .
           type_after(i, v) = type_before(i, v)

      b) for each constraint ci = 'cond1 & ... & condj => v contains cond'
         the following equations hold:

	   A(cond1) and ... and A(condj) ==> v contains B(cond)
	   for each condition l which refers to variables w1, ..., wm
	   and each of these variables w:
	     A(cond1) and ... and A(condj) ==> w contains B(condl)

           for all variables u mentioned in c1, ..., ck but not
  	   mentioned in condition of ci:
  	     A(cond1) and ... and A(condj) ==> u contains u
	   (ie constraints need not constrain all variables)

	   where A(cond) is B(cond) != empty-set
	   and B(x1 /\ ... /\ xp /\ constant) is
	     type_before(i, x1) /\ ... /\ type_before(i, xp) /\ constant

	 (omited consequences and constants behave naturally)

      c) type_after(i, v) contains only those elements implied by the
         equations in b, thus the definition of type_after(i, v) is
	 really:

	   type_after(i, v) =
	     union{cond = {condition} ==> v contains S and
	           condition is satisified} S

    explanation:
      a) means that there are no hidden effects on the types of
         variables not mentioned in the constraints
      b) summarises the consequence on the types of the variables
         present in the instruction
      c) means that all possible types of the variables are
         covered by the constraints

  Solving constraints
  -------------------

  The constraints are solved by a standard data-flow framework, which
  computes for each basic_block b, type_entry(b, v) and type_exit(b, v),
  the possible types for each variable v at entry and exit to the block.

  Given type_entry(b, v) it is possible to compute type_exit(b, v) by
  iteratively applying the constraints of the instructions in the block:

    type_before(first instruction of b, v) = type_entry(b, v)
    type_before(successor instruction i, v) = type_after(i, v)
    type_exit(b, v) = type_after(last instruction of b, v)

  The type inference is a forward data-flow problem (see the notes below
  for some justifications), with in(b) = type_entry(b), out(b) = type_exit(b)
  (ie the type sets for all variables of the function). The following
  equations must be satisfied:

    in(b) = union{p:predecessor of b} out(p)
    out(b) = result of applying constraints of b to in(b) (see above)
    in(entry) = all variables have type set "any"

  The union above is done per-variable type set, of course. Initialising
  all type sets to the empty set (except for in(entry)) and applying
  the standard iterative data-flow solution leads to minimal type
  sets satisfying all the equations [PROOF NEEDED...].


  Generating constraints
  ----------------------

  Each class of instruction will be considered separately.

  First, compute instructions:

    dest = op v1, ..., vn

  Each operation op has constraint templates, expressed in terms
  of its arguments and destinations. These templates are simply
  instantiated with the arguments and destination the actual
  instruction to produce the real constraints.

  Branches: like compute instructions, these have constraint
  templates, though with no consequence. In addition, basic blocks
  that end in a branch may have an additional constraint for the
  true branch, and another for the false branch.

  Traps: like compute instructions, again with no consequence.

  Memory: these are added after the optimisation phase, so can
  be ignored.

  Closure: in the absence of inter-procedural optimisation these
  just generate the constraint

    => dest contains { function }

  (Optimisation of calls to known functions, ie those within the
  same module which cannot change, is best handled by a separate
  algorithm)

  Return: no constraints.

  Call: function calls can be separated into 3 categories:

    a) those about which nothing is known (eg calls to functions passed
    as parameters, or to functions stored in global variables)

    b) calls to primitives, except those belonging to category c.

    c) calls to primitives that are known to cause no global side
    effects (most primitives except those like 'lforeach' which
    call a function passed as parameter, but also includes those
    that modify the 'actor' variable for instance ...)

  For a call instruction

    i: dest = call f, v1, ..., vn

  the constraints depend on the category of function f:

    if f belongs to categories a or b:
      forall v in ambvars(i) - { dest } .
        => v contains { "any" }

  This reflects the fact that all ambiguous variables may be assigned
  when an unknown function is called.

    if f belongs to categories b or c:
      f has some constraint templates which are instantiated as usual.

    if f belongs to category a:
      => dest contains { "any" }


  A final note about the instantiation of constants in constraint
  templates: they are simply replaced by '{ the-constants-type }',
  and all constants in the constraint are merged.


  Some notes
  ----------

  The system does purely forward type inference. Moving type checks
  backward in the code is tricky as possible globally visible
  side effects must be considered (the whole system does not stop
  at the first type error ...). This is similar to problems with
  exceptions.

  Consequences: type checks cannot be moved out of loops if they
  are not valid at the first iteration. There are however two
  possible ways to reduce these problems:

  a) the programmer can annotate function definitions with type
  information (which is good for documentation anyway), this
  reduces the number of loops were that information is missing
  b) the first iteration of a loop could be unrolled (not done)

  The framework does not consider the use of the same variable
  as multiple arguments (eg a[i] = i). Consider. (Correct solution
  appears to be that typeset for var is *intersection* of the
  consequences that concern it from a given constraint, and *union*
  between those from different constraints - cf semantics of constraints.
  Hmm, can lead to variables with no type after an operation ...
  Probably constraint conditions should be merged - is the obvious method
  correct?)

*/


/* Implementation notes.

   Type sets are represented by integers, this makes all the set manipulations
    simple and efficient.

   The itype_xxx constants represent the masks for the various types
   (itype_any being the "full" set, itype_none the empty set).

   The type_before/after/etc relations are represented by vectors indexed
   by the variable number, as produced by recompute_vars. Only type_entry/exit
   are explicitly kept (with the basic blocks, along with the rest of the
   data-flow information).

   constraint templates are represented in a form designed to make their entry
   easy. This form is different from that of the instantiated constraints,
   which is designed to make evaluation efficient.

   The type representation for constraints is as follows:

     block_constraints = list of instruction_constraints

     instruction_constraints =
       sequence(instruction,
		list of integer, // the variables concerned by the constraint
		list of constraint)

     constraint =
       sequence(list of condition,
		integer,	// consequence variable (false if absent)
		condition)	// consequence condition

     condition = pair(itypeset,
		      list of integer) // variables of condition

     itypeset = integer		// set built from the itype_xxx values

   variables are always identified by their index(number)

   See runtime.h for a description of the constraint template representation.
*/

library inference // type inference
requires compiler, dlist, flow, graph, ins3, misc, optimise, sequences, vars
defines mc:global_call_count, mc:itypeset_string
reads mc:verbose, mc:this_module
writes mc:tnargs, mc:tncstargs, mc:tnfull, mc:tnpartial, mc:this_function
[
  | op_types,
    branch_types, typesets, make_condition0, make_condition1,
    make_condition2, instantiate_constraint, build_iconstraint, new_typesets,
    generate_constraints, evaluate_condition, apply_iconstraint, typeset_eq?,
    typeset_union!, extract_types, show_typesets, showset, show_constraints,
    show_constraint, show_c, show_condition, generate_branch_constraints,
    simple_itypes, infer_typeof, infer_branch, infer_type_trap,
    describe_tsig, describe_typeset, concat_comma,
    tsig_has_args?, tsig_argc, verify_call_types,
    verify_branch_types, verify_compute_types, type_typesets,
    make_ftypes_from_cargs,
    changed_functions, changed_blocks |

  op_types = indexed_sequence(
    mc:b_eq             . '("xx.n"),
    mc:b_ne             . '("xx.n"),
    mc:b_lt             . '("nn.n"),
    mc:b_ge             . '("nn.n"),
    mc:b_le             . '("nn.n"),
    mc:b_gt             . '("nn.n"),
    mc:b_bitor          . '("nn.n"),
    mc:b_bitxor         . '("nn.n"),
    mc:b_bitand         . '("nn.n"),
    mc:b_shift_left     . '("nn.n"),
    mc:b_shift_right    . '("nn.n"),
    mc:b_add            . '("nn.n" "ss.s"),
    mc:b_subtract       . '("nn.n"),
    mc:b_multiply       . '("nn.n"),
    mc:b_divide         . '("nZ.n"),
    mc:b_remainder      . '("nZ.n"),
    mc:b_negate         . '("n.n"),
    mc:b_logical_not    . '("x.n"),
    mc:b_bitnot         . '("n.n"),
    mc:b_ref            . '("vn.x" "sn.n" "[ton]s.x"),
    mc:b_cons           . '("xx.k"),
    mc:b_logical_xor    . '("xx.n"),
    mc:b_assign         . '("x.1"),
    mc:b_car            . '("k.x"),
    mc:b_cdr            . '("k.x"),
    mc:b_slength        . '("s.n"),
    mc:b_vlength        . '("v.n"),
    mc:b_iadd           . '("nn.n"),
    mc:b_typeof         . '("x.n"),
    mc:b_loop_count     . '(".n"),
    mc:b_max_loop_count . '(".n"),
    mc:b_symbol_name    . '("y.s"),
    mc:b_symbol_get     . '("y.x"),
    mc:b_vector         . '("x*.v"),
    mc:b_sequence       . '("x*.v"),
    mc:b_pcons          . '("xx.k"),
    mc:b_ffs            . '("Z.Z" "z.z"),
    mc:b_funcarg        . '("n.x"));
  assert(vlength(op_types) == mc:builtins);

  | branch_descs, fmarkup, fmarkup_slength, fmarkup_vlength |
  fmarkup = fn (string s) fn () mc:markup_fn(s) + "()";
  fmarkup_slength = fmarkup("slength");
  fmarkup_vlength = fmarkup("vlength");

  branch_descs = indexed_sequence(
    mc:branch_bitand   . (fn () mc:builtin_long_name(mc:b_bitand)),
    mc:branch_nbitand  . (fn () mc:builtin_long_name(mc:b_bitand)),
    mc:branch_bitset   . fmarkup("bit_set?"),
    mc:branch_bitclear . fmarkup("bit_clear?"),
    mc:branch_vfind?   . fmarkup("vfind?"),
    mc:branch_vnfind?  . fmarkup("vfind?"),
    mc:branch_lt       . (fn () mc:builtin_long_name(mc:b_lt)),
    mc:branch_ge       . (fn () mc:builtin_long_name(mc:b_ge)),
    mc:branch_le       . (fn () mc:builtin_long_name(mc:b_le)),
    mc:branch_gt       . (fn () mc:builtin_long_name(mc:b_gt)),
    mc:branch_slength  . fmarkup("slength"),
    null               . fmarkup_slength,  // !=
    null               . fmarkup_slength,  // <
    null               . fmarkup_slength,  // >=
    null               . fmarkup_slength,  // <=
    null               . fmarkup_slength,  // >
    mc:branch_vlength  . fmarkup_vlength,  // ==
    null               . fmarkup_vlength,  // !=
    null               . fmarkup_vlength,  // <
    null               . fmarkup_vlength,  // >=
    null               . fmarkup_vlength,  // <=
    null               . fmarkup_vlength); // >
  assert(vlength(branch_descs) == mc:branch_equal);
  assert(vforeach(function?, branch_descs));

  branch_types = indexed_sequence(
    mc:branch_bitand   . '("nn"),
    mc:branch_nbitand  . '("nn"),
    mc:branch_bitset   . '("sn"),
    mc:branch_bitclear . '("sn"),
    mc:branch_vfind?   . '("xv"),
    mc:branch_vnfind?  . '("xv"),
    mc:branch_lt       . '("nn"),
    mc:branch_ge       . '("nn"),
    mc:branch_le       . '("nn"),
    mc:branch_gt       . '("nn"),
    mc:branch_slength  . '("sn"),  // ==
    null               . '("sn"),  // !=
    null               . '("sn"),  // <
    null               . '("sn"),  // >=
    null               . '("sn"),  // <=
    null               . '("sn"),  // >
    mc:branch_vlength  . '("vn"),  // ==
    null               . '("vn"),  // !=
    null               . '("vn"),  // <
    null               . '("vn"),  // >=
    null               . '("vn"),  // <=
    null               . '("vn")); // >
  assert(vlength(branch_types) == mc:branch_equal);

  | itype_set_signatures, itype_type_signatures |
  itype_set_signatures = '[
    (?n . ,itype_integer)
    (?l . ,itype_list)
    (?D . ,itype_float_like)
    (?B . ,itype_bigint_like)
    (?x . ,itype_any)
  ];

  itype_type_signatures = "fZsvuytkbdoz";
  assert(slength(itype_type_signatures) == vlength(itype_names));

  typesets = make_vector(128); // index from character to typeset
  vforeach(fn (s) typesets[car(s)] = cdr(s), itype_set_signatures);
  sforeachi(fn (i, sig) typesets[sig] = (1 << i), itype_type_signatures);
  protect(typesets);

  simple_itypes = '[
    (,itype_integer  . ,type_integer)
    (,itype_zero     . ,type_integer)
    (,itype_non_zero . ,type_integer)
    (,itype_string   . ,type_string)
    (,itype_vector   . ,type_vector)
    (,itype_pair     . ,type_pair)
    (,itype_symbol   . ,type_symbol)
    (,itype_table    . ,type_table)
    (,itype_null     . ,type_null)
    (,itype_float    . ,type_float)
    (,itype_bigint   . ,type_bigint)
  ];

  type_typesets = make_vector(mudlle_synthetic_types);
  vfill!(type_typesets, "x");
  vforeach(fn (t) type_typesets[car(t)] = cdr(t),
           '[(,type_integer      . "n")
             (,type_string       . "s")
             (,type_vector       . "v")
             (,type_pair         . "k")
             (,type_null         . "u")
             (,type_symbol       . "y")
             (,type_table        . "t")
             (,type_float        . "d")
             (,type_bigint       . "b")
             (,stype_function    . "f")
             (,stype_list        . "l")
             (,stype_float_like  . "D")
             (,stype_bigint_like . "B")
             (,stype_false       . "z")]);
  // consider whether to update the above if new types are added
  assert(mudlle_synthetic_types == 34);
  for (|t| t = 0; t < mudlle_types; ++t)
    match (mc:itypemap[t])
      [
        ,itype_other => type_typesets[t] = "o";
        ,itype_function => type_typesets[t] = "f";
      ];
  rprotect(type_typesets);

  | readonly_itypes, immutable_itypes |
  readonly_itypes = (itype_integer | itype_null | itype_float
                     | itype_bigint | itype_function);
  immutable_itypes = (itype_integer | itype_null | itype_float
                      | itype_bigint | itype_string);

  mc:global_call_count = make_table();

  concat_comma = fn (l, last)
    if (l == null)
      ""
    else if (cdr(l) == null)
      car(l)
    else
      [
        | result |
        result = car(l);
        loop
          [
            | this |
            l = cdr(l);
            this = car(l);
            if (cdr(l) == null)
              exit format("%s%s%s", result, last, this);
            result = format("%s, %s", result, this);
          ];
      ];

  | itype_star |
  itype_star = itype_any + 1; // signals Kleene closure for this argument

  | sig_to_isig, sig_isig_map, isig_args, isig_rtype, isig_rref |
  sig_isig_map = make_ctable();

  isig_args  = 0;    // vector of arg itypes; last may have itype_star
  isig_rtype = 1;    // return itype
  isig_rref  = 2;    // return arg reference index or null

  sig_to_isig = fn (string sig)
    [
      | sym |
      sym = table_symbol_ref(sig_isig_map, sig, null);
      match (symbol_get(sym))
        [
          () => null;
          x => exit<function> x;
        ];

      | nargs, siglen |
      siglen = slength(sig);
      nargs = 0;
      for (|i| i = 0; i < siglen; [ ++i; ++nargs ])
        match (sig[i])
          [
            ?. || ?* => exit<break> null;
            ?\[ => while (sig[++i] != ?\]) null;
          ];

      | v, rtype, rref |
      v = make_vector(nargs);
      rtype = for (|i, vi| vi = i = 0; ; ++i)
        [
          if (i == siglen)
            exit<break> itype_any;

          | c, t |
          c = sig[i];
          if (vi == nargs)
            [
              if (c == ?*)
                [
                  v[vi - 1] |= itype_star;
                  if (++i == siglen)
                    exit<break> itype_any;
                  c = sig[i];
                ];
              assert(c == ?.);
              if (++i == siglen)
                exit<break> itype_any;
              c = sig[i];
              if (c >= ?1 && c <= ?9)
                [
                  rref = c - ?1;
                  exit<break> v[rref] & ~itype_star;
                ];
            ];
          if (c == ?\[)
            [
              t = 0;
              loop
                [
                  c = sig[++i];
                  if (c == ?\]) exit null;
                  t |= typesets[c];
                ];
            ]
          else
            t = typesets[c];
          if (vi == nargs)
            exit<break> t;
          v[vi++] = t;
        ];
      symbol_set!(sym, sequence(protect(v), rtype, rref))
    ];

  | op_isigs, branch_isigs |
  op_isigs = protect(vmap(fn (sigs) [
    lprotect(lmap(sig_to_isig, sigs))
  ], op_types));
  branch_isigs = protect(vmap(fn (sigs) [
    lprotect(lmap(sig_to_isig, sigs))
  ], branch_types));

  // consider changing the below function
  assert(mudlle_synthetic_types == 34);

  mc:itypeset_string = fn """`n `b -> `s. Returns a description of itypeset\
 `n. If `b is false, separate options with "|"; otherwise comma-separate\
 them.""" (itype, simple?)
    [
      // keep in sync with sb_add_typeset() in error.c
      itype &= ~itype_star;
      assert(itype >= 0 && itype <= itype_any);
      if (itype == itype_any)
        exit<function> "any type";
      if (itype == 0)
        exit<function> "no type";
      if (itype == itype_any & ~itype_zero)
        exit<function> "not false";

      | spec |
      spec = '[
        (,itype_null        . ())
        (,itype_integer     . "integer")
        (,itype_zero        . ())
        (,itype_list        . "list")
        (,itype_string      . ())
        (,itype_vector      . ())
        (,itype_float_like  . "float_like")
        (,itype_bigint_like . "bigint_like")
      ];

      | l |
      itype = vreduce(fn (@(it . name), itype) [
        if (it == itype_null && (itype & itype_pair))
          exit<function> itype;  // handled by itype_list
        if (it & itype_integer
            && (itype & itype_bigint_like) == itype_bigint_like)
          exit<function> itype;  // handled by itype_{bigint,float}like
        if ((itype & it) == it)
          [
            if (name == null)
              name = itype_names[ffs(it) - 1];
            l = mc:markup_type(name) . l;
            itype &= ~it
          ];
        itype
      ], itype, spec);

      bits_foreach(fn (i) l = mc:markup_type(itype_names[i]) . l, itype);
      if (cdr(l) == null)
        car(l)
      else if (simple?)
        concat_comma(lreverse!(l), " or ")
      else
        concat_words(lreverse!(l), "|")
    ];

  describe_tsig = fn (sig)
    [
      | result |
      for (|i, len| [ i = 0; len = vlength(sig) ]; i < len; ++i)
        [
          | star? |
          star? = sig[i] & itype_star;
          | d |
          d = mc:itypeset_string(sig[i], false);
          if (star?)
            d += "...";
          result = d . result;
        ];
      format("(%s)", concat_comma(lreverse!(result), ", "))
    ];

  describe_typeset = fn (int ts)
    concat_comma(lmap(fn (n) mc:markup_type(type_names[n]),
                      types_from_typeset(ts)),
                 " and ");

  // traps are handled explicitly (only trap_type is of interest and
  // it is special)

  make_condition0 = fn (int constant) // makes "constant" condition
    constant . null;
  | condition_itype_any, condition_itype_function |
  condition_itype_any      = '(,itype_any);
  condition_itype_function = '(,itype_function);

  make_condition1 = fn (int constant, v) // makes condition v /\ constant
    match! (mc:const_itype(v))
      [
        ,false => constant . v[mc:v_number] . null;
        type   => (constant & type) . null;
      ];

  // makes condition v1 /\ v2 /\ constant
  make_condition2 = fn (int constant, v1, v2)
    [
      | type, vars |

      if (type = mc:const_itype(v1))
	constant = constant & type
      else vars = v1[mc:v_number] . vars;

      if (type = mc:const_itype(v2))
	constant = constant & type
      else vars = v2[mc:v_number] . vars;

      constant . vars
    ];

  | cv_conditions, cv_dest, cv_consequence |
  cv_conditions  = 0;           // list of conditions per argument
  cv_dest        = 1;           // destination variable number or false
  cv_consequence = 2;

  instantiate_constraint = fn (vector isig, list args, dest)
    // Types: isig: type signature vector isig_xxx
    //        args: list of var
    //	      dest: var (or false)
    // Requires: llength(args) = #arguments in template
    // Returns: the constraint produced by instantiating template with
    //   args and dest (if not false)
    // TBD: Prune constraints which contain a condition with itype_none.
    [
      | consequence, conditions, iargs |
      iargs = isig[isig_args];

      // Build conditions of constraint
      for (| i, sargs | [ i = 0; sargs = args ]; sargs != null; )
        [
          | arg, itype |
          @(arg . sargs) = sargs;
          itype = iargs[i];
          if (itype & itype_star)
            itype &= ~itype_star
          else
            ++i;
          conditions = make_condition1(itype, arg) . conditions;
        ];

      // Build consequence
      | dvar |
      if (dest)
	[
	  dvar = dest[mc:v_number];
          | rref |
          rref = isig[isig_rref];
	  if (rref != null)
	    [
	      | ref, nref, cond |
	      ref = nth(rref + 1, args);
	      nref = ref[mc:v_number];

	      // if ref is already in some condition, use same condition
	      if (cond = lexists?(fn (c) memq(nref, cdr(c)), conditions))
		consequence = cond
	      else
		consequence = make_condition1(itype_any, ref);
	    ]
          else
	    consequence = make_condition0(isig[isig_rtype]);
	]
      else
        dvar = false;

      // Finally assemble constraint; cv_xxx-indexed
      sequence(conditions, dvar, consequence)
    ];

  | icvars, init_icvars, icv_il, icv_icvars, icv_constraints, icv_copies |
  init_icvars = fn (ifn)
    if (icvars == null || slength(icvars) != (ifn[mc:c_fnvars] + 7) >> 3)
      icvars = mc:new_varset(ifn);

  icv_il          = 0;
  icv_icvars      = 1;
  icv_constraints = 2;
  icv_copies      = 3;

  build_iconstraint = fn (il, cl, copies)
    // Returns: A constraints list for instruction il, given its
    //   constraint list (extracts all vars referred to)
    [
      bclear(icvars);

      for (|scl| scl = cl; scl != null; scl = cdr(scl))
	[
	  | c |
	  c = car(scl);
          for (|conds| conds = c[cv_conditions];
               conds != null;
               conds = cdr(conds))
            for (|vl| vl = cdar(conds); vl != null; vl = cdr(vl))
              set_bit!(icvars, car(vl));
	  if (c[cv_dest])
	    [
              set_bit!(icvars, c[cv_dest]); // add dest
	      // but not its condition (cf semantics)
	    ];
	];

      // icv_xxx-indexed
      sequence(il, bitset_list(icvars), cl,
               lfilter(fn (@(dst . src)) [
                 bit_set?(icvars, dst) || bit_set?(icvars, src)
               ], copies))
    ];

  | return_itype |
  return_itype = fn (fvar)
    [
      | fclass, prim |
      fclass = if (mc:my_protected_global?(fvar))
        mc:v_global_constant
      else
        fvar[mc:v_class];
      if (fclass == mc:v_global_constant
          && any_primitive?(prim = global_value(fvar[mc:v_goffset])))
        lreduce(fn (sig, itype) [
          itype | sig_to_isig(sig)[isig_rtype]
        ], itype_none, primitive_type(prim))
      else
        itype_any
    ];

  | handle_apply, call_sites, add_call_site |

  add_call_site = fn (from_ifn, from_block, to_ifn)
    [
      | tonum |
      tonum = to_ifn[mc:c_fnumber];
      for (|cs| cs = call_sites[tonum]; cs != null; cs = cdr(cs))
        match (car(cs))
          [
            (,from_ifn . ,from_block) => exit<function> null;
          ];
      call_sites[tonum] = (from_ifn . from_block) . call_sites[tonum];
    ];

  handle_apply = fn (prim, args, types, dest, cfunc, block)
    [
      | fidx, rtypes |
      @[_ fidx _] = vexists?(fn (x) x[0] == prim, mc:apply_functions);

      rtypes = match (cfunc)
        [
          (_ . {vector} cifn) => [
            add_call_site(mc:this_function, block, cifn);
            cifn[mc:c_freturn_itype]
          ];
          _ => return_itype(nth(fidx, args))
        ];

      | l |
      l = lmap(fn (sig) instantiate_constraint(sig_to_isig(sig), args, dest),
               types);
      if (rtypes != itype_any)
        // rewrite consequences to only include rtypes
        lmap!(fn (@[condition dvar consequence]) [
          // cv_xxx-indexed
          sequence(condition, dvar,
                   lmap(fn (is) is & rtypes, consequence))
        ], l)
      else
        l
    ];

  | make_closure_condition, get_closure_return_itype, closure_args_callable? |

  get_closure_return_itype = fn (closure c)
    [
      | n |
      n = closure_return_itype(c);
      if (n < 0)
        mc:itypeset_from_typeset(closure_return_typeset(c))
      else
        n
    ];

  // true if function_arguments() 'cargs' can be called with 'nargs' arguments
  closure_args_callable? = fn (vector cargs, int nargs)
    [
      if (nargs == vlength(cargs))
        true
      else if (nargs > vlength(cargs))
        // allowed if last argument is variable-length
        vlength(cargs) > 0 && cdr(cargs[-1]) == null
      else
        match! (cdr(cargs[nargs]))
          [
            () => true;         // variable-length argument
            {int} n => n & TYPESET_FLAG_OPTIONAL
          ]
    ];

  make_closure_condition = fn (list args, int ndest,
                               vector targs, int tret)
    [
      | conditions |
      if (closure_args_callable?(targs, llength(args)))
        for (|i, a| [ i = 0; a = args ];
             a != null;
             [ ++i; a = cdr(a) ])
          [
            | tset |
            tset = cdr(targs[i]);
            if (tset == null)
              exit<break> null;    // hit variable-length argument
            tset &= ~typeset_flag_optional;
            conditions = make_condition1(
              mc:itypeset_from_typeset(tset),
              car(a)) . conditions;
          ];
      sequence(conditions, ndest, make_condition0(tret)) . null
    ];

  | exist_fns |
  exist_fns = '[
    [ ,vexists? ,vector? ,vreduce ]
    [ ,lexists? ,proper_list? ,lreduce ]
  ];

  | block_reset_copies |
  block_reset_copies = fn (block)
    [
      | all_copies |
      all_copies = block[mc:f_copies][mc:flow_map];
      block[mc:f_types][mc:flow_map] = breduce(fn (idx, copies) [
        | il, ins |
        il = all_copies[idx];
        ins = il[mc:il_ins];
        assert(ins[mc:i_class] == mc:i_compute
               && ins[mc:i_aop] == mc:b_assign);

        | dst, src |
        dst = ins[mc:i_adest][mc:v_number];
        src = car(ins[mc:i_aargs])[mc:v_number];
        if (dst && src)
          (dst . src) . copies
        else
          copies
      ], null, block[mc:f_copies][mc:flow_in]);
    ];

  generate_constraints = fn (block) fn (il, ambiguous, constraints)
    // Types: il: instruction
    // Returns: (constraints for instruction il) . constraints
    [
      | ins, class, new, ndvar, copies, add_copy |

      copies = block[mc:f_types][mc:flow_map];

      // kill copies of assigned variables
      ndvar = il[mc:il_defined_var];
      if (ndvar)
        copies = lfilter!(fn (@(dst . src)) dst != ndvar && src != ndvar,
                          copies);

      ins = il[mc:il_ins];
      class = ins[mc:i_class];
      if (class == mc:i_compute)
	<done> [
          | op, vclass, args, dest |
          op = ins[mc:i_aop];
	  args = ins[mc:i_aargs];
	  dest = ins[mc:i_adest];

          // type-infer constant dereference
          <normal> if (op == mc:b_ref && llength(args) == 2)
            [
              | value, dtypes, idxtype |
              vclass = car(args)[mc:v_class];
              if (vclass == mc:v_constant)
                value = car(args)[mc:v_kvalue]
              else if (vclass == mc:v_global_constant)
                value = global_value(car(args)[mc:v_goffset])
              else
                exit<normal> null;

              if (vector?(value))
                [
                  dtypes = vreduce(
                    fn (v, it) it | mc:value_itype(v), 0, value);
                  idxtype = itype_integer;
                ]
              else if (table?(value))
                [
                  dtypes = table_reduce(
                    fn (@<_ = v>, it) it | mc:value_itype(v),
                    itype_null, value);
                  idxtype = itype_string;
                ]
              else
                exit<normal> null;

              exit<done> new = sequence(
                make_condition1(idxtype, cadr(args)) . null,
                dest[mc:v_number],
                make_condition0(dtypes)) . null;
            ];

          if (op == mc:b_assign)
            [
              | dst, src |
              if ((dst = dest[mc:v_number]) && (src = car(args)[mc:v_number]))
                add_copy = (dst . src);
            ];

          new = lmap(fn (isig) instantiate_constraint(isig, args, dest),
                     op_isigs[op]);
	]
      else if (class == mc:i_branch)
	[
          | args, op |
	  args = ins[mc:i_bargs];
	  op = ins[mc:i_bop];
	  if (op < vlength(branch_isigs))
	    new = lmap(fn (isig) instantiate_constraint(isig, args, false),
		       branch_isigs[op]);
	]
      else if (class == mc:i_call)
	[
	  | escapes, f, fclass, prim, dest, ndest, args, clos, tfn |

	  dest = ins[mc:i_cdest];
	  ndest = dest[mc:v_number];
	  args = ins[mc:i_cargs];
	  f = car(args); args = cdr(args);
	  escapes = true;

          // allow type inference when calling our own functions if
          // this is a protected module
          fclass = if (mc:my_protected_global?(f))
            mc:v_global_constant
          else
            f[mc:v_class];

          tfn = ins[mc:i_cfunction];

	  // Call to known function ?
          if (vector?(tfn))
            [
              | atypes |
              atypes = mc:function_closure_args(tfn);

              add_call_site(mc:this_function, block, tfn);

              new = make_closure_condition(
                args, ndest, atypes,
                tfn[mc:c_freturn_itype]);

              if (tfn[mc:c_fnoescape])
                escapes = false;
            ]
          else if (fclass == mc:v_global_constant
                   && (primitive?(prim = global_value(f[mc:v_goffset]))
                    || secure?(prim))
                   && primitive_nargs(prim) == llength(args))
            [
              | types |
              if ((types = primitive_type(prim)) != null)
		[
		  if (primitive_flags(prim) & OP_APPLY)
                    new = handle_apply(prim, args, types, dest, tfn, block)
		  else
		    new = lmap(fn (sig) [
                      instantiate_constraint(sig_to_isig(sig), args, dest);
                    ], types)
		]
              else
                new = sequence(null, ndest, condition_itype_any) . null;
              if (primitive_flags(prim) & OP_NOESCAPE) escapes = FALSE;
            ]
          else if (fclass == mc:v_global_constant
                   && varargs?(prim = global_value(f[mc:v_goffset])))
            [
              | types, nargs |
              nargs = llength(args);
              types = primitive_type(prim);

              new = lreduce(fn (sig, new) [
                | isig |
                isig = sig_to_isig(sig);
                if (tsig_has_args?(isig[isig_args], nargs))
                  instantiate_constraint(isig, args, dest) . new
                else
                  new
              ], new, types);

              if (new == null)
                new = sequence(null, ndest, condition_itype_any) . null;

              if (primitive_flags(prim) & OP_NOESCAPE) escapes = FALSE;
            ]
          else if (fclass == mc:v_global_constant
                   && closure?(clos = global_value(f[mc:v_goffset])))
            [
              | ditype, exist_fn |

              ditype = get_closure_return_itype(clos);

              // exist_fn is [exist? type? reduce]
              exist_fn = vexists?(fn (@[ f ... ]) f == clos, exist_fns);
              if (exist_fn && llength(args) == 2)
                <skip> [
                  | haystack |
                  @(_ haystack) = args;
                  if (haystack[mc:v_class] != mc:v_constant)
                    exit<skip> null;
                  haystack = haystack[mc:v_kvalue];
                  if (!exist_fn[1](haystack))
                    exit<skip> null;

                  ditype = exist_fn[2](fn (e, dt) dt | mc:value_itype(e),
                                       itype_zero, haystack)
                ];

              new = make_closure_condition(
                args, ndest,
                function_arguments(clos),
                ditype);

              if (closure_flags(clos) & clf_noescape)
                escapes = false;
            ]
	  else
	    [
	      // destination is any
	      new = sequence(make_condition1(itype_function, f) . null,
                             ndest, condition_itype_any) . null;
	    ];

	  if (escapes) // note global side effects
            bforeach(fn (i) if (i != ndest) [
              copies = lfilter!(fn (@(dst . src)) [
                dst != i && src != i
              ], copies);
              new = sequence(null, i, condition_itype_any) . new
            ], ambiguous);
	]
      else if (class == mc:i_trap)
	<skip> [
          | itype, dvar, typearg, top |
          top = ins[mc:i_top];
          if (top != mc:trap_type && top != mc:trap_typeset)
            exit<skip> null;
          @(dvar typearg . _) = ins[mc:i_targs];
          assert(typearg[mc:v_class] == mc:v_constant);
          typearg = typearg[mc:v_kvalue];
	  itype = match (top)
            [
              ,mc:trap_type    => mc:itypemap[typearg];
              ,mc:trap_typeset => mc:itypeset_from_typeset(
                typearg & ~mc:typeset_flag_return);
            ];
          | dest |
          dest = dvar[mc:v_number];
          new = bits_reduce(fn (i, res) [
            i = 1 << i;
            sequence(make_condition1(i, dvar) . null,
                     dest, make_condition0(i)) . res
          ], null, itype);
	]
      else if (class == mc:i_closure)
	[
          | dest |
	  dest = ins[mc:i_fdest][mc:v_number];
	  new = sequence(null, dest, condition_itype_function) . null;
	]
      else if (class == mc:i_memory)
        [
          if (ins[mc:i_mop] == mc:memory_read)
            [
              | dest |
              dest = ins[mc:i_mscalar][mc:v_number];
              new = sequence(null, dest, condition_itype_any) . null;
            ]
        ]
      else if (class == mc:i_return || class == mc:i_nop)
        null
      else if (class == mc:i_maybe_sconcat)
        [
          | dest, args |
          dest = ins[mc:i_scdest];
          args = ins[mc:i_scargs];
          // maybe_sconcat is either string or integer addition
          new = lmap(fn (sig) [
            instantiate_constraint(sig_to_isig(sig), args, dest)
          ], '("s*.s" "n*.n"));
        ]
      else
        fail_message(format("unsupported class %d", class));

      if (new != null)
        constraints = build_iconstraint(il, new, copies) . constraints;

      if (add_copy != null)
        copies = add_copy . copies;
      block[mc:f_types][mc:flow_map] = copies;

      constraints
    ];

  generate_branch_constraints = fn (block)
    // Types: block: cfg block
    // Returns: a pair of constraints for blocks that end in "interesting"
    //   branches, false otherwise
    //   The first element of the pair is applied when the branch is taken,
    //   the 2nd when it isn't.
    [
      | lastins, lastil, op, type, itype, reversed, var, copies |

      lastil = dget(dprev(block[mc:f_ilist]));
      lastins = lastil[mc:il_ins];
      // type branches are interesting, so is == and != null.
      if (lastins[mc:i_class] != mc:i_branch)
	exit<function> false;

      copies = block[mc:f_types][mc:flow_map];

      op = lastins[mc:i_bop];
      if (op >= mc:branch_type?)
	[
          | btype |
	  var = car(lastins[mc:i_bargs]);
	  if (op >= mc:branch_ntype?)
	    [
	      btype = op - mc:branch_ntype?;
	      reversed = true;
	    ]
	  else
	    [
	      btype = op - mc:branch_type?;
	      reversed = false;
	    ];
          type = mc:itypemap[btype];
          itype = mc:itypemap_inverse[btype];
	]
      else if (op == mc:branch_any_prim || op == mc:branch_not_prim)
        [
	  var = car(lastins[mc:i_bargs]);
          reversed = (op == mc:branch_not_prim);
          type = itype_function;
          itype = itype_any;
        ]
      else if (op == mc:branch_true || op == mc:branch_false)
        [
	  var = car(lastins[mc:i_bargs]);
          reversed = (op == mc:branch_true);
          type = itype_zero;
          itype = itype_any & ~itype_zero;
        ]
      else if ((op == mc:branch_eq || op == mc:branch_ne
                || op == mc:branch_equal || op == mc:branch_nequal))
	[
          reversed = (op == mc:branch_ne || op == mc:branch_nequal);
          if (lexists?(fn (v) mc:const_itype(v) == itype_null,
                       lastins[mc:i_bargs]))
            [
              type = mc:itypemap[type_null];
              itype = mc:itypemap_inverse[type_null];

              // constant folding prevents null == null
              var = lexists?(fn (v) mc:const_itype(v) != itype_null,
                             lastins[mc:i_bargs]);
            ]
          else
            [
              | lvar, rvar, ctrue, cfalse |
              @(lvar rvar) = lastins[mc:i_bargs];
              ctrue = sequence(make_condition2(itype_any, lvar, rvar) . null,
                               false, null);

              ctrue = build_iconstraint(lastil, ctrue . null, copies);
              cfalse = sequence(null, false, null);
              cfalse = build_iconstraint(lastil, cfalse . null, copies);

              exit<function>
                if (reversed) cfalse . ctrue
                else ctrue . cfalse
            ]
	]
      else if (op >= mc:branch_immutable && op <= mc:branch_writable)
        [
	  var = car(lastins[mc:i_bargs]);
          reversed = op == mc:branch_mutable || op == mc:branch_writable;
          type = itype_any;
          // some types are always immutable/read-only
          itype = if (op == mc:branch_immutable || op == mc:branch_mutable)
            itype_any & ~immutable_itypes
          else
            itype_any & ~readonly_itypes;
        ]
      else if (op == mc:branch_vfind? || op == mc:branch_vnfind?)
        [
          | haystack |
          @(var haystack) = lastins[mc:i_bargs];
          if (haystack[mc:v_class] != mc:v_constant)
            exit<function> false;
          reversed = op == mc:branch_vnfind?;
          haystack = haystack[mc:v_kvalue];
          type = vreduce(fn (v, it) it | mc:value_itype(v), 0, haystack);
          itype = itype_any;
          itype &= ~(type & (itype_null | itype_zero))
        ]
      else
	exit<function> false; // not interesting

      | ctrue, cfalse |
      ctrue = sequence(make_condition1(type, var) . null,
                       false, null);
      ctrue = build_iconstraint(lastil, ctrue . null, copies);
      cfalse = sequence(make_condition1(itype, var) . null,
			false, null);
      cfalse = build_iconstraint(lastil, cfalse . null, copies);

      if (reversed) cfalse . ctrue
      else ctrue . cfalse
    ];

  evaluate_condition = fn (condition, vector typeset)
    // Types: condition: condition
    //        typeset: vector of typesets
    // Returns: Result of condition given types in typeset
    [
      | x |
      x = car(condition);
      loop
        [
          condition = cdr(condition);
          if (condition == null) exit x;
          x &= typeset[car(condition)];
          if (x == itype_none) exit x;
        ]
    ];

  apply_iconstraint = fn (vector iconstraint, vector typeset)
    // Types: iconstraint: instruction_constraint
    //        typeset: vector of itypeset
    // Returns: The typeset resulting from the application of constraint
    //   to typeset
    [
      // tiny performance optimization
      assert(vlength(iconstraint) == icv_copies + 1);

      | new |

      // clear modified vars
      new = vcopy(typeset);
      for (|c| c = iconstraint[icv_icvars]; c != null; c = cdr(c))
        new[car(c)] = itype_none;

      for (|constr|constr = iconstraint[icv_constraints]; constr != null; )
	<next_constr> [
	  | results, last_result, c |
          @(c . constr) = constr;

          // tiny performance optimization
          assert(vlength(c) == cv_consequence + 1);

	  // dformat("applying %s\n", c);
	  for (|conds| conds = c[cv_conditions]; conds != null; )
	    [
	      | x, cond |
              @(cond . conds) = conds;
	      x = evaluate_condition(cond, typeset);
	      if (x == itype_none) exit<next_constr> null; // constraint failed

              // retain order from c[cv_conditions]
              x = list(x);
              if (last_result == null)
                results = x
              else
                set_cdr!(last_result, x);
              last_result = x;
	    ];
	  //dformat("success %s\n", results);

	  // condition successful, modify new typesets
	  // first, destination:
          | dest |
          dest = c[cv_dest];
	  if (dest)
	    new[dest] |= evaluate_condition(c[cv_consequence], typeset);

	  // then all concerned variables
	  for (|conds| conds = c[cv_conditions]; conds != null; )
	    [
              | cond, x |
              @(cond . conds) = conds;
	      @(x . results) = results;
              for (|args| args = cdr(cond); args != null; )
                [
                  | arg |
                  @(arg . args) = args;
                  if (arg != dest)
                    new[arg] |= x
                ];
	    ];
	];

      for (|copies| copies = iconstraint[icv_copies]; copies != null; )
        [
          | dst, src |
          @((dst . src) . copies) = copies;
          new[dst] = (new[src] &= new[dst])
        ];

      new
    ];

  new_typesets = fn (ifn)
    // Returns: A new sequence of typesets initialised to itype_none
    vfill!(make_vector(ifn[mc:c_fnvars]), itype_none);

  // Returns: True if all the typesets in ts1 are equal to those in ts2
  typeset_eq? = vequal?;

  // ts1 = ts1 U ts2 (per variable)
  typeset_union! = vector_bitor!;

  infer_type_trap = fn (il, ins, set?)
    [
      | v, itype, itypeset |
      v = cadr(ins[mc:i_targs]);
      itype = car(ins[mc:i_ttypes]);
      v = v[mc:v_kvalue];
      itypeset = if (set?)
        mc:itypeset_from_typeset(v & ~mc:typeset_flag_return)
      else
        mc:itypemap[v];
      if ((itype & itypeset) != itype_none)
        exit<function> null;
      mc:set_loc(il[mc:il_loc]);
      mc:warning("always causes bad type error");
      ins[mc:i_top] = mc:trap_always;
      ins[mc:i_targs] = null;
    ];

  // itypes for which we cannot use == instead of equal?();
  // cf. simple_equal?() in optimise.mud
  | itype_full_equal |
  itype_full_equal = (itype_symbol | itype_vector | itype_pair
                      | itype_table | itype_string | itype_float
                      | itype_bigint);

  infer_branch = fn (il, types, fold, change, all?)
    [
      | ins, bop, type1, type2 |

      ins = il[mc:il_ins];
      bop = ins[mc:i_bop];

      if (bop == mc:branch_always || bop == mc:branch_never)
        exit<function> if (all?) fold(il, bop == mc:branch_always);

      // unpack type1 and, optionally, type2
      @(type1 . (() || (type2))) = types;

      if (bop == mc:branch_eq || bop == mc:branch_ne
          || bop == mc:branch_equal || bop == mc:branch_nequal)
        [
          if (!(type1 & type2))
            fold(il, bop == mc:branch_ne || bop == mc:branch_nequal)
          else if ((type1 == itype_null || type1 == itype_zero)
                   && type1 == type2)
            fold(il, bop == mc:branch_eq || bop == mc:branch_equal)
          else if ((bop == mc:branch_equal || bop == mc:branch_nequal)
                   && ((type1 & itype_full_equal) == 0
                       || (type2 & itype_full_equal) == 0))
            [
              | nop |
              nop = if (bop == mc:branch_equal)
                mc:branch_eq
              else
                mc:branch_ne;
              change(ins, nop)
            ]
        ]
      else if (bop == mc:branch_true || bop == mc:branch_false)
        [
          if (~type1 & itype_zero)
            fold(il, bop == mc:branch_true)
          else if (type1 == itype_zero)
            fold(il, bop == mc:branch_false)
        ]
      else if (bop == mc:branch_immutable || bop == mc:branch_mutable)
        [
          if (!(type1 & ~immutable_itypes))
            fold(il, bop == mc:branch_immutable);
        ]
      else if (bop == mc:branch_readonly || bop == mc:branch_writable)
        [
          if (!(type1 & ~readonly_itypes))
            fold(il, bop == mc:branch_readonly);
        ]
      else if (bop >= mc:branch_type?
               && bop < mc:branch_ntype? + mudlle_synthetic_types)
        [
          | btype, reversed |
          if (bop >= mc:branch_ntype?)
            [
              btype = bop - mc:branch_ntype?;
              reversed = true;
            ]
          else
            [
              btype = bop - mc:branch_type?;
              reversed = false;
            ];
          if (type1 & mc:itypemap[btype] == 0)
            fold(il, reversed)
          else if (type1 & mc:itypemap_inverse[btype] == 0)
            fold(il, !reversed)
        ]
    ];

  infer_typeof = fn (ins)
    [
      | simple, atype |
      atype = car(ins[mc:i_atypes]);
      simple = vexists?(fn (s) car(s) == atype, simple_itypes);
      if (simple)
        [
          ins[mc:i_aop] = mc:b_assign;
          ins[mc:i_aargs] = mc:var_make_constant(cdr(simple)) . null;
          if (mc:verbose >= 3)
            [
              display("Inferred typeof completely!\n");
            ]
        ]
    ];

  // calculate the number of arguments 'sig' requires (~N for N or more)
  tsig_argc = fn (vector sig)
    [
      | l |
      l = vlength(sig);
      if (l > 0 && (sig[-1] & itype_star))
        ~(l - 1)
      else
        l
    ];

  // true if 'sig' allows for 'argc' arguments
  tsig_has_args? = fn (vector sig, int argc)
    [
      | n |
      n = tsig_argc(sig);
      if (n < 0)
        argc >= ~n
      else
        argc == n
    ];

  make_ftypes_from_cargs = pair fn (vector cargs, int nargs)
    [
      | ftypes |
      ftypes = vfill!(make_vector(nargs), itype_any);

      for (|i| i = 0; i < nargs; ++i)
        [
          | ts |
          @(_ . ts) = cargs[i];
          if (ts == null)
            // hit variable-length argument, no more constraints
            exit<break> null;
          ts &= ~TYPESET_FLAG_OPTIONAL;
          ftypes[i] = mc:itypeset_from_typeset(ts);
        ];

      ftypes . null
    ];

  | our_define? |
  our_define? = fn (int gidx)
    lexists?(fn (def) def[mc:mv_gidx] == gidx,
             mc:this_module[mc:m_defines]);

  verify_call_types = fn (ins, typeset)
    [
      | f, ftype, args, atypes, nargs, fclass, fval, var_type, name,
        call_check |

      call_check = fn (fval)
        [
          | test_val |

          test_val = fn (v)
            [
              | vclass, val |
              vclass = v[mc:v_class];
              if (vclass == mc:v_constant)
                val = v[mc:v_kvalue]
              else if (vclass == mc:v_global_constant)
                val = global_value(v[mc:v_goffset])
              else
                exit<function> typeset[v[mc:v_number]];
              mc:itypemap[typeof(val)] . val
            ];

          | test_fn |
          if (!function?(test_fn = mc:lookup_call_check(fval)))
            exit<function> true;

          | s, targs |
          targs = lmap(test_val, args);
          if (s = test_fn(fval, targs))
            [
              mc:warning("%s", s);
              exit<function> false;
            ];

          true
        ];

      var_type = fn (v)
        [
          | type |
          if (type = mc:const_itype(v)) type
          else typeset[v[mc:v_number]]
        ];

      @(f . args) = ins[mc:i_cargs];
      ins[mc:i_ctypes] = atypes = lmap(var_type, ins[mc:i_cargs]);
      @(ftype . atypes) = atypes;
      nargs = llength(args);

      fclass = f[mc:v_class];

      if (~ftype & itype_function)
        [
          mc:warning("call of non-function (%s)",
                     mc:itypeset_string(ftype, true));
          exit<function> null;
        ];

      fval = ins[mc:i_cfunction];
      if (vector?(fval))
        name = fn() mc:fname(fval)
      else
        [
          name = fn() mc:markup_fn(global_name(f[mc:v_goffset])) + "()";
          if (fclass == mc:v_constant)
            fval = f[mc:v_kvalue]
          else if (fclass == mc:v_global_constant)
            fval = global_value(f[mc:v_goffset])
          else if (fclass == mc:v_global_define)
            [
              // cannot check our own defines
              if (our_define?(f[mc:v_goffset]))
                exit<function> null;
              fval = global_value(f[mc:v_goffset])
            ]
          else if (fclass == mc:v_global)
            [
              fval = global_value(f[mc:v_goffset]);
              if (!function?(fval))
                exit<function> null;
            ]
          else
            exit<function> null;

          if (fclass != mc:v_constant)
            [
              | vname |
              vname = global_name(f[mc:v_goffset]);
              if (mc:global_call_count[vname] == null)
                mc:global_call_count[vname] = 1
              else
                mc:global_call_count[vname]++;
            ];

          if (!function?(fval))
            [
              mc:warning("call of non-function (%s)",
                         mc:markup_type(type_names[typeof(fval)]));
              exit<function> null;
            ];
        ];

      if (function?(fval) && !call_check(fval))
        exit<function> null;

      | ftypes, badarg, desc, bad_nargs |
      bad_nargs = fn ({string,int,vector} expect)
        [
          if (vector?(expect))
            [
              | vararg?, min |
              vararg? = false;
              min = 0;
              for (|i|i = vlength(expect); --i >= 0; )
                match (cdr(expect[i]))
                  [
                    () => vararg? = true;
                    {int} n && !(n & TYPESET_FLAG_OPTIONAL)
                      => exit<break> min = i + 1;
                  ];
              | minstr |
              minstr = mc:markup_number(min);
              expect = if (min == vlength(expect))
                minstr
              else if (vararg?)
                format("at least %s", minstr)
              else if (min + 1 == vlength(expect))
                format("%s or %s", minstr, mc:markup_number(vlength(expect)))
              else
                format("between %s and %s", minstr,
                       mc:markup_number(vlength(expect)))
            ];

          mc:warning("""bad number of arguments (%s) in call to %s %s,\
 expected %s""", mc:markup_number(nargs), desc, name(), expect);
        ];

      if (primitive?(fval) || secure?(fval))
        [
          desc = "primitive";
          if (primitive_nargs(fval) != nargs)
            bad_nargs(primitive_nargs(fval))
          else
            ftypes = lmap!(fn (sig) sig_to_isig(sig)[isig_args],
                         primitive_type(fval));
        ]
      else if (varargs?(fval))
        [
          desc = "vararg primitive";
          ftypes = lmap!(fn (sig) sig_to_isig(sig)[isig_args],
                         primitive_type(fval));
          if (ftypes != null
              && !lexists?(fn (t) tsig_has_args?(t, nargs), ftypes))
            [
              | allowed |
              // list of N or ~N for N+
              allowed = lmap(tsig_argc, ftypes);

              // sort according to N
              allowed = lqsort(fn (a, b) [
                if (a < 0) a = ~a;
                if (b < 0) b = ~b;
                a < b;
              ], allowed);

              // find min. fixed arguments for any vararg
              | minvararg |
              minvararg = MAXINT;
              lforeach(fn (n) if (n < 0) [
                n = ~n;
                if (n < minvararg)
                  minvararg = n
              ], allowed);

              if (minvararg < MAXINT)
                [
                  // merge any non-vararg which is one less
                  allowed = lreverse!(allowed);
                  lforeach(fn (n) [
                    if (n == minvararg - 1)
                      minvararg = n;
                  ], allowed);

                  // remove any unnecessary entries
                  allowed = lfilter!(fn (n) n > 0 && n < minvararg, allowed);
                  allowed = lreverse!(~minvararg . allowed);
                ];

              // filter out "mergable" options
              for (|a|a = allowed; cdr(a) != null; )
                [
                  if (car(a) < 0)
                    [
                      // if this is N+, then the rest do not matter
                      set_cdr!(a, null);
                      exit<break> null;
                    ];
                  if (car(a) == cadr(a))
                    [
                      // merge N and N
                      set_cdr!(a, cddr(a));
                    ]
                  else
                    a = cdr(a);
                ];

              // "pretty"-print
              allowed = lmap!(fn (n) [
                if (n >= 0)
                  itoa(n)
                else
                  format("at least %s", mc:markup_number(~n))
              ], allowed);
              bad_nargs(concat_comma(allowed, " or "));
              ftypes = null
            ]
        ]
      else if (closure?(fval) || vector?(fval))
        [
          | cargs |
          desc = "closure";
          cargs = if (closure?(fval))
            function_arguments(fval)
          else
            mc:function_closure_args(fval);

          if (!closure_args_callable?(cargs, nargs))
            bad_nargs(cargs)
          else
            ftypes = make_ftypes_from_cargs(cargs, nargs);
        ];

      if (!pair?(ftypes))
        exit<function> null;

      // assume defines from other modules retain their current type
      // for the sake of generating warnings
      [
        | aargs |
        aargs = args;
        atypes = lmap(fn (at) [
          | arg, gidx |
          @(arg . aargs) = aargs;
          if (at == itype_any
              && ((arg[mc:v_class] == mc:v_global_define
                   && !our_define?(gidx = arg[mc:v_goffset]))
                  || (arg[mc:v_class] == mc:v_global
                      && string?(module_vstatus(gidx = arg[mc:v_goffset])))))
            at = mc:value_itype(global_value(gidx));
          at
        ], atypes);
      ];

      if (!lexists?(fn (type) [
        | ai, ti, a |

        if (!tsig_has_args?(type, nargs))
          exit<function> false;

        ai = ti = 0;
        a = atypes;
        loop
          [
            if (a == null) exit true;
            if (ti >= vlength(type) || (type[ti] & car(a)) == 0)
              [
                badarg = vector(ai, ti, car(a));
                exit false;
              ];
            ++ai;
            if (!(type[ti] & itype_star))
              ++ti;
            a = cdr(a);
          ];
      ], ftypes))
        if (cdr(ftypes) == null && vector?(badarg))
          mc:warning(
            "bad type (%s) in argument %s of call to %s %s, expected %s",
            mc:itypeset_string(badarg[2], true),
            mc:markup_number(badarg[0] + 1),
            desc,
            name(),
            mc:itypeset_string(car(ftypes)[badarg[1]], true))
        else
          mc:warning(
            "bad type%s (%s) in call to %s %s, expected one of:%s",
            if (nargs == 1) "" else "s",
            concat_comma(lmap(fn (t) mc:itypeset_string(t, false),
                              atypes),
                         ", "),
            desc,
            name(),
            concat_words(
              lmap(fn (tsig) format("\n    %s", describe_tsig(tsig)),
                   ftypes),
              ""));
    ];

  | verify_sig_types |
  verify_sig_types = fn (atypes, otypes, ins, describe)
    [
      | badarg, badotype |
      if (!lexists?(fn (otype) [
        for (| a, ai, oi | [ a = atypes; oi = 0; ai = 1 ];
             a != null;
             [ ++ai; a = cdr(a) ])
          [
            | ot |
            ot = otype[isig_args][oi];
            if (car(a) & ot == 0)
              [
                badarg   = ai;
                badotype = ot;
                exit<function> false;
              ];
            if (!(ot & itype_star))
              ++oi;
          ];
        true
      ], otypes))
        [
          if (cdr(otypes) == null)
            mc:warning(
              "bad type (%s) in argument %s to %s, expected %s",
              mc:itypeset_string(nth(badarg, atypes), true),
              badarg,
              describe(ins),
              mc:itypeset_string(badotype, true))
          else
            mc:warning(
              "bad types (%s) in arguments to %s, expected one of:%s",
              concat_comma(lmap(fn (t) mc:itypeset_string(t, false), atypes),
                           ", "),
              describe(ins),
              concat_words(
                lmap(fn (isig) format("\n    %s",
                                      describe_tsig(isig[isig_args])),
                     otypes),
                ""))
        ];
    ];

  verify_compute_types = fn (ins)
    [
      | otypes, atypes |
      otypes = op_isigs[ins[mc:i_aop]];
      if (otypes == null) exit<function> null;

      atypes = ins[mc:i_atypes];
      verify_sig_types(atypes, otypes, ins,
                       fn (ins) mc:builtin_long_name(ins[mc:i_aop]))
    ];

  verify_branch_types = fn (ins)
    [
      | otypes, atypes, bop |
      bop = ins[mc:i_bop];
      if (bop >= vlength(branch_isigs))
        exit<function> null;
      otypes = branch_isigs[bop];
      if (otypes == null) exit<function> null;

      atypes = ins[mc:i_atypes];
      verify_sig_types(atypes, otypes, ins,
                       fn (ins) branch_descs[ins[mc:i_bop]]())
    ];

  | infer_argument_typesets |
  infer_argument_typesets = fn (ifn, orig_argtypesets)
    [
      | fg, entry, types, otypes, written_vars, escapes |

      mc:set_loc(ifn[mc:c_loc]);

      // get the first (entry) basic block
      fg = ifn[mc:c_fvalue];
      entry = graph_node_get(car(fg));

      types = entry[mc:f_types];
      otypes = types[mc:flow_out];

      // do ambiguous variables escape?
      escapes = dexists?(fn (il) [
        | ins, class |
        ins = il[mc:il_ins];
        class = ins[mc:i_class];
        class == mc:i_call && mc:call_escapes?(ins)
      ], entry[mc:f_ilist]);

      // the variables (possibly) written in this block
      written_vars = entry[mc:f_dvars];
      if (escapes)
        written_vars = bunion(written_vars,
                              entry[mc:f_ambiguous_w][mc:flow_gen]);

      for (|argn, fargs| [ argn = 1; fargs = ifn[mc:c_ffullargs] ];
           fargs != null;
           ++argn)
        [
          | arg, farg, var, ts, orig_argtypeset |
          @(farg . fargs) = fargs;
          @(orig_argtypeset . orig_argtypesets) = orig_argtypesets;
          arg = farg[mc:fullarg_arg];
          @[var ts _] = arg;
          if (ts == null)
            // do nothing for varargs
            exit<continue> null;
          if (bit_set?(written_vars, var[mc:v_number]))
            // do nothing if this variable was written in the block
            exit<continue> null;

          ts &= ~typeset_flag_optional;

          // the inferred typeset of this argument
          | newts |
          newts = mc:typeset_from_itypeset(otypes[var[mc:v_number]],
                                           ts & TYPESET_FALSE);

          // if necessary, update the argument type with type
          // information from this (first) basic block
          if (ts & ~newts)
            [
              newts &= ts;
              if (newts == 0)
                mc:warning("no valid type for argument %d (%s)",
                           argn, var[mc:v_name])
              else if (orig_argtypeset != typeset_any)
                mc:warning("invalid type(s) for argument %d (%s): %s",
                           argn, var[mc:v_name],
                           describe_typeset(ts ^ newts));
              arg[mc:vl_typeset] = newts;
            ];
        ]
    ];

  | function_isvs, isv_fn, isv_globals, isv_all_globals, isv_var_nums,
    isv_orig_argtypesets |
  isv_fn               = 0;
  isv_globals          = 1;
  isv_all_globals      = 2;
  isv_var_nums         = 3;
  isv_orig_argtypesets = 4;

  | ksconcat |
  ksconcat = mc:make_kglobal("sconcat");

  extract_types = fn (ifn)
    // Types: ifn: intermediate function
    // Modifies: ifn
    // Effects: Sets the type fields of ifn's instructions
    [
      | fg, nargs, ncstargs, npartial, nfull, compute_types |

      fg = ifn[mc:c_fvalue];
      nargs = ncstargs = npartial = nfull = 0;

      compute_types = fn (il, types)
	[
	  | ins, class, vtype, iconstraint, typeset, prevloc |

          prevloc = mc:get_loc();
          mc:set_loc(il[mc:il_loc]);

	  ins = il[mc:il_ins];
	  //mc:print_ins(ins, null);
	  //display("  types:"); show_typesets(car(types));
	  //newline();
	  class = ins[mc:i_class];
	  typeset = car(types);

	  vtype = fn (v)
	    [
	      | type |

	      ++nargs;
	      if (type = mc:const_itype(v))
		[
		  ++ncstargs;
		  type
		]
	      else
		[
                  | vnum |
                  vnum = v[mc:v_number];
                  assert(vnum > 0);
		  type = typeset[vnum];
                  if (type && (type & (type - 1)) == 0)
                    // only one bit set; fully inferred
		    ++nfull
		  else if (type != itype_any)
		    ++npartial;

		  type
		]
	    ];

	  if (class == mc:i_compute)
	    [
	      if (ins[mc:i_aop] != mc:b_assign)
                [
                  ins[mc:i_atypes] = lmap(vtype, ins[mc:i_aargs]);
                  if (ins[mc:i_aop] == mc:b_typeof)
                    infer_typeof(ins);
                  verify_compute_types(ins);
                ]
	    ]
	  else if (class == mc:i_branch)
	    [
              ins[mc:i_btypes] = lmap(vtype, ins[mc:i_bargs]);
              infer_branch(il, ins[mc:i_btypes],
                           mc:fold_branch,
                           fn (ins, op) ins[mc:i_bop] = op,
                           false);
              verify_branch_types(ins);
	    ]
	  else if (class == mc:i_trap)
            <skip> [
              | set? |
              set? = match (ins[mc:i_top])
                [
                  ,mc:trap_type => false;
                  ,mc:trap_typeset => true;
                  _ => exit<skip> null;
                ];
              ins[mc:i_ttypes] = lmap(vtype, ins[mc:i_targs]);
              infer_type_trap(il, ins, set?);
            ]
          else if (class == mc:i_return)
            [
              | rtype |
              rtype = ins[mc:i_rtype] = vtype(ins[mc:i_rvalue]);
              if (ifn[mc:c_freturn_itype] != rtype)
                lforeach(fn (@(cfn . cblock)) [
                  if (!lfind?(cfn, changed_functions))
                    changed_functions = cfn . changed_functions;
                  if (!lfind?(cblock, changed_blocks[cfn[mc:c_fnumber]]))
                    changed_blocks[cfn[mc:c_fnumber]]
                      = cblock . changed_blocks[cfn[mc:c_fnumber]];
                ], call_sites[ifn[mc:c_fnumber]]);

              ifn[mc:c_freturn_itype] = rtype;
            ]
          else if (class == mc:i_call)
            verify_call_types(ins, typeset)
          else if (class == mc:i_closure)
            [
              | cifn |
              cifn = ins[mc:i_ffunction];
              lforeach(fn (cvar) [
                | itype, base, var |
                assert(cvar[mc:v_class] == mc:v_closure);
                var = cvar[mc:v_cparent];
                base = mc:var_base(var);
                itype = mc:const_itype(base);
                if (!itype)
                  [
                    // we only propagate types of read-only variables
                    // (function arguments)
                    if (base[mc:v_lclosure_uses] != mc:closure_read)
                      exit<function> null;
                    itype = vtype(var);
                  ];
                if (itype == itype_any)
                  exit<function> null;

                | oitype, nitype, cfg, centry, cvnum |
                cvnum = cvar[mc:v_number];
                cfg = cifn[mc:c_fvalue];
                centry = graph_node_get(car(cfg));
                oitype = centry[mc:f_types][mc:flow_in][cvnum];
                nitype = oitype & itype;
                if (oitype == nitype)
                  exit<function> null;

                // we have proven some types impossible
                graph_nodes_apply(fn (n) [
                  | block |
                  block = graph_node_get(n);
                  block[mc:f_types][mc:flow_in][cvnum] &= itype;
                  block[mc:f_types][mc:flow_out][cvnum] &= itype;
                ], cdr(cfg));
                if (!lfind?(cifn, changed_functions))
                  changed_functions = cifn . changed_functions;
              ], cifn[mc:c_fclosure]);
            ]
          else if (class == mc:i_trap
                   || class == mc:i_memory
                   || class == mc:i_nop)
            null
          else if (class == mc:i_maybe_sconcat)
            [
              for (|args| args = ins[mc:i_scargs]; args != null; )
                [
                  | arg, atype |
                  @(arg . args) = args;
                  atype = vtype(arg);
                  if ((atype & itype_string) == 0)
                    // for sure integer addition; remove this instruction
                    exit<break> mc:make_il_nop(il);

                  if ((atype & itype_integer) == 0)
                    [
                      // string addition; upgrade to call to sconcat()
                      | newins |
                      il[mc:il_ins] = newins = mc:make_call_ins(
                        ins[mc:i_scdest], ksconcat . ins[mc:i_scargs]);
                      newins[mc:i_ctypes] = itype_function . ins[mc:i_sctypes];
                      il[mc:il_defined_var] = ins[mc:i_scdest][mc:v_number];
                      // il_arguments remains the same

                      // delete now-useless adds
                      lforeach(fn (addil) [
                        | addins |
                        addins = addil[mc:il_ins];
                        assert(addins[mc:i_class] == mc:i_compute
                               && addins[mc:i_aop] == mc:b_add);
                        mc:make_il_nop(addil)
                      ], ins[mc:i_scilist]);
                      exit<break> null;
                    ];
                ]
            ]
          else
            fail_message(format("unsupported class %d", class));

          mc:set_loc(prevloc);

	  if (cdr(types) != null && (iconstraint = cadr(types))[icv_il] == il)
	    [
	      // this instruction has a constraint
	      //display("applying "); show_constraint(iconstraint);
	      //newline();
	      apply_iconstraint(iconstraint, typeset) . cddr(types)
	    ]
	  else
	    types
	];

      graph_nodes_apply
        (fn (n)
	 [
	   | block, types |

	   block = graph_node_get(n);
	   types = block[mc:f_types];
	   //mc:ins_list1(block[mc:f_ilist]);
	   //mc:show_type_info(types);
	   dreduce(compute_types, types[mc:flow_in] . types[mc:flow_gen],
		   block[mc:f_ilist]);
	 ], cdr(fg));

      if (mc:verbose >= 3)
	[
	  dformat("Type inference results for %s:\n", mc:fname(ifn));
	  dformat("%d args, of which %d constant, %d fully inferred,"
                  + " %d partially.\n",
                  nargs, ncstargs, nfull, npartial);
	];
      mc:tnargs += nargs;
      mc:tncstargs += ncstargs;
      mc:tnfull += nfull;
      mc:tnpartial += npartial;
    ];

  | change_branch_to, remove_code_edge |

  remove_code_edge = fn (edge, entry)
    [
      | enode |
      enode = graph_edge_to(edge);
      graph_remove_edge(edge);

      // Remove the destination node if it is no longer reachable
      if (enode == entry
          || (graph_edges_in_exists?(fn (e) graph_edge_from(e) != enode, enode)
              && graph_node_reachable?(entry, enode)))
        exit<function> null;

      if (mc:verbose >= 3)
        [
          dformat(
            "UNREACHABLE BLOCK %d\n",
            dget(graph_node_get(enode)[mc:f_ilist])[mc:il_number]);
        ];
      lforeach(graph_remove_edge, graph_edges_in(enode));
      lforeach(fn (edge) remove_code_edge(edge, entry),
               graph_edges_out(enode));
      // mark instructions as gone
      dforeach(fn (il) il[mc:il_ins] = null,
               graph_node_get(enode)[mc:f_ilist]);
      graph_remove_node(enode);
    ];

  // Modify the branch target in 'edge' to point to the 'via_il' (a branch
  // instruction). Use its branch destination if 'take?' is true; otherwise use
  // its fall-through target.
  change_branch_to = fn (edge, via_il, take?, entry)
    [
      | dst_edge, dst_node, dst_block |
      dst_edge = graph_edges_out_exists?(fn (e) graph_edge_get(e) ^^ take?,
                                         via_il[mc:il_node]);

      dst_node = graph_edge_to(dst_edge);
      dst_block = graph_node_get(dst_node);

      | from_block, from_il, from_ins |
      // last instruction of from-block
      from_block = graph_node_get(graph_edge_from(edge));
      from_il = dget(dprev(from_block[mc:f_ilist]));
      from_ins = from_il[mc:il_ins];

      if (!graph_edge_get(edge))
        [
          // modify branch-taken edge
          assert(from_ins[mc:i_class] == mc:i_branch);
          | lab, dst_il |
          dst_il = dget(dst_block[mc:f_ilist]);
          lab = dst_il[mc:il_label];
          if (!lab)
            [
              lab = mc:new_label();
              mc:set_label(lab, dst_il);
            ];
          from_ins[mc:i_bdest] = lab;
          graph_add_edge(graph_edge_from(edge), dst_node, false);
        ]
      else
        [
          // modify fall-through edge
          | nblock, flow_in, live_in, branch_constraints |
          nblock = mc:add_fallthrough_block(from_block, dst_block);

          flow_in = from_block[mc:f_types][mc:flow_out];
          branch_constraints = from_block[mc:f_types][mc:flow_kill];
          if (branch_constraints)
            // apply fall-through constraints
            flow_in = apply_iconstraint(cdr(branch_constraints), flow_in);

          nblock[mc:f_types] = indexed_vector(
            mc:flow_gen  . null,
            mc:flow_kill . false, // branch constraints
            mc:flow_in   . flow_in,
            mc:flow_out  . flow_in,
            mc:flow_map  . from_block[mc:f_types][mc:flow_map]); // copies

          live_in = from_block[mc:f_live][mc:flow_out];
          nblock[mc:f_live] = indexed_vector(
            mc:flow_gen  . null,
	    mc:flow_kill . false,
            mc:flow_in   . live_in,
            mc:flow_out  . live_in,
            mc:flow_map  . from_block[mc:f_live][mc:flow_map]);

          flow_in = from_block[mc:f_copies][mc:flow_out];
          nblock[mc:f_copies] = indexed_vector(
            mc:flow_gen  . "",
            mc:flow_kill . "",
            mc:flow_in   . flow_in,
            mc:flow_out  . flow_in,
            mc:flow_map  . from_block[mc:f_copies][mc:flow_map]); // all copies
        ];

      remove_code_edge(edge, entry);
    ];

  | edge_flow_out_types |
  edge_flow_out_types = fn (predecessor)
    [
      | pnode, ptypes, flow_out, branch_constraints |
      pnode = graph_node_get(graph_edge_from(predecessor));
      ptypes = pnode[mc:f_types];
      flow_out = ptypes[mc:flow_out];

      branch_constraints = ptypes[mc:flow_kill]; // slot reuse
      if (!branch_constraints)
        exit<function> flow_out;

      | c |
      c = if (graph_edge_get(predecessor))
        // fallthrough, ie false edge
        cdr(branch_constraints)
      else // branch, ie true edge
        car(branch_constraints);
      apply_iconstraint(c, flow_out);
    ];

  | short_cut_branch |
  short_cut_branch = fn (n, entry)
    [
      | node, firstil |
      node = graph_node_get(n);
      firstil = dget(node[mc:f_ilist]);
      if (firstil[mc:il_ins][mc:i_class] != mc:i_branch)
        exit<function> false;

      | predecessors, change |
      change = false;

      predecessors = graph_edges_in(n);
      while (predecessors != null)
        [
          | flow_out, btypes, predecessor |
          @(predecessor . predecessors) = predecessors;

          flow_out = edge_flow_out_types(predecessor);

          btypes = firstil[mc:il_ins][mc:i_bargs];
          if (btypes != null)
            [
              | vtype |
              vtype = fn (v)
                match (mc:const_itype(v))
                  [
                    ,false => [
                      | vnum |
                      vnum = v[mc:v_number];
                      assert(vnum > 0);
                      flow_out[vnum]
                    ];
                    x => x;
                  ];
              btypes = lmap(vtype, btypes);
            ];

          infer_branch(firstil, btypes, fn (il, take?) [
            change_branch_to(predecessor, il, take?, entry);
            change = true;
          ], fn (ins, nop) null, !graph_edge_get(predecessor));
        ];
      change
    ];

  | merge_block |
  merge_block = fn (string all_globals, vector n)
    [
      | node, types, new_in, new_out |

      node = graph_node_get(n);
      types = node[mc:f_types];

      // compute in as 'union' of out's of predecessors
      new_in = graph_edges_in_reduce(fn (edge, new_in) [
        typeset_union!(new_in, edge_flow_out_types(edge))
      ], types[mc:flow_in], n);

      // compute new out
      //display("APPLY\n");
      //show_constraints(types[mc:flow_gen]);
      //display("TO "); show_typesets(new_in); newline();
      new_out = if (types[mc:flow_gen] == null)
        vcopy(new_in)
      else
        lreduce(apply_iconstraint, new_in, types[mc:flow_gen]);

      //display("-> "); show_typesets(new_out); newline();
      assert(new_out != types[mc:flow_out]);
      | live_out |
      live_out = node[mc:f_live][mc:flow_out];
      for (|i| i = vlength(new_out); --i >= 0; )
        if (!bit_set?(all_globals, i) && !bit_set?(live_out, i))
          // ignore output type of dead variables
          new_out[i] = itype_any;

      if (typeset_eq?(new_out, types[mc:flow_out]))
        false
      else
        [
          types[mc:flow_out] = new_out;
          true
        ]
    ];

  | init_infer |

  init_infer = fn (ifn)
    [
      mc:this_function = ifn;
      if (mc:verbose >= 3)
	[
	  dformat("Inferring %s\n", mc:fname(ifn));
	];
      mc:recompute_vars(ifn, true);
      mc:flow_ambiguous(ifn, mc:f_ambiguous_w);
      mc:flow_live(ifn);
      mc:flow_copies(ifn);

      | fg, all_globals, globals |
      fg = ifn[mc:c_fvalue];
      all_globals = mc:set_vars!(mc:new_varset(ifn), ifn[mc:c_fglobals]);

      // Writable closures may change across function calls
      globals = lreduce(fn (var, globals) [
        | base |
        base = mc:var_base(var);
        if (base[mc:v_lclosure_uses] & mc:closure_write)
          set_bit!(globals, var[mc:v_number]);
        globals
      ], mc:new_varset(ifn), ifn[mc:c_fclosure]);

      // Not-defined globals may change across function calls
      mc:set_vars!(globals, lfilter(fn (v) v[mc:v_class] != mc:v_global_define,
				    ifn[mc:c_fglobals]));

      init_icvars(ifn);

      graph_nodes_apply
	(fn (n)
	 [
	   | block, types |

	   block = graph_node_get(n);
           assert(mc:this_function == ifn);
	   block[mc:f_types] = types = indexed_vector(
             mc:flow_gen  . null,
             mc:flow_kill . null,
             mc:flow_in   . new_typesets(ifn),
             mc:flow_out  . new_typesets(ifn),
             mc:flow_map  . null);             // list(dst . src) of copies

           block_reset_copies(block);
           types[mc:flow_gen] = lreverse!(
             mc:scan_ambiguous(generate_constraints(block), null,
                               block, globals, mc:f_ambiguous_w));
           // use kill slot for per-edge constraint
           types[mc:flow_kill] = generate_branch_constraints(block);
	 ], cdr(fg));

      // solve data-flow problem

      // init entry node:
      | entry |
      entry = graph_node_get(car(fg));

      if (ifn[mc:c_fnargs_var])
        [
          | var |
          var = ifn[mc:c_fnargs_var][mc:vl_var];
          entry[mc:f_types][mc:flow_in][var[mc:v_number]] = itype_integer;
        ];

      for (|fargs|fargs = ifn[mc:c_ffullargs]; fargs != null; )
        [
          | farg, var, ts |
          @(farg . fargs) = fargs;
          @[var ts _] = farg[mc:fullarg_arg];
          // varargs are always vectors
          entry[mc:f_types][mc:flow_in][var[mc:v_number]]
            = if (ts == null) itype_vector else itype_any
        ];
      lforeach(fn (arg) [
        entry[mc:f_types][mc:flow_in][arg[mc:v_number]] = itype_any
      ], ifn[mc:c_fglobals]);
      lforeach(fn (arg) [
        entry[mc:f_types][mc:flow_in][arg[mc:v_number]] = itype_any
      ], ifn[mc:c_fclosure]);

      mc:this_function = null;

      indexed_vector(
        isv_fn          . ifn,
        isv_globals     . globals,
        isv_all_globals . all_globals,
        isv_var_nums    . vmap(fn (v) [
          if (v != null)
            v[mc:v_number]
          else
            null
        ], ifn[mc:c_fallvars]),
        isv_orig_argtypesets . lmap(fn (farg) [
          farg[mc:fullarg_arg][mc:vl_typeset]
        ], ifn[mc:c_ffullargs]))
    ];

  | restore_infer_state |
  restore_infer_state = fn (isv)
    [
      | ifn, var_nums |
      ifn = isv[isv_fn];
      var_nums = isv[isv_var_nums];

      mc:this_function = ifn;

      vforeachi(fn (i, var) [
        if (var != null)
          var[mc:v_number] = var_nums[i]
      ], ifn[mc:c_fallvars]);
    ];

  | infer_run |
  infer_run = fn (isv)
    [
      restore_infer_state(isv);

      | ifn, globals, all_globals, fg |
      ifn = isv[isv_fn];
      globals = isv[isv_globals];
      all_globals = isv[isv_all_globals];
      fg = ifn[mc:c_fvalue];

      | blocks |
      blocks = changed_blocks[ifn[mc:c_fnumber]];
      changed_blocks[ifn[mc:c_fnumber]] = null;

      while (blocks != null)
        [
          | block |
          @(block . blocks) = blocks;
          init_icvars(ifn);
          block_reset_copies(block);
          block[mc:f_types][mc:flow_gen] = lreverse!(
            mc:scan_ambiguous(generate_constraints(block), null,
                              block, globals, mc:f_ambiguous_w));
        ];

      | icount |
      icount = 0;
      for (;;)
	[
	  ++icount;

	  if (graph_nodes_reduce(fn (n, change) [
            merge_block(all_globals, n) || change
          ], false, cdr(fg)))
            exit<continue> null;

          if (graph_nodes_reduce(fn (n, change) [
            short_cut_branch(n, car(fg)) || change
          ], false, cdr(fg)))
            exit<continue> null;

          exit<break> null;
	];

      if (mc:verbose >= 3)
	[
	  dformat("Type inference iterations %d\n", icount);
	];

      // make sure we didn't delete all nodes
      assert(graph_nodes_exists?(fn (n) true, cdr(fg)));

      extract_types(ifn);
      infer_argument_typesets(ifn, isv[isv_orig_argtypesets]);

      mc:this_function = null;
    ];

  | fini_infer |
  fini_infer = fn (ifn)
    [
      | ortypes, nrtypes |
      ortypes = ifn[mc:c_freturn_typeset];
      nrtypes = ortypes & mc:typeset_from_itypeset(ifn[mc:c_freturn_itype],
                                                   ortypes & TYPESET_FALSE);
      if (ortypes != nrtypes)
        [
          ifn[mc:c_freturn_typeset] = nrtypes;
          if (ortypes != typeset_any)
            [
              mc:this_function = ifn;
              mc:set_loc(ifn[mc:c_fendloc]);
              | dtypes, str |
              dtypes = ortypes & ~nrtypes;
              str = if (cdr(types_from_typeset(dtypes)) != null)
                "types but they are"
              else
                "type but it is";
              mc:warning(
                "function specifies %s as return %s never generated",
                describe_typeset(dtypes), str)
            ];
        ];

      mc:clear_dataflow(ifn);
    ];

  | infer_types |
  infer_types = fn (fns)
    [
      changed_functions = fns;

      | nfuncs |
      nfuncs = lreduce(fn (ifn, n) max(ifn[mc:c_fnumber], n), -1, fns) + 1;
      function_isvs = make_vector(nfuncs);
      call_sites = make_vector(nfuncs);
      changed_blocks = make_vector(nfuncs);
      lforeach(fn (ifn) function_isvs[ifn[mc:c_fnumber]] = init_infer(ifn),
               fns);
      while (changed_functions != null)
        [
          | changed |
          changed = changed_functions;
          changed_functions = null;
          lforeach(fn (ifn) infer_run(function_isvs[ifn[mc:c_fnumber]]),
                   changed);
        ];
      lforeach(fini_infer, fns);

      // free some memory
      call_sites = null;
      function_isvs = null;
      icvars = null;
    ];

  | show_type_info |
  show_type_info = fn (types)
    if (types)
      [
	display("Types:\n");
	show_constraints(types[mc:flow_gen]);
	display("in:"); show_typesets(types[mc:flow_in]); newline();
	display("out:"); show_typesets(types[mc:flow_out]); newline();
      ];

  show_typesets = fn (typeset)
    for (|v| v = 1; v < vlength(typeset); ++v)
      dformat(" %s(%s)", v, showset(typeset[v]));

  showset = fn (tset)
    if (tset == itype_none) "none"
    else if (tset == itype_any) "any"
    else
      [
        | op, i |
        op = make_string_port();
        vforeach(fn (s) [
          | is |
          is = cdr(s);
          if (tset & is == is)
            [
              pputc(op, car(s));
              tset &= ~is;
            ];
        ], itype_set_signatures);
        i = 0;
        while (tset > 0)
          [
            if (tset & 1)
              pputc(op, itype_type_signatures[i]);
            ++i;
            tset >>= 1;
          ];
        port_string(op);
      ];

  show_constraints = fn (constraints)
    [
      | i |

      i = 0;
      while (constraints != null)
	[
	  dformat("constraint %d\n", i);
	  show_constraint(car(constraints));
	  ++i;
	  constraints = cdr(constraints);
	];
    ];

  show_constraint = fn (constraint)
    [
      dformat("  vars: %s\n",
              concat_words(lmap(itoa, constraint[icv_icvars]), " "));
      lforeach(show_c, constraint[icv_constraints]);
    ];

  show_c = fn (c)
    [
      dformat("  %s", concat_words(lmap(show_condition, c[cv_conditions]),
                                   " & "));
      if (c[cv_dest])
	dformat(" => %s contains %s\n", c[cv_dest],
                show_condition(c[cv_consequence]));
    ];

  show_condition = fn (cond)
    [
      | s |

      s = showset(car(cond));
      lforeach(fn (v) s = s + format(" /\\ %s", v), cdr(cond));
      s
    ];

  mc:register_inference_fns(infer_types, show_type_info);

];
