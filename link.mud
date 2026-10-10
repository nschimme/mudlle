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

library link // A linker.
requires compiler, misc, sequences, vars
defines mc:prelink, mc:prelink_llvm, mc:display_as, mc:prelinked_requires, mc:prelinked_name
reads mc:describe_seclev, mc:compiler_mcode_version, mc:llvm_constants
writes mc:this_filenames, mc:this_module, mc:erred, mc:linkrun

[

  | make_code, seen_code, prelink, mstart,
    pmodule_name, pmodule_imports, pmodule_defines, pmodule_writes,
    pmodule_protect, pmodule_class, pmodule_reads, pmodule_body,
    pmodule_version, prelinked_module_fields,
    pfn_code, pfn_help, pfn_varname, pfn_filename, pfn_loc, pfn_subfns,
    pfn_constants, pfn_builtins, pfn_globals, pfn_kglobals, pfn_kglobal_code,
    pfn_primitives, pfn_primops, pfn_npcrel, pfn_return_typeset,
    pfn_return_itype,
    pfn_linenos, pfn_arguments, pfn_vararg_alloc, pfn_seclevs, pfn_flags,
    pfn_nicename, prelinked_function_fields,
    check_presence, check_dependencies, dependencies, depend_immutable,
    depend_primitive, depend_type, depend_closure, depend_value,
    depend_vstatus, dependency, check_dependency, check_present,
    set_this_filenames,
    prelinked_fns,
    describe_seclev,
    my:assq, my:lappend!, my:lforeach, my:lmap, my:mc:error, my:mc:loc_line,
    my:mc:warning, my:mcode_version, my:vmap, my:vqsort!, my:vtol, my:ltov,
    my:subfn_closure, my:subfn_called, my:subfn_code,
    my:mc:markup_fn, my:mc:markup_type, my:mc:markup_var,
    word_size |

  // Linker:

  // The prelinker accepts the results of phase4 and produces a
  // prelinked module (pmodule), which can be saved with save_data.

  // The linker takes a prelinked module, checks everything, and then
  // links the module into the current environment. Finally it runs
  // the generated code, and updates the module's status.

  // prelinked module structure (similar to module):
  pmodule_class = 0;		// module class
  pmodule_protect = 1;		// true if module should be protected
  pmodule_name = 2;		// module name (or false)
  pmodule_imports = 3;		// dependencies (details below)
  pmodule_defines = 4;		// defined symbols (list of string)
  pmodule_reads = 5;		// read symbols (list of string)
  pmodule_writes = 6;		// written symbols (list of string)
  pmodule_body = 7;		// top-level function (prelinked function)
  pmodule_version = 8;          // mc:arch | (mc:mcode_version << 8)

  prelinked_module_fields = 9;

  // The dependencies for a module is the set of symbols (defines) imported
  // from modules that it requires, along with any checks on the actual values
  // of these symbols.
  // The linker requires that these symbols belong to the same modules as at
  // compile time.
  // Complex dependencies are only present for "protected" modules.

  // imports is thus an associative array, with the imported modules as keys
  // Associated with each entry is a list:
  //   car: status of imported module at compile time (loaded or protected)
  //   cdr: list of imports
  //     if loaded: simply list of symbol names
  //     if protected: list of dependencies (see end of this file)

  // All the functions are also transformed into a "prelinked" form:
  pfn_code = 0;		   // machine code (string)
  pfn_help = 1;		   // help (string or null)
  pfn_varname = 2;	   // varname (string or null)
  pfn_nicename = 3;	   // pretty-printed filename (string)
  pfn_loc = 4;             // (line . column)
  // references (all of the form list of <info> . offset,
  // where offset is an integer offset into code
  pfn_subfns = 5;	   // sub-functions list(pfn . offset)
  pfn_constants = 6;	   // constants list(value . offset)
  pfn_builtins = 7;	   // builtins list(string . offset)
  pfn_globals = 8;	   // globals list(string . offset)
  pfn_kglobals = 9;	   // constant globals list(string . offset)
  pfn_kglobal_code = 10;   // constant global code list(string . offset)
  pfn_primitives = 11;	   // prims list(string . offset)
  pfn_primops = 12;	   // primops list(string . offset)
  pfn_npcrel = 13;         // number of PC-relative addresses after code
  pfn_seclevs = 14;	   // seclevs list(offset)
  pfn_return_typeset = 15; // return typeset
  pfn_return_itype = 16;   // return itype
  pfn_linenos = 17;        // DWARF line number information
  pfn_arguments = 18;      // vector(name|false . typeset|null ...)
  pfn_vararg_alloc = 19;   // vararg vector allocated
  pfn_flags = 20;          // clf_xxx flags
  pfn_filename = 21;	   // filename (string)

  prelinked_function_fields = 22;

  // Linking
  // -------

  // linkrun can unload anything, hence it should only depend on stuff in
  // system and local vars while running
  my:assq           = assq;
  my:lappend!       = lappend!;
  my:lforeach       = lforeach;
  my:lmap           = lmap;
  my:ltov           = list_to_vector;
  my:mc:error       = mc:error;
  my:mc:loc_line    = mc:loc_line;
  my:mc:markup_fn   = mc:markup_fn;
  my:mc:markup_type = mc:markup_type;
  my:mc:markup_var  = mc:markup_var;
  my:mc:warning     = mc:warning;
  my:vmap           = vmap;
  my:vqsort!        = vqsort!;
  my:vtol           = vector_to_list;

  my:subfn_closure = mc:subfn_closure;
  my:subfn_called  = mc:subfn_called;
  my:subfn_code    = mc:subfn_code;

  my:mcode_version = if (integer?(mc:compiler_mcode_version))
    mc:compiler_mcode_version
  else
    mc:mcode_version;

  word_size = (INTBITS + 1) / 8;

  | darwin? |
  darwin? = string_equal?(uname()[un_sysname], "Darwin");

  describe_seclev = fn (int lev)
    if (function?(mc:describe_seclev))
      mc:describe_seclev(lev)
    else
      lev;

  | qsort_by_cdr |
  qsort_by_cdr = fn (list l)
    my:vtol(my:vqsort!(fn (a, b) cdr(a) < cdr(b), my:ltov(l)));

  mc:display_as = fn """`v -> . Displays GNU assembler corresponding to\
 prelinked object file `v.""" (prelink)
    [
      | all_fn_names, all_fns, fns, print_fn, func_name, sname |
      all_fn_names = make_table();

      sname = fn (s)
        smap(fn (c) [
          if (calpha?(c) || cdigit?(c))
            c
          else if (c == ??)
            ?p
          else if (c == ?!)
            ?b
          else
            ?_
        ], s);

      func_name = fn (f)
        [
          | p |
          p = my:assq(f, all_fns);
          if (p)
            exit<function> cdr(p);

          | s, base, n |
          s = f[pfn_varname];
          s = base = if (s == null)
            format("fn_%d", my:mc:loc_line(f[pfn_loc]))
          else
            sname(s);
          n = 0;
          while (all_fn_names[s] != null)
            s = format("%s_%d", base, ++n);
          all_fn_names[s] = f;
          all_fns = (f . s) . all_fns;
          s
        ];

      print_fn = fn (f)
        [
          | data |
          data = lreduce(fn (@[f o type], d) [
            if (!my:assq(f, all_fns))
              fns = f . fns;
            | s |
            s = func_name(f);
            s = match! (type)
              [
                ,my:subfn_closure => "closure_" + s;
                ,my:subfn_code => "fn_" + s;
                ,my:subfn_called => "fn_code_" + s;
              ];
            (s . o) . d
          ], data, f[pfn_subfns]);
          data = lreduce(fn (@(c . o), d) [
            (("cst_" + type_names[typeof(c)]) . o) . d
          ], data, f[pfn_constants]);
          data = lappend(f[pfn_builtins], data);
          data = lreduce(fn (g, d) [
            | n |
            n = match (car(g))
              [
                (name . 0) => "gidx_" + name;
                (name . 1) => "mgidx_" + name;
                name => "glb_" + name;
              ];
            ((n . 4) . cdr(g)) . d
          ], data, f[pfn_globals]);
          data = lappend(f[pfn_kglobals], data);
          data = lreduce(fn (@(k . o), d) [
            (("code-" + k) . o) . d
          ], data, f[pfn_kglobal_code]);
          data = lreduce(cons, data, f[pfn_primitives]);
          data = lreduce(fn (@(f . o), d) [
            (f + "_op" . o) . d
          ], data, f[pfn_primops]);
          data = lreduce(fn (@(l . o), d) [
            (('["seclev" "mseclev" "maxlev"][l] . '[2 4 4][l]) . o)
              . d
          ], data, f[pfn_seclevs]);

          data = '(() . ,maxint) . data;

          data = qsort_by_cdr(data);

          | fname |
          fname = func_name(f);
	  // .align uses bytes on GNU, trailing zero bits on Darwin
          dformat(".align %d\n.globl %s\n%s:\n",
		  if (darwin?) 4 else 16, fname, fname);

          | code, lni, nextra |
          code = f[pfn_code];
          lni = expand_line_number_info(f[pfn_linenos]);

          // pad if necessary
          nextra = ((-slength(code) & (word_size - 1))
                    + f[pfn_npcrel] * word_size);

          for (|i, l, cl, lnipos| [
            lnipos = i = 0;
            cl = slength(code);
            l = cl + nextra
          ]; ; )
            [
              | e |
              e = min(cdar(data), l);
              | prefix |
              prefix = ".byte ";
              <at_e> while (i < e)
                [
                  if (i == car(lni[lnipos]))
                    [
                      newline();
                      // hack: .loc needs to be followed by an instruction (not
                      // .byte and such), but a second .loc works as well
                      dformat(".loc 1 %d\n", cdr(lni[lnipos]));
                      dformat(".loc 1 %d\n", cdr(lni[lnipos]));
                      prefix = ".byte ";
                      ++lnipos;
                    ];

                  if (i == cl)
                    [
		      newline();
		      if (!darwin?)
			dformat(".size %s, . - %s\n", fname, fname);
                      if (nextra > 0)
                        [
			  | align |
			  align = if (darwin?)
			    ffs(word_size) - 1
			  else
			    word_size;

                          dformat("\n.align %d\n", align);
                          i = (i + word_size - 1) & -word_size;
                          if (i == e)
                            exit<at_e> null;
                        ];
                      prefix = ".byte ";
                    ];
                  dformat("%s%d", prefix, if (i < cl) code[i] else 0);
                  ++i;
                  prefix = ", ";
                ];
              display("\n");
              if (i == l) exit<break> null;
              | arg |
              arg = caar(data);
              if (!pair?(arg))
                arg = arg . ((INTBITS + 1) / 8);
              match! (arg)
                [
                  (s . 2) => [ dformat(".word %s\n", sname(s)); i += 2 ];
                  (s . 4) => [ dformat(".long %s\n", sname(s)); i += 4 ];
                  (s . 8) => [ dformat(".quad %s\n", sname(s)); i += 8 ];
                ];
              data = cdr(data);
            ];
          display("\n");
        ];

      dformat(".file 1 %w\n", prelink[pmodule_body][pfn_filename]);
      fns = prelink[pmodule_body] . null;
      while (fns != null)
        [
          | f |
          @(f . fns) = fns;
          print_fn(f);
        ];
    ];

  mc:prelinked_requires = fn """`pmodule -> `l. Returns the list of library\
 names required by prelinked file `pmodule.""" (vector pmodule)
    table_reduce(fn (@<name = _>, l) name . l, null, pmodule[pmodule_imports]);

  mc:prelinked_name = fn """`pmodule -> `s|false. Returns the name of the\
 module in prelinked file `pmodule.""" (vector pmodule)
    pmodule[pmodule_name];

  // false - failed linking
  // null  - failed running
  // list(result)  - ok
  mc:linkrun = fn (prelinked_module, seclev, reload)
    [
      | res, mname, filenames |

      mname = prelinked_module[pmodule_name];
      if (!reload && mname && module_status(mname) != module_unloaded)
	exit<function> '(,true . ());

      res = false;
      mc:erred = false;
      mc:this_module = null;
      filenames = make_ctable();
      if (mstart(prelinked_module, seclev))
	[
	  if (!mc:erred) // run only if no errors
	    [
	      | code, codev |

              seen_code = null;
	      code = make_code(prelinked_module[pmodule_body], seclev, true,
                               filenames);
              codev = my:lmap(fn (x) cdr(cdr(x)), seen_code);
              register_mcode_module(codev);
              seen_code = null;
              res = true;
              | val |
	      val = with_maxseclevel(
                seclev | (seclev << msl:trace_seclevel_shift),
                fn() trap_error(code, fn (n) res = null, call_trace_barrier,
                                null));
              if (res == true)
                res = list(val);
	    ];

	  if (mname)
	    if (pair?(res) && prelinked_module[pmodule_protect])
	      [
		module_set!(mname, module_protected, seclev);
		// check immutability, otherwise dependencies on immutable
		// symbols of the loaded module might fail
		detect_immutability();
	      ]
	    else
	      module_set!(mname,
			  if (pair?(res)) module_loaded else module_error,
			  seclev);
	];

      mc:this_module = null;
      mc:this_filenames = null;

      res
    ];

  set_this_filenames = fn (m)
    [
      | b |
      b = m[pmodule_body];
      mc:this_filenames = b[pfn_filename] . b[pfn_nicename]
    ];

  | module_describe |
  module_describe = fn (vstatus)
    if (string?(vstatus))
      format("belongs to the %s module", vstatus)
    else if (vstatus == var_system_write)
      "cannot be written from mudlle"
    else if (vstatus == var_system_mutable)
      "belongs to the system module"
    else
      fail();

  mstart = fn (m, seclev)
    [
      if (vlength(m) != prelinked_module_fields
          || vlength(m[pmodule_body]) != prelinked_function_fields
          || (m[pmodule_version] & 0xff) != mc:arch
          || (m[pmodule_version] >> 8) < mc:mcode_version)
        [
          dformat("%s: object file has bad version\n", m[pmodule_name]);
          exit<function> false;
        ];

      set_this_filenames(m);

      | mname |
      mname = m[pmodule_name];
      if (mname)
	[
	  // unload it
	  if (module_seclevel(mname) > seclev)
	    [
	      dformat("cannot unload module %s (seclevel %s > %s)\n",
                      mname, describe_seclev(module_seclevel(mname)),
                      describe_seclev(seclev));
	      exit<function> false;
	    ];
	  if (!module_unload(mname))
            [
              dformat("cannot unload protected module %s\n", mname);
              exit<function> false;
            ];
	  module_set!(mname, module_loading, seclev);
	];

      if (seclev < SECLEVEL_GLOBALS)
        [
          if (m[pmodule_class] == mc:m_plain)
            my:mc:error("cannot create 'plain' modules at seclevel %s"
                        +" (use a module or lib instead)",
                        describe_seclev(seclev));

          if (m[pmodule_writes] != null)
            my:mc:error("cannot write globals at seclevel %s",
                        describe_seclev(seclev));

          if (m[pmodule_reads] != null)
            my:mc:error("cannot read globals at seclevel %s",
                        describe_seclev(seclev));
        ];


      // load & check imported modules
      table_foreach
	(fn (@<iname = minfo>)
	 [
	   | mstatus, erred |
	   erred = mc:erred;
	   mstatus = module_require(iname);
	   mc:this_module = null; // could be set by module_require
           set_this_filenames(m);
	   mc:erred = erred;

	   if (mstatus < module_loaded)
	     [
	       if (mstatus == module_loading)
		 my:mc:error("loop in requires of %s", iname)
	       else
		 my:mc:error("failed to load %s", iname);
	     ]
	   else if (car(minfo) == module_loaded)
	     check_presence(cdr(minfo), iname)
	   else if (car(minfo) == module_protected)
	     if (mstatus != module_protected)
	       my:mc:error("%s is not protected anymore", iname)
	     else
	       check_dependencies(cdr(minfo), iname);
	 ],
	 m[pmodule_imports]);

      // Change status of variables
      my:lforeach
	(fn (var)
	 [
	   | n, vstatus |

	   n = global_lookup(var);
	   vstatus = module_vstatus(n);

	   if (vstatus == var_write && seclev < SECLEVEL_GLOBALS)
	     my:mc:error("cannot define %s: exists and is writable",
                         my:mc:markup_var(var))
	   else if (!module_vset!(n, mname))
	     my:mc:error("cannot define %s: %s", my:mc:markup_var(var),
                         module_describe(vstatus))
	   else if (vstatus == var_write)
	     my:mc:warning("%s was writable", my:mc:markup_var(var));
	 ],
	 m[pmodule_defines]);

      my:lforeach
	(fn (var)
	 [
	   | n |

	   n = global_lookup(var);

	   if (!module_vset!(n, var_write))
             my:mc:error("cannot write %s: %s", my:mc:markup_var(var),
                         module_describe(module_vstatus(n)));
	 ],
	 m[pmodule_writes]);

      true // can proceed
    ];

  check_presence = fn (vars, mod)
    // Types: vars: list of string, mod: string
    // Effects: Checks that all of vars belong to module mod
    my:lforeach(fn (v) check_present(v, global_lookup(v), mod), vars);

  check_dependencies = fn (deps, mod)
    // Types: deps: list of dependencies, mod: string
    // Effects: Checks that all vars belong to module mod and that the
    //   depdendencies are respected
    my:lforeach(fn (d)
	     [
	       | n, v |

	       v = d[0];
	       n = global_lookup(v);
	       if (check_present(v, n, mod)) check_dependency(d, n);
	     ],
	     deps);

  make_code = fn (prelinked_fn, seclev, want_closure, table filenames)
    [
      // seen_code is a list of (prelinked . (closure . mcode))

      | found |
      if (found = my:assq(prelinked_fn, seen_code))
        exit<function> [
          found = cdr(found);
          if (want_closure)
            [
              if (!car(found))
                set_car!(found, make_closure(cdr(found)))
              else
                car(found)
            ]
          else
            cdr(found)
        ];

      found = prelinked_fn . false;
      seen_code = found . seen_code;

      // LLVM prelinked functions store [IR, entry symbol, arity, constants]
      // instead of architecture-specific machine code.
      if (vector?(prelinked_fn[pfn_code]))
        [
          | native, closure |
          native = prelinked_fn[pfn_code];
          if (vlength(native) != 4) error(error_bad_value);
          closure = llvm_load_ir_closure(
            native[0], native[1], native[2], seclev, native[3]);
          set_cdr!(found, closure . closure_code(closure));
          exit<function> closure
        ];

      | csts, code_csts |

      // make code for all sub-functions
      csts = prelinked_fn[pfn_constants];

      csts = my:lappend!(my:lmap(fn (@(name . ofs)) [
        global_value(global_lookup(name)) . ofs
      ], prelinked_fn[pfn_kglobals]), csts);

      code_csts = my:lmap(fn (@(name . ofs)) [
        | cl |
        cl = global_value(global_lookup(name));
        // assert() may not be available
        if (!(closure?(cl) && (closure_flags(cl) & clf_noclosure)))
          error(error_abort);
        closure_code(cl) . ofs
      ], prelinked_fn[pfn_kglobal_code]);

      my:lforeach(fn (@[f ofs type]) [
        match! (type)
          [
            ,my:subfn_closure =>
              csts = (make_code(f, seclev, true, filenames) . ofs) . csts;
            ,my:subfn_code =>
              csts = (make_code(f, seclev, false, filenames) . ofs) . csts;
            ,my:subfn_called =>
              code_csts = (make_code(f, seclev, false, filenames) . ofs)
                . code_csts;
          ];
      ], prelinked_fn[pfn_subfns]);

      csts = qsort_by_cdr(csts);
      code_csts = qsort_by_cdr(code_csts);

      | fname |
      fname = prelinked_fn[pfn_filename];
      match! (filenames[fname])
        [
          {pair} p => fname = p;
          () => fname = filenames[fname] = pcons(
            fname, prelinked_fn[pfn_nicename]);
        ];

      | f |
      f = link(
        prelinked_fn[pfn_code], seclev, prelinked_fn[pfn_help],
        prelinked_fn[pfn_varname],
        fname, prelinked_fn[pfn_loc],
        csts, code_csts,
        prelinked_fn[pfn_builtins],
        prelinked_fn[pfn_globals],
        prelinked_fn[pfn_primitives],
        prelinked_fn[pfn_primops],
        prelinked_fn[pfn_npcrel],
        prelinked_fn[pfn_seclevs],
        prelinked_fn[pfn_return_typeset],
        prelinked_fn[pfn_return_itype],
        prelinked_fn[pfn_linenos],
        prelinked_fn[pfn_arguments],
        prelinked_fn[pfn_vararg_alloc],
        prelinked_fn[pfn_flags]);
      if (want_closure)
        [
          | c |
          c = make_closure(f);
          set_cdr!(found, c . f);
          c
        ]
      else
        [
          set_cdr!(found, false . f);
          f
        ]
    ];

  // Prelinking
  // ----------

  mc:prelink = fn (vector mod, protect)
    // Types: mod: module after phase4, protect: boolean
    // Effects: Does a "prelink" of module and returns a value that may be:
    //   a) saved to disk with obj_save
    //   b) made into an executable function with mc:link
    //   If protect is true, module is marked as "protected"
    // Returns: Prelinked module
    [
      prelinked_fns = null;
      sequence(
        mod[mc:m_class],
        !!protect,
        mod[mc:m_name],
        dependencies(mod[mc:m_requires]),
        lmap(fn (v) v[mc:mv_name], mod[mc:m_defines]),
        lmap(fn (v) v[mc:mv_name], mod[mc:m_reads]),
        lmap(fn (v) v[mc:mv_name], mod[mc:m_writes]),
        prelink(mod[mc:m_body]),
        mc:arch | (my:mcode_version << 8))
    ];

  mc:prelink_llvm = fn (vector mod, string ir, protect)
    // Build the same serializable pmodule envelope as mc:prelink, with an
    // LLVM entry descriptor in the top-level function code slot.
    [
      | top, llvm_body |
      top = mod[mc:m_body];
      llvm_body = sequence(
        vector(ir, format("entry_%d", top[mc:c_fnumber]),
               llength(top[mc:c_ffullargs]),
               my:ltov(mc:llvm_constants())),
        top[mc:c_fhelp],
        if (top[mc:c_fvar]) top[mc:c_fvar][mc:v_name] else null,
        top[mc:c_fnicename],
        top[mc:c_loc],
        null, null, null, null, null, null, null, null, null, null,
        top[mc:c_freturn_typeset],
        0,
        null,
        mc:function_closure_args(top),
        false,
        0,
        top[mc:c_ffilename]);
      sequence(
        mod[mc:m_class],
        !!protect,
        mod[mc:m_name],
        dependencies(mod[mc:m_requires]),
        lmap(fn (v) v[mc:mv_name], mod[mc:m_defines]),
        lmap(fn (v) v[mc:mv_name], mod[mc:m_reads]),
        lmap(fn (v) v[mc:mv_name], mod[mc:m_writes]),
        llvm_body,
        mc:arch | (my:mcode_version << 8))
    ];

  dependencies = fn (imports)
    // Types: imports: table of import lists
    // Effects: Returns dependency information for this module, based
    //   on the current state of the symbols from the modules that it
    //   required.
    [
      table_foreach
	(fn (imp)
	 [
	   | mstatus, syms |

	   @[mstatus _ syms] = symbol_get(imp);
	   if (mstatus == module_loaded)
	     // weak dependencies: symbols must simply exist
	     // simply keep list of symbol names
             symbol_set!(imp, mstatus . lmap(fn (v) v[mc:v_name], syms))
	   else if (mstatus == module_protected)
	     // strong dependencies: may depend on type, value, etc of symbol
             symbol_set!(imp, mstatus . lmap(fn (v) dependency(v), syms))
	 ],
	 imports);

      imports
    ];

  prelink = fn (top)
    // Types: top: assembled intermediate function
    // Returns: Prelinked form of function top
    [
      | pfn_marker |

      match! (my:assq(top, prelinked_fns))
        [
          ,false => null;           // fallthrough
          (_ . {vector} v) => exit<function> v;
          (_ . ,false) => fail_message("recursion in prelink()");
        ];

      // add marker to catch any recursion
      pfn_marker = top . false;
      prelinked_fns = pfn_marker . prelinked_fns;

      | arguments, vararg_alloc? |
      arguments = mc:function_closure_args(top);
      vararg_alloc? = if (top[mc:c_farginfo][mc:arginfo_vararg])
        [
          | var |
          @[var _ _] = last_element(top[mc:c_ffullargs])[mc:fullarg_arg];
          !!var[mc:v_location]
        ]
      else
        false;

      | info |
      info = cdr(top[mc:c_fvalue]);

      | flags |
      flags = clf_compiled;
      if (top[mc:c_fnoescape])
        flags |= clf_noescape;
      if (top[mc:c_fclosure] == null)
        flags |= clf_noclosure;

      | linenos, var, subfns |
      linenos = dwarf_line_number_info(info[mc:a_linenos]);
      var     = if (top[mc:c_fvar]) top[mc:c_fvar][mc:v_name] else null;
      subfns  = lmap(fn (@[f ofs type]) vector(prelink(f), ofs, type),
                     info[mc:a_subfns]);

      set_cdr!(pfn_marker, indexed_sequence(
        pfn_code           . car(top[mc:c_fvalue]),
        pfn_help           . top[mc:c_fhelp],
        pfn_varname        . var,
        pfn_nicename       . top[mc:c_fnicename],
        pfn_loc            . top[mc:c_loc],
        pfn_subfns         . subfns,
        pfn_constants      . info[mc:a_constants],
        pfn_builtins       . info[mc:a_builtins],
        pfn_globals        . info[mc:a_globals],
        pfn_kglobals       . info[mc:a_kglobals],
        pfn_kglobal_code   . info[mc:a_kglobal_code],
        pfn_primitives     . info[mc:a_primitives],
        pfn_primops        . info[mc:a_primops],
        pfn_npcrel         . info[mc:a_npcrel],
        pfn_seclevs        . info[mc:a_seclevs],
        pfn_return_typeset . top[mc:c_freturn_typeset],
        pfn_return_itype   . top[mc:c_freturn_itype],
        pfn_linenos        . linenos,
        pfn_arguments      . arguments,
        pfn_vararg_alloc   . vararg_alloc?,
        pfn_flags          . flags,
        pfn_filename       . top[mc:c_ffilename]))
    ];


  // Dependency checking
  // -------------------

  // dependency types:
  depend_immutable = 1;		// or'ed into any other depend_xxx

  // depend_none = 0;		// no checks
  depend_primitive = 2;		// primitive: type, args, flags, and signature
  depend_type = 4;		// type
  depend_value = 6;		// variable with given value compared using
  				// equal?()
  depend_closure = 8;		// closure with argument and return types
  depend_vstatus = 10;          // depend on module_vstatus()

  | closure_arg_depends |
  closure_arg_depends = fn (c)
    [
      | val |
      val = function_arguments(c);
      protect(my:vmap(cdr, val))
    ];

  dependency = fn (v)
    // Types: v: global constant or var_system_xxx variable
    // Returns: dependency information for constant global v
    [
      | val, name, type, immutable_flag, vstat |

      // Currently, we extract the maximum possible dependencies.
      // However, the code generation could simply record in v what
      // assumptions it needs.

      name = v[mc:v_name];

      vstat = module_vstatus(v[mc:v_goffset]);
      if (vstat == var_system_mutable || vstat == var_system_write)
        exit<function> vector(name, depend_vstatus, vstat);

      val = global_value(v[mc:v_goffset]);
      type = typeof(val);

      immutable_flag = if (immutable?(val)) depend_immutable else 0;

      if (type == type_primitive || type == type_varargs
          || type == type_secure)
	vector(name, depend_primitive, type, primitive_nargs(val),
               primitive_flags(val) & ~COMPILER_SAFE_OP_FLAGS,
	       primitive_type(val))
      else if (type == type_closure)
        vector(name,
               depend_closure | immutable_flag,
               closure_return_typeset(val),
               closure_arg_depends(val),
               closure_flags(val))
      else if (type == type_integer || type == type_float)
	vector(name, depend_value, val)
      else // type dependency
	vector(name, depend_type | immutable_flag, type)
    ];

  check_dependency = fn (d, n)
    // Types: d: dependency, n: int (index of d[0])
    // Effects: checks that dependency d is still valid
    //   giving appropriate error messages
    [
      | name, val, dtype, check_cargs |

      // return true if 'dep' and 'current' closure arguments are
      // compatible
      check_cargs = fn ({null,vector} dep, {null,vector} current)
        [
          if (dep == null)
            exit<function> current == null;
          if (current == null)
            exit<function> false;

          | len |
          len = vlength(dep);
          if (len != vlength(current))
            exit<function> false;
          for (|i| i = 0; i < len; ++i)
            [
              if (dep[i] == null)
                [
                  if (current[i] != null)
                    exit<function> false;
                ]
              else if (current[i] == null)
                exit<function> false
              else if (~dep[i] & current[i])
                exit<function> false;
            ];
          true
        ];

      name = d[0];
      val = global_value(n);
      dtype = d[1] & ~depend_immutable;

      if ((d[1] & depend_immutable) && !immutable?(val))
	my:mc:error("%s is not immutable anymore", my:mc:markup_var(name))
      else if (dtype == depend_primitive)
	[
	  if (typeof(val) != d[2]
	      || primitive_nargs(val) != d[3]
	      || (d[4] & ~COMPILER_SAFE_OP_FLAGS & ~primitive_flags(val))
              || !equal?(d[5], primitive_type(val)))
	    my:mc:error("%s() has suffered an incompatible change",
                        my:mc:markup_fn(name));
	]
      else if (dtype == depend_closure)
	[
	  if (vlength(d) != 5
              || !closure?(val)
              || (~d[2] & closure_return_typeset(val))
              || !check_cargs(d[3], closure_arg_depends(val))
              || (d[4] & ~closure_flags(val)))
	    my:mc:error("%s() has suffered an incompatible change",
                        my:mc:markup_fn(name));
	]
      else if (dtype == depend_value)
	[
	  if (!equal?(val, d[2]))
	    my:mc:error("%s is not %w anymore", my:mc:markup_var(name), d[2]);
	]
      else if (dtype == depend_type)
	[
	  if (typeof(val) != d[2])
	    my:mc:error("the type of %s has changed (was %s, now %s)",
                        my:mc:markup_var(name),
                        my:mc:markup_type(type_names[d[2]]),
                        my:mc:markup_type(type_names[typeof(val)]));
	]
      else if (dtype == depend_vstatus)
        [
          | ovstat |
          ovstat = d[2];
          if (equal?(module_vstatus(n), ovstat))
            null
          else if (ovstat == var_system_write || ovstat == var_system_mutable)
            my:mc:error("%s is not a system variable anymore",
                        my:mc:markup_var(name))
          else
            fail()
        ]
      else
        fail()
    ];

  check_present = fn (string vname, int n, string mod)
    // Effects: Checks that vname (global n) belongs to mod
    // Returns: false if not
    [
      | vstatus |

      vstatus = module_vstatus(n);
      if (vstatus == var_system_write || vstatus == var_system_mutable)
        vstatus = "system";
      if (equal?(vstatus, mod))
        exit<function> true;
      my:mc:error("%s does not belong to %s anymore", my:mc:markup_var(vname),
                  mod);
      false
    ];

];
