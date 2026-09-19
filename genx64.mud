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

library genx64 // Code generation for x86-64 (not particularly good)
requires ax64, compiler, flow, graph, ins3, misc, mx64,
  sequences, vars

defines
  x64:nscratch, x64:ncaller, x64:nregargs, x64:ncallee,
  x64:select_registers, x64:mgen_preamble, x64:mgen_instruction,
  x64:migrate, x64:gassemble, x64:uses_regclass

reads mc:update_maxseclev
writes mc:nops_called, mc:nops_inlined, mc:framesizes
[

  | reg_argcount, reg_closure_in, mgen_relop, reg_result,
    regs_scratch, regs_scratch2, regs_caller, select_registers,
    builtins, relops, var_in_reg, reg_dest, mgen_return, mgen_branch,
    mgen_compute, mgen_memory, mgen_closure, mgen_call,
    callop2, callop3, rev_x64relop, fetch1, move,
    compare, special_compare,
    reg_scratch, reg_scratch2,
    reg_arg0, reg_arg1, reg_arg2, reg_arg3, reg_arg4, reg_arg5,
    regs_native_args,
    mgen_trap, regs_allscratch, type_branch, get_type,
    typearg1, typearg2, inline2?, mgen_inline1, mgen_inline2,
    type_trap, typeset_trap, call, set_seclev,
    mzero, mfalse, cfalse, cemptystr,
    call_closure, call_primitive, call_varargs,
    call_builtin,
    perform3, int31?, int32?, uint31?,
    argstart, enames,
    commute_x64relop, in_scratch?, safemove,
    push_args, push_args_unaligned, pop_args, pop_args_unaligned,
    move_native_args,
    cmpeq, kset, kequal?, kseclevel, kmaxseclevel, call_kset, call_seclevel,
    ksconcat, kvcopy, kvequal?, kvector_bitor!, kprotect,
    call_bconcat, kglobal_lookup, maybe_call_global_lookup,
    needs_closure?, is_leaf?, update_maxseclev?,
    needs_global?, leaaddcst, fetch2, fetch_for_dest,
    fake_prim_type,
    immutable_itypes, itype_null_int,
    word_size,
    stack_frame_size |

  word_size = 8;

  // used to indicate any primitive; i.e., stype_function - type_closure
  fake_prim_type = '[];

  mc:nops_inlined = mc:nops_called = 0;
  mc:framesizes = make_vector(10);
  vfill!(mc:framesizes, 0);

  // Register usage for mudlle
  //   rax: scratch, argument count, function result
  //   rbx: callee-saved, (opt.) globals
  //   rdi,rsi: args 0-1, scratch
  //   rdx,rcx,r8,r9: caller-saved, native args 2-5
  //   r10: caller-saved, closure-in
  //   r11: scratch
  //   r12-r14: callee-saved
  //   r15: callee-saved, (opt.) closure
  //   rbp: frame pointer
  //   rsp: stack pointer
  // Arguments to mudlle functions are on the stack (for debuggability).

  reg_argcount   = x64:reg_rax; // same as reg_scratch, beware
  reg_closure_in = x64:reg_r10; // when passed as parameter
  reg_result     = x64:reg_rax;
  argstart       = 2 * word_size; // offset of first argument on stack

  reg_scratch     = x64:reg_rax;
  reg_scratch2    = x64:reg_r11;

  // Arguments for builtins
  reg_result = x64:reg_rax;
  reg_arg0 = x64:reg_rdi;
  reg_arg1 = x64:reg_rsi;
  reg_arg2 = x64:reg_rdx;
  reg_arg3 = x64:reg_rcx;
  reg_arg4 = x64:reg_r8;
  reg_arg5 = x64:reg_r9;

  regs_native_args = '[
    ,reg_arg0 ,reg_arg1 ,reg_arg2 ,reg_arg3 ,reg_arg4 ,reg_arg5
  ];

  // General regs
  regs_scratch    = '[,reg_scratch];
  regs_scratch2   = '[,reg_scratch2];
  regs_allscratch = '[,reg_scratch ,reg_scratch2];
  regs_caller     = '[,reg_arg2 ,reg_arg3 ,reg_arg4 ,reg_arg5 ,x64:reg_r10];

  mfalse = mzero = x64:mudlleint(0);
  cfalse = mc:var_make_constant(false);
  cemptystr = mc:var_make_constant("");

  int31? = fn (int n) n >= -0x40000000 && n <= 0x3fffffff;
  int32? = fn (int n) n >= -0x80000000 && n <= 0x7fffffff;
  uint31? = fn (int n) (n & ~0x7fffffff) == 0;

  | power_of_2? |
  power_of_2? = fn (n) n && (n & (n - 1)) == 0;

  needs_closure? = fn (ifn)
    (ifn[mc:c_fclosure] != null);

  needs_global? = fn (ifn)
    // Types: ifn : intermediate function
    // Returns: true if ifn reads or writes a global variable
    [
      | is_global?, uses_global |

      is_global? = fn (v)
	[
	  | class |

	  class = v[mc:v_class];
	  (class == mc:v_global || class == mc:v_global_define
           || (class == mc:v_global_constant
               && !immutable?(global_value(v[mc:v_goffset]))))
	];

      uses_global = fn (il)
	[
	  | dvar, ins |

	  ins = il[mc:il_ins];
	  dvar = mc:defined_var(ins);
	  if (dvar && is_global?(dvar))
	    true
	  else
	    lexists?(is_global?, mc:arguments(ins, null))
	];

      graph_nodes_exists?(fn (n) [
        dexists?(uses_global, graph_node_get(n)[mc:f_ilist])
      ], cdr(ifn[mc:c_fvalue]));
    ];

  // nb of registers of each category available
  x64:nscratch = fn (ifn) 1;    // rax
  x64:ncaller = fn (ifn) 5;     // arg2-arg5, r10
  x64:nregargs = fn (ifn) 0;    // arguments on stack
  x64:ncallee = fn (ifn)        // rbx (unless globals), r12-r14,
                                // r15 (unless closure)
    [
      | ncallee |

      ncallee = 3;

      if (!(ifn[mc:c_fmisc][mc:c_fm_globalsbase] = needs_global?(ifn)))
        ++ncallee;

      if (!(ifn[mc:c_fmisc][mc:c_fm_closurebase] = needs_closure?(ifn)))
        ++ncallee;

      ncallee
    ];

  kequal?        = mc:make_kglobal("equal?");
  kglobal_lookup = mc:make_kglobal("global_lookup");
  kmaxseclevel   = mc:make_kglobal("maxseclevel");
  kprotect       = mc:make_kglobal("protect");
  ksconcat       = mc:make_kglobal("sconcat");
  kseclevel      = mc:make_kglobal("seclevel");
  kset           = mc:make_kglobal("set!");
  kvcopy         = mc:make_kglobal("vcopy");
  kvequal?       = mc:make_kglobal("vequal?");
  kvector_bitor! = mc:make_kglobal("vector_bitor!");

  | inline_bref? |
  inline_bref? = fn (type1, arg2)
    [
      | c |
      c = mc:var_value(arg2);
      (integer?(c) && c >= 0
       && ((!(type1 & itype_vector) && c < MAX_STRING_SIZE)
           || (!(type1 & itype_string) && c < MAX_VECTOR_SIZE)))
    ];

  | intcst? |
  intcst? = fn (v)
    v[mc:v_class] == mc:v_constant && integer?(v[mc:v_kvalue]);

  | assign_src_uses_scratch? |
  assign_src_uses_scratch? = fn (src)
    [
      | cls, val |
      cls = src[mc:v_class];
      // assignment from local does not use scratch
      if (cls == mc:v_local) exit<function> false;
      if (cls != mc:v_constant) exit<function> true;
      val = src[mc:v_kvalue];
      // assignment from null and 31-bit integers do not use scratch
      !(val == null || (integer?(val) && int31?(val)))
    ];

  x64:uses_regclass = fn (ins)
    [
      | class |
      class = ins[mc:i_class];

      if (class == mc:i_branch)
        [
          | op |
          op = ins[mc:i_bop];
          if (op == mc:branch_always
              || op == mc:branch_never
              || op == mc:branch_true
              || op == mc:branch_false
              // comparisons: normal and {v,s}length
              || (op >= mc:branch_eq && op < mc:branch_equal)
              || (op >= mc:branch_type?
                  && op < mc:branch_ntype? + mudlle_synthetic_types)
              || op == mc:branch_any_prim
              || op == mc:branch_not_prim
              || op == mc:branch_bitand
              || op == mc:branch_nbitand)
            mc:regclass_none
          else if (op == mc:branch_equal
                   || op == mc:branch_nequal)
            mc:regclass_caller
          else
            mc:regclass_scratch
        ]
      else if (class == mc:i_trap)
        [
          | op |
          op = ins[mc:i_top];
          if (op == mc:trap_type
              || op == mc:trap_typeset
              || op == mc:trap_loop)
            mc:regclass_none
          else if (op == mc:trap_global_read
                   || op == mc:trap_global_write)
            mc:regclass_caller
          else
            mc:regclass_scratch
        ]
      else if (class == mc:i_compute)
        [
          | op |
          op = ins[mc:i_aop];
          if (op == mc:b_assign)
            [
              | src |
              @(src) = ins[mc:i_aargs];
              if (assign_src_uses_scratch?(src))
                mc:regclass_scratch
              else
                mc:regclass_none
            ]
          else if (op == mc:b_ref)
            [
              | atypes |
              atypes = ins[mc:i_atypes];
              if (atypes && inline_bref?(car(atypes), cadr(ins[mc:i_aargs])))
                mc:regclass_none
              else
                mc:regclass_scratch
            ]
          else if (op == mc:b_vector
                   || op == mc:b_sequence)
            mc:regclass_early_scratch
          else if (op == mc:b_slength
                   || op == mc:b_vlength
                   || op == mc:b_car
                   || op == mc:b_cdr
                   || op == mc:b_symbol_name
                   || op == mc:b_symbol_get
                   || op == mc:b_negate
                   || op == mc:b_bitnot
                   || op == mc:b_logical_not
                   || op == mc:b_typeof
                   || op == mc:b_funcarg
                   || op == mc:b_shift_right
                   || (op == mc:b_shift_left
                       && intcst?(car(ins[mc:i_aargs]))))
            mc:regclass_none
          else
            mc:regclass_scratch
        ]
      else if (class == mc:i_memory)
        if (ins[mc:i_mop] == mc:memory_read)
          mc:regclass_none
        else
          mc:regclass_scratch
      else if (class == mc:i_nop)
        mc:regclass_none
      else if (class == mc:i_call)
        mc:regclass_caller
      else if (class == mc:i_closure)
        mc:regclass_early_scratch
      else
        mc:regclass_scratch;
    ];

  get_type = fn (v) // minimalistic type inference ...
    [
      | t |

      if (t = mc:const_itype(v)) t
      else itype_any
    ];

  select_registers = fn (ifn, type, regs)
    [
      | select |

      select = fn (var)
        [
          | vloc |

          vloc = var[mc:v_location];

          if (vloc && vloc[mc:v_lclass] == mc:v_lregister
              && vloc[mc:v_lrtype] == type)
            vloc[mc:v_lrnumber] = regs[vloc[mc:v_lrnumber]];
        ];

      lforeach(select, ifn[mc:c_flocals]);
      lforeach(select, ifn[mc:c_fclosure]);
    ];

  x64:select_registers = fn (ifn, ainfo)
    // Effects: Selects registers for ifn
    // Returns: Information on allocation count
    [
      // Allocate caller regs
      select_registers(ifn, mc:reg_caller, regs_caller);

      // Allocate callee regs
      // set regs_callee to the callee registers actually needed
      // (used to generate correct push/pops)
      | regs_callee |
      if (ainfo[mc:vainfo_callee] > 0) // list_first_n! doesn't handle 0. grr.
	[
	  regs_callee = list(x64:reg_r12, x64:reg_r13, x64:reg_r14);
	  if (!ifn[mc:c_fmisc][mc:c_fm_closurebase])
	    regs_callee = x64:reg_closure . regs_callee;
	  if (!ifn[mc:c_fmisc][mc:c_fm_globalsbase])
	    regs_callee = x64:reg_globals . regs_callee;
	  regs_callee = list_to_vector(
            list_first_n!(ainfo[mc:vainfo_callee], regs_callee));
	]
      else
	regs_callee = '[];
      ifn[mc:c_fmisc][mc:c_fm_regs_callee] = regs_callee;
      select_registers(ifn, mc:reg_callee, regs_callee);

      // Allocate scratch regs
      select_registers(ifn, mc:reg_scratch, regs_scratch);

      // set/adjust offsets of all spilled variables
      | cvars, offset |
      cvars = ifn[mc:c_fclosure];
      offset = x64:object_offset + word_size; // skip over function
      while (cvars != null)
	[
	  | cvar, cvarloc |

	  cvar = car(cvars);
	  // myself is not present in closures, it is the closure
	  if (cvar[mc:v_cparent] == mc:myself)
	    cvar[mc:v_location] = vector(mc:v_lregister, mc:reg_callee,
                                         x64:reg_closure)
	  else
	    [
	      cvarloc = cvar[mc:v_location];
	      if (cvarloc[mc:v_lclass] == mc:v_lspill)
		cvarloc[mc:v_lsoffset] = offset;
	      offset += word_size;
	    ];
	  cvars = cdr(cvars);
	];

      // For fn (arg0, arg1 = e1, arg2 = e2, arg3...)
      //
      // bp[5]  arg 3 - goes into vararg
      // bp[4]  arg 2 - optional argument
      // bp[3]  arg 1 - optional argument
      // bp[2]  arg 0 - fixed argument
      // bp[1]  return PC
      // bp[0]  old bp
      // bp[-1] nargs     (if noptional > 0)
      //     <locals>

      | arginfo, nargs, noptional, nfixed |
      arginfo = ifn[mc:c_farginfo];

      noptional = arginfo[mc:arginfo_noptargs];
      nargs     = arginfo[mc:arginfo_nargs];
      nfixed    = nargs - noptional;

      | reserved_locals |
      reserved_locals = noptional > 0;

      // increase framesize accordingly
      ainfo[mc:vainfo_spill] += reserved_locals;

      | locals, local_start |
      local_start = 1 + reserved_locals; // bp[0] is old bp
      // spilled locals are stored below bp
      locals = ifn[mc:c_flocals];
      while (locals != null)
	[
	  | localoc |

	  localoc = car(locals)[mc:v_location];
	  if (localoc[mc:v_lclass] == mc:v_lspill
              && localoc[mc:v_lstype] == mc:spill_spill)
	    localoc[mc:v_lsoffset]
              = -word_size * (local_start + localoc[mc:v_lsoffset]);
	  locals = cdr(locals);
	];

      | fixedoffset |
      fixedoffset = argstart;

      | nargs_var |
      nargs_var = ifn[mc:c_fnargs_var];
      if (nargs_var)
        [
          | var, argloc |
          var = nargs_var[mc:vl_var];
          assert(!var[mc:v_indirect]); // shouldn't happen
          argloc = var[mc:v_location];
          if (argloc)
            [
              argloc[mc:v_lclass] = mc:v_lspill;
              argloc[mc:v_lstype] = mc:spill_spill;
              argloc[mc:v_lsoffset] = -word_size;
            ]
        ];

      // setup arguments, add indirection
      for (| n, fargs | [ n = 0; fargs = ifn[mc:c_ffullargs] ];
           n < nfixed;
           ++n)
        [
          | farg, argloc |
          @(farg . fargs) = fargs;
          argloc = farg[mc:fullarg_arg][mc:vl_var][mc:v_location];

          if (argloc
              && argloc[mc:v_lclass] == mc:v_lspill
              && argloc[mc:v_lstype] == mc:spill_args)
            argloc[mc:v_lsoffset] = fixedoffset;
          fixedoffset += word_size;
        ];

      ainfo
    ];

  x64:migrate = fn (ifn, vars, notspilt, spilt, locals, temps)
    // Effetcs: Receives the grouping of variables used by the
    //   register allocator. May move some variables between the group to
    //   better suit the processor. May only strengthen needs ...
    //   On x64: move all but one any closure or argument in temps to locals
    [
      | detemp, any? |
      any? = false;
      detemp = fn (v)
        [
	  | n |
	  n = v[mc:v_number];
	  if (!bit_set?(temps, n))
            null
          else if (!any?)
            any? = true
          else
            [
              clear_bit!(temps, n);
              set_bit!(locals, n)
            ]
	];

      for (|fargs| fargs = ifn[mc:c_ffullargs]; fargs != null; )
        [
          | farg |
          @(farg . fargs) = fargs;
          detemp(farg[mc:fullarg_arg][mc:vl_var])
        ];
      lforeach(detemp, ifn[mc:c_fclosure]);
    ];

  enames =
    '[
      "berror_bad_function"
      "berror_stack_underflow"
      "berror_bad_type"
      "berror_divide_by_zero"
      "berror_bad_index"
      "berror_bad_value"
      "berror_variable_read_only"
      "berror_loop"
      "berror_recurse"
      "berror_wrong_parameters"
      "berror_security_violation"
      "berror_value_read_only"
      "berror_user_interrupt"
      "berror_no_match"
      "berror_compile"
      "berror_abort"
    ];
  assert(vlength(enames) == last_runtime_error);

  x64:gassemble = fn (code)
    [
      // Generate error calls
      lforeach(fn (err) [
        | errno, label, label2, args, loc |
        @[errno loc label args label2] = err;
        mc:set_loc(loc);
        x64:label(code, label);
        if (args == null)
          [
            | bname |
            bname = if (errno == -error_wrong_parameters)
              "bearly_error_wrong_parameters"
            else
              [
                assert(errno >= 0);
                enames[errno]
              ];
            exit<function> x64:call(code, x64:lbuiltin, bname, true);
          ];

        if (errno == error_no_match)
          [
            x64:mov(code, x64:lvar, args, x64:lreg, reg_arg0);
            exit<function>
              x64:call(code, x64:lbuiltin, "bno_match_error", true);
          ];

        assert(errno == error_bad_type);
        | typeset, mvf, mvarg, argnum |
        @[typeset argnum mvf mvarg] = args;
        mvf(code, mvarg, x64:lreg, reg_arg0);
        if (typeset == null)
          x64:jmp(code, label2)
        else
          [
            if (label2)
              x64:label(code, label2);
            move(code,
                 if (int32?(typeset)) x64:limm else x64:limm64, typeset,
                 x64:lreg, reg_arg1);
            move(code, x64:limm, argnum + 1, x64:lreg, reg_arg2);
            exit<function> x64:call(code, x64:lbuiltin, "btype_error", true);
          ]
      ], code[x64:vcode_traps]);
      x64:assemble(code);
    ];

  is_leaf? = fn (ifn)
    !dexists?(fn (il) [
      | ins, class |
      ins = il[mc:il_ins];
      class = ins[mc:i_class];
      if (class == mc:i_call)
        [
          | called, args |
          @(called . args) = ins[mc:i_cargs];
          if (called == kseclevel || called == kmaxseclevel)
            [
              if (args == null)
                exit<function> false;
            ]

          else if (called == kset)
            [
              if (llength(args) == 3)
                [
                  | types, type |
                  types = ins[mc:i_ctypes];
                  type = if (types) cadr(types) else get_type(car(args));
                  // count vector/string assignment as a leaf operation
                  if (type & ~(itype_vector | itype_string) == 0)
                    exit<function> false;
                ]
            ]
          else if (called == kglobal_lookup)
            [
              if (llength(args) == 1
                  && get_type(car(args)) == itype_string)
                exit<function> false;
            ]
          else if (called == ksconcat)
            exit<function> false;

          exit<function> true;
        ];

      false
    ], ifn[mc:c_fvalue]);

  update_maxseclev? = fn (code)
    (mc:update_maxseclev == true && !code[x64:vcode_leaf?]);

  set_seclev = fn (code, dreg, type)
    x64:mov(code, x64:lseclev, type, x64:lreg, dreg);

  pop_args_unaligned = fn (code, nargs)
    if (nargs > 0)
      x64:add(code, x64:limm, word_size * nargs, x64:lreg, x64:reg_rsp);

  pop_args = fn (code, nargs)
    [
      if ((nargs + stack_frame_size) & 1)
        ++nargs;
      pop_args_unaligned(code, nargs);
    ];

  | saved_callee_regs |
  saved_callee_regs = fn (fmisc)
    [
      | regs |
      regs = vector_to_list(fmisc[mc:c_fm_regs_callee]);
      if (fmisc[mc:c_fm_closurebase])
        regs = x64:reg_closure . regs;
      if (fmisc[mc:c_fm_globalsbase])
        regs = x64:reg_globals . regs;
      regs
    ];

  x64:mgen_preamble = fn (ifn, ainfo)
    [
      | code, fmisc |

      x64:reset_ins_count();

      code = x64:new_code(is_leaf?(ifn));

      mc:set_loc(ifn[mc:c_loc]);

      // Allocate & clear stack frame
      x64:push(code, x64:lreg, x64:reg_rbp);
      stack_frame_size = 0;
      move(code, x64:lreg, x64:reg_rsp, x64:lreg, x64:reg_rbp);

      | framesize |
      framesize = ainfo[mc:vainfo_spill];
      if (framesize > 0)
        [
          x64:sub(code, x64:limm, framesize * word_size,
                  x64:lreg, x64:reg_rsp);
          stack_frame_size += framesize;
        ];

      | arginfo, nargs, noptional, nfixed, vararg? |
      arginfo = ifn[mc:c_farginfo];

      noptional = arginfo[mc:arginfo_noptargs];
      nargs     = arginfo[mc:arginfo_nargs];
      vararg?   = !!arginfo[mc:arginfo_vararg];
      nfixed    = nargs - noptional;

      ++mc:framesizes[if (framesize < 10) framesize else 9];

      if (noptional > 0)
        [
          if (nfixed > 0)
            [
              if (vararg?)
                [
                  // trap if too few arguments
                  cmpeq(code, x64:limm, nfixed,
                        x64:lreg, reg_argcount);
                  x64:trap(code, x64:bl, -error_wrong_parameters, null);
                ]
              else
                [
                  // trap if < nfixed or > nargs
                  x64:lea(code, x64:lidx, reg_argcount . -nfixed,
                          x64:lreg, reg_scratch2);
                  x64:cmp(code, x64:limm, noptional, x64:lreg, reg_scratch2);
                  x64:trap(code, x64:ba, -error_wrong_parameters, null);
                ]
            ]
          else if (!vararg?)
            [
              // trap if too many arguments
              cmpeq(code, x64:limm, nfixed + noptional,
                    x64:lreg, reg_argcount);
              x64:trap(code, x64:bg, -error_wrong_parameters, null);
            ];

          // preserve makeint(argcount)
          --framesize;
          x64:lea(code, x64:lridx, reg_argcount . 1 . reg_argcount . 1,
                  x64:lreg, x64:reg_rdx);
        ]
      else
        // clear ZF on incorrect argcount (bcleargc will trap)
        cmpeq(code, x64:limm, nargs, x64:lreg, reg_argcount);

      if (code[x64:vcode_leaf?] && framesize < 3)
        [
          // skip the infinite loop and minlevel security checks for leaf
          // functions (note that this is a minor security hole)
          if (noptional == 0)
            x64:trap(code, x64:bne, -error_wrong_parameters, null);
          for (|i|i = -framesize; i < 0; ++i)
            // initialise stack frame to legal mudlle values
            x64:mov(code, x64:limm, 0,
                    x64:lidx, x64:reg_rbp . WORD_SIZE * (i - noptional));
        ]
      else
        [
          if (noptional > 0)
            // set ZF to avoid bcleargc trap
            x64:xor(code, x64:lreg, reg_argcount, x64:lreg, reg_argcount);

          set_seclev(code, reg_arg1, x64:sl_c);

          | f |
          f = if (framesize >= 4)
            "bcleargc"
          else
            '["bcleargc0" "bcleargc1" "bcleargc2" "bcleargc3"][framesize];
          call_builtin(code, f);
        ];

      if (noptional > 0)
        //  store makeint(argcount) at bp[-1]
        x64:mov(code, x64:lreg, x64:reg_rdx,
                x64:lidx, x64:reg_rbp . -WORD_SIZE);

      if (update_maxseclev?(code))
        [
          set_seclev(code, reg_arg1, x64:sl_maxlev);
          x64:mov(code, x64:lbuiltin, "maxseclevel", x64:lreg, reg_scratch);
          x64:push(code, x64:lidx, reg_scratch . 0);
          ++stack_frame_size;
          x64:cmp(code, x64:lreg, reg_arg1, x64:lidx, reg_scratch . 0);
          | l |
          l = x64:new_label(code);
          x64:jcc(code, x64:bge, l);
          x64:mov(code, x64:lreg, reg_arg1, x64:lidx, reg_scratch . 0);
          x64:label(code, l);
        ];

      | ident, code_call_count_offset |
      ident = fn (x) x;         // silence warning
      code_call_count_offset = ident(x64:code_call_count_offset);
      if (code_call_count_offset != null)
        [
          | l, ofs |
          ofs = code_call_count_offset - x64:mcode_code_offset;
          l = x64:new_label(code);
          x64:add32(code, x64:limm, 1,
                    x64:lidx, x64:reg_rip . (fn (mode) [
                      l = x64:skip_label_alias(l);
                      match! (mode)
                        [
                          0 => 4;  // size
                          1 => ofs - l[x64:l_ins][x64:il_offset][0]; // value
                          2 => format("%d-&%d", ofs, l[x64:l_number]); // str
                        ]
                    ]));
          x64:label(code, l);
        ];

      // Save callee-saved registers
      fmisc = ifn[mc:c_fmisc];
      lforeach(fn (r) [
        x64:push(code, x64:lreg, r);
        ++stack_frame_size;
      ], saved_callee_regs(fmisc));
      if (fmisc[mc:c_fm_closurebase])
        move(code, x64:lreg, reg_closure_in, x64:lreg, x64:reg_closure);
      if (fmisc[mc:c_fm_globalsbase])
	[
	  x64:mov(code, x64:lbuiltin, "env_values", x64:lreg, x64:reg_globals);
          x64:mov(code, x64:lidx, x64:reg_globals . 0,
                  x64:lreg, x64:reg_globals);
	];

      // setup variables:

      | extra_move |

      // setup arguments, add indirection
      for (|n, fargs| [ n = 0; fargs = ifn[mc:c_ffullargs] ];
           fargs != null;
           ++n)
	[
	  | farg, arg, var, varloc, ts, loc, locarg |
          @(farg . fargs) = fargs;
          arg = farg[mc:fullarg_arg];
          @[var ts varloc] = arg;
	  if (!var[mc:v_location]) // ignore unused arguments
            exit<continue> null;

          mc:set_loc(varloc);

          if (ts == null || (ts & TYPESET_FLAG_OPTIONAL))
            [
              loc = x64:limm;
              locarg = 0;
            ]
          else
            [
              loc = x64:lidx;
              locarg = x64:reg_rbp . (argstart + n * word_size);
            ];

          // if variable is indirect create indirection record
          if (var[mc:v_indirect])
            [
              assert(!(loc == x64:lreg && locarg == reg_scratch));
              call_builtin(code, "balloc_variable");
              safemove(code, loc, locarg,
                       x64:lidx, reg_result . x64:object_offset,
                       regs_scratch2);
              if (loc == x64:limm)
                move(code, x64:lreg, reg_result, x64:lvar, var)
              else
                [
                  loc = x64:lreg;
                  locarg = reg_result;
                ]
            ];

          if (ts == null)
            [
              | alloc_vararg |
              alloc_vararg = fn ()
                [
                  move(code, x64:limm, x64:mudlleint(nargs - 1),
                       x64:lreg, reg_arg0);
                  call_builtin(code, "bvarargs");
                  if (var[mc:v_indirect])
                    [
                      | areg |
                      areg = fetch1(code, var);
                      move(code, x64:lreg, reg_scratch,
                               x64:lidx, areg . x64:object_offset);
                    ]
                  else
                    move(code, x64:lreg, reg_scratch, x64:lvar, var);
                ];
              if (in_scratch?(var))
                [
                  assert(extra_move == null);
                  extra_move = vector(alloc_vararg, '[], varloc);
                ]
              else
                alloc_vararg();
              exit<continue> null;
            ];

          if (ts & TYPESET_FLAG_OPTIONAL)
            exit<continue> null;

          // & copy to correct location
          | mov |
          mov = vector(code, loc, locarg, x64:lvar, var);
          if (in_scratch?(var))
            [
              assert(extra_move == null);
              extra_move = vector(move, mov, varloc);
            ]
          else
            apply(move, mov)
	];

      mc:set_loc(ifn[mc:c_loc]);

      // unspill closure vars that need it
      | offset |
      offset = x64:object_offset + word_size;
      for (|cvars| cvars = ifn[mc:c_fclosure]; cvars != null; )
	[
	  | cvar, cvarloc |
          @(cvar . cvars) = cvars;

	  if (cvar[mc:v_cparent] == mc:myself)
            exit<continue> null;

          cvarloc = cvar[mc:v_location];
          if (cvarloc[mc:v_lclass] == mc:v_lregister)
            [
              // unspill closure entry
              | mov |
              mov = vector(code, x64:lidx, x64:reg_closure . offset,
                           x64:lreg, cvarloc[mc:v_lrnumber]);
              if (in_scratch?(cvar))
                [
                  assert(extra_move == null);
                  extra_move = vector(move, mov, ifn[mc:c_loc]);
                ]
              else
                apply(move, mov);
            ];
          offset += word_size;
        ];

      // add indirection for other local variables
      for (|locals| locals = ifn[mc:c_flocals]; locals != null; )
	[
	  | local |
          @(local . locals) = locals;

	  if (local[mc:v_indirect]
              && !lexists?(fn (farg) farg[mc:fullarg_arg][mc:vl_var] == local,
                           ifn[mc:c_ffullargs]))
	    [
	      call_builtin(code, "balloc_variable");
	      move(code, x64:limm, 0,
                   x64:lidx, reg_result . x64:object_offset);
	      safemove(code, x64:lreg, reg_result, x64:lvar, local, '[]);
	      assert_message(!in_scratch?(local),
                             "oops - local var unspilt to scratch");
	    ];
	];

      if (extra_move != null)
        [
          | func, args, loc |
          @[func args loc] = extra_move;
          mc:set_loc(loc);
          apply(func, args);
        ];

      code
    ];

  x64:mgen_instruction = fn (code, ifn, ainfo, il)
    [
      | ins, class |

      if (il[mc:il_label])
	x64:label(code, il[mc:il_label][mc:l_mclabel]);

      ins = il[mc:il_ins];
      class = ins[mc:i_class];

      mc:set_loc(il[mc:il_loc]);

      if (class == mc:i_compute) mgen_compute(code, ins)
      else if (class == mc:i_branch) mgen_branch(code, ins)
      else if (class == mc:i_trap) mgen_trap(code, ins)
      else if (class == mc:i_memory) mgen_memory(code, ins)
      else if (class == mc:i_closure) mgen_closure(code, ins)
      else if (class == mc:i_call) mgen_call(code, ins)
      else if (class == mc:i_return) mgen_return(code, ifn, ainfo, ins)
      else if (class == mc:i_nop) null
      else fail()
    ];

  mgen_trap = fn (code, ins)
    [
      | trap, nerror, args, types, arg1, type1, arg2 |

      trap = ins[mc:i_top];
      nerror = ins[mc:i_tdest];
      args = ins[mc:i_targs];
      types = ins[mc:i_ttypes];
      if (args != null)
	[
	  arg1 = car(args);
	  if (!types) type1 = get_type(arg1)
	  else type1 = car(types);

	  if (cdr(args) != null)
	    arg2 = cadr(args);
	];

      if (trap == mc:trap_always)
        [
          if (mc:trap_is_unreachable?(ins))
            exit<function> null;

          | arg |
          arg = mc:trap_is_nomatch?(ins);
          if (!arg)
            exit<function> x64:trap(code, x64:balways, nerror, null);

          x64:trap(code, x64:balways, nerror, arg)
        ]
      else if (trap == mc:trap_loop)
	[
          // must not use scratch
          | lab |
          lab = x64:new_label(code);
          x64:mov(code, x64:lbuiltin, "xcount", x64:lreg, reg_scratch2);
          x64:dec(code, x64:lidx, reg_scratch2 . 0);
          x64:jcc(code, x64:bg, lab);
          call_builtin(code, "bcheck_xcount");
          x64:label(code, lab);
	]
      else if (trap == mc:trap_global_write || trap == mc:trap_global_read)
	[
          // Don't check reads for >= V
          if (trap == mc:trap_global_write || mc:update_maxseclev == true)
            [
              if (trap == mc:trap_global_write)
                x64:mov(code, x64:lvar, arg2, x64:lreg, reg_arg1);
              // ignores nerror value
              x64:mov(code, x64:lglobal_index, arg1[mc:v_name] . x64:gl_c,
                      x64:lreg, reg_arg0);
              | fname |
              fname = if (trap == mc:trap_global_write)
                "bwglobal"
              else
                "brglobal";
              x64:mov(code, x64:lbuiltin, fname, x64:lreg, reg_closure_in);
              call_builtin(code, "bcall_prim_noalloc");
            ];
	]
      else if (trap == mc:trap_type)
	// must not use scratch; ignores nerror value
	type_trap(code, arg2[mc:v_kvalue], arg1, type1)
      else if (trap == mc:trap_typeset)
	// must not use scratch; ignores nerror value
	typeset_trap(code, arg2[mc:v_kvalue], arg1, mc:var_value(caddr(args)),
                     type1, true)
      else
        fail();
    ];

  mgen_return = fn (code, ifn, ainfo, ins)
    [
      move(code, x64:lvar, ins[mc:i_rvalue], x64:lreg, reg_result);

      | check_xcount_lab, post_xcount_lab |
      x64:mov(code, x64:lbuiltin, "xcount", x64:lreg, reg_scratch2);
      x64:cmp(code, x64:limm, 0, x64:lidx, reg_scratch2 . 0);

      check_xcount_lab = x64:new_label(code);
      post_xcount_lab = x64:new_label(code);

      // forward jump predicts not taken
      x64:jcc(code, x64:bs, check_xcount_lab);
      x64:label(code, post_xcount_lab);

      | fmisc |
      fmisc = ifn[mc:c_fmisc];
      lforeach(fn (r) x64:pop(code, x64:lreg, r),
               lreverse!(saved_callee_regs(fmisc)));
      if (update_maxseclev?(code))
        [
          x64:mov(code, x64:lbuiltin, "maxseclevel", x64:lreg, reg_scratch2);
          x64:pop(code, x64:lidx, reg_scratch2 . 0);
        ];
      | framesize |
      framesize = ainfo[mc:vainfo_spill];
      if (framesize == 0)
        x64:pop(code, x64:lreg, x64:reg_rbp)
      else
        x64:leave(code);
      x64:ret(code);

      x64:label(code, check_xcount_lab);
      call_builtin(code, "bcheck_xcount");
      x64:jmp(code, post_xcount_lab);
    ];

  // map relops to x64 relops
  relops = indexed_sequence(
    mc:branch_eq . x64:be,
    mc:branch_ne . x64:bne,
    mc:branch_lt . x64:bl,
    mc:branch_ge . x64:bge,
    mc:branch_le . x64:ble,
    mc:branch_gt . x64:bg);
  rev_x64relop = fn (op) op ^ 1; // reverse meaning of x64 branch

  // change op assuming cmp operands have been commuted
  commute_x64relop = indexed_sequence(
    x64:bb  . x64:ba,           // swap
    x64:ba  . x64:bb,           // swap
    x64:be  . x64:be,           // no change
    x64:bne . x64:bne,          // no change
    x64:bbe . x64:bae,          // swap
    x64:bae . x64:bbe,          // swap
    x64:ble . x64:bge,          // swap
    x64:bge . x64:ble,          // swap
    x64:bl  . x64:bg,           // swap
    x64:bg  . x64:bl);          // swap

  itype_null_int = itype_null | itype_integer;
  // some strings have their immutable bit removed; don't add itype_string
  immutable_itypes = itype_null | itype_integer | itype_float | itype_bigint;

  | mgen_xor |
  // Computes r1 ^^ r2 as 0 or 1 (with condition codes set) and returns the
  // result register; or null if r1 == r2
  // If byte?, only the lower 8 bits will be valid.
  mgen_xor = fn (code, r1, r2, dstreg, byte?)
    [
      | reg1, reg2 |
      reg1 = mc:get_reg(r1);
      reg2 = mc:get_reg(r2);

      if (dstreg == reg1 || dstreg == reg2)
        dstreg = reg_scratch2;

      if (reg1 == reg_scratch)
        [
          // a ^^ a is false
          if (reg2 == reg_scratch)
            exit<function> null;
          reg2 = dstreg;
        ]
      else if (reg2 == reg_scratch)
        reg1 = dstreg
      else
        [
          reg1 = if (dstreg == reg_scratch) reg_scratch2 else reg_scratch;
          reg2 = dstreg
        ];

      if (!byte?)
        x64:xor(code, x64:lreg, dstreg, x64:lreg, dstreg);
      x64:cmp(code, x64:limm, mfalse, x64:lvar, r1);
      x64:setcc(code, x64:be, x64:lreg, reg1);
      x64:cmp(code, x64:limm, mfalse, x64:lvar, r2);
      x64:setcc(code, x64:be, x64:lreg, reg2);
      x64:xorbyte(code, x64:lreg, reg1 ^ reg2 ^ dstreg, x64:lreg, dstreg);
      dstreg
    ];

  | unroll_vfind? |
  unroll_vfind? = fn (code, dest, op, arg1, haystack)
    [
      | r1, slab |
      r1 = fetch2(code, arg1);
      arg1 = var_in_reg(arg1, r1);
      for (|i|i = 0; i < vlength(haystack); ++i)
        [
          | cop, lab |
          cop = compare(code, mc:var_make_constant(haystack[i]),
                        arg1, x64:be);
          lab = if (op == mc:branch_vfind?)
            dest
          else
            [
              if (slab == null)
                slab = x64:new_label(code);
              slab
            ];

          x64:jcc(code, cop, lab);
        ];
      if (op == mc:branch_vnfind?)
        [
          x64:jmp(code, dest);
          if (slab != null)
            x64:label(code, slab)
        ];
      null
    ];

  mgen_branch = fn (code, ins)
    [
      | op, dest, args, arg1, arg2, types, type1, type2 |

      op = ins[mc:i_bop];
      dest = ins[mc:i_bdest][mc:l_mclabel];
      args = ins[mc:i_bargs];
      types = ins[mc:i_btypes];
      if (args != null)
	[
	  arg1 = car(args);
	  if (!types) type1 = get_type(arg1)
	  else type1 = car(types);

	  if (cdr(args) != null)
	    [
	      arg2 = cadr(args);
	      if (!types) type2 = get_type(arg2)
	      else type2 = cadr(types);
	    ];
	];

      if (op == mc:branch_always)
	x64:jmp(code, dest)
      else if (op == mc:branch_never)
        null
      else if (op == mc:branch_true)
	[
          | cop |
          cop = compare(code, cfalse, arg1, x64:bne);
	  x64:jcc(code, cop, dest);
	]
      else if (op == mc:branch_false)
	[
          | cop |
          cop = compare(code, cfalse, arg1, x64:be);
	  x64:jcc(code, cop, dest);
	]
      else if (op == mc:branch_bitand || op == mc:branch_nbitand)
        [
          // must not use scratch
          | cst, cop |
          type_trap(code, type_integer, arg1, type1);
          type_trap(code, type_integer, arg2, type2);
          if (integer?(cst = mc:var_value(arg1)))
            null
          else if (integer?(cst = mc:var_value(arg2)))
            [
              | t |
              t = arg1; arg1 = arg2; arg2 = t;
            ];
          cop = x64:bne;
          if (integer?(cst))
            [
              if (int31?(cst) || uint31?(cst))
                x64:test(code, x64:limm, x64:doubleint(cst), x64:lvar, arg2)
              else if (power_of_2?(cst))
                [
                  x64:bt(code, x64:limm, ffs(cst), x64:lvar, arg2);
                  cop = x64:bb;
                ]
              else
                [
                  x64:mov(code, x64:limm64, x64:doubleint(cst),
                          x64:lreg, reg_scratch2);
                  x64:test(code, x64:lreg, reg_scratch2, x64:lvar, arg2);
                ]
            ]
          else
            [
              if (mc:in_reg(arg1))
                x64:lea(code, x64:lidx, mc:get_reg(arg1) . -1,
                        x64:lreg, reg_scratch2)
              else
                [
                  move(code, x64:lvar, arg1, x64:lreg, reg_scratch2);
                  x64:dec(code, x64:lreg, reg_scratch2);
                ];
              x64:test(code, x64:lreg, reg_scratch2, x64:lvar, arg2);
            ];
          if (op == mc:branch_nbitand)
            cop = rev_x64relop(cop);
          x64:jcc(code, cop, dest)
        ]
      else if (op == mc:branch_bitset || op == mc:branch_bitclear)
        [
	  type_trap(code, type_string, arg1, type1);
	  type_trap(code, type_integer, arg2, type2);
          callop2(code, "bbitref", arg1, arg2);
          // sets carry flag
          x64:jcc(code, if (op == mc:branch_bitset) x64:bb else x64:bae, dest)
        ]
      else if (op == mc:branch_vfind? || op == mc:branch_vnfind?)
        [
          | haystack |
          if (arg2[mc:v_class] == mc:v_constant
              && vector?(haystack = arg2[mc:v_kvalue])
              && vlength(haystack) < 5)
            exit<function> unroll_vfind?(code, dest, op, arg1, haystack);

          // will verify that arg2 is a vector
          callop2(code, "bvfindp", arg1, arg2);
          // sets zero flag
          x64:jcc(code, if (op == mc:branch_vfind?) x64:be else x64:bne, dest)
        ]
      else if (op == mc:branch_eq || op == mc:branch_ne)
	[
          // must not use scratch
          | cop |
	  cop = compare(code, arg1, arg2, relops[op]);
	  x64:jcc(code, cop, dest);
	]
      else if (op == mc:branch_equal || op == mc:branch_nequal)
        [
          call_primitive(code, kequal?, equal?, 2, args);
          x64:cmp(code, x64:limm, mfalse, x64:lreg, reg_result);
          x64:jcc(code, if (op == mc:branch_equal) x64:bne else x64:be, dest);
        ]
      else if (op >= mc:branch_lt && op <= mc:branch_gt) // relop
	[
          // must not use scratch
	  | x64op |

	  type_trap(code, type_integer, arg1, type1);
	  type_trap(code, type_integer, arg2, type2);

	  x64op = compare(code, arg2, arg1, relops[op]);
	  x64:jcc(code, x64op, dest);
	]
      else if (op >= mc:branch_slength && op < mc:branch_equal)
        [
          // must not use scratch
          | n |
          n = mc:var_value(arg2);
          assert(integer?(n));

          | areg |
          areg = fetch1(code, arg1);
          arg1 = var_in_reg(arg1, areg);

          if (op >= mc:branch_vlength)
            [
              op -= mc:branch_vlength;
              n *= word_size;
              type_trap(code, type_vector, arg1, type1);
            ]
          else
            [
              op -= mc:branch_slength;
              ++n;              // trailing zero
              type_trap(code, type_string, arg1, type1);
            ];
          op = relops[op + mc:branch_eq];
          n += x64:object_offset;

          x64:cmp(code, x64:limm, n, x64:lidx, areg . x64:object_size);
          x64:jcc(code, op, dest);
        ]
      else if (op >= mc:branch_immutable && op <= mc:branch_writable)
        [
          | inv?, flag |

          inv? = (op == mc:branch_mutable || op == mc:branch_writable);
          flag =
            if (op == mc:branch_immutable || op == mc:branch_mutable)
              MUDLLE_IMMUTABLE
            else
              MUDLLE_READONLY;

          if (!(type1 & ~immutable_itypes))
            [
              if (!inv?) x64:jmp(code, dest);
            ]
          else
            [
              | xr, fdest, usef |

              fdest = x64:new_label(code);
              usef = false;

              xr = fetch1(code, arg1);

              if (type1 & itype_integer)
                [
                  x64:test(code, x64:limm, 1, x64:lreg, xr);
                  x64:jcc(code, x64:bne, if (inv?) fdest else dest);
                  if (inv?) usef = true;
                ];
              if (type1 & itype_null)
                [
                  x64:test(code, x64:lreg, xr, x64:lreg, xr);
                  x64:jcc(code, x64:be, if (inv?) fdest else dest);
                  if (inv?) usef = true;
                ];
              x64:test(code, x64:limm, flag, x64:lidx, xr . x64:object_flags);
              x64:jcc(code, if (inv?) x64:be else x64:bne, dest);

              if (usef) x64:label(code, fdest);
            ];
        ]
      else if (op == mc:branch_xor || op == mc:branch_xnor)
        [
          if (mgen_xor(code, arg1, arg2, reg_scratch, true) != null)
            x64:jcc(code, if (op == mc:branch_xnor) x64:be else x64:bne, dest)
          else if (op == mc:branch_xnor)
            x64:jmp(code, dest);
        ]
      else if (op == mc:branch_any_prim || op == mc:branch_not_prim)
        type_branch(code, fake_prim_type, op == mc:branch_not_prim,
                    arg1, type1, dest)
      else if (op >= mc:branch_type? && op < mc:branch_ntype?)
	type_branch(code, op - mc:branch_type?, false, arg1, type1, dest)
      else if (op >= mc:branch_ntype?
               && op < mc:branch_ntype? + mudlle_synthetic_types)
	type_branch(code, op - mc:branch_ntype?, true, arg1, type1, dest)
      else
        fail();
    ];

  builtins = indexed_sequence(
    mc:b_shift_left  . "bshift_left",
    mc:b_shift_right . "bshift_right",
    mc:b_add         . "badd",
    mc:b_multiply    . "bmultiply",
    mc:b_divide      . "bdivide",
    mc:b_remainder   . "bremainder",
    mc:b_ref         . "bref",
    mc:b_cons        . "bcons",
    mc:b_pcons       . "bpcons",
    mc:b_funcarg . null); // here to make the vector the full length
  assert(vlength(builtins) == mc:builtins);

  // Type of compute op arguments (uses type_xxx/stype_xxx sets)
  typearg1 = indexed_sequence(
    mc:b_eq          . stype_any,
    mc:b_ne          . stype_any,
    mc:b_lt          . type_integer,
    mc:b_ge          . type_integer,
    mc:b_le          . type_integer,
    mc:b_gt          . type_integer,
    mc:b_bitor       . type_integer,
    mc:b_bitxor      . type_integer,
    mc:b_bitand      . type_integer,
    mc:b_shift_left  . stype_any,       // special handling
    mc:b_shift_right . stype_any,       // special handling
    mc:b_add         . stype_any,
    mc:b_subtract    . type_integer,
    mc:b_multiply    . stype_any,       // special handling
    mc:b_divide      . stype_any,       // special handling
    mc:b_remainder   . type_integer,
    mc:b_negate      . type_integer,
    mc:b_logical_not . stype_any,
    mc:b_bitnot      . type_integer,
    mc:b_ref         . stype_any,
    mc:b_logical_xor . stype_any,
    mc:b_car         . type_pair,
    mc:b_cdr         . type_pair,
    mc:b_slength     . type_string,
    mc:b_vlength     . type_vector,
    mc:b_iadd        . type_integer,
    mc:b_typeof      . stype_any,
    mc:b_symbol_name . type_symbol,
    mc:b_symbol_get  . type_symbol,
    mc:b_ffs         . stype_any,       // special handling
    mc:b_funcarg     . stype_any);      // special handling
  assert(mc:builtins == mc:b_funcarg + 1);

  typearg2 = indexed_sequence(
    mc:b_eq          . stype_any,
    mc:b_ne          . stype_any,
    mc:b_lt          . type_integer,
    mc:b_ge          . type_integer,
    mc:b_le          . type_integer,
    mc:b_gt          . type_integer,
    mc:b_bitor       . type_integer,
    mc:b_bitxor      . type_integer,
    mc:b_bitand      . type_integer,
    mc:b_shift_left  . stype_any,       // special handling
    mc:b_shift_right . stype_any,       // special handling
    mc:b_add         . stype_any,
    mc:b_subtract    . type_integer,
    mc:b_multiply    . stype_any,       // special handling
    mc:b_divide      . stype_any,       // special handling
    mc:b_remainder   . type_integer,
    mc:b_ref         . stype_any,
    mc:b_logical_xor . stype_any,
    mc:b_iadd        . type_integer);
  assert(mc:builtins == mc:b_funcarg + 1);

  var_in_reg = fn (var, reg)
    if (mc:in_reg(var) && mc:get_reg(var) == reg)
      var
    else
      [
        var = vcopy(var);
        var[mc:v_location] = vector(mc:v_lregister, mc:reg_scratch, reg);
        var
      ];

  | var_or_reg |
  var_or_reg = fn (var, fallback)
    if (mc:in_reg(var))
      mc:get_reg(var)
    else
      fallback;

  reg_dest = fn (dvar) var_or_reg(dvar, reg_scratch);

  | add_imm |
  // add two double/mudlleints; return x64:limm{,64} . double/mudlleint
  add_imm = fn (a0, @(b0 . b1))
    [
      | a1, r0, r1 |
      match! (a0)
        [
          (h . l) => [ a0 = h; a1 = l ];
          n => [ a0 = n >> 1; a1 = n & 1 ];
        ];
      r0 = a0 + b0;
      r1 = a1 + b1;
      r0 += (r1 >> 1);
      r1 &= 1;
      (if (int31?(r0)) x64:limm else x64:limm64) . (r0 . r1)
    ];

  | trap_mv_double, trap_mv_var |
  trap_mv_double = fn (code, svar, dloc, darg)
    loop
      if (dloc == x64:lreg && mc:get_reg(svar) == darg)
        exit x64:add(code, x64:lvar, svar, dloc, darg)
      else
        [
          | sreg |
          sreg = mc:get_reg(svar);
          if (sreg >= 0)
            exit x64:lea(code, x64:lridx, sreg . 1 . sreg . 0, dloc, darg);
          sreg = if (dloc == x64:lreg) darg else reg_scratch2;
          x64:mov(code, x64:lvar, svar, x64:lreg, sreg);
          svar = var_in_reg(svar, sreg);
        ];

  trap_mv_var = fn (code, svar, dloc, darg)
    move(code, x64:lvar, svar, dloc, darg);

  mgen_inline1 = fn (code, op, r, type, d)
    // Effects: Generates code for d = op r
    //   d, r are variables
    if (op == mc:b_negate)
      [
        // must not use scratch
        if ([
          if (mc:in_reg(r))
            !mc:in_reg(d) || mc:get_reg(r) != mc:get_reg(d)
          else
            mc:in_reg(d)
        ])
          [
            // used for reg-A/reg-B, reg/mem, or mem/reg
            safemove(code, x64:limm, 2, x64:lvar, d, regs_scratch2);
            x64:sub(code, x64:lvar, r, x64:lvar, d);
          ]
        else
          [
            safemove(code, x64:lvar, r, x64:lvar, d, regs_scratch2);
            x64:neg(code, x64:lvar, d);
            x64:add(code, x64:limm, 2, x64:lvar, d);
          ]
      ]
    else if (op == mc:b_bitnot)
      [
        // must not use scratch
	safemove(code, x64:lvar, r, x64:lvar, d, regs_scratch2);
	x64:neg(code, x64:lvar, d);
      ]
    else if (op == mc:b_logical_not)
      [
        // must not use scratch

        // should have been optimized away already
        mgen_relop(code, x64:be, cfalse, r, d);
      ]
    else if (op == mc:b_car || op == mc:b_symbol_name)
      [
        // must not use scratch
	| xr |
	xr = fetch1(code, r);
	safemove(code, x64:lidx, xr . x64:object_offset,
                 x64:lvar, d, regs_scratch2)
      ]
    else if (op == mc:b_cdr || op == mc:b_symbol_get)
      [
        // must not use scratch
	| xr |
	xr = fetch1(code, r);
	safemove(code, x64:lidx, xr . x64:object_offset + word_size,
                 x64:lvar, d, regs_scratch2)
      ]
    else if (op == mc:b_slength)
      [
        // must not use scratch
	| xr, dr |

	xr = fetch1(code, r);
	dr = var_or_reg(d, reg_scratch2);

        // (strsize * 2 - (objsize * 2 + 1) = slen * 2 + 1
	move(code, x64:lidx, xr . x64:object_size, x64:lreg, dr);
	x64:lea(code, x64:lridx, dr . 1 . dr . -(2 * x64:object_offset + 1),
                x64:lreg, dr);
	safemove(code, x64:lreg, dr, x64:lvar, d, '[]);
      ]
    else if (op == mc:b_vlength)
      [
        // must not use scratch
	| xr, dr |

	xr = fetch1(code, r);
	dr = var_or_reg(d, reg_scratch2);

        // (vecsize / 4) - (objsize / 4) - 1 = vecelems * 2 + 1
	move(code, x64:lidx, xr . x64:object_size, x64:lreg, dr);
	x64:shr(code, x64:limm, 2, x64:lreg, dr);
	x64:sub(code, x64:limm, (x64:object_offset >> 2) - 1, x64:lreg, dr);
	safemove(code, x64:lreg, dr, x64:lvar, d, '[]);
      ]
    else if (op == mc:b_typeof)
      [
        // must not use scratch
        if (mc:in_reg(r) && mc:get_reg(r) == mc:get_reg(d))
          [
            move(code, x64:lvar, r, x64:lreg, reg_scratch2);
            r = var_in_reg(r, reg_scratch2);
          ];

        | elab |
        if ((type & itype_null_int) && !power_of_2?(type))
          elab = x64:new_label(code);

        if (type & itype_null)
          [
            type &= ~itype_null;
            if (type != 0)
              cmpeq(code, x64:limm, 0, x64:lvar, r);
            x64:mov(code, x64:limm, x64:mudlleint(type_null), x64:lvar, d);
            if (type != 0)
              x64:jcc(code, x64:be, elab);
          ];

        if (type & itype_integer)
          [
            type &= ~itype_integer;
            if (type != 0)
              x64:test(code, x64:limm, 1, x64:lvar, r);
            x64:mov(code, x64:limm, x64:mudlleint(type_integer), x64:lvar, d);
            if (type != 0)
              x64:jcc(code, x64:bne, elab);
          ];

        | tset |
        tset = mc:typeset_from_itypeset(type, false);
        if (power_of_2?(tset))
          x64:mov(code, x64:limm, x64:mudlleint(ffs(tset) - 1), x64:lvar, d)
        else if (tset != 0)
          [
            | dr, rr |
            rr = dr = if (mc:in_reg(d)) mc:get_reg(d) else reg_scratch2;
            if (mc:in_reg(r))
              rr = mc:get_reg(r)
            else
              move(code, x64:lvar, r, x64:lreg, dr);
            x64:movzxbyte(code, x64:lidx, rr . x64:object_type, x64:lreg, dr);
            x64:lea32(code, x64:lridx, dr . 1 . dr . 1, x64:lreg, dr);
            move(code, x64:lreg, dr, x64:lvar, d);
          ];

        if (elab != null)
          x64:label(code, elab);
      ]
    else if (op == mc:b_ffs)
      [
        | dr, sr |
        dr = reg_dest(d);

        if (mc:in_reg(r))
          sr = mc:get_reg(r)
        else
          [
            sr = reg_scratch;
            move(code, x64:lvar, r, x64:lreg, sr);
            r = var_in_reg(r, sr);
          ];

        if (type & ~itype_integer)
          type_trap(code, type_integer, r, type);

        if (sr == reg_scratch)
          x64:sub(code, x64:limm, 1, x64:lreg, reg_scratch)
        else
          x64:lea(code, x64:lidx, sr . -1, x64:lreg, reg_scratch);
        x64:bsf(code, x64:lreg, reg_scratch, x64:lreg, reg_scratch);
        x64:lea32(code, x64:lridx, reg_scratch . 1 . reg_scratch . 1,
                  x64:lreg, dr);

        if (type & itype_zero)
          [
            | tr |
            tr = if (dr == reg_scratch) reg_scratch2 else reg_scratch;
            x64:mov(code, x64:limm, mzero, x64:lreg, tr);
            x64:cmovcc32(code, x64:be, x64:lreg, tr, x64:lreg, dr);
          ];
        move(code, x64:lreg, dr, x64:lvar, d);
      ]
    else if (op == mc:b_funcarg)
      [
        // must not use scratch
        assert(intcst?(r));
        safemove(
          code,
          x64:lidx, x64:reg_rbp . (argstart + r[mc:v_kvalue] * word_size),
          x64:lvar, d,
          regs_scratch2);
      ]
    else
      fail();

  | mulcst?, divcst? |

  // b_multiply can be inlined with power of two or 32-bit integer
  mulcst? = fn (v)
    match (mc:var_value(v))
      [
        {int} n => int32?(n) || power_of_2?(n);
      ];

  // b_divide and b_remainder can be inlined with (negative) power of two
  divcst? = fn (v)
    match (mc:var_value(v))
      [
        {int} n => power_of_2?(n) || power_of_2?(-n);
      ];

  inline2? = fn (op, arg1, type1, arg2, type2)
    // Returns: True if op should be inlined on arg1, arg2
    if (op == mc:b_add)
      !(type1 & type2 & itype_string)
    else if (op == mc:b_shift_left || op == mc:b_shift_right)
      intcst?(arg1) || intcst?(arg2)
    else if (op == mc:b_ref) // may inline vector_ref or string_ref
      (type1 == itype_vector || type1 == itype_string
       || inline_bref?(type1, arg2))
    else if (op == mc:b_multiply)
      mulcst?(arg1) || mulcst?(arg2)
    else if (op == mc:b_divide || op == mc:b_remainder)
      divcst?(arg2)
    else
      !(op == mc:b_cons || op == mc:b_pcons);

  mgen_relop = fn (code, branch, r1, r2, d)
    [
      | tmpreg, dstreg, before, need_zero |

      need_zero = false;
      dstreg = reg_dest(d);

      before = fn (reg1, reg2)
        [
          tmpreg = dstreg;
          if (tmpreg == reg1 || tmpreg == reg2)
            [
              if (reg1 == reg_scratch2 || reg2 == reg_scratch2)
                exit<function> need_zero = true;
              tmpreg = reg_scratch2;
            ];
          // zero tmpreg without affecting the post-compare status flags
          x64:xor(code, x64:lreg, tmpreg, x64:lreg, tmpreg);
        ];

      branch = special_compare(code, r2, r1, branch, before);
      assert(tmpreg != null);   // before() must have been called

      if (need_zero)
        x64:mov(code, x64:limm, 0, x64:lreg, tmpreg);
      // sets the lowest byte in tmpreg
      x64:setcc(code, branch, x64:lreg, tmpreg);
      x64:lea32(code, x64:lridx, tmpreg . 1 . tmpreg . 1,
                x64:lreg, dstreg);
      safemove(code, x64:lreg, dstreg, x64:lvar, d, '[]);
    ];

  // tries to compute d = r1 +/- r2 using lea, where r1 or r2 is a
  // constant; returns true if successful
  leaaddcst = fn (code, r1, r2, d, subtract)
    [
      | cst |

      if (!mc:in_reg(d)) exit<function> false;

      if (!subtract && integer?(cst = mc:var_value(r1)))
	r1 = r2
      else if (!integer?(cst = mc:var_value(r2)))
	exit<function> false;

      if (!mc:in_reg(r1)) exit<function> false;
      r1 = mc:get_reg(r1);
      d = mc:get_reg(d);
      if (d == r1) exit<function> false;

      if (subtract) cst = -cst;
      if (!int31?(cst))
	exit<function> false;
      x64:lea(code, x64:lidx, r1 . (cst << 1), x64:lreg, d);
      true
    ];

  // return list of factors of n:
  //   9, 8, 5, 4, 3, 2
  //   or -n for other powers of 2: (1 << n),
  //   or (n . m) for multiply by n (a power of 2) and then add m
  // or null if we should use imul
  | multiply_factorize |
  multiply_factorize = fn (n, neg?)
    [
      assert(n > 0);

      | f, n2, n3, n5, pow2_delta, d |
      n2 = ffs(n) - 1;          // number of powers of 2
      n >>= n2;
      n3 = 0;                   // number of powers of 3
      while ((d = n / 3) * 3 == n)
        [
          ++n3;
          n = d;
        ];
      n5 = 0;                   // number of powers of 5
      while ((d = n / 5) * 5 == n)
        [
          ++n5;
          n = d;
        ];

      if (n >= 7 && (pow2_delta = vexists?(fn (add) [
        | p2 |
        p2 = n - add;
        p2 >= 8 && (p2 & (p2 - 1)) == 0
      ], '[ 1 -1 2 3 4 5 8 9 -2 -3 -4 -5 -8 -9])))
        [
          pow2_delta = ((n - pow2_delta) . pow2_delta);
          n = 1
        ];

      if (n != 1)
        // other prime factors than 2, 3, 5, and (2^n + m)
        exit<function> null;
      if (n5 + (n3 + 1) / 2 + (n2 > 0) + (pow2_delta != null)
          > (if (neg?) 2 else 3))
        // too expensive, use imul
        exit<function> null;

      while (--n5 >= 0)
        f = 5 . f;
      while (n3 >= 2)
        [
          f = 9 . f;
          n3 -= 2;
        ];
      if (n3)
        f = 3 . f;
      if (n2 >= 2 && n2 <= 3)
        [
          f = (1 << n2) . f;
          n2 = 0;
        ];
      // multiply by 2^n +/- m (m != +/- 1)
      if (pow2_delta != null && abs(cdr(pow2_delta)) != 1)
        [
          f = pow2_delta . f;
          pow2_delta = null;
        ];
      if (n2 > 0)
        [
          // try to shift (shl) or multiply by 2 (add) in the middle;
          // may save moves or explicit subs
          | e |
          e = if (n2 > 3) -n2 else (1 << n2);
          if (f != null && cdr(f) != null)
            set_cdr!(f, e . cdr(f))
          else
            f = e . f;
        ];
      // multiply by 2^n +/- 1 first, as it may save a move
      if (pow2_delta != null)
        f = pow2_delta . f;
      f
    ];

  | mgen_multiply |
  mgen_multiply = fn (code, r1, type1, c, d)
    [
      // multiply by constant (32-bit or a power of two)
      if (c >= -1 && c <= 1)
        [
          type_trap(code, type_integer, r1, type1);
          if (c == 0)
            move(code, x64:limm, mzero, x64:lvar, d)
          else if (c == 1)
            move(code, x64:lvar, r1, x64:lvar, d)
          else
            mgen_inline1(code, mc:b_negate, r1, type1, d);
          exit<function> null;
        ];

      | neg? |
      if (neg? = (c < 0))
        c = -c;

      | dr, factors |
      dr = reg_dest(d);
      if (c == minint)
        [
          neg? = false;
          factors = '(,(-(intbits - 1)))
        ]
      else
        [
          factors = multiply_factorize(c, neg?);
          if (factors == null)
            [
              assert(int32?(c));

              type_trap(code, type_integer, r1, type1);
              if (neg?)
                c = -c;
              x64:imul(code, x64:lvar, r1, x64:lreg, dr, x64:limm, c);
              --c;
              if (int32?(c))
                x64:sub(code, x64:limm, c, x64:lreg, dr)
              else
                [
                  x64:mov(code, x64:limm64, c, x64:lreg, reg_scratch2);
                  x64:sub(code, x64:lreg, reg_scratch2, x64:lreg, dr);
                ];
              exit<function> move(code, x64:lreg, dr, x64:lvar, d);
            ];
        ];

      | r |
      r = fetch2(code, r1);
      type_trap(code, type_integer, var_in_reg(r1, r), type1);

      | excess |
      excess = 1;
      while (factors != null)
        [
          | f, add, addmod, addreg |
          @(f . factors) = factors;

          add = 0;
          addmod = 0;
          if (pair?(f))
            [
              @(f . add) = f;
              assert(f & (f - 1) == 0);
              addreg = r;
              if (r == dr || (add != 1 && add != -1))
                [
                  // this shouldn't happen!
                  assert(dr != reg_scratch2 && r != reg_scratch2);
                  addreg = reg_scratch2;
                  if (factors == null)
                    [
                      addmod = -excess * (f + add);
                      addmod += (if (neg?) -1 else 1);
                    ];

                  | absadd |
                  absadd = add;
                  if (add < 0)
                    [
                      addmod = -addmod;
                      absadd = -add;
                    ];

                  if (absadd == 1)
                    if (addmod == 0)
                      move(code, x64:lreg, r, x64:lreg, addreg)
                    else
                      x64:lea(code, x64:lidx, r . addmod, x64:lreg, addreg)
                  else if (absadd == 2 || absadd == 4 || absadd == 8)
                    x64:lea(code, x64:lqidx, r . absadd . addmod,
                            x64:lreg, addreg)
                  else
                    x64:lea(code, x64:lridx, r . (absadd - 1) . r . addmod,
                            x64:lreg, addreg);
                ];

              if (f > 8)
                f = -(ffs(f) - 1)
            ];

          if (f < 0)
            [
              f = -f;
              | nexcess |
              nexcess = (excess << f) + excess * add;
              // make a subtraction here if it's worth it
              if (!int32?(c) && int32?(c >> f))
                [
                  assert(excess > 0 && excess < 0x7fffffff);
                  if (r != dr)
                    x64:lea(code, x64:lidx, r . -excess, x64:lreg, dr)
                  else
                    x64:sub(code, x64:limm, excess, x64:lreg, dr);
                  nexcess = 0;
                ]
              else
                move(code, x64:lreg, r, x64:lreg, dr);
              excess = nexcess;
              x64:shl(code, x64:limm, f, x64:lreg, dr);
            ]
          else
            [
              | mod |
              excess *= f + add;
              mod = 0;
              if (factors == null && addmod == 0)
                [
                  mod = (if (neg?) -1 else 1) - excess;
                  excess += mod;
                ];

              if (f == 2 && r == dr && mod == 0)
                x64:add(code, x64:lreg, r, x64:lreg, dr)
              else if (f == 2 || f == 3 || f == 5 || f == 9)
                x64:lea(code, x64:lridx, r . (f - 1) . r . mod, x64:lreg, dr)
              else if (f == 4 || f == 8)
                if (add > 0)
                  [
                    x64:lea(code, x64:lridx, r . f . addreg . mod,
                            x64:lreg, dr);
                    excess += addmod;
                    add = 0;
                  ]
                else
                  x64:lea(code, x64:lqidx, r . f . mod, x64:lreg, dr)
              else
                fail();
            ];

          if (add > 0)
            [
              excess += addmod;
              | mod |
              mod = (if (neg?) -1 else 1) - excess;
              if (factors == null && mod != 0)
                [
                  x64:lea(code, x64:lridx, dr . 1 . addreg . mod,
                          x64:lreg, dr);
                  excess += mod;
                ]
              else
                x64:add(code, x64:lreg, addreg, x64:lreg, dr);
            ]
          else if (add < 0)
            [
              x64:sub(code, x64:lreg, addreg, x64:lreg, dr);
              excess -= addmod
            ];

          r = dr;
        ];

      assert(r == dr);
      if (neg?)
        [
          x64:neg(code, x64:lreg, dr);
          excess = -excess;
        ];
      --excess;               // need one left
      if (excess == 0)
        null
      else if (excess == -1)
        x64:orbyte(code, x64:limm, 1, x64:lreg, dr)
      else
        [
          | op |
          op = if (excess < 0)
            [
              excess = -excess;
              x64:add
            ]
          else
            x64:sub;

          if (int32?(excess))
            op(code, x64:limm, excess, x64:lreg, dr)
          else
            [
              x64:mov(code, x64:limm64, excess, x64:lreg, reg_scratch2);
              op(code, x64:lreg, reg_scratch2, x64:lreg, dr);
            ];
        ];
      move(code, x64:lreg, dr, x64:lvar, d);
    ];

  | mgen_divide |
  mgen_divide = fn (code, r1, type1, r2, type2, d)
    [
      | c, neg? |
      c = mc:var_value(r2);
      if (c == MININT)
        [
          type_trap(code, type_integer, r1, type1);
          // equivalent to r1 == minint
          exit<function> mgen_relop(code, x64:be, r1, r2, d);
        ];

      if (c == 1)
        [
          type_trap(code, type_integer, r1, type1);
          exit<function> move(code, x64:lvar, r1, x64:lvar, d);
        ];

      if (c == -1)
        [
          type_trap(code, type_integer, r1, type1);
          exit<function> mgen_inline1(code, mc:b_negate, r1, itype_any, d)
        ];

      if (neg? = c < 0)
        c = -c;

      | dr, sr, wr |
      wr = dr = reg_dest(d);
      if (mc:in_reg(r1))
        [
          sr = mc:get_reg(r1);
          if (sr == dr)
            wr = if (dr == reg_scratch) reg_scratch2 else reg_scratch
        ]
      else
        sr = (if (dr == reg_scratch) fetch1 else fetch2)(code, r1);

      assert(sr != wr);

      type_trap(code, type_integer, var_in_reg(r1, sr), type1);

      | bits |
      bits = ffs(c) - 1;

      // For negative integers we need to shift (n + c - 1), so we add
      // (n + c - 1) * 2 - (n * 2 + 1) = (c * 2 - 3) before shifting
      if (c == 2)
        [
          x64:mov(code, x64:lreg, sr, x64:lreg, wr);
          // Special case as c * 2 - 3 == 1
          x64:shr(code, x64:limm, word_size * 8 - 1, x64:lreg, dr);
          // 'dr' is now 0 for non-negative; 1 for negative
          x64:add(code, x64:lreg, if (wr == dr) sr else wr, x64:lreg, dr);
        ]
      else
        [
          c = c * 2 - 3;
          if (int32?(c))
            x64:lea(code, x64:lidx, sr . c, x64:lreg, wr)
          else
            [
              x64:mov(code, x64:limm64, c, x64:lreg, wr);
              x64:add(code, x64:lreg, sr, x64:lreg, wr);
            ];
          x64:test(code, x64:lreg, sr, x64:lreg, sr);
          if (wr == dr)
            x64:cmovcc(code, x64:bns, x64:lreg, sr, x64:lreg, dr)
          else
            x64:cmovcc(code, x64:bs, x64:lreg, wr, x64:lreg, dr)
        ];

      x64:sar(code, x64:limm, bits, x64:lreg, dr);
      x64:orbyte(code, x64:limm, 1, x64:lreg, dr);

      if (neg?)
        mgen_inline1(code, mc:b_negate, var_in_reg(d, dr), itype_any, d)
      else
        move(code, x64:lreg, dr, x64:lvar, d)
    ];

  | mgen_remainder |
  mgen_remainder = fn (code, r1, type1, r2, type2, d)
    [
      | c |
      c = mc:var_value(r2);
      if (c == 1 || c == -1)
        [
          // n % +/-1 = 0
          type_trap(code, type_integer, r1, type1);
          exit<function> move(code, x64:limm, x64:mudlleint(0), x64:lvar, d);
        ];

      | dr, sr |
      dr = reg_dest(d);
      if (mc:in_reg(r1))
        [
          sr = mc:get_reg(r1);
          if (sr == dr)
            dr = if (sr == reg_scratch) reg_scratch2 else reg_scratch;
          move(code, x64:lvar, r1, x64:lreg, sr);
        ]
      else
        sr = (if (dr == reg_scratch) fetch1 else fetch2)(code, r1);

      assert(sr != dr);
      type_trap(code, type_integer, var_in_reg(r1, sr), type1);

      if (c == MININT)
        [
          // dr = if (sr == MININT) 0 else sr
          x64:mov(code, x64:limm64, x64:mudlleint(MININT), x64:lreg, dr);
          x64:cmp(code, x64:lreg, sr, x64:lreg, dr);
          | zr |
          if (dr == reg_scratch2)
            [
              assert(sr == reg_scratch);
              zr = dr;
              dr = reg_scratch;
            ]
          else
            [
              x64:mov(code, x64:lreg, sr, x64:lreg, dr);
              zr = if (dr == reg_scratch) reg_scratch2 else reg_scratch;
            ];
          x64:mov(code, x64:limm, x64:mudlleint(0), x64:lreg, zr);
          x64:cmovcc(code, x64:be, x64:lreg, zr, x64:lreg, dr);
          move(code, x64:lreg, dr, x64:lvar, d);
          exit<function> null;
        ];

      c = abs(c);               // remainder is the same for +/- 2^k

      // given sr = 2 * n + 1, we want this:
      //   if sr >= 0
      //     dr = sr & (2*c - 1)
      //   else
      //     dr = ((sr + 2*c - 3) & (2*c - 1)) - (2*c - 3)
      // which gives:
      //   tr = (sr sar 63) & (2*c - 3)
      //   dr = ((sr + tr) & (2*c - 1)) - tr

      | tr |
      tr = reg_arg0;

      x64:mov(code, x64:lreg, sr, x64:lreg, tr);
      if (c == 2)
        // (sr sar 63) & (2*c - 3) = (sr sar 63) & 1 = sr shr 63
        x64:shr(code, x64:limm, word_size * 8 - 1, x64:lreg, tr)
      else
        [
          x64:sar(code, x64:limm, word_size * 8 - 1, x64:lreg, tr);
          // 2*c - 3 = 2*(c - 2) + 1 = x64:mudlleint(c - 2)
          if (int31?(c - 2) || uint31?(c - 2))
            x64:and(code, x64:limm, x64:mudlleint(c - 2), x64:lreg, tr)
          else
            [
              x64:mov(code, x64:limm64, x64:mudlleint(c - 2), x64:lreg, dr);
              x64:and(code, x64:lreg, dr, x64:lreg, tr);
            ];
        ];
      // dr = sr + tr
      if (dr == reg_scratch2)
        [
          assert(sr == reg_scratch);
          dr = reg_scratch;
          x64:add(code, x64:lreg, tr, x64:lreg, dr);
        ]
      else
        x64:lea(code, x64:lridx, sr . 1 . tr . 0, x64:lreg, dr);
      // dr = dr & (2*c - 1) = dr & (2*(c - 1) + 1)
      if (int31?(c - 1) || uint31?(c - 1))
        x64:and(code, x64:limm, x64:mudlleint(c - 1), x64:lreg, dr)
      else
        [
          | mr |
          mr = if (dr == reg_scratch) reg_scratch2 else reg_scratch;
          x64:mov(code, x64:limm64, x64:mudlleint(c - 1), x64:lreg, mr);
          x64:and(code, x64:lreg, mr, x64:lreg, dr);
        ];
      // dr = dr - tr
      x64:sub(code, x64:lreg, tr, x64:lreg, dr);
      move(code, x64:lreg, dr, x64:lvar, d)
    ];

  | vmodval_lhs, vmodval_rhs, vmodval_dest |
  vmodval_lhs  = 0;
  vmodval_rhs  = 1;
  vmodval_dest = 2;

  | default_mod_op |
  default_mod_op = fn (code, commute, op, stype, src, dtype, dest, mod_vals)
    [
      op(code, stype, src, dtype, dest);
      if (mod_vals != null)
        match! (mod_vals[vmodval_dest])
          [
            -1 => x64:dec(code, dtype, dest);
            1 => x64:inc(code, dtype, dest);
          ];
    ];

  | mgen_iadd |
  mgen_iadd = fn (code, r1, r2, d)
    if (leaaddcst(code, r1, r2, d, false))
      null
    else if (mc:in_reg(r1) && mc:in_reg(r2))
      [
        | dr |

        dr = reg_dest(d);
        x64:lea(code, x64:lridx,
                mc:get_reg(r1) . 1 . mc:get_reg(r2) . -1,
                x64:lreg, dr);
        move(code, x64:lreg, dr, x64:lvar, d);
      ]
    else
      [
        | lea_add |
        lea_add = fn (code, commute, op, stype, src, dtype, dest, mod_vals)
          [
            assert(op == x64:add);
            if (stype == x64:lreg && dtype == x64:lreg && mod_vals != null)
              x64:lea(code, x64:lridx, src . 1 . dest . mod_vals[vmodval_dest],
                      x64:lreg, dest)
            else
              default_mod_op(code, commute, op, stype, src, dtype, dest,
                             mod_vals)
          ];

        perform3(code, r1, r2, d, x64:add, x64:add, lea_add, '[-1 -1 -1]);
      ];

  | mgen_shift |
  mgen_shift = fn (code, r1, r2, type2, d, left?)
    [
      // must not use scratch
      assert(intcst?(r1));
      | v1, dr |
      v1 = r1[mc:v_kvalue];
      dr = reg_dest(d);
      if (dr != x64:reg_rcx)
        x64:mov(code, x64:lreg, x64:reg_rcx, x64:lreg, reg_scratch2)
      else
        dr = reg_scratch2;
      move(code, x64:lvar, r2, x64:lreg, x64:reg_rcx);
      x64:sar(code, x64:limm, 1, x64:lreg, x64:reg_rcx);
      if (type2 & ~itype_integer)
        x64:trap(code, x64:bae, error_bad_type,
                 vector(TSET_INT, -1, trap_mv_double,
                        var_in_reg(r2, x64:reg_rcx)));
      x64:mov(code,
              if (int31?(v1)) x64:limm else x64:limm64, x64:doubleint(v1),
              x64:lreg, dr);
      (if (left?) x64:shl else x64:sar)(
        code, x64:lreg, x64:reg_rcx, x64:lreg, dr);
      if (dr != reg_scratch2)
        x64:mov(code, x64:lreg, reg_scratch2, x64:lreg, x64:reg_rcx);
      x64:orbyte(code, x64:limm, 1, x64:lreg, dr);
      move(code, x64:lreg, dr, x64:lvar, d);
    ];

  | call_builtin2 |
  call_builtin2 = fn (code, name, arg0, arg1, dest)
    [
      callop2(code, name, arg0, arg1);
      move(code, x64:lreg, reg_result, x64:lvar, dest);
    ];

  | shift_mask |
  shift_mask = ((word_size * 8) - 1); // bits used in shift left/right

  mgen_inline2 = fn (code, op, r1, type1, r2, type2, d, ins)
    // Effects: Generates code for d = r1 op r2
    //   type1 & type2 are provided to help generate code for polymorphic ops
    //   r1, r2, d are variables
    if (op >= mc:b_eq && op <= mc:b_gt)
      mgen_relop(code, relops[op + (mc:branch_eq - mc:b_eq)], r1, r2, d)
    else if (op == mc:b_bitor)
      perform3(code, r1, r2, d, x64:or, x64:or, null, null)
    else if (op == mc:b_bitand)
      [
        <normal> if (intcst?(r2))
          [
            | i, movop |
            i = r2[mc:v_kvalue];
            movop = if (i == 0x7f)
              x64:movzxbyte
            else if (i == 0x7fff)
              x64:movzxword
            else if (i == 0x7fffffff)
              x64:movzx32
            else
              exit<normal> null;

            | r, dr |
            r = fetch_for_dest(code, r1, d);
            dr = reg_dest(d);
            movop(code, x64:lvar, r, x64:lreg, dr);
            exit<function> move(code, x64:lreg, dr, x64:lvar, d);
          ];

        perform3(code, r1, r2, d, x64:and, x64:and, null, null)
      ]
    else if (op == mc:b_bitxor)
      perform3(code, r1, r2, d, x64:xor, x64:xor, null, '[-1 -1 1])
    else if (op == mc:b_logical_xor)
      [
        | dstreg, tmpreg |
        dstreg = reg_dest(d);
        tmpreg = mgen_xor(code, r1, r2, dstreg, false);
        if (tmpreg == null)
          move(code, x64:limm, mfalse, x64:lvar, d)
        else
          [
            x64:lea32(code, x64:lridx, tmpreg . 1 . tmpreg . 1,
                      x64:lreg, dstreg);
            move(code, x64:lreg, dstreg, x64:lvar, d);
          ];
      ]
    else if (op == mc:b_shift_left)
      [
        if (intcst?(r1))
          // must not use scratch
          exit<function> mgen_shift(code, r1, r2, type2, d, true);

        assert(intcst?(r2));
        mgen_multiply(
          code, r1, type1, 1 << (r2[mc:v_kvalue] & shift_mask), d)
      ]
    else if (op == mc:b_shift_right)
      [
        // must not use scratch
        if (intcst?(r1))
          exit<function> mgen_shift(code, r1, r2, type2, d, false);

        assert(intcst?(r2));
        | i |
        i = r2[mc:v_kvalue] & shift_mask;
        safemove(code, x64:lvar, r1, x64:lvar, d, regs_scratch2);
        if (i != 1)
          type_trap(code, type_integer, d, type1);
        if (i != 0)
          [
            x64:sar(code, x64:limm, i, x64:lvar, d);
            if (i == 1 && (type1 & ~itype_integer))
              // trap unless CF
              x64:trap(code, x64:bae, error_bad_type,
                       vector(TSET_INT, -1, trap_mv_double, d));
            x64:orbyte(code, x64:limm, 1, x64:lvar, d);
          ]
      ]
    else if (op == mc:b_multiply) // integer multiply with constant
      [
        if (intcst?(r2))
          mgen_multiply(code, r1, type1, r2[mc:v_kvalue], d)
        else
          [
            assert(intcst?(r1));
            mgen_multiply(code, r2, type2, r1[mc:v_kvalue], d)
          ]
      ]
    else if (op == mc:b_divide) // integer divide by constant
      mgen_divide(code, r1, type1, r2, type2, d)
    else if (op == mc:b_remainder) // integer remainder by constant
      mgen_remainder(code, r1, type1, r2, type2, d)
    else if (op == mc:b_add || op == mc:b_iadd) // integer addition only
      [
        if (op == mc:b_add)
          [
            type_trap(code, type_integer, r1, type1);
            type_trap(code, type_integer, r2, type2);
          ];

        mgen_iadd(code, r1, r2, d)
      ]
    else if (op == mc:b_subtract)
      [
        | cst2 |
        if (integer?(cst2 = mc:var_value(r2)) && !int31?(cst2))
          // avoid move + neg for imm64 constants
          exit<function> mgen_iadd(code, r1, mc:var_make_constant(-cst2), d);

        | commute_sub, lea_sub |
        commute_sub = fn (code, m1, a1, m2, a2)
          [
            assert(m2 == x64:lreg);
            // dst = dst - dst case is always handled by lea_sub()
            assert(!(m1 == x64:lreg && a1 == a2));

            x64:neg(code, m2, a2);
            x64:add(code, m1, a1, m2, a2);
          ];

        lea_sub = fn (code, commute, op, stype, src, dtype, dest, mod_vals)
          [
            if (commute && stype == x64:lreg && mod_vals != null)
              [
                assert(dtype == x64:lreg); // required by 'commute'
                x64:neg(code, dtype, dest);
                x64:lea(code, x64:lridx,
                        src . 1 . dest . mod_vals[vmodval_dest],
                        x64:lreg, dest)
              ]
            else
              default_mod_op(code, commute, op, stype, src, dtype, dest,
                             mod_vals)
          ];
	if (!leaaddcst(code, r1, r2, d, true))
	  perform3(code, r1, r2, d, x64:sub, commute_sub, lea_sub, '[1 -1 1]);
      ]
    else if (op == mc:b_ref)
      [
        // must not use scratch if inline_bref?()
	| c |
	c = mc:var_value(r2);

	if (!(type1 & itype_string)) // vector
	  [
	    if (integer?(c) && c >= 0 && c < MAX_VECTOR_SIZE)
	      [
                | reg1 |
                r1 = fetch_for_dest(code, r1, r1);
                reg1 = mc:get_reg(r1);
                type_trap(code, type_vector, r1, type1 & ~itype_null);

                | unsafe? |
                unsafe? = c >= ins[mc:i_asizeinfo];
		c = word_size * c + x64:object_offset;
                if (unsafe?)
                  [
                    assert(int31?(c));
                    x64:cmp(code, x64:limm, c,
                            x64:lidx, reg1 . x64:object_size);
                    x64:trap(code, x64:bbe, error_bad_index, null);
                  ];
		safemove(code, x64:lidx, reg1 . c, x64:lvar, d, regs_scratch2);
	      ]
	    else
              [
                assert(!inline_bref?(type1, r2));
                if (type1 & ~(itype_null | itype_integer | itype_vector))
                  r1 = fetch_for_dest(code, r1, r1);
                type_trap(code, type_vector, r1, type1 & ~itype_null);
                call_builtin2(code, "bvref", r1, r2, d)
              ]
	  ]
	else if (!(type1 & itype_vector)) // string
	  [
	    if (integer?(c) && c >= 0 && c < MAX_STRING_SIZE)
	      [
                | reg1 |
                r1 = fetch_for_dest(code, r1, r1);
                reg1 = mc:get_reg(r1);
                type_trap(code, type_string, r1, type1 & ~itype_null);

                | unsafe? |
                unsafe? = c >= ins[mc:i_asizeinfo];
		c += x64:object_offset;
                if (unsafe?)
                  [
                    assert(int31?(c + 1));
                    x64:cmp(code, x64:limm, c + 1, x64:lidx,
                            reg1 . x64:object_size);
                    x64:trap(code, x64:bbe, error_bad_index, null);
                  ];

                | dr |
                dr = reg_dest(d);
		x64:movzxbyte(code, x64:lidx, reg1 . c, x64:lreg, dr);

                x64:lea32(code, x64:lridx, dr . 1 . dr . 1, x64:lreg, dr);
                safemove(code, x64:lreg, dr, x64:lvar, d, regs_scratch2);
	      ]
	    else
              [
                assert(!inline_bref?(type1, r2));
                if (type1 & ~(itype_null | itype_integer | itype_string))
                  r1 = fetch_for_dest(code, r1, r1);
                type_trap(code, type_string, r1, type1 & ~itype_null);
                call_builtin2(code, "bsref", r1, r2, d)
              ]
	  ]
	else fail()
      ]
    else fail();

  | args_immutable? |
  args_immutable? = fn (list args, {list,int} types)
    loop
      [
        if (args == null) exit true;

        | t, arg |
        @(arg . args) = args;
        if (types)
          @(t . types) = types
        else
          t = get_type(arg);

        if ((t & ~immutable_itypes) != 0
            && arg[mc:v_class] != mc:v_constant)
          exit false;
      ];

  mgen_compute = fn (code, ins)
    [
      | args, arg1, arg2, op, dest, types, type1, type2 |

      op = ins[mc:i_aop];
      dest = ins[mc:i_adest];
      args = ins[mc:i_aargs];
      types = ins[mc:i_atypes];
      if (args != null)
	[
	  arg1 = car(args);
	  if (!types) type1 = get_type(arg1)
	  else type1 = car(types);

	  if (cdr(args) != null)
	    [
	      arg2 = cadr(args);
	      if (!types) type2 = get_type(arg2)
	      else type2 = cadr(types);
	    ]
	];

      if (op == mc:b_assign)
        safemove(code, x64:lvar, arg1, x64:lvar, dest,
                 if (assign_src_uses_scratch?(arg1)) regs_scratch
                 else regs_scratch2)
      else if (op == mc:b_loop_count)
        [
          | dr |
          dr = reg_dest(dest);
          x64:mov(code, x64:lbuiltin, "xcount", x64:lreg, dr);
          x64:mov(code, x64:lidx, dr . 0, x64:lreg, dr);
          x64:lea(code, x64:lridx, dr . 1 . dr . 1, x64:lreg, dr);
          move(code, x64:lreg, dr, x64:lvar, dest);
        ]
      else if (op == mc:b_max_loop_count)
        [
          | dr |
          dr = reg_dest(dest);
          x64:mov(code, x64:lbuiltin, "max_loop_count", x64:lreg, dr);
          move(code, x64:lreg, dr, x64:lvar, dest);
        ]
      else if (op == mc:b_vector || op == mc:b_sequence)
	[
          | nargs |
          nargs = llength(args);
          move(code, x64:limm, word_size * nargs + x64:object_offset,
               x64:lreg, reg_arg0);
	  call_builtin(code, "balloc_vector");

          lreduce(fn (arg, ofs) [
            assert(!in_scratch?(arg));
            safemove(code, x64:lvar, arg,
                     x64:lidx, reg_result . x64:object_offset + ofs,
                     regs_scratch2);
            ofs + word_size
          ], 0, args);

          if (op == mc:b_sequence)
            [
              | flags |
              flags = if (args_immutable?(args, types))
                MUDLLE_READONLY | MUDLLE_IMMUTABLE
              else
                MUDLLE_READONLY;
              x64:orbyte(code, x64:limm, flags, x64:lidx,
                         reg_result . x64:object_flags);
            ];
	  move(code, x64:lreg, reg_result, x64:lvar, dest);
	]
      else if (arg2 == null)	// 1-argument ops
        [
          if (op == mc:b_car || op == mc:b_cdr
              || op == mc:b_symbol_name
              || op == mc:b_symbol_get
              || op == mc:b_slength
              || op == mc:b_vlength)
            [
              // will cause error later on otherwise
              type1 &= ~itype_null;
              arg1 = fetch_for_dest(code, arg1, dest);
            ];
          type_trap(code, typearg1[op], arg1, type1);
          mgen_inline1(code, op, arg1, type1, dest);
          ++mc:nops_inlined;
        ]
      else // 2-argument ops
	if (inline2?(op, arg1, type1, arg2, type2))
	  [
	    type_trap(code, typearg1[op], arg1, type1);
	    type_trap(code, typearg2[op], arg2, type2);
	    mgen_inline2(code, op, arg1, type1, arg2, type2, dest, ins);
	    ++mc:nops_inlined;
	  ]
	else
	  [
	    ++mc:nops_called;
            if (op == mc:b_cons || op == mc:b_pcons)
              [
                // cons takes arguments in reverse order; optimize
                // for cons(x, cons(...))
                | t |
                t = arg1;
                arg1 = arg2;
                arg2 = t;
              ];

	    callop2(code, builtins[op], arg1, arg2);
	    move(code, x64:lreg, reg_result, x64:lvar, dest);
	  ]
    ];

  mgen_memory = fn (code, ins)
    [
      | array, areg, scalar, offset |

      array = ins[mc:i_marray];
      scalar = ins[mc:i_mscalar];
      offset = x64:object_offset + word_size * ins[mc:i_mindex];

      areg = fetch1(code, array);

      if (ins[mc:i_mop] == mc:memory_read)
        // must not use scratch register
	safemove(code, x64:lidx, areg . offset, x64:lvar, scalar,
                 regs_scratch2)
      else
        [
          if (ins[mc:i_mop] == mc:memory_write_safe)
            [
              x64:test(code, x64:limm, MUDLLE_READONLY,
                       x64:lidx, areg . x64:object_flags);
              x64:trap(code, x64:bne, error_value_read_only, null);
            ];
          // write - note: reg_scratch may be in use, allow reg_scratch2 too
          safemove(code, x64:lvar, scalar,
                   x64:lidx, areg . offset, regs_allscratch);
        ];
    ];

  mgen_closure = fn (code, ins)
    [
      | cvars, f, offset, cdest |

      f = ins[mc:i_ffunction];
      cvars = lfilter(fn (cvar) cvar[mc:v_cparent] != mc:myself,
		      f[mc:c_fclosure]);

      cdest = ins[mc:i_fdest];

      if (cvars == null)
        [
          move(code, x64:lclosure, f, x64:lvar, cdest);
          exit<function> null;
        ];

      move(code, x64:limm,
           word_size * (1 + llength(cvars)) + x64:object_offset,
	   x64:lreg, reg_arg0);
      call_builtin(code, "balloc_closure");
      safemove(code, x64:lfunction, f,
               x64:lidx, reg_result . x64:object_offset,
               regs_scratch2);
      offset = x64:object_offset + word_size;
      while (cvars != null)
	[
	  | cvar |

	  cvar = car(cvars)[mc:v_cparent];
	  if (cvar == cdest) // place ourselves in closure
	    move(code, x64:lreg, reg_result, x64:lidx, reg_result . offset)
	  else
            [
              assert(!in_scratch?(cvar));
              safemove(code, x64:lvar, cvar, x64:lidx, reg_result . offset,
                       regs_scratch2);
            ];
	  offset += word_size;
	  cvars = cdr(cvars);
	];
      move(code, x64:lreg, reg_result, x64:lvar, cdest);
    ];

  // Push arguments on the stack, in reverse order
  push_args_unaligned = fn (code, args)
    lforeach(fn (v) x64:push(code, x64:lvar, v), lreverse(args));

  push_args = fn (code, int nargs, args)
    [
      if ((nargs + stack_frame_size) & 1)
        x64:push(code, x64:limm, 0);
      push_args_unaligned(code, args);
    ];

  move_native_args = fn (code, int nargs, args)
    [
      // move registers around to their right places
      | simple, regv |

      lforeachi(fn (didx, arg) [
        | reg, type, loc |
        @(type . loc) = x64:resolve(x64:lvar, arg);
        reg = match (type)
          [
            ,x64:lreg => [
              if (loc == regs_native_args[didx])
                // already in its correct place
                exit<function> null;
              loc
            ];
            ,x64:lqidx => car(loc);
            ,x64:lridx => fail();
            _ => null
          ];

        | regidx, this |
        regidx = vector_index(reg, regs_native_args);
        this = vector(didx, reg, type, loc);
        if (regidx >= 0 && regidx < nargs)
          [
            assert(type == x64:lreg);
            if (regv == null)
              regv = make_vector(nargs);
            | old |
            old = regv[regidx];
            if (old != null)
              [
                // the same value is being copied to several args
                this[3] = regs_native_args[old[0]];
                simple = this . simple
              ]
            else
              regv[regidx] = this;
          ]
        else
          simple = this . simple
      ], args);

      if (regv != null)
        loop <again> [
          | xchg, again? |
          again? = false;
          for (|i| i = 0; i < nargs; ++i)
            [
              | this, didx, type, loc |
              this = regv[i];
              if (this == null) exit<continue> null;
              @[didx _ type loc] = this;
              if (regv[didx] == null)
                [
                  move(code, type, loc, x64:lreg, regs_native_args[didx]);
                  regv[i] = null;
                  again? = true;
                ]
              else
                xchg = i;
            ];
          if (again?)
            exit<again> null;

          if (xchg == null)
            exit null;

          | other, tloc, tdidx, oloc |
          @[tdidx _ ,x64:lreg tloc] = regv[xchg];
          @[_ _ ,x64:lreg oloc] = other = regv[tdidx];
          x64:xchg(code, x64:lreg, tloc, x64:lreg, oloc);
          regv[tdidx] = null;
          if (tloc == regs_native_args[xchg])
            regv[xchg] = null
          else
            [
              other[3] = tloc;
              regv[xchg] = other
            ];
        ];

      lforeach(fn (@[didx _ type loc]) [
        // move the remaining arguments into place
        move(code, type, loc, x64:lreg, regs_native_args[didx]);
      ], simple);
    ];

  call_primitive = fn (code, called, prim, int nargs, args)
    [
      move_native_args(code, nargs, args);
      | flags, call |
      flags = primitive_flags(prim);
      // Save stack frame address (for GC and call traces)
      x64:mov(code, x64:lprimitive, called[mc:v_name],
              x64:lreg, reg_closure_in);
      call = if (flags & OP_NOALLOC) "bcall_prim_noalloc" else "bcall_prim";
      call_builtin(code, call);
    ];

  call_closure = fn (code, called, nargs, f)
    [
      if (called[mc:v_class] == mc:v_function)
        move(code, x64:lcalled, called[mc:v_fvalue], x64:lreg, reg_scratch2)
      else if (closure?(f) && (closure_flags(f) & clf_noclosure))
        [
          assert(called[mc:v_class] == mc:v_global_constant);
          move(code, x64:limm, nargs, x64:lreg, reg_argcount);
          x64:call(code, x64:lcalled_global, called[mc:v_name], false);
          exit<function> null;
        ]
      else
        [
          move(code, x64:lvar, called, x64:lreg, reg_closure_in);
          move(code, x64:lidx, reg_closure_in . x64:object_offset,
               x64:lreg, reg_scratch2);
          x64:add(code, x64:limm, x64:mcode_code_offset,
                  x64:lreg, reg_scratch2);
        ];
      move(code, x64:limm, nargs, x64:lreg, reg_argcount);
      x64:call(code, x64:lreg, reg_scratch2, false);
    ];

  call = fn (code, called, nargs, callprimop, seclev?)
    [
      // update find_mcode() in error.c if these instructions change
      move(code, x64:lvar, called, x64:lreg, reg_closure_in);
      move(code, x64:limm, nargs, x64:lreg, reg_argcount);
      if (seclev?)
        set_seclev(code, reg_arg5, x64:sl_c);
      call_builtin(code, callprimop);
      true
    ];

  call_varargs = fn (code, called, func, args, dest)
    [
      | nargs, nfixed, vecargs |

      nargs = llength(args);
      nfixed = ~primitive_nargs(func);

      vecargs = nth_pair(nfixed + 1, args);

      if (nargs > nfixed
          && lforall?(fn (v) v[mc:v_class] == mc:v_constant, vecargs))
        [
          // all arguments that go into the argument vector are constant
          | argv |
          argv = check_immutable(protect(
            list_to_vector(lmap(fn (v) v[mc:v_kvalue], vecargs))));
          assert(immutable?(argv));
          argv = mc:var_make_constant(argv);

          | effargs |
          for (|i, a|[ i = 0; a = args ]; i < nfixed; [ ++i; a = cdr(a) ])
            effargs = car(a) . effargs;

          effargs = lreverse!(argv . effargs);

          push_args(code, nfixed + 1, effargs);
          move(code, x64:lprimop, called[mc:v_name], x64:lreg, reg_arg0);
          set_seclev(code, reg_arg2, x64:sl_c);
          call_builtin(code, "bapply_varargs");
          pop_args(code, nfixed + 1);
          move(code, x64:lreg, reg_result, x64:lvar, dest);

          exit<function> true;
        ];

      push_args(code, nargs, args);
      move(code, x64:lprimop, called[mc:v_name], x64:lreg, reg_arg0);
      move(code, x64:limm, nargs, x64:lreg, reg_arg1);
      set_seclev(code, reg_arg2, x64:sl_c);
      call_builtin(code, "bcall_varargs");
      pop_args(code, nargs);
      move(code, x64:lreg, reg_result, x64:lvar, dest);
    ];

  | call_vcopy |
  call_vcopy = fn (code, arg, dest)
    [
      move(code, x64:lvar, arg, x64:lreg, reg_arg0);
      call_builtin(code, "bvcopy");
      move(code, x64:lreg, reg_result, x64:lvar, dest);
    ];

  call_bconcat = fn (code, args, dest)
    [
      | nargs |
      args = lfilter(fn (v) !equal?(mc:var_value(v), ""), args);
      nargs = llength(args);
      if (nargs <= 2)
        [
          | a1, a2 |
          a1 = a2 = cemptystr;
          // unpack items 1 and 2 if available
          @(() || (a1 . (() || (a2)))) = args;
          callop2(code, builtins[mc:b_add], a1, a2);
        ]
      else
        [
          push_args_unaligned(code, args);
          move(code, x64:limm, nargs, x64:lreg, reg_arg0);
          call_builtin(code, "bconcat");
          pop_args_unaligned(code, nargs);
        ];
      move(code, x64:lreg, reg_result, x64:lvar, dest);
    ];

  call_kset = fn (code, args, dest, types, sizeinfo)
    [
      | obj, idx, nidx, val, type1 |
      @(obj idx val) = args;

      if (!(types
            && ((type1 = car(types = cdr(types))) == itype_vector
                || type1 == itype_string)
            && integer?(nidx = mc:var_value(idx))
            && nidx >= 0 && nidx < sizeinfo))
        [
          callop3(code, "bset", obj, idx, val);
          move(code, x64:lreg, reg_result, x64:lvar, dest);
          exit<function> null;
        ];

      | robj |
      if (mc:get_reg(val) == reg_scratch)
        robj = fetch1(code, obj)
      else
        robj = fetch2(code, obj);
      // robj == mc:get_reg(val) is possible for obj[idx] = obj

      x64:test(code, x64:limm, MUDLLE_READONLY,
               x64:lidx, robj . x64:object_flags);
      x64:trap(code, x64:bne, error_value_read_only, null);

      if (type1 == itype_vector)
        [
          | vtype, vloc |
          @(vtype . vloc) = x64:resolve(x64:lvar, val);
          if (vtype != x64:limm && vtype != x64:lreg)
            [
              // cannot move directly to indexed destination
              if (mc:in_reg(dest) && robj != mc:get_reg(dest))
                move(code, x64:lvar, val, vtype = x64:lvar, vloc = dest)
              else
                [
                  vtype = x64:lreg;
                  vloc = if (robj == reg_scratch)
                    fetch1(code, val)
                  else
                    fetch2(code, val);
                ];
            ];
          nidx = nidx * word_size + x64:object_offset;
          x64:mov(code, vtype, vloc, x64:lidx, robj . nidx);
          move(code, vtype, vloc, x64:lvar, dest);
          exit<function> null;
        ];

      // it's a string
      nidx += x64:object_offset;

      if (intcst?(val))
        [
          | c |
          c = val[mc:v_kvalue] & 255;
          x64:movbyte(code, x64:limm, c, x64:lidx, robj . nidx);
          x64:mov(code, x64:limm, x64:mudlleint(c), x64:lvar, dest);
          exit<function> null;
        ];

      | rval |
      rval = fetch1(code, val);

      // make sure we have a register that isn't GC-protected as it
      // will end up with a non-mudlle value
      if (!vfind?(rval, regs_allscratch))
        [
          | nr |
          nr = if (robj == reg_scratch) reg_scratch2 else reg_scratch;
          move(code, x64:lreg, rval, x64:lreg, nr);
          rval = nr
        ];

      val = var_in_reg(val, rval);
      type_trap(code, type_integer, val, caddr(types));

      assert(rval != robj);

      | rdest |
      rdest = reg_dest(dest);

      x64:shr(code, x64:limm, 1, x64:lreg, rval);
      x64:movbyte(code, x64:lreg, rval, x64:lidx, robj . nidx);
      x64:movzxbyte(code, x64:lreg, rval, x64:lreg, rdest);
      x64:lea32(code, x64:lridx, rdest . 1 . rdest . 1, x64:lreg, rdest);
      move(code, x64:lreg, rdest, x64:lvar, dest);
    ];

  call_seclevel = fn (code, dest, type)
    [
      | dreg |
      dreg = reg_dest(dest);
      set_seclev(code, dreg, type);
      move(code, x64:lreg, dreg, x64:lvar, dest);
    ];

  maybe_call_global_lookup = fn (code, arg, dest)
    [
      | val |
      if (!string?(val = mc:var_value(arg)))
        exit<function> false;
      move(code, x64:lglobal_index, val . x64:gl_mudlle, x64:lvar, dest);
      exit<function> true;
    ];

  mgen_call = fn (code, ins)
    [
      | args, nargs, called, dest |

      args = ins[mc:i_cargs];
      called = car(args);
      args = cdr(args);
      nargs = llength(args);
      dest = ins[mc:i_cdest];

      if (called == kset)
        [
          if (nargs == 3)
            exit<function> call_kset(code, args, dest, ins[mc:i_ctypes],
                                     ins[mc:i_csizeinfo]);
        ]
      else if (called == kseclevel)
        [
          if (nargs == 0)
            exit<function> call_seclevel(code, dest, x64:sl_mudlle);
        ]
      else if (called == kmaxseclevel)
        [
          if (nargs == 0)
            [
              | dreg |
              dreg = reg_dest(dest);
              move(code, x64:lbuiltin, "maxseclevel", x64:lreg, dreg);
              move(code, x64:lidx, dreg . 0, x64:lvar, dest);
              exit<function> null;
            ]
        ]
      else if (called == kglobal_lookup)
        [
          if (nargs == 1
              && maybe_call_global_lookup(code, car(args), dest))
            exit<function> null;
        ]
      else if (called == ksconcat)
        exit<function> call_bconcat(code, args, dest)
      else if (called == kvcopy && nargs == 1)
        exit<function> call_vcopy(code, car(args), dest)
      else if (called == kprotect && nargs == 1)
        <skip> [
          | type, lab, arg, reg, types |
          @(arg) = args;
          types = ins[mc:i_ctypes];
          type = if (types) cadr(types) else get_type(arg);

          // ports and tables need special handling
          if (type & (itype_other | itype_table))
            exit<skip> null;

          arg = fetch_for_dest(code, arg, dest);
          reg = mc:get_reg(arg);
          if (type & (itype_null | itype_integer | itype_string))
            [
              // avoid static values: null, integer, and static strings
              lab = x64:new_label(code);
              if (type & itype_null)
                type_branch(code, type_null, false, arg, type, lab);
              if (type & itype_integer)
                type_branch(code, type_integer, false, arg, type, lab);
              if (type & itype_string)
                [
                  x64:test(code, x64:limm, MUDLLE_READONLY,
                           x64:lidx, reg . x64:object_flags);
                  x64:jcc(code, x64:bne, lab);
                ];
            ];

          x64:orbyte(code, x64:limm, MUDLLE_READONLY,
                     x64:lidx, reg . x64:object_flags);
          if (lab != NULL)
            x64:label(code, lab);
          move(code, x64:lvar, arg, x64:lvar, dest);
          exit<function> null;
        ]
      else if (called == kvequal? && nargs == 2)
        exit<function>
          call_builtin2(code, "bvequalp", car(args), cadr(args), dest)
      else if (called == kvector_bitor! && nargs == 2)
        exit<function>
          call_builtin2(code, "bvector_bitor", car(args), cadr(args), dest);

      // Optimise calls to global constants
      | closure |
      if (called[mc:v_class] == mc:v_global_constant)
	[
	  | f, t |

	  f = global_value(called[mc:v_goffset]);
	  t = typeof(f);
	  if (t == type_varargs)
	    exit<function> call_varargs(code, called, f, args, dest);

          if ((t == type_secure || t == type_primitive)
              && primitive_nargs(f) == nargs)
            [
              if (t == type_secure)
                [
                  move_native_args(code, nargs, args);
                  call(code, called, nargs, "bcall_secure", true);
                ]
              else
                call_primitive(code, called, f, nargs, args);
              exit<function> move(code, x64:lreg, reg_result,
                                  x64:lvar, dest);
            ];

          if (t == type_closure)
            closure = f;
        ];

      push_args(code, nargs, args);
      if (closure != null || vector?(ins[mc:i_cfunction]))
        call_closure(code, called, nargs, closure)
      else
        call(code, called, nargs, "bcall", false);
      pop_args(code, nargs);
      move(code, x64:lreg, reg_result, x64:lvar, dest);
    ];

  // considering changing type_branch() if this changes
  assert(mudlle_synthetic_types == 34);

  type_branch = fn (code, type, reversed, arg, itypeset, dest)
    // Effects: Generates:
    //   !reversed: if typeof(arg) == type goto dest
    //   reversed: if typeof(arg) != type goto dest
    //   itypeset is inferred type information on arg
    [
      | success, commit, abort, fail, abort_notptr, usedfail, r |

      fail = x64:new_label(code);
      usedfail = false;

      // Handle the 3 cases that arise in positive/negative typechecks:
      //   - value *not* of type (abort)
      //     flow of control must not proceed (eg not pointer)
      //   - value *of* type (success)
      //   - end of type check, final test (commit)
      if (reversed)
	[
	  commit = fn (cc)
	    x64:jcc(code, rev_x64relop(cc), dest);

	  success = fn (cc)
	    [
	      x64:jcc(code, cc, fail);
	      usedfail = true;
	    ];

	  abort = fn (cc)
	    x64:jcc(code, cc, dest);
	]
      else
	[
	  commit = fn (cc)
	    x64:jcc(code, cc, dest);

	  success = fn (cc)
	    x64:jcc(code, cc, dest);

	  abort = fn (cc)
	    [
	      x64:jcc(code, cc, fail);
	      usedfail = true;
	    ];
	];

      // checks can now assume the !reversed case

      abort_notptr = fn (r, itypeset)
	[
	  if (itypeset & itype_integer)
	    [
	      x64:test(code, x64:limm, 1, x64:lreg, r);
	      abort(x64:bne);
	    ];
	  if (itypeset & itype_null)
	    [
	      x64:test(code, x64:lreg, r, x64:lreg, r);
	      abort(x64:be);
	    ];
	];

      for (;;)
	[
          | itype, itype_inv |
          if (type == fake_prim_type)
            [
              itype     = mc:itypemap[stype_function];
              itype_inv = itype_any;
            ]
          else
            [
              itype     = mc:itypemap[type];
              itype_inv = mc:itypemap_inverse[type];
            ];
	  if ((itype & itypeset) == itype_none)
	    [
	      // is not of given type
	      if (reversed) x64:jmp(code, dest)
	    ]
	  else if ((itype_inv & itypeset) == itype_none)
	    [
	      // is of given type
	      if (!reversed) x64:jmp(code, dest)
	    ]
	  else if (type == type_integer)
	    [
	      x64:test(code, x64:limm, 1, x64:lvar, arg);
	      commit(x64:bne);
	    ]
	  else if (type == type_null)
	    [
              cmpeq(code, x64:limm, 0, x64:lvar, arg);
	      commit(x64:be);
	    ]
	  else if (type == stype_list)
	    [
	      if (r == null)
		r = fetch1(code, arg);

	      // if null or int are possible, check for those and try
	      // again
	      if (itypeset & itype_null_int)
		[
		  // Note: success for null...
		  if (itypeset & itype_null)
		    [
		      x64:test(code, x64:lreg, r, x64:lreg, r);
		      success(x64:be);
		    ];
		  if (itypeset & itype_integer)
		    [
		      x64:test(code, x64:limm, 1, x64:lreg, r);
		      abort(x64:bne);
		    ];
		  // stype_list becomes type_pair as we now know it's
		  // not null
		  type = type_pair;
		  itypeset &= ~itype_null_int;
		  exit<continue> null;
		];

	      x64:cmpbyte(code, x64:limm, type_pair,
			  x64:lidx, r . x64:object_type);
	      commit(x64:be);
	    ]
          else if (type == stype_float_like || type == stype_bigint_like)
            [
              | imask |
              imask = if (type == stype_float_like)
                itype_float_like
              else
                itype_bigint_like;

              // if only one of these types is possible, check for it
              if (itypeset & imask & ~itype_integer == 0)
                exit<continue> type = type_integer;
              if (itypeset & imask & ~itype_bigint == 0)
                exit<continue> type = type_bigint;
              if (type == stype_float_like
                  && itypeset & imask & ~itype_float == 0)
                exit<continue> type = type_float;

	      if (r == null)
		r = fetch1(code, arg);

              if (itypeset & itype_null)
                [
                  x64:test(code, x64:lreg, r, x64:lreg, r);
                  abort(x64:be);
                  itypeset &= ~itype_null;
                  exit<continue> null;
                ];

              if (itypeset & itype_integer)
                [
                  x64:test(code, x64:limm, 1, x64:lreg, r);
                  success(x64:bne);
                  itypeset &= ~itype_integer;
                  exit<continue> null;
                ];

              assert(itypeset & imask == imask & ~itype_integer);
              x64:cmpbyte(code, x64:limm, type_bigint,
                          x64:lidx, r . x64:object_type);
              if (type == stype_float_like)
                [
                  success(x64:be);
                  x64:cmpbyte(code, x64:limm, type_float,
                              x64:lidx, r . x64:object_type);
                ];
              commit(x64:be);
            ]
	  else if (itypeset & itype_null_int)
	    [
	      // if null or int are possible, check for those and try
	      // again
	      if (r == null)
		r = fetch1(code, arg);
	      abort_notptr(r, itypeset);
	      itypeset &= ~itype_null_int;
	      exit<continue> null;
	    ]
	  else if (type == stype_function || type == fake_prim_type)
	    [
	      if (r == null)
		r = fetch1(code, arg);
              if (type == stype_function)
                [
                  x64:cmpbyte(code, x64:limm, type_closure,
                              x64:lidx, r . x64:object_type);
                  success(x64:be);
                ];
	      x64:cmpbyte(code, x64:limm, mc:garbage_primitive,
			  x64:lidx, r . x64:object_info);
	      commit(x64:be);
	    ]
	  else			// generic type check
	    [
              assert(type < mudlle_types);
	      if (r == null)
		r = fetch1(code, arg);
	      x64:cmpbyte(code, x64:limm, type, x64:lidx, r . x64:object_type);
	      commit(x64:be);
	    ];
	  exit<break> null;
	];

      if (usedfail) x64:label(code, fail);
    ];

  // Check if 'var' is one of the types in 'typeset', given type
  // inference information in 'itypeset'.
  // If 'check_null?' is true, explicitly test for null. This gives
  // better error messages.
  typeset_trap = fn (code, int typeset, var, int argnum, int itypeset,
                     check_null?)
    [
      | orig_typeset |
      orig_typeset = typeset;
      typeset &= ~mc:typeset_flag_return;

      if (typeset == typeset_any)
        exit<function> null;

      | possible |

      // 'possible' is the typeset of (inferred) current possible types in var
      possible = mc:typeset_from_itypeset(itypeset, typeset & TYPESET_FALSE);

      // don't bother about impossible types
      typeset &= possible;

      // do nothing if no types can trap
      if ((possible & ~typeset) == 0)
        exit<function> null;

      | trap, jmpok, ok, r, trap_args |
      trap_args = vector(orig_typeset, argnum, trap_mv_var, var);
      jmpok = fn (cc)
        [
          if (ok == null)
            ok = x64:new_label(code);
          x64:jcc(code, cc, ok);
        ];
      trap = fn (cc) x64:trap(code, cc, error_bad_type, trap_args);

      // no valid types: always trap
      if (typeset == 0)
        exit<function> trap(x64:balways);

      // skip move to register if only testing for one of integer,
      // null, or false|null
      if ((typeset & ~(TSET_NULL | TYPESET_FALSE) != 0)
          && typeset != TSET_INT)
        [
          r = fetch1(code, var);
          var = var_in_reg(var, r);
        ];

      <done> [
        if (typeset & TSET_INT)
          [
            x64:test(code, x64:limm, 1, x64:lvar, var);
            typeset &= ~(TYPESET_FALSE | TSET_INT);
            if (typeset == 0)
              exit<done> trap(x64:be);
            jmpok(x64:bne);
            possible &= ~(TYPESET_FALSE | TSET_INT);
          ]
        else if (typeset & TYPESET_FALSE)
          [
            | bop |
            x64:cmp(code, x64:limm, x64:mudlleint(false), x64:lvar, var);
            // x64:ba tests for unsigned > 1, which is not (null-or-false)
            bop = if (typeset & TSET_NULL) x64:ba else x64:bne;
            typeset &= ~(TYPESET_FALSE | TSET_NULL);
            if (typeset == 0)
              exit<done> trap(bop);
            jmpok(rev_x64relop(bop));
            possible &= ~(TYPESET_FALSE | TSET_NULL);
          ];
        if (typeset & TSET_NULL)
          [
            cmpeq(code, x64:limm, 0, x64:lvar, var);
            typeset &= ~TSET_NULL;
            if (typeset == 0)
              exit<done> trap(x64:bne);
            jmpok(x64:be);
            possible &= ~TSET_NULL;
          ];

        if (possible & TSET_INT)
          [
            x64:test(code, x64:limm, 1, x64:lvar, var);
            trap(x64:bne);
            possible &= ~TSET_INT;
          ];
        if (check_null? && (possible & TSET_NULL))
          [
            cmpeq(code, x64:limm, 0, x64:lvar, var);
            trap(x64:be);
            possible &= ~TSET_NULL;
          ];

        // done if no types left that can trap
        if ((possible & ~typeset) == 0)
          exit<done> null;

        assert(r != null);

        | typeset_primitive |
        typeset_primitive = typeset_function & ~(1 << type_closure);
        if ((typeset & typeset_primitive) == typeset_primitive)
          [
            x64:cmpbyte(code, x64:limm, mc:garbage_primitive,
                        x64:lidx, r . x64:object_info);
            typeset &= ~typeset_primitive;
            if (typeset == 0)
              exit<done> trap(x64:bne);
            // the compare will trap on null
            jmpok(x64:be);
            possible &= ~(typeset_primitive | TSET_NULL);
          ];

        // don't have spare register for bit test here, so do a series
        // of compares
        | types |
        types = bits_reduce(cons, null, typeset);
        loop
          [
            | type |
            @(type . types) = types;
            x64:cmpbyte(code, x64:limm, type, x64:lidx, r . x64:object_type);

            // the compare will trap on null; done if that was the
            // last possible invalid type
            possible &= ~TSET_NULL;
            if ((possible & ~typeset) == 0)
              exit<done> null;

            | tmask |
            tmask = ~(1 << type);
            typeset &= tmask;
            if (typeset == 0)
              exit<done> trap(x64:bne);
            jmpok(x64:be);
            possible &= tmask;
          ];
      ];                        // end of <done>

      if (ok != null)
        x64:label(code, ok);
    ];

  type_trap = fn (code, type, var, itypeset)
    // Effects: Generate typecheck for value in var, given type
    //   knowledge itypeset.
    typeset_trap(code, type_typesets[type], var, -1, itypeset, false);

  in_scratch? = fn (v)
    mc:in_reg(v) && mc:get_reg(v) == reg_scratch;

  fetch1 = fn (code, var)
    if (mc:in_reg(var))
      mc:get_reg(var)
    else
      [
        // reg_scratch might be in use
        move(code, x64:lvar, var, x64:lreg, reg_scratch2);
        reg_scratch2
      ];

  // uses reg_scratch if var not in register
  fetch2 = fn (code, var)
    if (mc:in_reg(var))
      mc:get_reg(var)
    else
      [
        move(code, x64:lvar, var, x64:lreg, reg_scratch);
        reg_scratch
      ];

  // fetch var into dest's register, or reg_scratch2
  fetch_for_dest = fn (code, var, dest)
    if (mc:in_reg(var))
      var
    else if (mc:in_reg(dest))
      [
        move(code, x64:lvar, var, x64:lvar, dest);
        dest
      ]
    else
      var_in_reg(var, fetch1(code, var));

  call_builtin = fn (code, string op)
    x64:call(code, x64:lbuiltin, op, false);

  callop2 = fn (code, builtin, arg1, arg2)
    [
      move_native_args(code, 2, list(arg1, arg2));
      call_builtin(code, builtin);
    ];

  callop3 = fn (code, builtin, arg1, arg2, arg3)
    [
      move_native_args(code, 3, list(arg1, arg2, arg3));
      call_builtin(code, builtin);
    ];

  move = fn (code, stype, source, dtype, dest)
    safemove(code, stype, source, dtype, dest, regs_scratch);

  safemove = fn (code, stype, source, dtype, dest, scratchregs)
    // Uses scratch register if destination not a register and source
    // is neither an index nor a constant
    [
      | sea, dea |

      // type: x64:limm, x64:lcst, x64:lfunction, x64:lreg,
      // x64:lidx, x64:l[rq]idx, x64:lvar
      sea = x64:resolve(stype, source);
      stype = car(sea); source = cdr(sea);
      dea = x64:resolve(dtype, dest);
      dtype = car(dea); dest = cdr(dea);

      // type: x64:limm, x64:lcst, x64:lfunction, x64:lreg,
      // x64:lidx, x64:l[rq]idx, x64:lglobal(_constant)

      if (stype == dtype && equal?(source, dest))
        exit<function> null;

      // can use mov if source or destination is a register or if
      // source is a constant

      if (dtype == x64:lreg && stype == x64:limm && source == 0)
        x64:xor(code, dtype, dest, dtype, dest)
      else if (dtype == x64:lreg
               || stype == x64:lreg
               || stype == x64:lseclev
               || stype == x64:lglobal_index
               || stype == x64:limm)
        x64:mov(code, stype, source, dtype, dest)
      else
        [
          assert_message(dtype != x64:lridx && dtype != x64:lqidx,
                         "scaled destination unsupported (for now)");
          // find a usable scratch register
          | sr |
          for (|i| i = 0; i < vlength(scratchregs); ++i)
            [
              | r |
              r = scratchregs[i];
              if (!(dtype == x64:lidx && car(dest) == r))
                exit<break> sr = r;
            ];
          assert(sr != null);
          x64:mov(code, stype, source, x64:lreg, sr);
          x64:mov(code, x64:lreg, sr, dtype, dest);
        ];
    ];

  // calls before(reg1, reg2) just before the comparison is made;
  // either reg can be null
  special_compare = fn (code, arg1, arg2, relop, before)
    [
      | stype1, source1, stype2, source2, cmpop |

      cmpop = x64:cmp;
      <normal> if (relop == x64:be || relop == x64:bne)
        cmpop = cmpeq
      else
        [
          if (intcst?(arg2) && mc:in_reg(arg1))
            [
              | t |
              t = arg1;
              arg1 = arg2;
              arg2 = t;
              relop = commute_x64relop[relop];
            ]
          else if (intcst?(arg1) && mc:in_reg(arg2))
            null
          else
            exit<normal> null;

          // use test %reg,%reg to compare to zero instead of 2*{-1,0}+1
          // when applicable
          | val |
          val = arg1[mc:v_kvalue];
          if ((val == 0 && (relop == x64:bge || relop == x64:bl))
              || (val == -1 && (relop == x64:ble || relop == x64:bg)))
            [
              | reg |
              reg = mc:get_reg(arg2);
              before(reg, null);
              x64:test(code, x64:lreg, reg, x64:lreg, reg);

              // use bs/bns which don't read OF/CF; this may allow the
              // 'test' to be optimized away later
              exit<function> if (relop == x64:bge || relop == x64:be)
                x64:bns
              else
                x64:bs;
            ]
        ];

      @(stype1 . source1) = x64:resolve(x64:lvar, arg1);
      @(stype2 . source2) = x64:resolve(x64:lvar, arg2);

      if (stype1 == x64:limm64)
        [
          x64:mov(code, stype1, source1, x64:lreg, reg_scratch2);
          stype1 = x64:lreg; source1 = reg_scratch2;
        ]
      else if (stype2 == x64:limm64)
        [
          x64:mov(code, stype2, source2, x64:lreg, reg_scratch2);
          stype2 = x64:lreg; source2 = reg_scratch2;
        ];

      if (stype2 == x64:lreg || (stype1 == x64:limm && stype2 != x64:limm))
        null
      else if (stype1 == x64:lreg
               || (stype2 == x64:limm && stype1 != x64:limm))
        [
          | t |
          t = stype1; stype1 = stype2; stype2 = t;
          t = source1; source1 = source2; source2 = t;
          relop = commute_x64relop[relop];
        ]
      else
        [
          x64:mov(code, stype2, source2, x64:lreg, reg_scratch2);
          stype2 = x64:lreg; source2 = reg_scratch2;
        ];
      | breg |
      breg = fn (stype, src)
        if (stype == x64:lreg)
          src
        else if (x64:ltype_may_indirect(stype))
          reg_scratch2
        else
          null;
      before(breg(stype1, source1), breg(stype2, source2));
      cmpop(code, stype1, source1, stype2, source2);
      relop
    ];

  compare = fn (code, arg1, arg2, relop)
    special_compare(code, arg1, arg2, relop, fn (reg1, reg2) null);

  cmpeq = fn (fcode, m1, a1, m2, a2)
    [
      if (m1 == x64:limm && a1 == 0
	  && (m2 == x64:lreg || m2 == x64:lvar && mc:in_reg(a2)))
	x64:test(fcode, m2, a2, m2, a2)
      else
	x64:cmp(fcode, m1, a1, m2, a2)
    ];

  // If 'mod_vals' is a vector(lhs, rhs, d), possibly add either 'lhs' or 'rhs'
  // to one of the sources before calling op(), or afterwards 'd' to the
  // destination.
  //
  // If 'mod_op' is a function, it is called to perform operate-and-modify.
  perform3 = fn (code, arg1, arg2, dest, op, commute_op,
                 {null,function} mod_op, {null,vector} mod_vals)
    [
      if (mod_op == null)
        mod_op = default_mod_op;

      | stype1, source1, stype2, source2, dtype |
      @(stype1 . source1) = x64:resolve(x64:lvar, arg1);
      @(stype2 . source2) = x64:resolve(x64:lvar, arg2);

      if (op == x64:and)
        [
          // 'and' can take uint32 immediates
          if (stype1 == x64:limm64 && uint31?(car(source1)))
            stype1 = x64:limm;
          if (stype2 == x64:limm64 && uint31?(car(source2)))
            stype2 = x64:limm;
        ];

      @(dtype . dest) = x64:resolve(x64:lvar, dest);

      if (mod_vals == null)
        null
      else if (stype1 == x64:limm || stype1 == x64:limm64)
        [
          @(stype1 . source1) = add_imm(source1, 0 . mod_vals[vmodval_lhs]);
          mod_vals = null
        ]
      else if (stype2 == x64:limm || stype2 == x64:limm64)
        [
          @(stype2 . source2) = add_imm(source2, 0 . mod_vals[vmodval_rhs]);
          mod_vals = null
        ];

      if (dtype == x64:lreg)
	[
	  if (dtype == stype2 && dest == source2)
            [
              // no need for move, arg2 is already in dest
              if (stype1 == x64:limm64)
                [
                  | reg |
                  reg = if (dest == reg_scratch)
                    reg_scratch2
                  else
                    reg_scratch;
                  move(code, stype1, source1, x64:lreg, reg);
                  stype1 = x64:lreg; source1 = reg;
                ];
              mod_op(code, true, commute_op, stype1, source1, dtype, dest,
                     mod_vals);
              exit<function> null;
            ];

          // dst is register && dst != src2
          if (mod_vals != null && stype1 == x64:lreg && source1 != dest)
            [
              x64:lea(code, x64:lidx, source1 . mod_vals[vmodval_lhs],
                      x64:lreg, dest);
              assert(stype2 != x64:limm64); // otherwise mod_vals == null
              op(code, stype2, source2, dtype, dest);
              exit<function> null;
            ];

          if (stype2 == x64:limm64)
            [
              assert(mod_vals == null);
              if (!(dtype == stype1 && dest == source1))
                [
                  move(code, stype2, source2, dtype, dest);
                  commute_op(code, stype1, source1, dtype, dest);
                  exit<function> null;
                ];
              | reg |
              reg = if (dest == reg_scratch)
                reg_scratch2
              else
                reg_scratch;
              move(code, stype2, source2, x64:lreg, reg);
              stype2 = x64:lreg; source2 = reg;
            ];

          move(code, stype1, source1, dtype, dest);
          mod_op(code, false, op, stype2, source2, dtype, dest, mod_vals);
          exit<function> null;
        ];

      // dst is not a register

      if (dtype == stype1 && equal?(dest, source1))
        [
          if (stype2 != x64:lreg && stype2 != x64:limm)
            [
              move(code, stype2, source2, x64:lreg, reg_scratch2);
              stype2 = x64:lreg; source2 = reg_scratch2;
            ];
          mod_op(code, false, op, stype2, source2, dtype, dest, mod_vals);
          exit<function> null;
        ];

      if (stype2 == x64:limm64)
        [
          assert(mod_vals == null);
          move(code, stype2, source2, x64:lreg, reg_scratch2);
          commute_op(code, stype1, source1, x64:lreg, reg_scratch2);
          move(code, x64:lreg, reg_scratch2, dtype, dest);
          exit<function> null;
        ];

      // we can modify the source if it's a scratch register
      if (stype2 == x64:lreg && source2 == reg_scratch)
        [
          mod_op(code, true, commute_op, stype1, source1, stype2, source2,
                 mod_vals);
          move(code, stype2, source2, dtype, dest);
          exit<function> null;
        ];

      if (stype1 == x64:lreg && source1 == reg_scratch)
        null
      else if ((stype1 == x64:lreg || stype1 == x64:limm)
               && (stype2 == x64:lreg || stype2 == x64:limm))
        [
          move(code, stype1, source1, dtype, dest);
          stype1 = dtype; source1 = dest;
        ]
      else
        [
          move(code, stype1, source1, x64:lreg, reg_scratch);
          stype1 = x64:lreg; source1 = reg_scratch;
        ];

      mod_op(code, false, op, stype2, source2, stype1, source1, mod_vals);
      move(code, stype1, source1, dtype, dest);
    ];
];
