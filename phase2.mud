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

library phase2 // Phase 2: 3-address (not really) generation
requires compiler, dihash, dlist, ins3, misc, sequences, vars
defines mc:phase2, mc:inline_builtin_call, mc:reset_closure_count
reads mc:this_module
writes mc:this_function
// See ins3.mud for details on these instructions

// temporaries are added to the local variables of each function
// there is no distinction between compiler-generated temps and user
// variables.

// A function is represented using the same structure as the tree structure,
// with the following change:
//   [mc:c_fvalue] contains the intermediate code
//   [mc:c_flocals] contains the extra local variables

// The result of phase2 is the converted top-level function. All other
// functions are reachable through the constant variables that contain
// them.

[

  | cundefined, ctrue, cfalse, czero, cone, closure_count, builtin_branch,
    builtin_call?, builtin_branch_not, comp_true, comp_false, kset, phase2,
    gen_clist, gen_partial_clist, gen_component, gen_if, gen_while,
    gen_condition, make_bf, builtin_functions, builtin_branches, make_bb,
    make_btype, gen_abs_comp, gen_cadr, gen_list, gen_vector,
    gen_set_mem!, klist,
    kplist, kvector, ksequence, gen_const, ins_typeset_trap, kerror, gen_error,
    gen_fail, gen_max_min, gen_scopy, gen_vref,
    kerror_message, gen_assert,
    gen_find, gen_find_branch, gen_builtin,
    fold_add,
    kvfind?, ksfind?, klfind?, kmemq,
    kbicmp, kfcmp, kstring_equal?, kstring_iequal?, kstring_cmp, kstring_icmp,
    ksconcat, var_global_read_trap? |

  kerror_message    = mc:make_kglobal("error_message");
  ksconcat          = mc:make_kglobal("sconcat");
  kerror            = mc:make_kglobal("error");
  kbicmp            = mc:make_kglobal("bicmp");
  kfcmp             = mc:make_kglobal("fcmp");
  klist             = mc:make_kglobal("list");
  kplist            = mc:make_kglobal("plist");
  ksequence         = mc:make_kglobal("sequence");
  kset              = mc:make_kglobal("set!");
  kstring_cmp       = mc:make_kglobal("string_cmp");
  kstring_equal?    = mc:make_kglobal("string_equal?");
  kstring_icmp      = mc:make_kglobal("string_icmp");
  kstring_iequal?   = mc:make_kglobal("string_iequal?");
  kvector           = mc:make_kglobal("vector");
  kvfind?           = mc:make_kglobal("vfind?");
  ksfind?           = mc:make_kglobal("sfind?");
  klfind?           = mc:make_kglobal("lfind?");
  kmemq             = mc:make_kglobal("memq");

  // Mapping of tree-operators to intermediate code branch operators
  builtin_branch = indexed_sequence(
    mc:b_eq          . mc:branch_eq,
    mc:b_ne          . mc:branch_ne,
    mc:b_lt          . mc:branch_lt,
    mc:b_ge          . mc:branch_ge,
    mc:b_le          . mc:branch_le,
    mc:b_gt          . mc:branch_gt,
    mc:b_bitand      . mc:branch_bitand,
    mc:b_logical_xor . mc:branch_xor,
    mc:b_assign      . null);
  assert(vlength(builtin_branch) == mc:parser_builtins);
  builtin_branch_not = indexed_sequence(
    mc:b_eq          . mc:branch_ne,
    mc:b_ne          . mc:branch_eq,
    mc:b_lt          . mc:branch_ge,
    mc:b_ge          . mc:branch_lt,
    mc:b_le          . mc:branch_gt,
    mc:b_gt          . mc:branch_le,
    mc:b_bitand      . mc:branch_nbitand,
    mc:b_logical_xor . mc:branch_xnor,
    mc:b_assign      . null);
  assert(vlength(builtin_branch_not) == mc:parser_builtins);

  | bf_nargs, bf_op, bf_notop, bf_partial |
  bf_nargs   = 0;
  bf_op      = 1;               // function or mc:branch_xxx
  bf_notop   = 2;               // null or mc:branch_xxx
  bf_partial = 3;               // true if takes partial_clist

  make_bf = fn (name, op, nargs, partial)
    global_lookup(name) . sequence(nargs, op, null, partial);

  gen_abs_comp = fn (fcode, result, func, @(arg))
    [
      | varg, vres, lab |
      varg = mc:var_make_local("%arg");
      vres = mc:var_make_local("%res");

      // %arg = 'arg'
      mc:ins_assign(fcode, varg, arg);
      // %res = -%arg
      mc:ins_compute(fcode, mc:b_negate, vres, list(varg));

      // unless %res >= 0: %res = %arg
      lab = mc:new_label();
      mc:ins_branch(fcode, mc:branch_ge, lab,
                    list(vres, mc:var_make_constant(0)));
      mc:ins_assign(fcode, vres, varg);
      mc:ins_label(fcode, lab);

      // 'result' = %res
      mc:ins_assign(fcode, result, vres);
      result
    ];

  gen_cadr = fn (second, first) fn (fcode, result, func, args)
    [
      | t |
      t = mc:new_local(fcode);
      mc:ins_compute(fcode, first, t, args);
      mc:ins_compute(fcode, second, result, list(t));
      result
    ];

  gen_list = fn (prot?) fn (fcode, result, func, args)
    [
      if (args == null)
        mc:ins_assign(fcode, result, mc:var_make_constant(null))
      else if (llength(args) < 4)
        [
          | prev |
          prev = mc:var_make_constant(null);
          args = lreverse(args);
          while (args != null)
            [
              | arg, dst |
              @(arg . args) = args;
              dst = if (args == null)
                result
              else
                mc:new_local(fcode);
              mc:ins_compute(fcode, if (prot?) mc:b_pcons else mc:b_cons,
                             dst, list(arg, prev));
              prev = dst
            ];
        ]
      else
        mc:ins_call(fcode, result, func . args);
      result
    ];

  gen_vector = fn (seq?) fn (fcode, result, func, args)
    [
      // slightly arbitrary cutoff
      if (llength(args) <= 8)
        mc:ins_compute(fcode,
                       if (seq?) mc:b_sequence else mc:b_vector,
                       result, args)
      else
        mc:ins_call(fcode, result, func . args);
      result
    ];

  gen_set_mem! = fn (offset, type) fn (fcode, result, func, @(dst idx))
    [
      mc:ins_trap(fcode, mc:trap_type, error_bad_type,
                  list(dst, mc:var_make_constant(type)));
      | val |
      val = mc:var_make_local("%tmp");
      mc:ins_assign(fcode, val, idx);
      mc:ins_memory(fcode, mc:memory_write_safe, dst, offset, val);
      mc:ins_assign(fcode, result, val);
    ];

  gen_const = fn (val) fn (fcode, result, func, @())
    mc:ins_assign(fcode, result, mc:var_make_constant(val));

  gen_scopy = fn (fcode, result, func, args)
    [
      mc:ins_compute(fcode, mc:b_add,
                     result, mc:var_make_constant("") . args);
    ];

  gen_fail = fn (fcode, result, func, args)
    mc:ins_trap(fcode, mc:trap_always, error_abort, null);

  | gen_fail_no_match |
  gen_fail_no_match = fn (fcode, result, func, args)
    mc:ins_trap(fcode, mc:trap_always, error_no_match, args);

  | gen_unreachable |
  gen_unreachable = fn (fcode)
    mc:ins_trap(fcode, mc:trap_always, error_abort, ctrue . null);

  // optional 'msg' decides between assert() and assert_message()
  gen_assert = fn (fcode, result, func, @(arg . (() || (msg))))
    [
      | slab, flab |
      slab = mc:new_label();
      flab = mc:new_label();

      if (msg != null)
        msg = gen_component(fcode, msg);

      gen_condition(
        fcode, list(arg), slab, false,
        flab, fn () [
          mc:ins_label(fcode, flab);
          if (msg == null)
            gen_fail(fcode, null, null, null)
          else
            [
              mc:ins_call(fcode, result,
                          list(kerror_message,
                               mc:var_make_constant(error_abort),
                               msg));
              gen_unreachable(fcode)
            ];
        ], false, false, false);
      mc:ins_label(fcode, slab);
      mc:ins_assign(fcode, result, cundefined);
    ];

  gen_error = fn (fcode, result, func, args)
    [
      | arg, val |
      @(arg) = args;
      if (arg[mc:v_class] == mc:v_constant)
        val = arg[mc:v_kvalue]
      else if (arg[mc:v_class] == mc:v_global_constant)
        val = global_value(arg[mc:v_goffset]);
      if (integer?(val) && val >= 0 && val < last_runtime_error)
        mc:ins_trap(fcode, mc:trap_always, val, null)
      else
        [
          mc:ins_call(fcode, result, kerror . args);
          gen_unreachable(fcode)
        ]
    ];

  gen_max_min = fn (max?) fn (fcode, result, func, @(a b))
    [
      | rvar, elab |
      rvar = mc:var_make_local("%tmp");
      // do not use mc:ins_assign() to not alias variables
      mc:ins_compute(fcode, mc:b_assign, rvar, list(b));
      elab = mc:new_label();
      mc:ins_branch(fcode, if (max?) mc:branch_gt else mc:branch_lt, elab,
                    list(rvar, a));
      mc:ins_compute(fcode, mc:b_assign, rvar, list(a));
      mc:ins_label(fcode, elab);
      mc:ins_assign(fcode, result, rvar);
    ];

  gen_vref = fn (idx) fn (fcode, result, func, @(arg))
    [
      mc:ins_trap(fcode, mc:trap_type, error_bad_type,
                  list(arg, mc:var_make_constant(type_vector)));
      mc:ins_compute(fcode, mc:b_ref, result,
                     list(arg, mc:var_make_constant(idx)));
    ];

  | type_makers, vmakers, lmakers |
  vmakers = '[,kvector ,ksequence];
  lmakers = '[,klist ,kplist];

  type_makers = fn (type)
    match! (type)
      [
        ,type_vector  => vmakers;
        ,stype_list   => lmakers;
        ,type_string  => '[]
      ];

  // needle and haystack are from gen_partial_clist()
  gen_find_branch = fn (fcode, type, slab, @(needle haystack))
    [
      | hclass, hvar, hfunc, maxlen, gen_vfind, orig_haystack |

      orig_haystack = haystack;

      gen_vfind = fn (slab, fcode, needle, haystack)
        [
          slab();
          vector(mc:branch_vfind?, mc:branch_vnfind?,
                 list(gen_component(fcode, needle),
                      gen_component(fcode, haystack)))
        ];

      hclass = haystack[mc:c_class];

      maxlen = 10;
      if (hclass == mc:c_execute
          && ((hfunc = last_element(car(haystack[mc:c_efnargs])))[mc:c_class]
              == mc:c_recall)
          && vfind?(hfunc[mc:c_rsymbol], type_makers(type)))
        haystack = vmap(fn (arg) gen_clist(fcode, arg),
                        list_to_vector(cdr(haystack[mc:c_efnargs])))
      else if (hclass == mc:c_recall
               && (hvar = haystack[mc:c_rsymbol])[mc:v_class] == mc:v_constant)
        [
          maxlen = 5;
          | hval |
          hval = hvar[mc:v_kvalue];
          haystack = match! (type)
            [
              ,type_vector => [
                if (!vector?(hval))
                  exit<function> false;
                hval
              ];
              ,type_string => [
                if (!string?(hval))
                  exit<function> false;
                vmapi!(fn (i, e) hval[i], make_vector(slength(hval)))
              ];
              ,stype_list => [
                if (!list?(hval))
                  exit<function> false;
                // make sure 'val' is a well-formed list
                match (last_pair(hval))
                  [
                    (_ . x) && x != null => exit<function> false;
                  ];
                list_to_vector(hval);
              ]
            ];
          haystack = vmap(mc:var_make_constant, haystack);
        ]
      else if (type == type_vector)
        exit<function> gen_vfind(slab, fcode, needle, orig_haystack)
      else
        exit<function> false;

      | len |
      len = if (string?(haystack)) slength(haystack) else vlength(haystack);
      if (len > maxlen)
        exit<function> if (type == type_vector)
          gen_vfind(slab, fcode, needle, orig_haystack)
        else
          false;

      needle = gen_component(fcode, needle);

      slab = slab();
      if (type == type_string)
        mc:ins_trap(fcode, mc:trap_type, error_bad_type,
                    list(needle, mc:var_make_constant(type_integer)));
      for (|i|i = 0; i < len - 1; ++i)
        mc:ins_branch(fcode, mc:branch_eq, slab, list(needle, haystack[i]));
      vector(mc:branch_eq, mc:branch_ne, list(needle, haystack[len - 1]));
    ];

  gen_find = fn (type) fn (fcode, result, func, args)
    [
      | slab |
      match! (gen_find_branch(fcode, type,
                              fn () [
                                mc:ins_assign(fcode, result, cfalse);
                                slab = mc:new_label();
                              ],
                              args))
        [
          [ _ bf bargs ] => [
            | dlab |
            dlab = mc:new_label();
            mc:ins_branch(fcode, bf, dlab, bargs);
            mc:ins_label(fcode, slab);
            mc:ins_assign(fcode, result, ctrue);
            mc:ins_label(fcode, dlab);
          ];
          ,false => [
            | f |
            f = match! (type)
              [
                ,type_vector => kvfind?;
                ,type_string => ksfind?;
                ,stype_list  => klfind?;
              ];
            | cargs |
            cargs = lmap(fn (arg) gen_component(fcode, arg), args);
            mc:ins_call(fcode, result, f . cargs)
          ]
        ]
    ];

  | gen_indexed_sequence |
  gen_indexed_sequence = fn (fcode, result, func, args)
    [
      // convert any cons(a, b) arguments into pcons(a, b) which lets
      // subsequent optimizations compile-time evaluate the call
      args = lmap(fn (c) [
        if (c[mc:c_class] == mc:c_builtin && c[mc:c_bfn] == mc:b_cons)
          c[mc:c_bfn] = mc:b_pcons;
        gen_component(fcode, c)
      ], args);
      mc:ins_call(fcode, result, func . args)
    ];

  | gen_noreturn |
  gen_noreturn = fn (fcode, result, func, args)
    [
      mc:ins_call(fcode, result, func . args);
      gen_unreachable(fcode);
    ];

  | make_builtins |
  make_builtins = fn (v...)
    [
      | di |
      di = vreduce(fn (@(gvar . e), di) [
        dihash_set!(di, gvar, e);
        di
      ], make_dihash(), v);
      // also link aliases
      table_foreach(fn (@<gname = gvar>) [
        | val, fname |
        val = global_value(gvar);
        if (function?(val)
            && (fname = function_name(val))
            && fname != gname
            && !string_equal?(gname, fname))
          [
            | altvar, e |
            altvar = global_lookup(fname);
            if (global_value(altvar) == val
                && (e = dihash_ref(di, altvar)) != null)
              dihash_set!(di, altvar, e);
          ];
      ], global_table());
      dihash_protect(di)
    ];

  builtin_functions = make_builtins(
    make_bf("car",            mc:b_car,                     1, false),
    make_bf("cdr",            mc:b_cdr,                     1, false),
    make_bf("caar",           gen_cadr(mc:b_car, mc:b_car), 1, false),
    make_bf("cadr",           gen_cadr(mc:b_car, mc:b_cdr), 1, false),
    make_bf("cdar",           gen_cadr(mc:b_cdr, mc:b_car), 1, false),
    make_bf("cddr",           gen_cadr(mc:b_cdr, mc:b_cdr), 1, false),
    make_bf("slength",        mc:b_slength,                 1, false),
    make_bf("vlength",        mc:b_vlength,                 1, false),
    make_bf("scopy",          gen_scopy,                    1, false),
    make_bf("bcopy",          gen_scopy,                    1, false),
    make_bf("typeof",         mc:b_typeof,                  1, false),
    make_bf("list",           gen_list(false),              -1, false),
    make_bf("plist",          gen_list(true),               -1, false),
    make_bf("vector",         gen_vector(false),            -1, false),
    make_bf("sequence",       gen_vector(true),             -1, false),
    make_bf("abs",            gen_abs_comp,                 1, false),
    make_bf("ffs",            mc:b_ffs,                     1, false),
    make_bf("set_car!",       gen_set_mem!(0, type_pair),   2, false),
    make_bf("set_cdr!",       gen_set_mem!(1, type_pair),   2, false),
    make_bf("symbol_name",    mc:b_symbol_name,             1, false),
    make_bf("symbol_get",     mc:b_symbol_get,              1, false),
    make_bf("symbol_set!",    gen_set_mem!(1, type_symbol), 2, false),
    make_bf("cons",           mc:b_cons,                    2, false),
    make_bf("pcons",          mc:b_pcons,                   2, false),
    make_bf("compiled?",      gen_const(true),              0, false),
    make_bf("loop_count",     mc:b_loop_count,              0, false),
    make_bf("max_loop_count", mc:b_max_loop_count,          0, false),
    make_bf("error",          gen_error,                    1, false),
    make_bf("fail",           gen_fail,                     0, false),
    make_bf("fail_no_match",  gen_fail_no_match,            1, false),
    make_bf("iadd",           mc:b_iadd,                    2, false),
    make_bf("min",            gen_max_min(false),           2, false),
    make_bf("max",            gen_max_min(true),            2, false),
    make_bf("dget",           gen_vref(0),                  1, false),
    make_bf("dnext",          gen_vref(1),                  1, false),
    make_bf("dprev",          gen_vref(2),                  1, false),
    make_bf("graph_node_get", gen_vref(5),                  1, false),
    make_bf("graph_node_graph", gen_vref(2),                1, false),
    make_bf("graph_edge_from", gen_vref(0),                 1, false),
    make_bf("graph_edge_to",  gen_vref(1),                  1, false),
    make_bf("graph_edge_get", gen_vref(2),                  1, false),
    make_bf("sfind?",         gen_find(type_string),        2, true),
    make_bf("vfind?",         gen_find(type_vector),        2, true),
    make_bf("lfind?",         gen_find(stype_list),         2, true),
    make_bf("indexed_sequence", gen_indexed_sequence,      -1, true),
    make_bf("indexed_vector", gen_indexed_sequence,        -1, true),
    make_bf("error_message",  gen_noreturn,                 2, false),
    make_bf("fail_message",   gen_noreturn,                 1, false),
    make_bf("longjmp",        gen_noreturn,                 2, false),
    make_bf("rethrow_error",  gen_noreturn,                 0, false),
    make_bf("assert_message", gen_assert,                   2, true),
    make_bf("assert",         gen_assert,                   1, true));

  make_bb = fn (name, op, notop, nargs)
    global_lookup(name) . sequence(nargs, op, notop, false);

  make_btype = fn (name, type)
    make_bb(name, mc:branch_type? + type, mc:branch_ntype? + type, 1);

  assert(mudlle_synthetic_types == 34); // consider adding new types below

  builtin_branches = make_builtins(
    make_btype("bigint?",       type_bigint),
    make_btype("bigint_like?",  stype_bigint_like),
    make_btype("closure?",      type_closure),
    make_btype("file?",         type_file),
    make_btype("float?",        type_float),
    make_btype("float_like?",   stype_float_like),
    make_btype("function?",     stype_function),
    make_btype("integer?",      type_integer),
    make_btype("list?",         stype_list),
    make_btype("null?",         type_null),
    make_btype("pair?",         type_pair),
    make_btype("primitive?",    type_primitive),
    make_btype("secure?",       type_secure),
    make_btype("string?",       type_string),
    make_btype("symbol?",       type_symbol),
    make_btype("table?",        type_table),
    make_btype("varargs?",      type_varargs),
    make_btype("vector?",       type_vector),

    make_btype("character?",    type_character),
    make_btype("connection?",   type_connection),
    make_btype("gone?",         type_gone),
    make_btype("object?",       type_object),
    make_btype("magic_cookie?", type_cookie),
    make_btype("port?",         type_oport),
    make_btype("regexp?",       type_regexp),

    make_bb("immutable?",     mc:branch_immutable, mc:branch_mutable,  1),
    make_bb("readonly?",      mc:branch_readonly,  mc:branch_writable, 1),
    make_bb("any_primitive?", mc:branch_any_prim,  mc:branch_not_prim, 1),

    make_bb("equal?",         mc:branch_equal,     mc:branch_nequal,   2),

    make_bb("bit_set?",       mc:branch_bitset,    mc:branch_bitclear, 2),
    make_bb("bit_clear?",     mc:branch_bitclear,  mc:branch_bitset,   2));

  builtin_call? = fn (function, args, builtins)
    [
      | fc |
      fc = function[mc:v_class];
      if (fc == mc:v_global_define)
        [
          | g, gs |
          g = function[mc:v_goffset];
          gs = module_vstatus(g);
          if (string?(gs) && module_status(gs) == module_protected)
            function = mc:var_make_kglobal(global_name(g), g)
          else
            exit<function> false;
        ]
      else if (fc != mc:v_global_constant)
        exit<function> false;

      | bf |
      bf = dihash_ref(builtins, function[mc:v_goffset]);
      if (bf != null && (bf[bf_nargs] < 0 || bf[bf_nargs] == llength(args)))
	bf
      else
	false
    ];

  var_global_read_trap? = fn (var)
    [
      | vstat |
      (var[mc:v_class] == mc:v_global
       && ((vstat = module_vstatus(var[mc:v_goffset])) != var_system_write)
       && vstat != var_system_mutable)
    ];

  closure_count = 0;
  mc:reset_closure_count = fn () closure_count = 0;

  // gniark, gniark, guess the values
  cundefined = mc:var_make_constant(42);
  ctrue = cone = mc:var_make_constant(true);
  comp_true = sequence(mc:c_recall, mc:no_loc, ctrue);
  cfalse = czero = mc:var_make_constant(false);
  comp_false = sequence(mc:c_recall, mc:no_loc, cfalse);

  mc:phase2 = fn (mod)
    mod[mc:m_body] = phase2(mod[mc:m_body]);

  mc:inline_builtin_call = fn (il)
    [
      | ins, args, result, function, bf |

      ins = il[mc:il_ins];
      assert(ins[mc:i_class] == mc:i_call);
      @(function . args) = ins[mc:i_cargs];
      result = ins[mc:i_cdest];

      if ((bf = builtin_call?(function, args, builtin_functions))
          && !function?(bf[bf_op]))
        il[mc:il_ins] = mc:make_compute_ins(bf[bf_op], result, args);
    ];

  ins_typeset_trap = fn (topf, arg, int argnum, vector loc,
                         int typeset, return?)
    [
      // common case
      if (typeset == typeset_any)
        exit<function> null;

      assert((typeset & ~(typeset_any | typeset_false)) == 0);
      if (return?)
        typeset |= mc:typeset_flag_return;
      mc:set_loc(loc);
      mc:ins_trap(topf,
                  mc:trap_typeset,
                  error_bad_type,
                  list(arg,
                       mc:var_make_constant(typeset),
                       mc:var_make_constant(argnum)));
    ];

  | clist_trivial_read? |
  clist_trivial_read? = fn (cl)
    match (cl)
      [
        (c) && c[mc:c_class] == mc:c_recall
          => !var_global_read_trap?(c[mc:c_rsymbol]);
      ];

  phase2 = fn (top)
    // Returns: intermediate rep of function top
    [
      | clist, topf, result, oloc |

      oloc = mc:get_loc();

      mc:this_function = top;
      clist = top[mc:c_fvalue];
      topf = mc:new_fncode(top);

      mc:set_loc(top[mc:c_loc]);

      for (|fargs, argn| [ fargs = top[mc:c_ffullargs]; argn = 0 ];
           fargs != null;
           ++argn)
        [
          | farg, var, typeset, loc, next_lab |
          @(farg . fargs) = fargs;
          @[var typeset loc] = farg[mc:fullarg_arg];

          if (typeset == null)
            exit<continue> null; // vararg argument

          mc:set_loc(loc);
          if (typeset & typeset_flag_optional)
            [
              | provided_lab, trivial? |
              trivial? = clist_trivial_read?(farg[mc:fullarg_default_val]);

              next_lab = mc:new_label();
              if (!trivial?)
                [
                  provided_lab = mc:new_label();
                  mc:ins_branch(topf, mc:branch_gt, provided_lab,
                                list(top[mc:c_fnargs_var][mc:vl_var],
                                     mc:var_make_constant(argn)));
                ];
              mc:ins_assign(topf, var,
                            gen_clist(topf, farg[mc:fullarg_default_val]));
              if (!trivial?)
                [
                  mc:ins_branch(topf, mc:branch_always, next_lab, null);
                  mc:ins_label(topf, provided_lab);
                ]
              else
                mc:ins_branch(topf, mc:branch_le, next_lab,
                              list(top[mc:c_fnargs_var][mc:vl_var],
                                   mc:var_make_constant(argn)));
              typeset &= ~typeset_flag_optional;
              mc:ins_compute(topf, mc:b_funcarg, var,
                             list(mc:var_make_constant(argn)));
            ];
          ins_typeset_trap(topf, var, argn, loc, typeset, false);
          if (next_lab != null)
            mc:ins_label(topf, next_lab);
          if (farg[mc:fullarg_pat_expr] != null)
            gen_clist(topf, farg[mc:fullarg_pat_expr]);
	];

      // compute expression
      result = gen_clist(topf, clist);

      // return result
      ins_typeset_trap(topf, result, -1, top[mc:c_fendloc],
                       top[mc:c_freturn_typeset], true);
      mc:set_loc(top[mc:c_fendloc]);
      mc:ins_return(topf, result);

      top[mc:c_fvalue] =
	mc:remove_var_aliases(mc:remove_labels(mc:remove_aliases(
          mc:remove_branches(mc:get_instructions(topf)))));
      top[mc:c_fnumber] = ++closure_count;

      mc:this_function = null;

      mc:set_loc(oloc);

      top
    ];

  // Generate code for all but last expression, and return the last component
  gen_partial_clist = fn (fcode, clist)
    loop
      [
        | c |
        @(c . clist) = clist;
        if (clist == null)
          exit c;
        gen_component(fcode, c);
      ];

  gen_clist = fn (fcode, clist)
    // Types: fcode : fncode, clist : list of component
    // Requires: clist not be empty
    // Effects: Generates 3-address code to evaluate clist in fcode
    // Returns: The variable that contains the expression's value
    gen_component(fcode, gen_partial_clist(fcode, clist));

  gen_builtin = fn (fcode, op, args)
    [
      | result |
      result = mc:new_local(fcode);
      mc:ins_compute(fcode, op, result, args);
      result
    ];

  // constant-fold (nested) addition of args (must be a list of two
  // elements); if partial?, the top-level add will never be folded
  fold_add = fn (fcode, args, partial?)
    [
      | terms, recurse, oline, add_ils, add_leaves, add_type |

      // terms contains terms to be added; one of
      //   null
      //   arg1 . null
      //   arg2 . (loc . arg1)

      // updates terms with the remaining terms to be added
      recurse = fn (args, partial?, loc)
        lforeach(fn (argl) [
          | arg |
          arg = gen_partial_clist(fcode, argl);

          if (arg[mc:c_class] == mc:c_builtin
              && arg[mc:c_bfn] == mc:b_add)
            exit<function> recurse(arg[mc:c_bargs], false, arg[mc:c_loc]);

          | r |
          r = gen_component(fcode, arg);
          if (add_type == null)
            [
              | val |
              val = mc:var_value(r);
              if (val != null)
                add_type = if (!string?(val)) ?i else ?s;
            ];

          if (terms != null)
            [
              // check if r can be constant folded with the most recent
              // term
              if (!(partial? && cdr(terms) == null)
                  && r[mc:v_class] == mc:v_constant)
                [
                  | r2, v |
                  v = r[mc:v_kvalue];
                  r2 = car(terms);
                  if (r2[mc:v_class] == mc:v_constant)
                    [
                      | v2 |
                      v2 = r2[mc:v_kvalue];
                      if (integer?(v) && integer?(v2)
                          || string?(v) && string?(v2))
                        [
                          | sum |
                          sum = mc:var_make_constant(protect(v2 + v));
                          add_leaves = sum . cdr(add_leaves);
                          exit<function> set_car!(terms, sum);
                        ]
                    ]
                ];

              | nterm |
              match! (terms)
                [
                  (t1) => nterm = t1;
                  (t2 . (tloc . t1)) => [
                    // There were already two terms in the list; add
                    // them together now
                    mc:maybe_set_loc(tloc);
                    nterm = gen_builtin(fcode, mc:b_add, list(t1, t2));
                    add_ils = dprev(fcode[0]) . add_ils;
                  ];
                ];

              terms = loc . nterm;
            ];
          terms = r . terms;
          add_leaves = r . add_leaves;
        ], args);

      oline = mc:get_loc();
      recurse(args, partial?, mc:get_loc());
      mc:set_loc(oline);

      | result |
      if (cdr(terms) == null)
        result = car(terms)
      else
        [
          mc:maybe_set_loc(cadr(terms));
          result = gen_builtin(fcode, mc:b_add, list(cddr(terms), car(terms)));
          add_ils = dprev(fcode[0]) . add_ils;
          mc:set_loc(oline);
        ];

      if (add_type != ?i && llength(add_leaves) > 2)
        [
          add_leaves = lreverse!(add_leaves);
          if (add_type == ?s)
            [
              // replace multiple string adds with one call to sconcat()
              lforeach(fn (n) [
                | il, ins |
                il = dget(n);
                ins = il[mc:il_ins];
                assert(ins[mc:i_class] == mc:i_compute
                       && ins[mc:i_aop] == mc:b_add);
                mc:make_il_nop(il);
              ], add_ils);
              result = mc:new_local(fcode);
              mc:ins_call(fcode, result, ksconcat . add_leaves)
            ]
          else
            mc:ins_maybe_sconcat(fcode, result, add_leaves,
                                 lmap!(dget, add_ils));
        ];

      result
    ];

  gen_component = fn (fcode, c)
    // Types: fcode : fncode, c : component
    // Effects: Generates 3-address code to evaluate c in fcode
    // Returns: The variable that contains the expression's value
    [
      | class, prevloc, component_result |

      prevloc = mc:get_loc();
      mc:maybe_set_loc(c[mc:c_loc]);

      class = c[mc:c_class];

      component_result = if (class == mc:c_assign)
	<done> [
	  | var, val, vclass |
          val = gen_clist(fcode, c[mc:c_avalue]);
	  var = c[mc:c_asymbol];
          vclass = var[mc:v_class];

          if (val == var)
            mc:warning("assigning %s to itself",
                       mc:markup_var(var[mc:v_name]));

          if (vclass == mc:v_static)
            [
              var = var[mc:v_sparent];
              mc:ins_memory(fcode, mc:memory_write_safe, var, 1, val);
              exit<done> val
            ];

	  // check global writes (except top-level defines and system-mutable)
          if (vclass == mc:v_global
              && module_vstatus(var[mc:v_goffset]) != var_system_mutable
              && !lexists?(fn (v) v[mc:mv_gidx] == var[mc:v_goffset],
                           mc:this_module[mc:m_defines]))
            [
              // use named local to prevent the global aliasing the temporary
              | tvar |
              tvar = mc:var_make_local("%tmp");
              mc:ins_assign(fcode, tvar, val);
              mc:ins_trap(fcode, mc:trap_global_write, 0, list(var, tvar));
              val = tvar
            ];

	  mc:ins_assign(fcode, var, val);
	  var
	]
      else if (class == mc:c_recall)
        [
	  | var |
	  var = c[mc:c_rsymbol];

          if (var[mc:v_class] == mc:v_static)
            [
              | dvar |
              dvar = mc:new_local(fcode);
              mc:ins_memory(fcode, mc:memory_read, var[mc:v_sparent], 1, dvar);
              var = dvar
            ]
	  else if (var_global_read_trap?(var))
	    mc:ins_trap(fcode, mc:trap_global_read, 0, list(var));

	  var
        ]
      else if (class == mc:c_closure)
	[
	  | closure, f |
	  closure = mc:new_local(fcode);
	  f = mc:this_function;
	  mc:ins_closure(fcode, closure, phase2(c));
	  mc:this_function = f;
	  closure
	]
      else if (class == mc:c_execute)
	<done> [
	  | args, result, function, bf, fval |

	  result = mc:new_local(fcode);
          @(function . args) = c[mc:c_efnargs];
          function = gen_clist(fcode, function);

          | partial? |
	  bf = builtin_call?(function, args, builtin_functions);
          partial? = bf && bf[bf_partial];

          // fold string concatenations for calls to OP_STR_READONLY primitives
          if (function[mc:v_class] == mc:v_global_constant
              && any_primitive?(fval = global_value(function[mc:v_goffset]))
              && ((primitive_flags(fval) & OP_STR_READONLY)))
            [
              assert(!partial?); // not supported yet
              lmap!(fn (argl) [
                | arg |
                arg = gen_partial_clist(fcode, argl);
                if (arg[mc:c_class] == mc:c_builtin
                    && arg[mc:c_bfn] == mc:b_add)
                  fold_add(fcode, arg[mc:c_bargs], false)
                else
                  gen_component(fcode, arg);
              ], args)
            ]
          else
            [
              lmap!(fn (arg) gen_partial_clist(fcode, arg), args);
              if (!partial?)
                lmap!(fn (arg) gen_component(fcode, arg), args);
            ];

	  // Check for builtin functions
	  if (bf)
            [
              | op |
              op = bf[bf_op];
              if (function?(op))
                op(fcode, result, function, args)
              else
                mc:ins_compute(fcode, op, result, args)
            ]
	  else if ((bf = builtin_call?(function, args, builtin_branches))
                   && bf[bf_op] != mc:branch_equal) // equal?() is better as-is
            [
              | cond, loc |
              loc = mc:get_loc();
              cond = list(vector(
                mc:c_execute, loc,
                lmap(fn (v) list(vector(mc:c_recall, loc, v)),
                     function . args)));
              result = gen_if(fcode, cond, false, false)
            ]
          else
	    mc:ins_call(fcode, result, function . args);
	  result
	]
      else if (class == mc:c_labeled)
	[
	  mc:start_block(fcode, c[mc:c_lname]);
	  mc:end_block(fcode, gen_clist(fcode, c[mc:c_lexpression]))
	]
      else if (class == mc:c_exit)
	[
	  if (!mc:exit_block(fcode, c[mc:c_ename],
                             gen_clist(fcode, c[mc:c_eexpression])))
	    if (c[mc:c_ename] == null) mc:error("no loop to exit from")
	    else mc:error("no block labeled %s", c[mc:c_ename]);
	  cundefined // but an exit never returns ...
	]
      else if (class == mc:c_builtin)
	[
	  | op, args |
	  op = c[mc:c_bfn];
	  args = c[mc:c_bargs];
	  if (op == mc:b_if)
	    [
              mc:maybe_set_loc(caar(args)[mc:c_loc]);
	      gen_if(fcode, car(args), cadr(args), false);
	      cundefined
	    ]
	  else if (op == mc:b_ifelse)
            [
              mc:maybe_set_loc(caar(args)[mc:c_loc]);
              gen_if(fcode, car(args), cadr(args), caddr(args))
            ]
	  else if (op == mc:b_logical_and || op == mc:b_logical_or
                   || op == mc:b_logical_not)
	    gen_if(fcode, c . null, false, false)
	  else if (op == mc:b_while)
            gen_while(fcode, car(args), cadr(args))
	  else if (op == mc:b_loop)
	    [
	      | looplab |

	      looplab = mc:new_label();
	      mc:ins_label(fcode, looplab);
	      mc:start_block(fcode, null);
	      gen_clist(fcode, car(args));
	      mc:ins_trap(fcode, mc:trap_loop, error_loop, null);
	      mc:ins_branch(fcode, mc:branch_always, looplab, null);
	      mc:end_block(fcode, false)
	    ]
	  else if (op == mc:b_set) // op with side effects
	    [
	      | result, vargs |
	      result = mc:new_local(fcode);
	      vargs = lmap(fn (arg) gen_clist(fcode, arg), args);
	      mc:ins_call(fcode, result, kset . vargs);
	      result
	    ]
	  else if (op == mc:b_add)
            fold_add(fcode, args, true)
          else
            [
              | vargs |
              vargs = lmap(fn (arg) gen_clist(fcode, arg), args);
              gen_builtin(fcode, op, vargs)
	    ]
	]
      else fail();

      mc:set_loc(prevloc);
      component_result
    ];

  gen_if = fn (fcode, condition, success, failure)
    // Types: fcode : fncode
    //        condition, success, failure : list of component or 'false'
    //        If both are 'false', return true/false result
    // Effects: generates code for 'if (condition) success else failure'
    // Returns: The variable that contains the if's result
    //   (if unless one of success or failure is false)
    [
      | slab, flab, endlab, result, boolean |

      slab = mc:new_label();
      flab = mc:new_label();
      endlab = mc:new_label();

      boolean = false;
      if (!success && !failure)
        [
          boolean = fn (r)
            [
              mc:ins_assign(fcode, result, r);
              mc:ins_branch(fcode, mc:branch_always, endlab, null);
            ];
          success = list(comp_true);
          failure = list(comp_false);
        ];

      | trivial |
      trivial = false;
      if (success && failure)
        [
          | inverse? |
          inverse? = false;
          if (clist_trivial_read?(success)
              || (inverse? = clist_trivial_read?(failure)))
            trivial = fn (bsuccess, bfailure, bargs)
              [
                | rvar, lab, rval |
                rvar = mc:var_make_local("%tmp");
                rval = gen_clist(fcode, if (inverse?) failure else success);

                // do not use mc:ins_assign() to not alias variables
                mc:ins_compute(fcode, mc:b_assign, rvar, list(rval));

                // use 'rval' if possible; this helps register allocation
                bargs = lmap(fn (v) if (v == rval) rvar else v, bargs);

                lab = mc:new_label();
                mc:ins_branch(
                  fcode, if (inverse?) bfailure else bsuccess, lab, bargs);
                mc:ins_compute(
                  fcode, mc:b_assign, rvar,
                  list(gen_clist(fcode, if (inverse?) success else failure)));
                mc:ins_label(fcode, lab);
                mc:ins_assign(fcode, result, rvar);
              ];
          result = mc:new_local(fcode);
        ];

      | successf, failuref |

      successf = fn ()
        [
          mc:ins_label(fcode, slab);
          if (success)
            [
              | sresult |
              sresult = gen_clist(fcode, success);
              if (failure) // if not an 'ifelse' result is discarded
                mc:ins_assign(fcode, result, sresult)
            ];
          mc:ins_branch(fcode, mc:branch_always, endlab, null);
        ];

      failuref = fn ()
        [
          mc:ins_label(fcode, flab);
          if (failure)
            [
              | fresult |
              fresult = gen_clist(fcode, failure);
              if (success) // if not an 'ifelse' result is discarded
                mc:ins_assign(fcode, result, fresult)
            ];
          mc:ins_branch(fcode, mc:branch_always, endlab, null);
        ];

      gen_condition(fcode, condition, slab, successf, flab, failuref, boolean,
                    trivial, false);
      mc:ins_label(fcode, endlab);
      result
    ];

  gen_while = fn (fcode, condition, iteration)
    // Types: fcode : fncode
    //	      condition, iteration : list of component
    // Effects: Generates code for 'while (condition) iteration'
    [
      | looplab, mainlab, exitlab, endlab |
      looplab = mc:new_label();
      mainlab = mc:new_label();
      exitlab = mc:new_label();
      endlab = mc:new_label();

      mc:start_block(fcode, null);
      mc:ins_label(fcode, looplab);
      gen_condition(fcode, condition,
		    mainlab, fn () [
		      mc:ins_label(fcode, mainlab);
		      gen_clist(fcode, iteration);
		      mc:ins_trap(fcode, mc:trap_loop, error_loop, null);
		      mc:ins_branch(fcode, mc:branch_always, looplab, null);
		    ],
		    exitlab, fn () [
		      mc:ins_label(fcode, exitlab);
		      mc:ins_branch(fcode, mc:branch_always, endlab, null);
		    ], false, false, false);
      mc:ins_label(fcode, endlab);
      mc:end_block(fcode, cundefined)
    ];

  gen_condition = fn (fcode, condition, slab, success, flab, failure, boolean,
                      trivial, inverse?)
    // Types: fcode : fncode
    //        condition : list of component
    //        slab, flab : label
    //        success, failure : 0-argument functions or false
    // Effects: generates code to evaluate condition and branch to
    //   slab (respectively flab) on success (failure).
    //   success() and failure() are called to generate the actual code
    //   for theses cases.
    //   If boolean is a function f, call f(var) where var contains the
    //   (possibly inverted) boolean result instead.
    //   If trivial is a function f, call f(var) instead of the above
    //   for simple, single-branch conditionals.
    //   inverse? tracks whether success/failure have been inverted
    //   along the way.
    [
      | class, bargs, branch_succeed, branch_fail, prevloc, bool_result |

      bool_result = fn (var)
        [
          boolean(var);
          if (success) success();
          if (failure) failure();
          mc:set_loc(prevloc);
        ];

      condition = gen_partial_clist(fcode, condition);

      prevloc = mc:get_loc();
      mc:maybe_set_loc(condition[mc:c_loc]);

      class = condition[mc:c_class];
      if (class == mc:c_builtin)
	[
	  | op, args |
	  op = condition[mc:c_bfn];
	  args = condition[mc:c_bargs];
	  if (op == mc:b_logical_and)
	    [
	      // Tricky ...
	      | label |
	      label = mc:new_label();
	      gen_condition(
                fcode, car(args), label,
                fn () [
                  mc:ins_label(fcode, label);
                  gen_condition(fcode, cadr(args), slab, success,
                                flab, failure, boolean, false, inverse?);
                ], flab, false, false, false, false);
              mc:set_loc(prevloc);
	      exit<function> null;
	    ]
	  else if (op == mc:b_logical_or)
	    [
	      // Tricky ...
	      | label |
	      label = mc:new_label();
	      gen_condition(
                fcode, car(args),
                slab, false,
                label, fn () [
                  mc:ins_label(fcode, label);
                  gen_condition(fcode, cadr(args), slab, success,
                                flab, failure, boolean, false, inverse?);
                ], false, false, false);
              mc:set_loc(prevloc);
	      exit<function> null;
	    ]
	  else if (op == mc:b_logical_not)
	    [
	      // Swap conclusions
	      gen_condition(fcode, car(args), flab, failure,
                            slab, success, boolean, trivial, !inverse?);
              mc:set_loc(prevloc);
	      exit<function> null;
	    ]
	  else if (builtin_branch[op] != null)
	    [
              | cst_val |

              // return constant or null
              cst_val = fn (c)
                match (c[mc:c_class])
                  [
                    ,mc:c_recall => mc:var_value(c[mc:c_rsymbol]);
                    ,mc:c_constant => c[mc:c_cvalue];
                    _ => null;
                  ];

	      // Generate specialised branch for certain operators
	      // (eg <, <=, ...)
              args = lmap(fn (arg) gen_partial_clist(fcode, arg), args);

              <normal> if (op == mc:b_eq || op == mc:b_ne)
                [
                  | arg1, arg2 |
                  @(arg1 arg2) = args;
                  if (cst_val(arg2) == false)
                    null
                  else if (cst_val(arg1) == false)
                    arg1 = arg2
                  else
                    exit<normal> null;

                  args = list(arg1);
                  if (op == mc:b_eq)
                    gen_condition(fcode, args, flab, failure, slab, success,
                                  boolean, trivial, !inverse?)
                  else
                    gen_condition(fcode, args, slab, success, flab, failure,
                                  boolean, trivial, inverse?);
                  mc:set_loc(prevloc);
                  exit<function> null;
                ]
              else if (op == mc:b_bitand)
                [
                  | arg1, arg2, cst, carg |
                  @(arg1 arg2) = args;
                  if (integer?(cst = cst_val(carg = arg1)))
                    arg1 = arg2
                  else if (integer?(cst = cst_val(carg = arg2)))
                    null
                  else
                    exit<normal> null;

                  if (cst && (cst & (cst - 1)) == 0)
                    [
                      // if cst has one bit only, check for ~arg2 & cst
                      | not? |
                      not? = (arg1[mc:c_class] == mc:c_builtin
                              && arg1[mc:c_bfn] == mc:b_bitnot);
                      if (not?)
                        [
                          @(arg1) = arg1[mc:c_bargs];
                          arg1 = gen_partial_clist(fcode, arg1);
                          inverse? = !inverse?;
                        ];

                      if (boolean)
                        [
                          | r, bit |
                          arg1 = gen_component(fcode, arg1);
                          r = mc:new_local(fcode);
                          bit = ffs(cst) - 1;
                          mc:ins_compute(
                            fcode, mc:b_shift_right, r,
                            list(arg1, mc:var_make_constant(bit)));
                          mc:ins_compute(fcode, mc:b_bitand, r,
                                         list(r, cone));
                          if (inverse?)
                            mc:ins_compute(fcode, mc:b_bitxor,
                                           r, list(r, cone));
                          exit<function> bool_result(r);
                        ];

                      if (not?)
                        [
                          condition[mc:c_bargs] = list(list(arg1), list(carg));
                          gen_condition(
                            fcode, list(condition), flab, failure,
                            slab, success, boolean, trivial, inverse?);
                          mc:set_loc(prevloc);
                          exit<function> null;
                        ]
                    ];
                ];

              bargs = lmap(fn (arg) gen_component(fcode, arg), args);
              if (boolean && op != mc:b_bitand && op != mc:b_logical_xor)
                [
                  assert(op >= mc:b_eq && op <= mc:b_gt);
                  | r |
                  r = mc:new_local(fcode);
                  if (inverse?)
                    op ^= 1;    // invert logic
                  mc:ins_compute(fcode, op, r, bargs);
                  exit<function> bool_result(r);
                ]
              else
                [
                  branch_fail = builtin_branch_not[op];
                  branch_succeed = builtin_branch[op];
                ];
	    ]
	  else
	    [
	      // default code
	      bargs = gen_component(fcode, condition) . null;
	      branch_fail = mc:branch_false;
	      branch_succeed = mc:branch_true;
	    ]
	]
      else if (class == mc:c_execute)
	[
	  | function, bf |

          @(function . bargs) = lmap(fn (arg) gen_partial_clist(fcode, arg),
                                     condition[mc:c_efnargs]);
          function = gen_component(fcode, function);

	  // Check for builtin functions
	  bf = builtin_call?(function, bargs, builtin_branches);
	  if (bf)
	    [
              assert(!bf[bf_partial]); // not supported yet
              bargs = lmap!(fn (arg) gen_component(fcode, arg), bargs);

	      branch_succeed = bf[bf_op];
	      branch_fail = bf[bf_notop];

              if (branch_succeed == mc:branch_equal)
                <done> [
                  | arg1, arg2, val, ok?, type |
                  ok? = fn (v) (string?(v) || float?(v) || bigint?(v)
                                || equal?(v, '[]));
                  @(arg1 arg2) = bargs;
                  if (ok?(val = mc:var_value(arg2)))
                    null
                  else if (ok?(val = mc:var_value(arg1)))
                    [
                      | t |
                      t = arg1;
                      arg1 = arg2;
                      arg2 = t;
                    ]
                  else
                    exit<done> null;

                  type = typeof(val);

                  // arg1 is variable, arg2 is the constant 'val'
                  if (type == type_vector)
                    [
                      // val must be the empty vector
                      branch_succeed = mc:branch_vlength;
                      branch_fail = (mc:branch_vlength
                                     + mc:branch_ne - mc:branch_eq);
                    ]
                  else if (type == type_string)
                    [
                      branch_succeed = mc:branch_slength;
                      branch_fail = (mc:branch_slength
                                     + mc:branch_ne - mc:branch_eq);
                    ];

                  trivial = false; // suppress trivial single-branch mode
                  mc:ins_branch(fcode, mc:branch_ntype? + type, flab,
                                list(arg1));
                  if (type == type_string && slength(val) > 0)
                    [
                      | res |
                      res = mc:new_local(fcode);
                      mc:ins_call(fcode, res,
                                  list(kstring_equal?, arg1, arg2));
                      bargs = list(res);
                      branch_succeed = mc:branch_true;
                      branch_fail = mc:branch_false;
                    ]
                  else if (type == type_float || type == type_bigint)
                    [
                      | res, cmp |
                      res = mc:new_local(fcode);
                      cmp = if (type == type_float) kfcmp else kbicmp;
                      mc:ins_call(fcode, res,
                                  list(cmp, arg1, arg2));
                      bargs = list(res);
                      branch_succeed = mc:branch_false;
                      branch_fail = mc:branch_true;
                    ]
                  else
                    bargs = list(arg1, czero);
                ]
	    ]
	  else
	    <done> [
	      | result, swap? |

              swap? = false;
	      result = mc:new_local(fcode);

              // equivalent for the sake of branch-inlining
              if (function == kmemq)
                function = klfind?;

              bf = builtin_call?(function, bargs, builtin_functions);
              if (!(bf && bf[bf_partial]))
                bargs = lmap!(fn (arg) gen_component(fcode, arg), bargs);

	      if (bf)
                [
                  if (bf[bf_partial])
                    [
                      | t |
                      t = match! (function)
                        [
                          ,kvfind? => type_vector;
                          ,ksfind? => type_string;
                          ,klfind? => stype_list;
                        ];
                      match! (gen_find_branch(fcode, t, fn() slab, bargs))
                        [
                          [ bsucc bfail args ] => [
                            trivial = false;
                            branch_succeed = bsucc;
                            branch_fail = bfail;
                            bargs = args;
                            exit<done> true;
                          ];
                          ,false => null;
                        ];
                    ];

                  | op |
                  op = bf[bf_op];
                  if (function?(op))
                    op(fcode, result, function, bargs)
                  else if (op == mc:b_slength || op == mc:b_vlength)
                    [
                      if (op == mc:b_slength)
                        [
                          branch_fail = mc:branch_slength; // eq
                          branch_succeed = (mc:branch_slength
                                            + mc:branch_ne - mc:branch_eq);
                        ]
                      else
                        [
                          branch_fail = mc:branch_vlength; // eq
                          branch_succeed = (mc:branch_vlength
                                            + mc:branch_ne - mc:branch_eq);
                        ];
                      bargs = list(car(bargs), czero);
                      exit<done> null;
                    ]
                  else
                    mc:ins_compute(fcode, op, result, bargs)
                ]
	      else
                [
                  if (function == kstring_cmp)
                    [
                      swap? = true;
                      function = kstring_equal?;
                    ]
                  else if (function == kstring_icmp)
                    [
                      swap? = true;
                      function = kstring_iequal?;
                    ];

                  mc:ins_call(fcode, result, function . bargs);
                ];
	      bargs = result . null;
              if (swap?)
                [
                  branch_fail = mc:branch_true;
                  branch_succeed = mc:branch_false;
                ]
              else
                [
                  branch_fail = mc:branch_false;
                  branch_succeed = mc:branch_true;
                ]
            ];
	]
      else
	[
	  // default code, again
	  bargs = gen_component(fcode, condition) . null;
	  branch_fail = mc:branch_false;
	  branch_succeed = mc:branch_true;
	];

      if (boolean
          && ((branch_fail == mc:branch_false
               && branch_succeed == mc:branch_true)
              || (branch_fail == mc:branch_true
                  && branch_succeed == mc:branch_false)))
        [
          | var, r |
          @(var) = bargs;
          if (branch_succeed != mc:branch_true)
            inverse? = !inverse?;
          r = mc:new_local(fcode);
          mc:ins_compute(fcode, if (inverse?) mc:b_eq else mc:b_ne,
                         r, list(var, cfalse));
          exit<function> bool_result(r);
        ];

      // generate basic code
      if (trivial)
        trivial(if (inverse?) branch_fail else branch_succeed,
                if (inverse?) branch_succeed else branch_fail,
                bargs)
      else if (success)
        [
          mc:ins_branch(fcode, branch_fail, flab, bargs);
          success();
          if (failure) failure();
        ]
      else
        [
          mc:ins_branch(fcode, branch_succeed, slab, bargs);
          if (failure) failure()
          else mc:ins_branch(fcode, mc:branch_always, flab, null);
        ];
      mc:set_loc(prevloc);
    ];

];
