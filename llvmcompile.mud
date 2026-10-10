/*
 * Architecture-independent LLVM IR compilation entry point.
 */

library llvmcompile // LLVM IR compiler
requires compiler, genllvm, ins3, link, misc, phase1, phase2, phase3, vars
defines mc:compile, mc:compile_llvm
writes mc:erred, mc:this_module
[
  | llvm_all_functions, llvm_compile_ir |

  llvm_all_functions = fn (vector root)
    [
      | todo, fns, ifn, scan, il, ins, child, called, seen, search |

      todo = root . null;
      fns = null;
      while (todo != null)
        [
          ifn = car(todo);
          todo = cdr(todo);
          fns = ifn . fns;

          if (vector?(ifn[mc:c_fvalue]))
            [
              scan = ifn[mc:c_fvalue];
              loop
                [
                  il = scan[0];
                  ins = il[mc:il_ins];
                  if (ins != null)
                    [
                      if (ins[mc:i_class] == mc:i_closure)
                        child = ins[mc:i_ffunction]
                      else if (ins[mc:i_class] == mc:i_call)
                        [
                          called = car(ins[mc:i_cargs]);
                          child = if (called[mc:v_class] == mc:v_function)
                            called[mc:v_fvalue]
                          else
                            null;
                        ]
                      else
                        child = null;

                      if (child != null)
                        [
                          seen = false;
                          search = todo;
                          while (search != null && !seen)
                            [
                              if (car(search) == child) seen = true;
                              search = cdr(search);
                            ];
                          search = fns;
                          while (search != null && !seen)
                            [
                              if (car(search) == child) seen = true;
                              search = cdr(search);
                            ];
                          if (!seen) todo = child . todo;
                        ];
                    ];

                  scan = scan[1];
                  if (scan == ifn[mc:c_fvalue]) exit 0
                ]
            ]
        ];
      fns
    ];

  llvm_compile_ir = fn (vector mod, int seclev, function get_source,
                        {vector,null} w, global_syms)
    [
      if (!callable?(get_source, 1))
        error(error_bad_value);

      mc:reset_closure_count();
      mc:reset_ins_count();
      mc:reset_var_count();

      mc:erred = false;
      mc:this_module = mod;
      mc:handle_messages(get_source);

      | result |
      result = trap_error(
        fn () [
          mc:phase1(mod, seclev, global_syms);
          if (mc:erred) exit<function> false;
          if (global_syms != null) exit<function> false;
          mc:phase2(mod);
          if (mc:erred) exit<function> false;
          | fns |
          fns = llvm_all_functions(mod[mc:m_body]);
          mc:phase3(fns);
          mc:gen_llvm_ir(mod, w, fns)
        ],
        fn (n) false,
        call_trace_on, null);

      mc:handle_messages(null);

      mc:reset_var_cache();

      result
    ];

  // Drop-in compiler entry point. Its argument order and result match the
  // x64 compiler: return a prelinked module ready for mc:linkrun.
  mc:compile = fn (vector mod, protect, int seclev, function get_source,
                   {vector,null} global_syms = null)
    [
      | ir |
      ir = llvm_compile_ir(mod, seclev, get_source, null, global_syms);
      if (ir == false)
        false
      else if (global_syms != null)
        false
      else
        mc:prelink_llvm(mod, ir, protect,
                        list_to_vector(mc:llvm_constants()),
                        list_to_vector(mc:llvm_global_relocations()))
    ];

  // Explicit IR inspection API; normal compilation uses mc:compile above.
  mc:compile_llvm = fn (vector mod, int seclev, function get_source,
                        {vector,null} w = null)
    llvm_compile_ir(mod, seclev, get_source, w, null);
];
