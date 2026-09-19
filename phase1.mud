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

library phase1 // Phase 1: name resolution
requires compiler, dihash, dlist, ins3, misc, sequences, vars
defines mc:phase1, mc:gsym_defines, mc:gsym_reads, mc:gsym_writes,
  mc:gsym_read, mc:gsym_written, mc:gsym_called

reads mc:this_module, mc:describe_seclev, mc:erred
writes mc:this_function

// Takes a parse tree as returned by mudlle_parse, and makes the following
// changes:
//   a) all variable names are replaced by a vector. Two uses of the
//      same variable in the same function will refer to the same vector.
//
//      There are 4 kinds of variable:
//        global: a global variable
//        global_constant: a constant global variable
//        local: local to a block or a parameter
//        closure: non-local variables (but not global) used in a function
//
//   b) The header of a function is changed to include:
//      all its local variables (parameters, locals)
//      the variables of its parent which will form its closure
//      the variable in which the function is stored (debugging)
//      the types of its arguments (instead of being in the argument list)
//
//   c) All block constructs are removed
//      as a result, all components become lists of components
//      explicit initialisation to null is added for all variables
//
//   d) a statement labeled "function" is added around every function
//
//   e) the module header and all global variable references are checked
//      errors:
//        the required modules must be present (successfully loaded)
//        no clashes between writes and defines
//        reads & writes must be legal, as specified by the header
//      warnings:
//        stealing an identifier from another module
//	  stealing a writable identifier
//      Note that the loader has a different concept of errors and
//      warnings for these cases (eg stealing an identifier is an error)


[
  | resolve_component, resolve_block, env_init, env, topenv, comp_null,
    env_add_block, env_lookup, env_enter_function, env_leave_function,
    env_enter_block, env_leave_block, mstart, mcleanup, mlookup, imported?,
    all_readable, all_writable, readable, writable, definable, statics,
    required_modules, import, system_import, env_toplevel?, import_protected,
    env_user_var_prefix, env_global_prefix,
    assv, warn_bad_module_variables,
    kget_static, kget_user_var,
    es_blocks, es_nlocals, es_args, es_closure, es_fn,
    describe_seclev, module_seclev, global_syms,
    symbol_error |

  mc:gsym_defines = 0;
  mc:gsym_reads   = 1;
  mc:gsym_writes  = 2;
  mc:gsym_read    = 3;
  mc:gsym_written = 4;
  mc:gsym_called  = 5;

  // environment stack (topenv) indices
  es_blocks  = 0;
  es_args    = 1;
  es_closure = 2;               // closure vars
  es_fn      = 3;
  es_nlocals = 4;

  env_global_prefix = ":";
  env_user_var_prefix = "$";

  kget_user_var      = mc:make_kglobal("c:get_user_var");
  kget_static        = mc:make_kglobal("c:get_static");

  | mk_recall |
  mk_recall = fn (loc, var)
    list(vector(mc:c_recall, loc, var));

  comp_null = mk_recall(mc:no_loc, mc:var_make_constant(null));

  | gsym_use |
  gsym_use = fn (int gidx, vector loc, int type)
    [
      if (global_syms == null) exit<function> null;
      // global_syms is a dihash(gidx) -> table(filename)
      //   -> assoc(mc:gsym_xxx) -> list((line << 32) | column)
      | tab |
      tab = dihash_ref(global_syms, gidx);
      if (tab == null)
        tab = dihash_set!(global_syms, gidx, make_ctable());
      | entry, this |
      entry = table_symbol_ref(tab, mc:this_module[mc:m_filename], null);
      this = assq(type, symbol_get(entry));
      if (!this)
        [
          this = type . null;
          symbol_set!(entry, this . symbol_get(entry));
        ];
      | old, iloc |
      old = cdr(this);
      iloc = (mc:loc_line(loc) << 32) | mc:loc_column(loc);
      assert(iloc >= 0);
      if (!lfind?(iloc, old))
        set_cdr!(this, iloc . old);
    ];

  describe_seclev = fn (int lev)
    if (function?(mc:describe_seclev))
      mc:describe_seclev(lev)
    else
      lev;

  // find vector v in l, for which v[0] == n
  assv = fn (n, l)
    loop
      [
        if (l == null) exit false;
        if (car(l)[0] == n) exit car(l);
        l = cdr(l);
      ];

  // environment handling

  env_init = fn ()
    // Effects: Initialises an empty environment
    [
      env = topenv = null;
    ];

  env_enter_function = fn (vector f)
    // Types: f : function
    // Modifies: env, topenv
    // Requires: the names in args be distinct
    // Effects: Adds a new function to the environment stack, with parameters
    //   called args
    [
      assert(vlength(f) == mc:c_fallvars + 1);
      mc:this_function = f;
      topenv = indexed_vector(
        es_fn       . f,
        es_nlocals  . '(0));
      env = dcons!(topenv, env);
      env_add_block(null);
    ];

  env_toplevel? = fn ()
    // Returns: true if we are in the toplevel function
    dnext(env) == env;

  // remove function at top of env and return vector of its
  // argument, local and closure vars
  env_leave_function = fn ()
    // Types : result : list of args . list of locs
    // Modifies: env, topenv
    // Requires: All blocks of the top-level function must be exited
    // Effects: Pops the top level function from the environment stack
    // Returns: args, where args is a list of variables representing the
    //   function's parameters; the first is the $nargs variable
    [
      | args |
      args = topenv[es_args];
      env = dremove!(env, env);
      if (env != null)
	[
	  topenv = dget(env);
	  mc:this_function = topenv[es_fn];
	]
      else
        mc:this_function = null;

      args
    ];

  | env_add_func_arg |
  env_add_func_arg = fn (v)
    [
      v[mc:vl_var] = mc:var_make_local(v[mc:vl_var]);

      topenv[es_args] = v . topenv[es_args];

      | blocks, nlocals |
      blocks = topenv[es_blocks];
      nlocals = topenv[es_nlocals];

      // find topmost (function) block
      loop
        [
          | nblocks |
          nblocks = cdr(blocks);
          set_car!(nlocals, car(nlocals) + 1);
          if (nblocks == null)
            exit null;
          blocks = nblocks;
        ];

      | vtable, name, var, loc |
      @[ var _ loc ] = v;
      name = var[mc:v_name];
      vtable = car(blocks);
      vtable[name] = vector(null, name, 0, loc) . var;
    ];

  env_enter_block = fn (locals, top?)
    // Types: locals : list of (string . type)
    // Modifies: topenv
    // Requires: the names in locals be distinct
    // Effects: A new block is entered in the current function with the
    //   specified local variables.
    // Returns: a list of components initialising the variables to null
    [
      lforeach(fn (v) v[mc:vl_var] = mc:var_make_local(v[mc:vl_var]), locals);
      if (top?)
        lforeach(fn (v) v[mc:vl_var] = mc:var_make_static(v[mc:vl_var]),
                 locals);
      env_add_block(locals);
      lmap(fn (@[var _ loc]) [
        | cl |
        if (top?)
          [
            | vname, getter |
            assert(var[mc:v_class] == mc:v_static);
            var = var[mc:v_sparent];
            vname = var[mc:v_name];
            getter = if (abbrev?(env_user_var_prefix, vname))
              kget_user_var
            else
              kget_static;
            cl = list(vector(
              mc:c_execute, loc,
              list(mk_recall(loc, getter),
                   mk_recall(loc, mc:var_make_constant(vname)))));
          ]
        else
          cl = comp_null;
        vector(mc:c_assign, loc, var, cl)
      ], locals)
    ];

  env_leave_block = fn ()
    // Modifies: topenv
    // Requires: At least one block must have been entered in the top level
    //   function
    // Effects: The top level block of the current function is exited
    [
      if (!mc:erred)
        table_foreach(fn (sym) [
          | var, err, vname |
          var = car(symbol_get(sym));
          err = match! (var[mc:mv_used])
            [
              0 => "unused";
              ,mc:muse_read => "never written";
              ,mc:muse_write => "never read";
              ,(mc:muse_read | mc:muse_write) => exit<function> null;
            ];
          vname = var[mc:mv_name];
          if (abbrev?(env_user_var_prefix, vname))
            exit<function> null;
          mc:set_loc(var[mc:mv_loc]);
          mc:warning("local variable %s is %s", mc:markup_var(vname), err);
        ], car(topenv[es_blocks]));

      topenv[es_blocks] = cdr(topenv[es_blocks]);
      topenv[es_nlocals] = cdr(topenv[es_nlocals]);
    ];

  // Add a new block of local vars
  env_add_block = fn (vars)
    [
      assert(vector?(topenv));

      | vtable, nv |
      vtable = make_table();
      nv = car(topenv[es_nlocals]);
      while (vars != null)
	[
          | var, loc, name |
          @([var _ loc] . vars) = vars;

          if (nv == mc:max_local_vars)
            [
              mc:set_loc(loc);
              mc:error("too many local variables");
            ];

	  name = var[mc:v_name];

          if (slength(name) && name[0] != ?%)
            // look for previous definitions in the same function
            for (|blocks| blocks = topenv[es_blocks]; blocks != null; )
              [
                | vtab, oldv |
                @(vtab . blocks) = blocks;
                oldv = vtab[name];
                if (oldv != null)
                  [
                    mc:set_loc(loc);
                    mc:warning("redefinition of '%s'", mc:markup_var(name));
                    mc:set_loc(car(oldv)[mc:mv_loc]);
                    mc:note("the previous declaration is here");
                  ]
              ];

          ++nv;
          vtable[name] = indexed_vector(
            mc:mv_name . name,
            mc:mv_used . 0,
            mc:mv_loc  . loc) . var;
	];
      topenv[es_blocks] = vtable . topenv[es_blocks];
      topenv[es_nlocals] = nv . topenv[es_nlocals];
    ];

  env_lookup = vector fn (name, write, call)
    // Types: name : string
    //        result : var
    //	      write : boolean
    // Modifies: env
    // Effects: Looks for the variable in the current environment that
    //   corresponds to name, starting in the innermost block of the top
    //   level function and working outwards.

    //   If not found, the variable is global, and library processing
    //   is done with mlookup (write is true for writes, false for reads)

    //   Otherwise appropriate closure variables are added to bring the
    //   variable to the top level function.

    // Returns: the var structure representing the variable in the top-level
    //   function.
    [
      | inenv, found, blocks |

      if (abbrev?(env_global_prefix, name))
	exit<function>
	  mlookup(string_tail(name, slength(env_global_prefix)), write, call);

      inenv = env;

      <search> loop
	[
	  // search all blocks of inenv function
	  blocks = dget(inenv)[es_blocks];
	  loop
            [
              if (blocks == null) exit 0;
              if ((found = car(blocks)[name]) != null)
                exit<search> 0; // found!
              blocks = cdr(blocks);
            ];

	  // not found, try next function
	  inenv = dnext(inenv);
	  if (inenv == env) // not found at all, is global
	    exit<function> mlookup(name, write, call);
	];

      // found is cons(mvar, var)
      car(found)[mc:mv_used] |= if (write) mc:muse_write else mc:muse_read;
      found = cdr(found);

      // Add found to all appropriate closures
      while (inenv != env)
	[
	  | cname, thisenv, finder |
	  inenv = dprev(inenv);
	  thisenv = dget(inenv);

	  // Is found already in the closure of the next function ?
          finder = if (found[mc:v_class] == mc:v_static)
            fn (cv)
              [
                if (cv[mc:v_class] != mc:v_static)
                  exit<function> false;
                cv = cv[mc:v_sparent];
                assert(cv[mc:v_class] == mc:v_closure);
                cv[mc:v_cparent] == found[mc:v_sparent]
              ]
          else
            fn (cv) (cv[mc:v_class] == mc:v_closure
                     && cv[mc:v_cparent] == found);
          cname = lexists?(finder, thisenv[es_closure]);

	  if (!cname)		// No, add it
            [
              found = if (found[mc:v_class] == mc:v_static)
                mc:var_make_static(
                  mc:var_make_closure(name, found[mc:v_sparent]))
              else
                mc:var_make_closure(name, found);
              thisenv[es_closure] = found . thisenv[es_closure]
            ]
	  else
	    found = cname;
	  // And repeat with new variable for next level
	];

      found
    ];

  // Module handling

  mstart = fn (m, int seclev, {vector,null} mglobal_syms)
    // Types: m : module
    // Effects: Does module-entry checks
    // Modifies: this_module, required_modules, readable, writable,
    //  definable, all_writable, all_readable
    [
      | all_loaded, mname |

      mname = m[mc:m_name];

      global_syms = mglobal_syms;
      symbol_error = if (mglobal_syms == null)
        mc:error
      else
        mc:warning;

      // Check that all modules are loaded. As opposed to the interpreter,
      // the compiler does *not* load missing modules. It is not in the
      // business of executing code.

      all_loaded = true;
      required_modules = make_table();
      lforeach
	(fn (required)
	 [
	   | name, s, loc |

	   @[name _ loc] = required;
           mc:set_loc(loc);
	   s = module_status(name);

	   if (s < module_loaded)
	     [
	       mc:error("%s not loaded", name);
	       all_loaded = false
	     ];
	   required_modules[name] = vector(s, mc:get_loc(), null);
	 ],
	 m[mc:m_requires]);

      all_writable = m[mc:m_class] == mc:m_plain;
      all_readable = m[mc:m_class] == mc:m_plain || !all_loaded;

      /* Check status of variables (gives warnings, not errors) */

      /* defines must be ours, or normal, or write */
      definable = lmap
	(fn (var)
	 [
	   | status, name, n, loc |

           @[name _ loc] = var;
           mc:set_loc(loc);
	   n = global_lookup(name);
	   status = module_vstatus(n);

	   if (string?(status) && string_icmp(status, mname) != 0)
	     mc:warning("cannot define %s: belongs to module %s",
                        mc:markup_var(name), status)
	   else if (status == var_write)
	     [
	       if (seclev < SECLEVEL_GLOBALS)
	         symbol_error("cannot define %s: exists and is writable",
                              mc:markup_var(name))
	       else
	         mc:warning("%s is writable", mc:markup_var(name));
             ]
	   else if (status == var_system_write || status == var_system_mutable)
	     symbol_error("cannot define %s in mudlle", mc:markup_var(name));

           gsym_use(n, mc:get_loc(), mc:gsym_defines);
	   vector(n, name, 0, mc:get_loc())
	 ],
	 m[mc:m_defines]);

      /* writes must not belong to a module */
      writable = lreduce(fn (var, l) [
        | status, name, n, loc |

        @[name _ loc] = var;
        mc:set_loc(loc);
        n = global_lookup(name);
        status = module_vstatus(n);

        if (assv(n, definable))
          [
            symbol_error("cannot write and define %s", mc:markup_var(name));
            exit<function> l;
          ];
        if (status == var_system_write)
          [
            symbol_error("cannot write %s from mudlle", mc:markup_var(name));
            exit<function> l;
          ];

        gsym_use(n, mc:get_loc(), mc:gsym_writes);
        if (status == var_system_mutable)
          [
            mc:warning("%s is always writable", mc:markup_var(name));
            exit<function> l;
          ];
        if (string?(status))
          mc:warning("cannot write %s: belongs to module %s",
                     mc:markup_var(name), status);

        vector(n, name, 0, mc:get_loc()) . l
      ], null, m[mc:m_writes]);

      /* reads */
      readable = lreduce(fn (@[name _ loc], l) [
        mc:set_loc(loc);

        | n, status |

        n = global_lookup(name);
        status = module_vstatus(n);

        gsym_use(n, mc:get_loc(), mc:gsym_reads);

        if (status == var_system_write
            || status == var_system_mutable
            || status == var_system_mutable
            || equal?(status, "system"))
          [
            mc:warning("%s is always readable", mc:markup_var(name));
            exit<function> l;
          ];

        vector(global_lookup(name), name, 0, mc:get_loc()) . l
      ], null, m[mc:m_reads]);

      statics = m[mc:m_statics];
      lforeach(fn (@[name _ _]) [
        | n |
        // avoid global_lookup here as that would create a global
        n = global_table()[name];
        if (!integer?(n)) exit<function> null;
        lforeach(fn (@(what . vars)) [
          match (assv(n, vars))
            [
              [ _ _ _ line ] => [
                mc:set_loc(line);
                mc:error("cannot %s static %s", what, mc:markup_var(name));
              ];
            ]
        ], list("define" . definable,
                "write" . writable,
                "read" . readable));
      ], statics);

      m[mc:m_requires] = required_modules;
      m[mc:m_defines] = definable;
      m[mc:m_writes] = writable;
      m[mc:m_reads] = readable;
      m[mc:m_statics] = statics;
    ];

  mcleanup = fn ()
    // Effects: Clean up module variables
    global_syms = readable = definable = writable = required_modules = null;

  imported? = fn (mod)
    // Returns: status of mod if it is in required_modules, false otherwise
    // Modifies: required_modules
    match! (required_modules[mod])
      [
        [m _ _] => m;
        () => false;
      ];

  import = fn (vector v, string mod)
    // Effects: Marks v as being imported from mod
    // Modifies: required_modules
    // Returns: v
    [
      | m |

      m = required_modules[mod];
      if (m == null)
	// implicitly import m
	required_modules[mod] = vector(module_status(mod), mc:no_loc, v . null)
      else if (!memq(v, m[2]))
	m[2] = v . m[2];
      v
    ];

  system_import = fn (int n, string name)
    import(mc:var_make_global(name, n), "system");

  import_protected = fn (name, n, mod)
    [
      | v, val |

      v = import(mc:var_make_kglobal(name, n), mod);
      // inline integers, floats and null
      val = global_value(n);
      if (val == null || integer?(val) || float?(val))
        mc:var_make_constant(val)
      else
        v
    ];

  mlookup = fn (name, write, call)
    // Types: name: string
    //        write: boolean
    // Effects: Checks read/write accesses to global name for validity
    // Returns: an appropriate variable
    [
      | vstatus, n, vent |

      n = global_lookup(name);
      gsym_use(n, mc:get_loc(),
               [
                 if (write)
                   mc:gsym_written
                 else if (call)
                   mc:gsym_called
                 else
                   mc:gsym_read
               ]);
      if (!write)
	[
	  // now: name is not imported
	  if (assv(n, definable))
	    [
              | st |
              st = module_vstatus(n);
              if (string?(st) && module_status(st) == module_protected)
                [
                  | val |
                  val = global_value(n);
                  // inline simple constants in their own library
                  if (val == null || integer?(val) || float?(val))
                    exit<function> mc:var_make_constant(val);
                ];

	      // local define, a dglobal except at top-level
	      if (!env_toplevel?())
		exit<function> mc:var_make_dglobal(name, n);
	    ]
	  else if ((vent = assv(n, readable))
                   || (vent = assv(n, writable)))
            vent[mc:mv_used] |= mc:muse_read
          else
	    [
	      vstatus = module_vstatus(n);
	      if (string?(vstatus))
		[
		  // implicitly import protected modules
		  if (module_status(vstatus) == module_protected
                      && (!mc:this_module[mc:m_name]
                          || !string_iequal?(mc:this_module[mc:m_name],
                                             vstatus)))
		    exit<function> import_protected(name, n, vstatus);

		  if (imported?(vstatus) == module_loaded)
		    exit<function> import(mc:var_make_dglobal(name, n),
                                          vstatus);
		  if (!all_readable)
		    symbol_error("read of global %s (module %s)",
                                 mc:markup_var(name), vstatus)
		]
	      else if (vstatus == var_system_write
                       || vstatus == var_system_mutable)
                exit<function> system_import(n, name)
              else if (!all_readable)
		symbol_error("read of global %s", mc:markup_var(name));
	    ]
	]
      else
	[
	  if (vent = assv(n, definable))
	    [
              vent[mc:mv_used] |= mc:muse_write;
	      if (!env_toplevel?())
		mc:error("define of %s not at top level", mc:markup_var(name));
	    ]
	  else if (vent = assv(n, writable))
            vent[mc:mv_used] |= mc:muse_write
          else
	    [
	      vstatus = module_vstatus(n);
              if (vstatus == var_system_write)
                symbol_error("cannot write global %s (module system)", name)
              else if (vstatus == var_system_mutable)
                exit<function> system_import(n, name)
              else if (all_writable)
		[
		  if (string?(vstatus))
		    mc:warning("write of global %s (module %s)",
                               mc:markup_var(name), vstatus);
		]
	      else if (string?(vstatus))
                symbol_error("write of global %s (module %s)",
                             mc:markup_var(name), vstatus)
              else
                symbol_error("write of global %s", mc:markup_var(name));
	    ]
	];
      // usual result, even for error cases
      mc:var_make_global(name, n)
    ];

  // Scan component tree

  resolve_block = fn (vars, comps, top?)
    [
      | components, init |
      init = env_enter_block(vars, top?);
      components = lappend!(init, mappend(resolve_component, comps));
      env_leave_block();
      components
    ];

  resolve_component = fn (vector c, call? = false, aname = false)
    [
      | class, prevline, result |
      prevline = mc:get_loc();
      mc:maybe_set_loc(c[mc:c_loc]);

      class = c[mc:c_class];
      result = if (class == mc:c_assign)
	[
          | var |
          mc:maybe_set_loc(c[mc:c_asymloc]);
	  c[mc:c_asymbol] = var = env_lookup(c[mc:c_asymbol], true, false);
          mc:maybe_set_loc(c[mc:c_loc]);
   	  c[mc:c_avalue] = resolve_component(c[mc:c_avalue], call?, var);
	  list(c)
	]
      else if (class == mc:c_recall)
        [
          c[mc:c_rsymbol] = env_lookup(c[mc:c_rsymbol], false, call?);
          list(c)
        ]
      else if (class == mc:c_constant)
	mk_recall(mc:no_loc, mc:var_make_constant(c[mc:c_cvalue]))
      else if (class == mc:c_closure)
	[
          c = indexed_vector(
            mc:c_class           . mc:c_closure,
            mc:c_loc             . c[mc:c_loc],
            mc:c_freturn_typeset . c[mc:c_freturn_typeset],
            mc:c_fhelp           . c[mc:c_fhelp],
            mc:c_ffullargs       . c[mc:c_ffullargs],
            mc:c_farginfo        . c[mc:c_farginfo],
            mc:c_fvalue          . c[mc:c_fvalue],
            mc:c_ffilename       . c[mc:c_ffilename],
            mc:c_fnicename       . c[mc:c_fnicename],
            mc:c_fendloc         . c[mc:c_fendloc],
            mc:c_freturn_itype   . mc:itypeset_from_typeset(
              c[mc:c_freturn_typeset]),
            mc:c_fvar            . aname,
            // skipped 6 varlists
            mc:c_fnoescape       . false,
            mc:c_fnargs_var      . false,
            // phase4: misc (skipped)
            mc:c_fnvars          . 0,
            mc:c_fallvars        . null);

          // validate the above assignments if this changes
          assert(mc:c_fallvars == 22);

          env_enter_function(c);
          | arginfo |
          arginfo = c[mc:c_farginfo];

          if (arginfo[mc:arginfo_noptargs] > 0)
            [
              | nargs_var |
              nargs_var = vector("%nargs", TYPESET_ANY | TYPESET_FLAG_OPTIONAL,
                                 c[mc:c_loc]);
              env_add_func_arg(nargs_var);
              c[mc:c_fnargs_var] = nargs_var;
            ];

          | blocks_added |
          blocks_added = false;
          for (| fargs | fargs = c[mc:c_ffullargs]; fargs != null; )
            [
              | farg, defval |
              @(farg . fargs) = fargs;
              defval = farg[mc:fullarg_default_val];
              if (defval != null)
                farg[mc:fullarg_default_val] = resolve_component(defval);
              env_add_func_arg(farg[mc:fullarg_arg]);

              | patcomp |
              if (farg[mc:fullarg_pat_vars] != null)
                [
                  ++blocks_added;
                  patcomp = env_enter_block(farg[mc:fullarg_pat_vars], false);
                ];
              if (farg[mc:fullarg_pat_expr] != null)
                patcomp = lappend!(
                  patcomp,
                  resolve_component(farg[mc:fullarg_pat_expr]));
              farg[mc:fullarg_pat_expr] = patcomp;
            ];
          | components |
          components = resolve_component(c[mc:c_fvalue]);
          for (; blocks_added > 0; --blocks_added)
            env_leave_block();
          env_leave_function();

	  // add a "function" label
	  components = list(vector(mc:c_labeled, mc:no_loc,
				   "function",
				   components));
          c[mc:c_fvalue] = components;
	  list(c)
	]
      else if (class == mc:c_execute)
	[
          | args, callee |
          args = c[mc:c_efnargs];
          callee = resolve_component(car(args), true);
	  args = callee . lmap(resolve_component, cdr(args));
          callee = car(last_pair(callee));

          c[mc:c_efnargs] = args;

          if (callee[mc:c_class] == mc:c_recall)
            [
              | sym, val, fsec, vcls |
              sym = callee[mc:c_rsymbol];
              vcls = sym[mc:v_class];
              if (vcls == mc:v_global_constant
                  && secure?(val = global_value(sym[mc:v_goffset]))
                  && (fsec = function_seclevel(val)) > module_seclev)
                mc:warning("calling secure %s primitive %s() from seclevel %s",
                           describe_seclev(fsec),
                           mc:markup_fn(val),
                           describe_seclev(module_seclev));
              if (vcls == mc:v_global || vcls == mc:v_global_constant
                  || vcls == mc:v_global_define)
                gsym_use(sym[mc:v_goffset], callee[mc:c_loc], mc:gsym_called);
            ];
	  list(c)
	]
      else if (class == mc:c_builtin)
	[
	  c[mc:c_bargs] = lmap(resolve_component, c[mc:c_bargs]);
	  list(c)
	]
      else if (class == mc:c_block)
        resolve_block(c[mc:c_klocals], c[mc:c_ksequence], false)
      else if (class == mc:c_labeled)
	[
	  c[mc:c_lexpression] = resolve_component(c[mc:c_lexpression]);
	  list(c)
	]
      else if (class == mc:c_exit)
	[
	  c[mc:c_eexpression] = resolve_component(c[mc:c_eexpression]);
	  list(c)
	]
      else
        fail();

      mc:set_loc(prevline);
      result
    ];

  warn_bad_module_variables = fn (int seclev)
    [
      lforeach(fn (var) [
        if (!(var[mc:mv_used] & mc:muse_write))
          [
            mc:set_loc(var[mc:mv_loc]);
            mc:warning("%s was never defined", mc:markup_var(var[mc:mv_name]))
          ]
      ], definable);
      lforeach(fn (var) [
        mc:set_loc(var[mc:mv_loc]);
        if (!(var[mc:mv_used] & mc:muse_read))
          mc:warning("%s was never %s", mc:markup_var(var[mc:mv_name]),
                     if (var[mc:mv_used]) "read" else "used");
        | n, vstatus |
        n = global_lookup(var[mc:mv_name]);
        vstatus = module_vstatus(n);
        if (string?(vstatus))
          [
            | mseclev |
            mseclev = module_seclevel(vstatus);
            mseclev = if (mseclev && mseclev < seclev)
              format(" (lvl %s)", describe_seclev(mseclev))
            else
              "";
            mc:warning("reads %s defined in %s%s",
                       mc:markup_var(var[mc:mv_name]), vstatus, mseclev);
          ]
      ], readable);
      lforeach(fn (var) [
        if (!(var[mc:mv_used] & mc:muse_write))
          [
            mc:set_loc(var[mc:mv_loc]);
            mc:warning("%s was never %s",
                       mc:markup_var(var[mc:mv_name]),
                       if (var[mc:mv_used]) "written" else "used")
          ]
      ], writable);
      table_foreach(fn (@<name = [_ loc syms]>) [
        if (syms == null)
          [
            mc:set_loc(loc);
            mc:warning("symbols from required module %s were never used",
                       name);
          ]
      ], required_modules);
    ];

  mc:phase1 = fn (m, int seclev, {vector,null} mglobal_syms)
    [
      | fname, nname, top_var |

      top_var = vector(mc:v_global, "top-level");
      module_seclev = seclev;

      fname = m[mc:m_filename];
      nname = m[mc:m_nicename];

      mstart(m, seclev, mglobal_syms);
      env_init();
      | func |
      func = indexed_vector(
        mc:c_class            . mc:c_closure,
        mc:c_loc              . m[mc:m_loc],
        mc:c_freturn_typeset  . typeset_any,
        mc:c_fhelp            . null,
        mc:c_ffullargs        . null,
        mc:c_farginfo         . indexed_sequence(
          mc:arginfo_nargs    . 0,
          mc:arginfo_noptargs . 0,
          mc:arginfo_vararg   . false),
        mc:c_fvalue           . null,
        mc:c_ffilename        . fname,
        mc:c_fnicename        . nname,
        mc:c_fendloc          . m[mc:m_endloc],
        mc:c_freturn_itype    . itype_any,
        mc:c_fvar             . top_var,
        // skipped 6 varlists
        mc:c_fnoescape        . false,
        mc:c_fnargs_var       . false,
        // phase4: misc (skipped)
        mc:c_fnvars           . 0,
        mc:c_fallvars         . null);

      // validate the above assignments if this changes
      assert(mc:c_fallvars == 22);

      env_enter_function(func);
      func[mc:c_fvalue] = resolve_block(m[mc:m_statics], list(m[mc:m_body]),
                                        true);
      @() = env_leave_function();
      warn_bad_module_variables(seclev);
      mcleanup();

      m[mc:m_body] = func;
    ];
];
