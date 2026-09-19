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

library phase4 // Phase 4: code generation
requires compiler, flow, graph, ins3, misc, mp, optimise, sequences, vars
defines mc:phase4
reads mc:verbose, mc:disassemble
[
  | clear_igraph, make_igraph, allocate_registers, cgen_function, cgen_code |


  clear_igraph = fn (vars)
    // Effects: Removes all references to the interference graph
    //  from vars
    [
      | remvar |

      remvar = fn (v) v[mc:v_neighbors] = null;
      lforeach(remvar, vars);
    ];

  make_igraph = fn (ifn)
    [
      | vars, map, add_interferences |

      map = ifn[mc:c_fallvars];
      // Make a neighbor bitset for every variable (except for 'myself')
      vars = lappend!(lfilter(fn (cvar) cvar[mc:v_cparent] != mc:myself,
                              ifn[mc:c_fclosure]),
                      ifn[mc:c_flocals]);

      lforeach(fn (v) v[mc:v_neighbors] = mc:new_varset(ifn), vars);

      // Then set bits in neighbors for variables that are simultaneously
      // live. (these represent flow graph edges)

      add_interferences = fn (ins, live_in, live_out, x)
	// add edges between all variables in live_out
	bforeach(fn (nv1)
		 [
		   | neighbors |

		   neighbors = map[nv1][mc:v_neighbors];
		   if (neighbors != null)
		     bunion!(neighbors, live_out)
		 ], live_out);

      graph_nodes_apply(fn (n)
			[
			  | block |

			  block = graph_node_get(n);
			  mc:rscan_live(add_interferences, null, block);
			  add_interferences(null, null,
                                            block[mc:f_live][mc:flow_in],
                                            null);
			],
			cdr(ifn[mc:c_fvalue]));

      lforeach(fn (v) clear_bit!(v[mc:v_neighbors], v[mc:v_number]), vars);

      vars
    ];

  allocate_registers = fn (ifn)
    // Types: ifn: intermediate function with flow graph
    // Effects: Allocates registers for the variables of ifn. Adds spills if
    //   necessary.
    [
      // Note that a lot of values start off spilled:
      //   arguments beyond nregargs
      //   closure variables
      // These should be spilled first if necessary
      // To be considered: variables that are only used once should not be
      // unspilled if they start that way. 1st approximation: count static
      // uses (fails for loops).

      | groups, no, nob, spiltargs, ncallee, ncaller, nscratch, nregargs,
	spill, easy_spill, changes, color_graph, color_order, ainfo,
        notspilt, spilt, temps, locals, map, vars, group_variables,
        select_colors, select_spill, localsb,
        vg_notspilt, vg_spilt, vg_local, vg_temp |

      vg_notspilt = 0;
      vg_spilt    = 1;
      vg_local    = 2;
      vg_temp     = 3;

      group_variables = fn (vars)
	[
	  | notspilt, spilt, temps, locals, group, bvars |

	  group = fn (il, live_in, live_out, x)
	    [
	      | ins, dvar, regclass |
	      ins = il[mc:il_ins];

              regclass = mp:uses_regclass(ins);
              if (regclass == mc:regclass_none)
                exit<function> null;

              dvar = il[mc:il_defined_var];

	      if (regclass == mc:regclass_caller)
		[
		  | survive_call |

		  // everything live after the call (except the result)
		  // belongs either in notspilt or in spilt
                  survive_call = live_out;
                  if (dvar && bit_set?(survive_call, dvar))
                    clear_bit!(survive_call = bcopy(survive_call), dvar);

		  bdifference!(temps, survive_call);
		  bdifference!(locals, survive_call);
		  bforeach(fn (nlive) [
                    | set |
                    set = if (map[nlive][mc:v_class] == mc:v_closure
                              || bit_set?(spiltargs, nlive)) // already spilt
                      spilt
                    else
                      notspilt;
                    set_bit!(set, nlive)
                  ], survive_call);
		]
	      else
		[
		  | survives |

		  // if live on the way in & out then can't be temp
		  // this misses some possible scratch vars (and
		  // makes register allocation for them rather pointless),
		  // but is the simplest test

                  if (regclass == mc:regclass_early_scratch)
                    // must not have inputs in scratch registers
                    survives = live_in
		  else
                    [
                      survives = bintersection(live_in, live_out);
                      if (dvar)
                        clear_bit!(survives, dvar);
                    ];

		  // those temps that survive move to locals
		  bunion!(locals, bintersection(temps, survives));
		  bdifference!(temps, survives);
		]
	    ];

	  // assume everything is a temp, and migrate it as forced
	  notspilt = mc:new_varset(ifn);
	  spilt = bcopy(notspilt);
	  locals = bcopy(notspilt);
	  bvars = mc:set_vars!(bcopy(notspilt), vars);
	  temps = bcopy(bvars);

	  graph_nodes_apply(fn (n) [
            mc:rscan_live(group, null, graph_node_get(n))
          ], cdr(ifn[mc:c_fvalue]));

	  mp:migrate(ifn, vars, notspilt, spilt, locals, temps);

	  // remove extraneous variables
	  bintersection!(notspilt, bvars);
	  bintersection!(spilt, bvars);

	  vector(notspilt, spilt, locals, temps);
	];

      easy_spill = fn (vars, bvars)
	[
	  | v |
          v = lexists?(fn (v) (!v[mc:v_location]
                               && (v[mc:v_class] == mc:v_closure
                                   || bit_set?(spiltargs, v[mc:v_number]))),
                       vars);
          if (!v) exit<function> false;

          // spill the already spilt variable
          v[mc:v_location] = vector(
            mc:v_lspill,
            [
              if (v[mc:v_class] == mc:v_closure)
                mc:spill_closure
              else
                mc:spill_args
            ],
            0); // spill offset not yet selected
          clear_bit!(bvars, v[mc:v_number]);
          true
	];

      spill = fn (vars, bvars)
	[
          // find variable with most neighbors to spill

	  | best, maxneigh |
          maxneigh = -1;

          loop
            [
              | v |
              @(v . vars) = vars;
              if (!v[mc:v_location])
                [
                  | n |
                  n = bcount_intersection(bvars, v[mc:v_neighbors]);
                  if (n > maxneigh)
                    [
                      maxneigh = n;
                      best = v;
                    ];
                ];
              if (vars == null)
                exit null;
            ];

          if (best == null)
            exit<function> false;

          best[mc:v_location] = vector(mc:v_lspill, mc:spill_spill, 0);
          clear_bit!(bvars, best[mc:v_number]);
          true
        ];

      color_order = vector(0, 0, 0);
      color_graph = fn (vars, bvars, regtype, nregs)
	// Types: vars: list of var
	//        bvars: varset
	//        regtype: mc:reg_xxx
	//        nregs: int
	// Effects: Allocates registers for variables in vars from amongst
	//   nregs available ones. Conflicts between a variable in vars and
	//   one outside are ignored.
	//   The algorithm ignores all nodes that are already allocated
	[
	  | count |

	  count = 0;

	  loop
	    [
	      | v |

	      // look for a node of vars with less than nregs neighbors
	      v = lexists?(fn (v) [
                (!v[mc:v_location]
                 && bcount_intersection(v[mc:v_neighbors], bvars) < nregs)
              ], vars);

	      if (!v) exit bempty?(bvars);

	      ++count;
	      changes = true;
	      v[mc:v_location] = vector(mc:v_lregister, regtype,
					color_order[regtype]);
	      clear_bit!(bvars, v[mc:v_number]);
	      ++color_order[regtype]
	    ]
	];

      | get_free_color |
      // return color unused by neighbors
      get_free_color = fn (allocated, colors, var, locfield)
        [
          sfill!(colors, ~0);
          // remove colors used by allocated neighbors
          breduce(fn (nneighbor, colors) [
            clear_bit!(colors,
                       map[nneighbor][mc:v_location][locfield]);
            colors
          ], colors, bintersection(allocated, var[mc:v_neighbors]));

          | color |
          color = bitset_ffs(colors) - 1;
          assert(color >= 0);

          var[mc:v_location][locfield] = color;
          set_bit!(allocated, var[mc:v_number]); // var is now allocated

          color
        ];

      select_colors = fn (vars, regtype, nregs)
	// Types: vars: list of var
	//        regtype: mc:reg_xxx
	//        nregs: int
	// Effects: Selects colors for the variables of the interference
	//   graph, of type regtype. nregs variables of that type are
	//   assumed available.
	//   This function is called once all variables have been allocated
	//   with color_graph or spilled.
	[
	  | ovars, i, nused |

	  nused = -1;
	  // Find order of variables for given type
	  i = color_order[regtype];
	  ovars = make_vector(i);
	  lforeach(fn (var) [
            | vloc |
            vloc = var[mc:v_location];
            if (vloc[mc:v_lclass] == mc:v_lregister
                && vloc[mc:v_lrtype] == regtype)
              ovars[vloc[mc:v_lrnumber]] = var
          ], vars);

	  // Allocate variables in order from highest to lowest
	  // (reverse of graph-removal order)
	  // nodes are marked once they have been allocated

          | allocated, colors |
          colors = new_bitset(nregs);
	  allocated = mc:new_varset(ifn);
          while (i > 0)
	    [
	      | var, color |
	      var = ovars[--i];
              color = get_free_color(allocated, colors, var, mc:v_lrnumber);
	      if (color > nused) nused = color;
	    ];

	  nused + 1
	];

      select_spill = fn (vars, maxspill)
	// Types: vars: list of var
	//        maxspill: int
	// Effects: Selects offsets for spilled variables (spill_spill),
	//   with an effort at minimising the number of spill entries
	//   required.
	//   This function is called once all variables have been allocated
	//   with color_graph or spilled.
	[
	  | nspilled, allocated, colors |

          colors = new_bitset(maxspill);
	  nspilled = -1;

	  // Allocate all spilled variables, in an arbitrary order
	  allocated = mc:new_varset(ifn);
	  lforeach(fn (var) [
            | vloc |
            vloc = var[mc:v_location];
            if (vloc[mc:v_lclass] == mc:v_lspill
                && vloc[mc:v_lrtype] == mc:spill_spill)
              [
                | color |
                color = get_free_color(allocated, colors, var, mc:v_lsoffset);
                if (color > nspilled) nspilled = color;
              ]
          ], vars);

	  nspilled + 1
	];

      map = ifn[mc:c_fallvars];
      // discover how many registers are available for this function
      ifn[mc:c_fmisc] = vector(false, false, false, false);
      nregargs = mp:nregargs(ifn);
      nscratch = mp:nscratch(ifn);
      ncaller = mp:ncaller(ifn);
      ncallee = mp:ncallee(ifn);

      assert(nregargs == 0);    // fix the below if this changes
      | spiltvars |
      for (|fargs| fargs = ifn[mc:c_ffullargs]; fargs != null;)
        [
          | farg, var, ts |
          @(farg . fargs) = fargs;
          @[var ts _] = farg[mc:fullarg_arg];
          if (ts == null || (ts & TYPESET_FLAG_OPTIONAL))
            exit<break> null;
          spiltvars = var . spiltvars
        ];
      spiltargs = mc:new_varset(ifn);
      mc:set_vars!(spiltargs, spiltvars);

      vars = make_igraph(ifn);
      // separate variables into 4 groups:
      //   0: notspilt: those that live across procedure calls and are
      //      not spilled
      //   1: spilt: those that live across procedure calls but are spilled
      //   3: temps: those that can live in the scratch registers
      //   2: locals: all the others
      groups = group_variables(vars);
      temps    = bitset_map_list(groups[vg_temp],     map);
      locals   = bitset_map_list(groups[vg_local],    map);
      spilt    = bitset_map_list(groups[vg_spilt],    map);
      notspilt = bitset_map_list(groups[vg_notspilt], map);

      if (mc:verbose >= 3)
	[
	  dformat("AVAILABLE: scratch: %s, caller: %s callee: %s\n",
                  nscratch, ncaller, ncallee);
	];

      // Do scratch registers first, as they should normally all
      // be successful
      while (temps != null
             && !color_graph(temps, groups[vg_temp], mc:reg_scratch, nscratch))
        [
          // spill one temp to locals and try again
          | first, fnum |
          temps = lfilter!(fn (v) !v[mc:v_location], temps);
          @(first . temps) = temps;
          locals = first . locals;
          fnum = first[mc:v_number];
          set_bit!(groups[vg_local], fnum);
          clear_bit!(groups[vg_temp], fnum);
        ];

      localsb = groups[vg_local];
      <allocate_locals> loop
	[
	  loop
	    [
	      changes = false;
	      if (color_graph(locals, localsb, mc:reg_caller, ncaller))
		exit<allocate_locals> 0;
	      if (!changes) exit 0
	    ];

	  // spill somebody, preferably already spilled
	  // beyond that, the heuristic needs much more thought
	  // (e.g. which is better: spill long-lived or short-lived vars ?)
	  if (!easy_spill(locals, localsb))
            spill(locals, localsb)
	];

      // Note: see old-allocate.mud for an idea that doesn't work
      // (summary: try & place locals in callee registers when caller
      // ones all full)
      // (strange things happen and registers go unused ...)
      // This needs further investigation.

      no = lappend(notspilt, spilt);
      nob = bunion(groups[vg_notspilt], groups[vg_spilt]);
      <allocate_others> loop
	[
	  loop
	    [
	      changes = false;
	      if (color_graph(no, nob, mc:reg_callee, ncallee))
		exit<allocate_others> 0;

	      if (!changes) exit 0;
	    ];

	  // spill somebody, preferably already spilled
	  // beyond that, the heuristic needs much more thought
	  // (e.g. which is better: spill long-lived or short-lived vars ?)
	  if (!easy_spill(spilt, nob))
            spill(notspilt, nob)
	];

      ainfo = vector(
        select_colors(vars, mc:reg_scratch, nscratch),
        select_colors(vars, mc:reg_caller,  ncaller),
        select_colors(vars, mc:reg_callee,  ncallee),
        select_spill(vars, llength(ifn[mc:c_flocals])));
      if (mc:verbose >= 3)
	[
	  dformat("USED: scratch: %d, caller: %d callee: %d, spilt %d\n",
                  ainfo[mc:vainfo_scratch], ainfo[mc:vainfo_caller],
                  ainfo[mc:vainfo_callee], ainfo[mc:vainfo_spill]);
	];
      clear_igraph(vars);
      ainfo
    ];

  cgen_function = fn (ifn)
    // Types: ifn: intermediate function with flow graph
    // Effects: Generates the actual machine code function for ifn, and stores
    //   it in ifn[mc:c_fvalue]
    [
      | ainfo |

      if (mc:verbose >= 2)
	[
	  dformat("Generating %s\n", mc:fname(ifn));
	];

      mc:recompute_vars(ifn, false);
      mc:flow_live(ifn);

      ainfo = allocate_registers(ifn);
      if (mc:verbose >= 3)
	[
	  dformat("ainfo is %s\n", ainfo);
	];
      //mc:display_blocks(ifn);
      mc:flatten_blocks(ifn);
      cgen_code(ifn, ainfo);
    ];

  cgen_code = fn (ifn, ainfo)
    [
      | code |

      ainfo = mp:select_registers(ifn, ainfo);
      if (mc:verbose >= 3)
	[
	  dformat("selected ainfo is %s\n", ainfo);
	];

      if (mc:verbose >= 4 || mc:disassemble)
	[
	  dformat("Code of function %s(%s)\n",
                  ifn[mc:c_fnumber], mc:fname(ifn));
          if (mc:verbose >= 4)
            [
              mc:ins_list1(ifn[mc:c_fvalue]);
              newline();
            ]
        ];

      code = mp:mgen_preamble(ifn, ainfo);
      dforeach(fn (il) [
        if (il[mc:il_label])
          il[mc:il_label][mc:l_mclabel] = mp:new_label(code)
      ], ifn[mc:c_fvalue]);
      dforeach(fn (il) [
        mp:mgen_instruction(code, ifn, ainfo, il)
      ], ifn[mc:c_fvalue]);

      if (mc:verbose >= 5)
	[
	  mp:ins_list(code);
	  newline();
	];

      mc:set_loc(ifn[mc:c_loc]);
      ifn[mc:c_fvalue] = mp:assemble(code);
    ];

  mc:phase4 = fn "intermediate -> fn. Generates code for the function" (fns)
    [
      lforeach(cgen_function, fns);
    ];
];
