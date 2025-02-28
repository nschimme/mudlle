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

	 (ommited consequences and constants behave naturally)

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

   constraint templates are represented in a form designed to make their
   entry easy. This form is different from that of the instantiated constraints,
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
defines mc:infer_types, mc:show_type_info, mc:constant?, mc:global_call_count,
  mc:itypeset_string
reads mc:verbose, mc:this_module
writes mc:tnargs, mc:tncstargs, mc:tnfull, mc:tnpartial, mc:this_function
[
  | op_types, branch_types, typesets, make_condition0, make_condition1,
    make_condition2, instantiate_constraint, build_iconstraint, new_typesets,
    generate_constraints, evaluate_condition, apply_iconstraint, typeset_eq?,
    typeset_union!, extract_types, show_typesets, showset, show_constraints,
    show_constraint, show_c, show_condition, generate_branch_constraints,
    simple_itypes, infer_typeof, infer_branch, infer_type_trap,
    describe_tsig, describe_typeset, concat_comma,
    tsig_has_args?, tsig_argc, verify_call_types,
    typesets_from_strings,
    verify_compute_types, type_typesets,
    return_itype, handle_apply, make_ftypes_from_cargs |

  op_types =          // indexed by mc:b_xxx
    '[()
      ()
      ("xx.n")        // ==
      ("xx.n")        // !=
      ("nn.n")        // <
      ("nn.n")        // >=
      ("nn.n")        // <=
      ("nn.n")        // >
      ("nn.n")        // |
      ("nn.n")        // ^
      ("nn.n")        // &
      ("nn.n")        // <<
      ("nn.n")        // >>
      ("nn.n" "ss.s") // +
      ("nn.n")        // -
      ("zn.z" "nz.z" "ZZ.n")               // *
      ("zn.z" "nz." "ZZ.n")                // /
      ("zn.z" "nz." "nZ.n")                // %
      ("Z.Z" "z.z")   // -
      ("x.n")         // not
      ("z.Z" "Z.n")   // ~
      ()              // if-else
      ()              // if
      ()              // while
      ()              // loop
      ("vn.x" "sn.n" "ts.x" "os.x" "ns.x") // ref
      ()              // set
      ("xx.k")        // cons
      ("x.1")         // =
      ("k.x")         // car
      ("k.x")         // cdr
      ("s.n")         // string_length
      ("v.n")         // vector_length
      ("nn.n")        // integer addition
      ("x.n")         // typeof
      (".n")          // loop_count
      (".n")          // max_loop_count
      ("y.s")         // symbol_name
      ("y.x")         // symbol_get
      ("x*.v")        // vector
      ("x*.v")        // sequence
      ("xx.k")        // pcons
      ("ts.y" "os.y" "ns.y")    // symbol_ref
    ];
  assert(vlength(op_types) == mc:builtins);

  branch_types = // indexed by mc:branch_xxx
    '[()     // never
      ()     // always
      ()     // true
      ()     // false
      ()     // or
      ()     // nor
      ()     // and
      ()     // nand
      ("nn") // bitand
      ("nn") // nbitand
      ("sn") // bitset
      ("sn") // bitclear
      ()     // ==
      ()     // !=
      ("nn") // <
      ("nn") // >=
      ("nn") // <=
      ("nn") // >
      ("sn") // slength ==
      ("sn") // slength !=
      ("sn") // slength <
      ("sn") // slength >=
      ("sn") // slength <=
      ("sn") // slength >
      ("vn") // vlength ==
      ("vn") // vlength !=
      ("vn") // vlength <
      ("vn") // vlength >=
      ("vn") // vlength <=
      ("vn") // vlength >
     ];
  assert(vlength(branch_types) == mc:branch_equal);

  | itype_set_signatures, itype_type_signatures |
  itype_set_signatures = '[
    (?n . ,itype_integer)
    (?l . ,itype_list)
    (?D . ,(itype_integer | itype_bigint | itype_float))
    (?B . ,(itype_integer | itype_bigint))
    (?x . ,itype_any)
  ];

  itype_type_signatures = "fZsvuytkbdroz";
  assert(slength(itype_type_signatures) == vlength(itype_names));

  typesets = make_vector(128); // index from character to typeset
  vforeach(fn (s) typesets[car(s)] = cdr(s), itype_set_signatures);
  sforeachi(fn (i, sig) typesets[sig] = (1 << i), itype_type_signatures);
  protect(typesets);

  simple_itypes =
    '[ (,itype_integer  . ,type_integer)
       (,itype_zero     . ,type_integer)
       (,itype_non_zero . ,type_integer)
       (,itype_string   . ,type_string)
       (,itype_vector   . ,type_vector)
       (,itype_pair     . ,type_pair)
       (,itype_symbol   . ,type_symbol)
       (,itype_table    . ,type_table)
       (,itype_null     . ,type_null)
       (,itype_float    . ,type_float)
       (,itype_bigint   . ,type_bigint) ];

  type_typesets = make_vector(last_synthetic_type);
  vfill!(type_typesets, "x");
  vforeach(fn (t) type_typesets[car(t)] = cdr(t),
           '[(,type_integer   . "n")
             (,type_string    . "s")
             (,type_vector    . "v")
             (,type_pair      . "k")
             (,type_null      . "u")
             (,type_symbol    . "y")
             (,type_table     . "t")
             (,type_float     . "d")
             (,type_bigint    . "b")
             (,stype_function . "f")
             (,stype_list     . "l") ]);
  for (|t| t = 0; t < last_type; ++t)
    match (mc:itypemap[t])
      [
        ,itype_other => type_typesets[t] = "o";
        ,itype_function => type_typesets[t] = "f";
      ];
  rprotect(type_typesets);

  | readonly_itypes, immutable_itypes |
  readonly_itypes = (itype_integer | itype_null | itype_float
                     | itype_bigint | itype_function);
  immutable_itypes = readonly_itypes | itype_string;

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

  mc:itypeset_string = fn "`n `b -> `s. Returns a description of itypeset `n. If `b is false, separate options with \"|\"; otherwise comma-separate them." (itype, simple?)
    [
      itype &= ~itype_star;
      assert(itype >= 0 && itype <= itype_any);
      if (itype == itype_any)
        "any type"
      else if (itype == 0)
        "no type"
      else if (itype == itype_any & ~itype_zero)
        "not false"
      else
        [
          | l, i |

          if (itype & itype_integer == itype_integer)
            [
              l = "integer" . l;
              itype &= ~itype_integer;
            ];
          if (itype & itype_list == itype_list)
            [
              l = "list" . l;
              itype &= ~itype_list;
            ];

          i = 0;
          while (itype)
            [
              if (itype & 1)
                l = itype_names[i] . l;
              ++i;
              itype >>= 1;
            ];
          if (cdr(l) == null)
            car(l)
          else if (simple?)
            concat_comma(lreverse!(l), " or ")
          else
            concat_words(lreverse!(l), "|")
        ];
    ];

  describe_tsig = fn (sig)
    [
      | result |
      for (|i, len|[i = 0; len = vlength(sig) ]; i < len; ++i)
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
    [
      | l |
      l = mc:types_from_typeset(ts);
      concat_comma(lmap(fn (n) type_names[n], l), " and ")
    ];

  // traps are handled explicitly (only trap_type is of interest and
  // it is special)

  mc:constant? = fn (v)
    // Types: v: var
    // Returns: false if v is not a constant
    //   an appropriate itype_xxx otherwise
    [
      | vclass, val |

      vclass = v[mc:v_class];
      val = if (vclass == mc:v_constant)
	v[mc:v_kvalue]
      else if (vclass == mc:v_global_constant)
	global_value(v[mc:v_goffset])
      else if (vclass == mc:v_function)
        exit<function> itype_function
      else
	exit<function> false;
      if (!val)
        itype_zero
      else if (integer?(val))
        itype_non_zero
      else
        mc:itypemap[typeof(val)]
    ];

  make_condition0 = fn (constant) // makes "constant" condition
    constant . null;

  make_condition1 = fn (int constant, v) // makes condition v /\ constant
    [
      | type |

      if (type = mc:constant?(v)) constant & type . null
      else constant . v[mc:v_number] . null
    ];

  make_condition2 = fn (constant, v1, v2) // makes condition v1 /\ v2 /\ constant
    [
      | type, vars |

      if (type = mc:constant?(v1))
	constant = constant & type
      else vars = v1[mc:v_number] . vars;

      if (type = mc:constant?(v2))
	constant = constant & type
      else vars = v2[mc:v_number] . vars;

      constant . vars
    ];

  instantiate_constraint = fn (template, args, dest)
    // Types: template: type signature (string)
    //        args: list of var
    //	      dest: var (or false)
    // Requires: llength(args) = #arguments in template
    // Returns: the constraint produced by instantiating template with
    //   args and dest (if not false)
    // TBD: Prune constraints which contain a condition with itype_none.
    [
      | dvar, consequence, conditions, nargs, type, sargs, i, ti |

      // Build conditions of constraint
      nargs = llength(args);
      ti = i = 0;
      sargs = args;
      while (i < nargs)
	[
	  | arg |

	  arg = car(sargs);
	  type = template[ti];

          if (type == ?*) type = template[--ti];

	  if (type >= ?1 && type <= ?9)
	    [
	      | ref, nref, cond |

	      ref = nth(type - ?0, args);
	      nref = ref[mc:v_number];

	      // if ref is already in some condition, just add arg there
	      if (cond = lexists?(fn (c) memq(nref, cdr(c)), conditions))
		set_cdr!(cond, ref . cdr(cond))
	      else
		conditions = make_condition2(itype_any, ref, arg) . conditions
	    ]
	  else //if ((tsets = typesets[type]) != itype_any)
	    conditions = make_condition1(typesets[type], arg) . conditions;

          ++i;
          ++ti;
	  sargs = cdr(sargs);
	];

      // Build consequence
      if (dest)
	[
	  | l |

	  dvar = dest[mc:v_number];

	  l = string_length(template);
	  if ((type = template[l - 1]) == ?.)
	    // destination is undefined, ie type_none
	    consequence = make_condition0(itype_none)
	  else if (type >= ?1 && type <= ?9)
	    [
	      | ref, nref, cond |

	      ref = nth(type - ?0, args);
	      nref = ref[mc:v_number];

	      // if ref is already in some condition, use same condition
	      if (cond = lexists?(fn (c) memq(nref, cdr(c)), conditions))
		consequence = cond
	      else
		consequence = make_condition1(itype_any, ref);
	    ]
	  else
	    consequence = make_condition0(typesets[type]);
	]
      else
        dvar = false;

      // Finally assemble constraint
      sequence(conditions, dvar, consequence)
    ];

  | icvars |
  build_iconstraint = fn (il, cl)
    // Returns: A constraints list for instruction il, given its
    //   constraint list (extracts all vars referred to)
    [
      | addvar, scl |

      addvar = fn (v) set_bit!(icvars, v);

      bclear(icvars);

      scl = cl;
      while (scl != null)
	[
	  | c |

	  c = car(scl);
	  // ovars = vars;
	  lforeach(fn (cond) lforeach(addvar, cdr(cond)), c[0]);
	  if (c[1])
	    [
	      addvar(c[1]);	// add dest
	      // but not its condition (cf semantics)
	    ];

	  /* Semantics: unused variables in conditions are unaffected.
	     Instead of coding this implicitly, add `u /\ any' conditions
	     for  such variables.
	     The variables between vars & ovars were not present in
	     constraints prior to c. Add the pseudo-conditions to them. */
/*
	  if (scl != cl && ovars != vars)
	    [
	      | searly, early, add, svars |

	      svars = vars;
	      while (svars != ovars)
		[
		  add = itype_any . car(svars) . null;
		  svars = cdr(svars);
		];
	      searly = cl;
	      while (searly != scl)
		[
		  early = car(searly);
		  early[0] = lappend(add, early[0]);
		  searly = cdr(searly);
		];
	    ];
*/
	  scl = cdr(scl);
	];

      sequence(il, breduce(cons, null, icvars), cl)
    ];

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
          | c |
          c = sig[-1];
          if (c == ?.)
            exit<function> itype;
          if (cdigit?(c))
            exit<function> itype_any;
          itype | typesets[c]
        ], itype_none, primitive_type(prim))
      else
        itype_any
    ];

  handle_apply = fn (prim, args, types, dest, cfunc)
    [
      | fidx, rtypes |
      @[_ fidx _] = vexists?(fn (x) x[0] == prim, mc:apply_functions);

      rtypes = match (cfunc)
        [
          (_ . v) && vector?(v) => v[mc:c_freturn_itype];
          _ => return_itype(nth(fidx + 1, args))
        ];

      | l |
      l = lmap(fn (sig) instantiate_constraint(sig, args, dest), types);
      if (rtypes != itype_any)
        // rewrite consequences to only include rtypes
        lmap!(fn (@[condition dvar consequence]) [
          sequence(condition, dvar,
                   lmap(fn (is) is & rtypes, consequence))
        ], l)
      else
        l
    ];

  | make_closure_condition, get_closure_return_itype |

  get_closure_return_itype = fn (closure c)
    [
      | n |
      n = closure_return_itype(c);
      if (n < 0)
        mc:itypeset_from_typeset(closure_return_typeset(c))
      else
        n
    ];

  make_closure_condition = fn (list args, int ndest, {vector,string} targs, int tret)
    [
      | conditions |
      if (vector?(targs)
          && vlength(targs) == llength(args))
        for (|i, a| [ i = 0; a = args ];
             a != null;
             [ ++i; a = cdr(a) ])
          conditions = make_condition1(mc:itypeset_from_typeset(cdr(targs[i])),
                                       car(a))
            . conditions;
      sequence(conditions, ndest, make_condition0(tret)) . null
    ];

  generate_constraints = fn (il, ambiguous, constraints)
    // Types: il: instruction
    // Returns: (constraints for instruction il) . constraints
    [
      | ins, class, new, args, dest, op |

      ins = il[mc:il_ins];
      class = ins[mc:i_class];
      if (class == mc:i_compute)
	<done> [
          | op, vclass |
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
                  dtypes = vreduce(fn (v, it) it | mc:itypemap[typeof(v)],
                                   0, value);
                  idxtype = itype_integer;
                ]
              else if (table?(value))
                [
                  dtypes = table_reduce(fn (sym, it) [
                    it | mc:itypemap[typeof(symbol_get(sym))]
                  ], itype_null, value);
                  idxtype = itype_string;
                ]
              else
                exit<normal> null;

              exit<done> new = sequence(
                make_condition1(idxtype, cadr(args)) . null,
                dest[mc:v_number],
                make_condition0(dtypes)) . null;
            ];

          new = lmap(fn (sig) instantiate_constraint(sig, args, dest),
                     op_types[op]);
	]
      else if (class == mc:i_branch)
	[
	  args = ins[mc:i_bargs];
	  op = ins[mc:i_bop];
	  if (op < vector_length(branch_types))
	    new = lmap(fn (sig) instantiate_constraint(sig, args, false),
		       branch_types[op]);
	]
      else if (class == mc:i_call)
	[
	  | escapes, f, fclass, prim, ndest, clos, tfn |

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
              atypes = if (tfn[mc:c_fvarargs])
                ""              // will be ignored
              else
                list_to_vector(lmap(fn (@[_ ts _]) false . ts,
                                    tfn[mc:c_fargs]));

              // A locally defined function
              new = make_closure_condition(
                args, ndest, atypes,
                tfn[mc:c_freturn_itype]);
              if (tfn[mc:c_fnoescape])
                escapes = false;
            ]
          else if (fclass == mc:v_global_constant &&
                   (primitive?(prim = global_value(f[mc:v_goffset]))
                    || secure?(prim)) &&
                   primitive_nargs(prim) == llength(args))
            [
              | types |
              if ((types = primitive_type(prim)) != null)
		[
		  if (primitive_flags(prim) & OP_APPLY)
                    new = handle_apply(prim, args, types, dest, tfn)
		  else
		    new = lmap(fn (sig) instantiate_constraint(sig, args, dest),
			       types)
		]
              else
                new = sequence(null, ndest, make_condition0(itype_any)) . null;
              if (primitive_flags(prim) & OP_NOESCAPE) escapes = FALSE;
            ]
          else if (fclass == mc:v_global_constant &&
                   varargs?(prim = global_value(f[mc:v_goffset])))
            [
              | types, nargs |
              nargs = llength(args);
              types = primitive_type(prim);

              lforeach(fn (sig) [
                | targs, ok? |

                ok? =
                  if ((targs = string_index(sig, ?*)) >= 0)
                    targs - 1 <= nargs
                  else if ((targs = string_index(sig, ?.)) >= 0)
                    targs == nargs
                  else
                    fail();

                if (ok?)
                  new = instantiate_constraint(sig, args, dest) . new
              ], types);

              if (new == null)
                new = sequence(null, ndest, make_condition0(itype_any)) . null;

              if (primitive_flags(prim) & OP_NOESCAPE) escapes = FALSE;
            ]
          else if (fclass == mc:v_global_constant &&
                   closure?(clos = global_value(f[mc:v_goffset])))
            [
              new = make_closure_condition(
                args, ndest,
                closure_arguments(clos),
                get_closure_return_itype(clos));

              if (closure_flags(clos) & clf_noescape)
                escapes = false;
            ]
	  else
	    [
	      // destination is any
	      new = sequence(make_condition1(itype_function, f) . null,
                             ndest, make_condition0(itype_any)) . null;
	    ];

	  if (escapes) // note global side effects
	    bforeach
	      (fn (i) if (i != ndest)
	         new = sequence(null, i, make_condition0(itype_any)) . new,
	       ambiguous);
	]
      else if (class == mc:i_trap)
	<skip> [
          | itype, dvar, argmap |
	  argmap = match (ins[mc:i_top])
            [
              ,mc:trap_type => fn (c) mc:itypemap[c];
              ,mc:trap_typeset => mc:itypeset_from_typeset;
              _ => exit<skip> null;
            ];
          args = ins[mc:i_targs];
          itype = argmap(mc:var_const_value(cadr(args)));
          dvar = car(args);
          dest = dvar[mc:v_number];
          new = sequence (make_condition1(itype, dvar) . null,
                          dest, make_condition0(itype))
            . null;
	]
      else if (class == mc:i_closure)
	[
	  dest = ins[mc:i_fdest][mc:v_number];
	  new = sequence(null, dest, make_condition0(itype_function)) . null;
	]
      else if (class == mc:i_vref)
        [
	  dest = ins[mc:i_vdest][mc:v_number];
          // vref returns type_variable
          new = sequence(null, dest, make_condition0(itype_other)) . null;
        ]
      else if (class == mc:i_return || class == mc:i_memory)
        null
      else
        fail_message(format("unsupported class %d", class));

      if (new != null) build_iconstraint(il, new) . constraints
      else constraints
    ];

  generate_branch_constraints = fn (block)
    // Types: block: cfg block
    // Returns: a pair of constraints for blocks that end in "interesting"
    //   branches, false otherwise
    //   The first element of the pair is applied when the branch is taken,
    //   the 2nd when it isn't.
    [
      | lastins, lastil, op, type, itype, reversed, ctrue, cfalse, var |

      lastil = dget(dprev(block[mc:f_ilist]));
      lastins = lastil[mc:il_ins];
      // type branches are interesting, so is == and != null.
      if (lastins[mc:i_class] != mc:i_branch)
	exit<function> false;

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
          itype = ~itype_zero;
        ]
      else if ((op == mc:branch_eq || op == mc:branch_ne
                || op == mc:branch_equal || op == mc:branch_nequal))
	[
          reversed = (op == mc:branch_ne || op == mc:branch_nequal);
          if (lexists?(fn (v) mc:constant?(v) == itype_null,
                       lastins[mc:i_bargs]))
            [
              type = mc:itypemap[type_null];
              itype = mc:itypemap_inverse[type_null];

              // constant folding prevents null == null
              var = lexists?(fn (v) mc:constant?(v) != itype_null,
                             lastins[mc:i_bargs]);
            ]
          else
            [
              | lvar, rvar |
              @(lvar rvar) = lastins[mc:i_bargs];
              ctrue = sequence(make_condition2(itype_any, lvar, rvar) . null,
                               false, null);
              ctrue = build_iconstraint(lastil, ctrue . null);
              cfalse = sequence(null, false, null);
              cfalse = build_iconstraint(lastil, cfalse . null);

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
      else
	exit<function> false; // not interesting

      ctrue = sequence(make_condition1(type, var) . null,
                       false, null);
      ctrue = build_iconstraint(lastil, ctrue . null);
      cfalse = sequence(make_condition1(itype, var) . null,
			false, null);
      cfalse = build_iconstraint(lastil, cfalse . null);

      if (reversed) cfalse . ctrue
      else ctrue . cfalse
    ];

  evaluate_condition = fn (condition, typeset)
    // Types: condition: condition
    //        typeset: vector of typesets
    // Returns: Result of condition given types in typeset
    [
      | x |

      x = car(condition);
      condition = cdr(condition);
      while (condition != null)
	[
	  x = x & typeset[car(condition)];
	  condition = cdr(condition);
	];
      x
    ];

  apply_iconstraint = fn (iconstraint, typeset)
    // Types: iconstraint: instruction_constraint
    //        typeset: vector of itypeset
    // Returns: The typeset resulting from the application of constraint
    //   to typeset
    [
      | new, apply_constraint |

      // clear modified vars
      new = vcopy(typeset);
      lforeach(fn (v) new[v] = itype_none, iconstraint[1]);

      apply_constraint = fn (c)
	[
	  | results, conditions |

	  //dformat("applying %s\n", c);
	  conditions = c[0];
	  while (conditions != null)
	    [
	      | x |

	      x = evaluate_condition(car(conditions), typeset);
	      if (x == itype_none) exit<function> 0; // constraint failed
	      results = x . results;
	      conditions = cdr(conditions);
	    ];
	  //dformat("success %s\n", results);

	  // condition successful, modify new typesets
	  // first, destination:
	  if (c[1])
	    new[c[1]] = new[c[1]] | evaluate_condition(c[2], typeset);

	  // then all concerned variables
	  conditions = lreverse(c[0]); // same order as results
	  while (conditions != null)
	    [
	      | x |

	      x = car(results);
	      lforeach(fn (arg) new[arg] = new[arg] | x, cdar(conditions));
	      conditions = cdr(conditions);
	      results = cdr(results);
	    ];
	];

      lforeach(apply_constraint, iconstraint[2]);
      new
    ];

  new_typesets = fn (ifn)
    // Returns: A new sequence of typesets initialised to itype_none
    [
      | v |

      vector_fill!(v = make_vector(ifn[mc:c_fnvars]), itype_none);
      v
    ];

  typeset_eq? = fn (ts1, ts2)
    // Returns: True if all the typesets in ts1 are equal to those in ts2
    [
      | l |

      l = vector_length(ts1);
      while ((l = l - 1) >= 0)
	if (ts1[l] != ts2[l]) exit<function> false;

      true
    ];

  typeset_union! = fn (ts1, ts2)
    // Effects: ts1 = ts1 U ts2 (per variable)
    // Modifies: ts1
    [
      | l |

      l = vector_length(ts1);
      while ((l = l - 1) >= 0) ts1[l] = ts1[l] | ts2[l];
    ];

  infer_type_trap = fn (il, ins, set?)
    [
      | v, itype, itypeset |
      @(_ v) = ins[mc:i_targs];
      @(itype _) = ins[mc:i_ttypes];
      v = v[mc:v_kvalue];
      itypeset = if (set?)
        mc:itypeset_from_typeset(v)
      else
        mc:itypemap[v];
      if ((itype & itypeset) != itype_none)
        exit<function> null;
      mc:set_loc(il[mc:il_loc]);
      mc:warning("always causes bad type error");
      ins[mc:i_top] = mc:trap_always;
    ];

  // itypes for which we cannot use == instead of equal?();
  // cf. simple_equal?() in optimise.mud
  | itype_full_equal |
  itype_full_equal = (itype_symbol | itype_vector | itype_pair
                      | itype_table | itype_string | itype_float
                      | itype_bigint);

  infer_branch = fn (il, ins)
    [
      | bop, types, type1, type2 |

      bop = ins[mc:i_bop];
      types = ins[mc:i_btypes];
      type1 = car(types);
      type2 = if (cdr(types) != null) cadr(types) else null;
      if (bop == mc:branch_eq || bop == mc:branch_ne
          || bop == mc:branch_equal || bop == mc:branch_nequal)
        [
          if (!(type1 & type2))
            mc:fold_branch(il, bop == mc:branch_ne || bop == mc:branch_nequal)
          else if ((type1 == itype_null || type1 == itype_zero)
                   && type1 == type2)
            mc:fold_branch(il, bop == mc:branch_eq || bop == mc:branch_equal)
          else if ((bop == mc:branch_equal || bop == mc:branch_nequal)
                   && ((type1 & itype_full_equal) == 0
                       || (type2 & itype_full_equal) == 0))
            ins[mc:i_bop] = if (bop == mc:branch_equal)
              mc:branch_eq
            else
              mc:branch_ne
        ]
      else if (bop == mc:branch_true || bop == mc:branch_false)
        [
          if (~type1 & itype_zero)
            mc:fold_branch(il, bop == mc:branch_true)
        ]
      else if (bop == mc:branch_or || bop == mc:branch_nor)
        [
          if (~type1 & itype_zero || ~type2 & itype_zero)
            mc:fold_branch(il, bop == mc:branch_or)
        ]
      else if (bop == mc:branch_and || bop == mc:branch_nand)
        [
          if (~type1 & itype_zero && ~type2 & itype_zero)
            mc:fold_branch(il, bop == mc:branch_and)
        ]
      else if (bop == mc:branch_immutable || bop == mc:branch_mutable)
        [
          if (!(type1 & ~immutable_itypes))
            mc:fold_branch(il, bop == mc:branch_immutable);
        ]
      else if (bop == mc:branch_readonly || bop == mc:branch_writable)
        [
          if (!(type1 & ~readonly_itypes))
            mc:fold_branch(il, bop == mc:branch_readonly);
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

  // calculate the number of arguments `sig requires (-n for (n - 1) or more)
  tsig_argc = fn (vector sig)
    [
      | l |
      l = vlength(sig);
      if (l > 0 && (sig[-1] & itype_star))
        -l
      else
        l
    ];

  // true if `sig allows for `argc arguments
  tsig_has_args? = fn (vector sig, int argc)
    [
      | n |
      n = tsig_argc(sig);
      if (n < 0)
        argc >= -(n + 1)
      else
        argc == n
    ];

  make_ftypes_from_cargs = list fn (vector cargs)
    vmap(fn (@(_ . ts)) [
      | r |
      r = 0;
      for (|t| t = 0; ts; [ ts >>= 1; ++t ])
        if (ts & 1)
          r |= mc:itypemap[t];
      r
    ], cargs) . null;

  typesets_from_strings = fn (list ftypes)
    [
      | result, add |
      add = fn (vector v)
        [
          if (result == null)
            exit<function> result = v . null;
          | miss, prev, l |
          prev = car(result);
          l = vlength(v);
          if (vlength(prev) != l)
            exit<function> result = v . result;
          for (|i| i = 0; i < l; ++i)
            if (v[i] != prev[i])
              // If itype_star changes between the two, the
              // entries should not be combined
              if (miss == null && !((v[i] ^ prev[i]) & itype_star))
                miss = i
              else
                exit<break> miss = -1;
          if (integer?(miss) && miss >= 0)
            [
              v[miss] |= prev[miss];
              result = cdr(result);
              exit<function> add(v);
            ]
          else if (miss != null)
            result = v . result;
        ];

      loop
        [
          if (ftypes == null)
            exit result;
          | v, l, ftype, star? |
          @(ftype . ftypes) = ftypes;
          l = string_index(ftype, ?.);
          if (star? = (l > 0 && ftype[l - 1] == ?*))
            --l;
          assert(l >= 0);
          v = make_vector(l);
          for (|i| i = 0; i < l; ++i)
            v[i] = typesets[ftype[i]];
          if (star?)
            v[-1] |= itype_star;
          add(v)
        ]
    ];

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
          if (type = mc:constant?(v)) type
          else typeset[v[mc:v_number]]
        ];

      @(f . args) = ins[mc:i_cargs];
      ins[mc:i_ctypes] = atypes = lmap(var_type, ins[mc:i_cargs]);
      @(ftype . atypes) = atypes;
      nargs = llength(args);

      fclass = f[mc:v_class];

      if (~ftype & itype_function)
        [
          mc:warning("call of non-function (%s)", mc:itypeset_string(ftype, true));
          exit<function> null;
        ];

      if (vector?(fval = ins[mc:i_cfunction]))
        name = fn() mc:fname(fval)
      else
        [
          name = fn() global_name(f[mc:v_goffset]) + "()";
          if (fclass == mc:v_constant)
            fval = f[mc:v_kvalue]
          else if (fclass == mc:v_global_constant)
            fval = global_value(f[mc:v_goffset])
          else if (fclass == mc:v_global_define)
            [
              // cannot check our own defines
              if (lexists?(fn (def) def[mc:mv_gidx] == f[mc:v_goffset],
                           mc:this_module[mc:m_defines]))
                exit<function> null;
              fval = global_value(f[mc:v_goffset])
            ]
          else if (fclass == mc:v_global)
            [
              fval = global_value(f[mc:v_goffset]);
              if (function?(fval))
                call_check(fval);
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
                         type_names[typeof(fval)]);
              exit<function> null;
            ];
        ];

      if (function?(fval) && !call_check(fval))
        exit<function> null;

      | ftypes, badarg, desc, bad_nargs |
      bad_nargs = fn (expect)
        mc:warning("bad number of arguments (%s) in call to %s %s, expected %s",
                   nargs,
                   desc,
                   name(),
                   expect);

      if (primitive?(fval) || secure?(fval))
        [
          desc = "primitive";
          if (primitive_nargs(fval) != nargs)
            bad_nargs(primitive_nargs(fval))
          else
            ftypes = typesets_from_strings(primitive_type(fval));
        ]
      else if (varargs?(fval))
        [
          desc = "vararg primitive";
          ftypes = typesets_from_strings(primitive_type(fval));
          if (ftypes != null)
            [
              if (!lexists?(fn (t) tsig_has_args?(t, nargs), ftypes))
                [
                  | allowed |
                  // list of N or -(N + 1) for N+
                  allowed = lmap(tsig_argc, ftypes);

                  // sort according to N
                  allowed = lqsort(fn (a, b) [
                    if (a < 0) a = -(a + 1);
                    if (b < 0) b = -(b + 1);
                    a < b;
                  ], allowed);

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
                      else if (car(a) == -(cadr(a) + 1))
                        [
                          // merge N and N+
                          set_car!(a, cadr(a));
                          set_cdr!(a, cddr(a));
                        ]
                      else if (car(a) + 1 == -(cadr(a) + 1))
                        [
                          // merge N and (N + 1)+ to N+
                          set_car!(a, cadr(a) + 1);
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
                      format("at least %s", -(n + 1))
                  ], allowed);
                  bad_nargs(concat_comma(allowed, " or "));
                  ftypes = null
                ]
            ]
        ]
      else if (closure?(fval))
        [
          | cargs |
          desc = "closure";
          cargs = closure_arguments(fval);
          if (vector?(cargs))
            if (vlength(cargs) != nargs)
              bad_nargs(vlength(cargs))
            else
              ftypes = make_ftypes_from_cargs(cargs);
        ]
      else if (vector?(fval))
        [
          desc = "closure";
          if (!fval[mc:c_fvarargs])
            [
              | cargs |
              cargs = list_to_vector(lmap(fn (@[_ ts _]) false . ts,
                                          fval[mc:c_fargs]));
              if (vlength(cargs) != nargs)
                bad_nargs(vlength(cargs))
              else
                ftypes = make_ftypes_from_cargs(cargs);
            ]
        ];

      if (pair?(ftypes) && !lexists?(fn (type) [
        | ai, ti, a, targc |

        targc = tsig_argc(type);

        if (targc < 0)
          [
            if (-(targc + 1) > nargs)
              exit<function> false;
          ]
        else if (targc > nargs)
          exit<function> false;

        ai = ti = 0;
        a = atypes;
        loop
          [
            if (a == null) exit true;
            if (ti >= vlength(type) || (type[ti] & car(a)) == 0)
              [
                badarg = ai . ti;
                exit false;
              ];
            ++ai;
            if (~type[ti] & itype_star)
              ++ti;
            a = cdr(a);
          ];
      ], ftypes))
        if (cdr(ftypes) == null && pair?(badarg))
          mc:warning("bad type (%s) in argument %s of call to %s %s, expected %s",
                     mc:itypeset_string(nth(car(badarg) + 1, atypes), true),
                     car(badarg) + 1,
                     desc,
                     name(),
                     mc:itypeset_string(car(ftypes)[cdr(badarg)], true))
        else
          mc:warning("bad type%s (%s) in call to %s %s, expected %s",
                     if (nargs == 1) "" else "s",
                     concat_comma(lmap(fn (t) mc:itypeset_string(t, false), atypes), ", "),
                     desc,
                     name(),
                     concat_comma(lmap(describe_tsig, ftypes), " or "));
    ];

  verify_compute_types = fn (ins)
    [
      | otypes, atypes, badarg |
      otypes = op_types[ins[mc:i_aop]];
      if (otypes == null) exit<function> null;

      atypes = ins[mc:i_atypes];

      if (!lexists?(fn (otype) [
        | a, i |
        a = atypes; i = 0;
        loop
          [
            if (a == null) exit true;
            | ot |
            ot = otype[i];
            if (ot == ?*)
              ot = otype[--i];
            if (car(a) & typesets[ot] == 0)
              [
                badarg = i;
                exit false;
              ];
            a = cdr(a); ++i
          ];
      ], otypes))
        [
          if (cdr(otypes) == null)
            mc:warning("bad type (%s) in argument %s to operator %s, expected %s",
                       mc:itypeset_string(nth(badarg + 1, atypes), true),
                       badarg + 1,
                       mc:builtin_names[ins[mc:i_aop]],
                       mc:itypeset_string(typesets[car(otypes)[badarg]], true))
          else
            mc:warning("bad types (%s) in arguments to operator %s, expected %s",
                       concat_comma(lmap(fn (t) mc:itypeset_string(t, false), atypes), ", "),
                       mc:builtin_names[ins[mc:i_aop]],
                       concat_comma(lmap(describe_tsig,
                                         typesets_from_strings(otypes)),
                                    " or "));
        ];
    ];

  | infer_argument_typesets |
  infer_argument_typesets = fn (ifn)
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

      for (|argn, args| [ argn = 1; args = ifn[mc:c_fargs] ];
           args != null;
           ++argn)
        [
          | arg, var, ts |
          @(arg . args) = args;
          @[var ts _] = arg;
          if (bit_set?(written_vars, var[mc:v_number]))
            // do nothing if this variable was written in the block
            exit<continue> null;

          // compute the inferred typeset of this argument
          | newts |
          newts = 0;
          for (|its, i| [ i = 0; its = otypes[var[mc:v_number]] ];
               its;
               [ its >>= 1; ++i ])
            if (its & 1)
              newts |= mc:itype_typeset[i];

          // if necessary, update the argument type with type
          // information from this (first) basic block
          if (ts & ~newts)
            [
              newts &= ts;
              if (newts == 0)
                mc:warning("no valid type for argument %d (%s)",
                           argn, var[mc:v_name])
              else if (ts != typeset_any)
                mc:warning("invalid type(s) for argument %d (%s): %s",
                           argn, var[mc:v_name],
                           describe_typeset(ts ^ newts));
              arg[mc:vl_typeset] = newts;
            ];
        ]
    ];

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

	      nargs = nargs + 1;
	      if (type = mc:constant?(v))
		[
		  ncstargs = ncstargs + 1;
		  type
		]
	      else
		[
		  type = typeset[v[mc:v_number]];
		  assert(v[mc:v_number] != 0);
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
              | bop |
              bop = ins[mc:i_bop];
	      if (bop == mc:branch_true || bop == mc:branch_false
                  || bop >= mc:branch_bitand)
                [
                  ins[mc:i_btypes] = lmap(vtype, ins[mc:i_bargs]);
                  infer_branch(il, ins);
                ]
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
              | nrtypes, ortypes, rtype |
              nrtypes = ortypes = ifn[mc:c_freturn_typeset];
              rtype = ins[mc:i_rtype] = vtype(ins[mc:i_rvalue]);
              for (|b, t| [ b = 1; t = 0 ]; b <= ortypes; [ b <<= 1; ++t ])
                if ((ortypes & b) && !(mc:itypemap[t] & rtype))
                  [
                    nrtypes &= ~b;
                    if (ortypes != typeset_any)
                      mc:warning("function specifies %s as return type but it is never generated",
                                 type_names[t]);
                  ];

              ifn[mc:c_freturn_typeset] = nrtypes;
              ifn[mc:c_freturn_itype] = rtype;
            ]
          else if (class == mc:i_call)
            verify_call_types(ins, typeset)
          else if (class == mc:i_trap || class == mc:i_closure
                   || class == mc:i_memory || class == mc:i_vref)
            null
          else
            fail_message(format("unsupported class %d", class));

          mc:set_loc(prevloc);

	  if (cdr(types) != null && (iconstraint = cadr(types))[0] == il)
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

      infer_argument_typesets(ifn);

      if (mc:verbose >= 3)
	[
	  display("Type inference results:\n");
	  dformat("%s args, of which %s constant, %s fully inferred, %s partially.\n", nargs, ncstargs, nfull, npartial);
	];
      mc:tnargs += nargs;
      mc:tncstargs += ncstargs;
      mc:tnfull += nfull;
      mc:tnpartial += npartial;
    ];

  mc:infer_types = fn (ifn)
    // Types: ifn: intermediate function
    // Modifies: ifn
    // Effects: infers types for the variables of ifn
    [
      | fg, entry, change, globals, icount, merge_block, all_globals |

      mc:this_function = ifn;

      if (mc:verbose >= 3)
	[
	  dformat("Inferring %s\n", mc:fname(ifn));
	];
      mc:recompute_vars(ifn, true);
      mc:flow_ambiguous(ifn, mc:f_ambiguous_w);
      mc:flow_live(ifn);

      icvars = mc:new_varset(ifn);

      fg = ifn[mc:c_fvalue];
      all_globals = mc:set_vars!(mc:new_varset(ifn), ifn[mc:c_fglobals]);
      // Defined globals do not change across function calls
      globals = mc:set_vars!(mc:new_varset(ifn), ifn[mc:c_fclosure]);
      mc:set_vars!(globals, lfilter(fn (v) v[mc:v_class] != mc:v_global_define,
				    ifn[mc:c_fglobals]));

      graph_nodes_apply
	(fn (n)
	 [
	   | block |

	   block = graph_node_get(n);
	   block[mc:f_types] = vector
	     (lreverse!(mc:scan_ambiguous(generate_constraints, null,
					  block, globals, mc:f_ambiguous_w)),
	      // use kill slot for per-edge constraint
	      generate_branch_constraints(block),
	      new_typesets(ifn),
	      new_typesets(ifn)); // no map
	 ], cdr(fg));

      // solve data-flow problem

      // init entry node:
      entry = graph_node_get(car(fg));

      if (ifn[mc:c_fvarargs])
        [
          // a vararg function always takes a vector argument
          | var |
          @([var _ _]) = ifn[mc:c_fargs];
          entry[mc:f_types][mc:flow_in][var[mc:v_number]] = itype_vector;
        ]
      else
        lforeach(fn (@[arg _ _]) entry[mc:f_types][mc:flow_in][arg[mc:v_number]] = itype_any,
                 ifn[mc:c_fargs]);
      lforeach(fn (arg) entry[mc:f_types][mc:flow_in][arg[mc:v_number]] = itype_any,
	       ifn[mc:c_fglobals]);
      lforeach(fn (arg) entry[mc:f_types][mc:flow_in][arg[mc:v_number]] = itype_any,
	       ifn[mc:c_fclosure]);

      // iterate till solution found

      merge_block = fn (n)
	[
	  | node, types, new_in, new_out |

	  node = graph_node_get(n);
	  types = node[mc:f_types];

	  // compute in as 'union' of out's of predecessors
	  new_in = types[mc:flow_in];
	  graph_edges_in_apply
	    (fn (predecessor)
	     [
	       | pnode, ptypes, branch_constraints, flow_out |

	       pnode = graph_node_get(graph_edge_from(predecessor));
	       ptypes = pnode[mc:f_types];
	       flow_out = ptypes[mc:flow_out];
	       branch_constraints = ptypes[mc:flow_kill]; // slot reuse
	       if (branch_constraints)
		 flow_out = apply_iconstraint
		   (if (graph_edge_get(predecessor))
		      // fallthrough, ie false edge
		      cdr(branch_constraints)
		    else // branch, ie true edge
		      car(branch_constraints),
		    flow_out);
	       typeset_union!(new_in, flow_out);
	     ], n);
	  types[mc:flow_in] = new_in;

	  // compute new out
	  //display("APPLY\n");
	  //show_constraints(types[mc:flow_gen]);
	  //display("TO "); show_typesets(new_in); newline();
	  if (types[mc:flow_gen] == null) new_out = vcopy(new_in)
	  else new_out = lreduce(apply_iconstraint, new_in, types[mc:flow_gen]);
	  //display("-> "); show_typesets(new_out); newline();
	  assert(new_out != types[mc:flow_out]);
          | live_out |
          live_out = node[mc:f_live][mc:flow_out];
          for (|i| i = vlength(new_out); --i >= 0; )
            if (!bit_set?(all_globals, i) && !bit_set?(live_out, i))
              // ignore output type of dead variables
              new_out[i] = itype_any;
	  if (!typeset_eq?(new_out, types[mc:flow_out]))
	    [
	      types[mc:flow_out] = new_out;
	      change = true
	    ]
	];

      icount = 0;
      loop
	[
	  change = false;
	  //dformat("*ITERATION %s*\n", icount + 1);
	  graph_nodes_apply(merge_block, cdr(fg));
	  icount = icount + 1;
	  if (!change) exit 0;
	];
      if (mc:verbose >= 3)
	[
	  dformat("Type inference iterations %s\n", icount);
	];

      extract_types(ifn);

      mc:clear_dataflow(ifn);

      icvars = null;
      mc:this_function = null;
    ];

  mc:show_type_info = fn (types)
    if (types)
      [
	display("Types:\n");
	show_constraints(types[mc:flow_gen]);
	display("in:"); show_typesets(types[mc:flow_in]); newline();
	display("out:"); show_typesets(types[mc:flow_out]); newline();
      ];

  show_typesets = fn (typeset)
    for (|v| v = 1; v < vector_length(typeset); ++v)
      dformat(" %s(%s)", v, showset(typeset[v]));

  showset = fn (tset)
    if (tset == itype_none) "none"
    else if (tset == itype_any) "any"
    else
      [
        | op, i |
        op = make_string_oport();
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
	  dformat("constraint %s\n", i);
	  show_constraint(car(constraints));
	  i = i + 1;
	  constraints = cdr(constraints);
	];
    ];

  show_constraint = fn (constraint)
    [
      dformat("  vars: %s\n", concat_words(lmap(itoa, constraint[1]), " "));
      lforeach(show_c, constraint[2]);
    ];

  show_c = fn (c)
    [
      dformat("  %s", concat_words(lmap(show_condition, c[0]), " & "));
      if (c[1])
	dformat(" => %s contains %s\n", c[1], show_condition(c[2]));
    ];

  show_condition = fn (cond)
    [
      | s |

      s = showset(car(cond));
      lforeach(fn (v) s = s + format(" /\\ %s", v), cdr(cond));
      s
    ];

];
