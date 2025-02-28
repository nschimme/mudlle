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

library phase3 // optimisation
requires compiler, dlist, flow, graph, ins3, misc, optimise, sequences, vars

defines mc:phase3, mc:myself

reads mc:verbose, mc:infer_types
writes mc:tnargs, mc:tncstargs, mc:tnpartial, mc:tnfull

// VARIABLE CLASSES: Some notes on their effects on optimisation
//   A function f uses:
//     - global variables (gvars)
//     - global defines (gdefs)
//     - global constants (gcsts, ie gdefs from protected modules)
//     - constants (csts)
//     - closure variables (closures)
//     - local variables (locals)

//   All these sets can be further subdivided into:
//     write: variables written in f
//     r&w: variables read and written in f (includes write)

//  There is no universal way of treating these, indeed the treatment of
//  some variables changes during the compilation process.
//  Some notes:

//  Ambiguous information:
//    - as far as f is concerned, gdefs, gcsts and csts do not change
//    - closures are essentially identical to globals (ie they may all
//      change at every function call)
//    - locals only change at function calls if they have escaped into
//      a closure
//    - locals are only read at function calls if they have escaped
//  This information is handled by the flow_ambiguous and scan_ambiguous
//  functions (flow_ambiguous computes which local variables have escaped
//  at each point, scan_ambiguous is a basic-block iterator that passes
//  the ambiguous information)

//  Some optimisations only care about writes. Ambiguous information currently
//  doesn't distinguish between reads & writes of local variables (for globals
//  & closures this can be specified by the 'globals' parameter to
//  scan_ambiguous). The ambiguous information could be split to handle this.

//  gdefs can be treated as constants, except for type inference.

//  gdefs & gcsts may not take part in constant folding (note that phase1
//  has made integers from protected modules into constants, so this isn't
//  much of a limitation).


// The following optimisations are done:
//   - constant folding (optimise.mud)
//   - dead code elimination (unreachable, useless) (optimise.mud)
//   - copy propogation (optimise.mud)
//     supports constant folding & dead code elimination
//   - simple type inference (see inference.mud)
//   - direct recursion detection (note: not possible for global functions)
//   - detection of non-indirect variables (that do not need a variable cell)
//     (this must be the *crucial* optimisation)

// Intra-procedural ideas:
//   - simplify some ops (see file reductions)
//   - common subexpressions
//   - loop invariant detection & removal (e.g. closure creation)
//   - tail recursion
//   - what about debugging ?
//   - variable splitting ? (2 independent uses of the same variable)

// Inter-procedural ideas
//   - build call-graph
//   - trace function value flow to call sites for better optimisations
//   - beta reduction
//   - function invariant detection & removal (to an extra closure var)
//     (e.g. closures)
//   - "local-call" optimisation to improve handling of functions
//     defined in a block and assigned to a local variable which is never
//     modified (ie most local functions):
//       - mutually recursive functions can be somehow "merged"
//       - calls to these "known" functions can be much simpler
//     note: what exactly characterises a "known" function (SML of NJ terminology) ?

[
  | compute_closure_uses, represent_variables, direct_recursion |

  compute_closure_uses = fn (fns)
    // Types: fns: list of intermediate function
    // Effects: Computes for every local variable information on its uses
    //   in closures (read, write)
    [
      | closure_uses |

      lforeach(fn (ifn) // clear info
	        lforeach(fn (local) local[mc:v_lclosure_uses] = 0,
			ifn[mc:c_flocals]),
	      fns);

      // compute uses
      closure_uses = fn (il)
	[
	  | ins, dvar, args |

	  ins = il[mc:il_ins];
	  dvar = mc:defined_var(ins);
	  args = mc:arguments(ins, null);

          if (ins[mc:i_class] == mc:i_vref)
            lforeach(fn (v) [
              | base |
              base = mc:var_base(v);
              base[mc:v_lclosure_uses] |=
                (mc:vref_indirect | mc:closure_read | mc:closure_write
                 | mc:local_write_once | mc:local_write_many);
            ], args)
          else
            lforeach(fn (v)
                     if (v[mc:v_class] == mc:v_closure)
                     [
                       | base |
                       base = mc:var_base(v);
                       base[mc:v_lclosure_uses] |= mc:closure_read;
                     ],
                     args);

	  if (dvar && dvar[mc:v_class] == mc:v_closure)
	    [
	      | base |

	      base = mc:var_base(dvar);
	      base[mc:v_lclosure_uses] |= mc:closure_write;
	    ];
	];

      lforeach
	(fn (ifn)
	   graph_nodes_apply
	     (fn (n) dforeach(closure_uses, graph_node_get(n)[mc:f_ilist]),
	      cdr(ifn[mc:c_fvalue])),
	 fns);
    ];

  represent_variables = fn (fns)
    // Types: fns: list of intermediate function
    // Effects: Works out which local variables must be indirect
    //   and sets the indirect field of all appropriate variables
    [
      | indirection, ambiguous_def, add_indirection |

      indirection = fn (ifn)
	[
	  | locals |

	  mc:flow_ambiguous(ifn, mc:f_ambiguous_rw);
	  locals = ifn[mc:c_flocals]; // candidates
	  // all locals assigned in closures must be indirect
	  /*lforeach(fn (v) v[mc:v_indirect] = true, locals);
	  locals = null;*/
	  locals = lfilter(fn (v)
			     [
			       | uses |
			       uses = v[mc:v_lclosure_uses];
			       if (uses & mc:closure_write)
				 [
				   v[mc:v_indirect] = true;
				   false
				 ]
			       else // consider further if read in closures
				 uses & mc:closure_read
			     ],
			   locals);

	  // For remaining locals, check if the local is part of the
	  // ambiguous set at its point of definition. If so it must
	  // be indirect.
	  // ambiguous info is available from prior optimisation
	  ambiguous_def = fn (local)
	    [
	      | nlocal |

	      nlocal = local[mc:v_number];

	      graph_nodes_exists?(fn (n) [
                mc:scan_ambiguous(fn (il, ambiguous, indirect) [
                  if (!indirect &&
                      nlocal == il[mc:il_defined_var] &&
                      bit_set?(ambiguous, nlocal))
                    indirect = local[mc:v_indirect] = true;
                  indirect
                ], false, graph_node_get(n), mc:new_varset(ifn),
                                  mc:f_ambiguous_rw);
              ], cdr(ifn[mc:c_fvalue]));
	    ];

	  lforeach(ambiguous_def, locals);
	  mc:clear_dataflow(ifn);
	];

      add_indirection = fn (ifn, ilist)
	// Types: ifn: intermediate function
	//        ilist: instruction list
	// Effects: Adds instructions to access and set indirect variables
	// Returns: new ilist (may have added instructions at the start)
	// Modifies: ilist
	[
	  | scan, fcode, vmap |

	  fcode = mc:new_fncode(ifn); // for modifications
	  vmap = ifn[mc:c_fallvars];

	  scan = ilist;
	  loop
	    [
	      | il, ins, args, dvar, ndvar, class |

	      il = dget(scan);
              mc:set_loc(il[mc:il_loc]);
	      ins = il[mc:il_ins];
	      class = ins[mc:i_class];
	      if (ndvar = il[mc:il_defined_var]) dvar = vmap[ndvar]
	      else dvar = false;

	      // Add a fetch of each indirect arg (not for closures or
	      // non-safe-write memory ops; the latter are only used for
	      // non-indirect reasons)
	      if (class != mc:i_closure &&
                  class != mc:i_vref &&
                  (class != mc:i_memory
                   || ins[mc:i_mop] == mc:memory_write_safe) &&
		  (args = lfilter(fn (v) v[mc:v_indirect],
                                  mc:arguments(ins, null))) != null)
		// Special case: replacing 'x := <indirect var>'
		if (class == mc:i_compute && ins[mc:i_aop] == mc:b_assign)
		  // replaced by x := <indirect var>[0]
                  [
                    il[mc:il_ins] = ins = mc:make_memory_ins(
                      mc:memory_read, car(args), 0, dvar);
                    class = ins[mc:i_class]
                  ]
		else
		  [
		    | new, replist, label |

		    mc:set_instruction(fcode, scan);
		    new = dprev(scan);
		    replist = null;
		    while (args != null)
		      [
			| temp, arg |

			arg = car(args);
			if (!assq(arg, replist)) // only fetch each var once
			  [
			    temp = mc:new_local(fcode);
			    mc:ins_memory(fcode, mc:memory_read, car(args),
                                          0, temp);
			    replist = (arg . temp) . replist;
			  ];
			args = cdr(args);
		      ];
		    new = dnext(new);	// new points to 1st added ins

		    mc:replace_args(ins, replist);

		    // may have added instructions at start
		    if (scan == ilist) ilist = new;

		    // move label of scan if any
		    if (label = il[mc:il_label])
		      [
			il[mc:il_label] = false;
			mc:set_label(label, dget(new));
		      ];
		  ];

	      // must come after arg, to make special assignment handling
	      // work correctly (assignments of the form <ind1> := <ind2>
	      // have already been replaced by <ind1> := <ind2>[0])
	      if (dvar && dvar[mc:v_indirect]) // indirect destination
		[
		  | temp |

		  // Special case: replacing '<indirect var> := x'
		  if (class == mc:i_compute && ins[mc:i_aop] == mc:b_assign)
		    [
		      | x |

		      // replaced by <indirect var>[0] := x
		      x = car(ins[mc:i_aargs]);
		      il[mc:il_ins] = mc:make_memory_ins(
                        mc:memory_write, dvar, 0, x);
		    ]
		  else
		    [
		      temp = mc:new_local(fcode);
		      mc:set_instruction(fcode, dnext(scan));
		      mc:ins_memory(fcode, mc:memory_write, dvar, 0, temp);
		      mc:replace_dest(ins, temp);
		    ];
		];

	      scan = dnext(scan);
	      if (scan == ilist) exit ilist
	    ]
	];

      lforeach(indirection, fns);
      lforeach(fn (ifn)	// forward indirection to closure vars
	      lforeach(fn (cvar)
		      cvar[mc:v_indirect] = mc:var_base(cvar)[mc:v_indirect],
		      ifn[mc:c_fclosure]),
	      fns);

      // add instructions to fetch and set indirect variables
      lforeach(fn (ifn)
	      graph_nodes_apply(fn (n)
				[
				  | block |
				  block = graph_node_get(n);
				  block[mc:f_ilist] =
				    add_indirection(ifn, block[mc:f_ilist])
				],
				cdr(ifn[mc:c_fvalue])),
	      fns);
    ];

  // Placeholder for "myself" in functions
  mc:myself = mc:var_make_constant("<myself>");

  direct_recursion = fn (ifn)
    // Types: ifn: intermediate function
    // Effects: Detects direct recursive calls for the functions contained in
    //   ifn: marks the variables concerned by replacing the parent variable by the
    //   special "mc:myself" constant variable
    [
      | detect_myself |

      detect_myself = fn (il)
	[
	  | ins |

	  ins = il[mc:il_ins];

	  if (ins[mc:i_class] == mc:i_closure)
	    [
	      | cdest, myself, subfn |

	      cdest = ins[mc:i_fdest];
	      subfn = ins[mc:i_ffunction];

	      // See if cdest is in subfn's variables
	      // (We are after indirection has been added, so this test is correct)

	      if (myself = lexists?(fn (cvar) cvar[mc:v_cparent] == cdest,
				    subfn[mc:c_fclosure]))
		myself[mc:v_cparent] = mc:myself;
	    ]
	];

      graph_nodes_apply
	(fn (n) dforeach(detect_myself, graph_node_get(n)[mc:f_ilist]),
	 cdr(ifn[mc:c_fvalue]));
    ];

  mc:phase3 = fn "intermediate -> intermediate. Phase 3 of the compiler" (fns)
    [
      // makes basic blocks explicit
      lforeach(mc:split_blocks, fns);

      compute_closure_uses(fns);
      mc:optimise_functions(fns);

      if (mc:verbose >= 2)
	[
	  display("Inferring types\n");
	];
      mc:tnargs = mc:tncstargs = mc:tnpartial = mc:tnfull = 0;
      lforeach(mc:infer_types, fns);
      if (mc:verbose >= 3)
	[
	  display("Complete type inference results:\n");
	  dformat("%s args, of which %s constant, %s fully inferred, %s partially.\n",
                  mc:tnargs, mc:tncstargs, mc:tnfull, mc:tnpartial);
	];

      if (mc:verbose >= 2)
	[
	  display("Adding indirection\n");
	];
      represent_variables(fns);
      lforeach(direct_recursion, fns);

      if (mc:verbose >= 5)
	lforeach(mc:display_blocks, fns);
    ];

];
