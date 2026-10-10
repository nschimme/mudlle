/*
 * LLVM IR Generator for Mudlle
 */

library genllvm
requires asmwriter, compiler, dlist, flow, ins3, misc, sequences, vars

defines mc:gen_llvm_ir, mc:gen_llvm_function

[
  | llvm_read_var, llvm_write_var, gen_ins, gen_function, tmp_seq, terminated, globals_seen |

  tmp_seq = 0;
  terminated = false;
  globals_seen = make_table();

  llvm_read_var = fn (vector var, w)
    [
      | class |
      class = var[mc:v_class];
      if (class == mc:v_constant)
        [
          | val |
          val = var[mc:v_kvalue];
          if (integer?(val))
            format("%d", (val << 1) | 1)
          else if (val == false)
            "1"
          else if (val == true)
            "3"
          else if (val == null)
            "1"
          else
            format("1 ; %w", val)
        ]
      else if (class == mc:v_function)
        format("@fn_%d", var[mc:v_fvalue][mc:c_fnumber])
      else if (class == mc:v_global || class == mc:v_global_constant || class == mc:v_global_define)
        [
          | gname, tname |
          gname = var[mc:v_name];
          globals_seen[gname] = var;
          tmp_seq = tmp_seq + 1;
          tname = format("%%gval_%d", tmp_seq);
          writer:format(w, "  %s = load i64, ptr @g_%s\n", tname, gname);
          tname
        ]
      else
        [
          | vnum, tname |
          vnum = var[mc:v_number];
          tmp_seq = tmp_seq + 1;
          tname = format("%%rd_%d_%d", vnum, tmp_seq);
          writer:format(w, "  %s = load i64, ptr %%slot_%d\n", tname, vnum);
          tname
        ]
    ];

  llvm_write_var = fn (vector var, string val_str, w)
    [
      | class |
      class = var[mc:v_class];
      if (class == mc:v_global || class == mc:v_global_constant || class == mc:v_global_define)
        [
          | gname |
          gname = var[mc:v_name];
          globals_seen[gname] = var;
          writer:format(w, "  store i64 %s, ptr @g_%s\n", val_str, gname);
        ]
      else if (class != mc:v_constant && class != mc:v_function)
        [
          | vnum |
          vnum = var[mc:v_number];
          writer:format(w, "  store i64 %s, ptr %%slot_%d\n", val_str, vnum);
        ];
    ];

  gen_function = fn (ifn, w)
    [
      | fname, args, fval, vars_seen, add_var, add_vars |

      fname = format("fn_%d", ifn[mc:c_fnumber]);
      args = lmap(fn (fa) fa[0][0], ifn[mc:c_ffullargs]);

      // Function header
      writer:format(w, "define i64 @%s(i64 %%env", fname);
      lforeach(fn (arg) [
        writer:format(w, ", i64 %%arg_%d", arg[mc:v_number]);
      ], args);
      writer:write_line(w, ") {");
      writer:write_line(w, "entry:");

      // Collect all variables used in function
      vars_seen = make_table();

      add_var = fn (v)
        [
          if (vector?(v))
            [
              | class |
              class = v[mc:v_class];
              if (class == mc:v_global || class == mc:v_global_constant || class == mc:v_global_define)
                globals_seen[v[mc:v_name]] = v
              else if (class != mc:v_constant && class != mc:v_function)
                vars_seen[itoa(v[mc:v_number])] = v;
            ]
        ];

      add_vars = fn (l)
        [
          if (list?(l))
            lforeach(add_var, l)
          else if (vector?(l))
            add_var(l)
        ];

      lforeach(add_var, args);
      if (ifn[mc:c_flocals] != null)
        lforeach(add_var, ifn[mc:c_flocals]);

      // Ensure blocks are flattened
      if (pair?(ifn[mc:c_fvalue]))
        mc:flatten_blocks(ifn);

      fval = ifn[mc:c_fvalue];

      if (vector?(fval))
        [
          | scan |
          scan = fval;
          loop
            [
              | il, ins, cls |
              il = dget(scan);
              ins = il[mc:il_ins];
              if (ins != null)
                [
                  cls = ins[mc:i_class];
                  if (cls == mc:i_compute)
                    [
                      add_var(ins[mc:i_adest]);
                      add_vars(ins[mc:i_aargs]);
                    ]
                  else if (cls == mc:i_branch)
                    add_vars(ins[mc:i_bargs])
                  else if (cls == mc:i_memory)
                    [
                      add_var(ins[mc:i_mscalar]);
                      add_var(ins[mc:i_marray]);
                    ]
                  else if (cls == mc:i_closure)
                    add_var(ins[mc:i_fdest])
                  else if (cls == mc:i_call)
                    [
                      add_var(ins[mc:i_cdest]);
                      add_vars(ins[mc:i_cargs]);
                    ]
                  else if (cls == mc:i_return)
                    add_var(ins[mc:i_rvalue])
                  else if (cls == mc:i_trap)
                    add_vars(ins[mc:i_targs]);
                ];
              scan = dnext(scan);
              if (scan == fval) exit 0
            ]
        ];

      // Allocate slots for all variables
      table_foreach(fn (@<_ = var>) [
        writer:format(w, "  %%slot_%d = alloca i64\n", var[mc:v_number]);
      ], vars_seen);

      // Store function arguments in their slots
      lforeach(fn (arg) [
        | vnum |
        vnum = arg[mc:v_number];
        writer:format(w, "  store i64 %%arg_%d, ptr %%slot_%d\n", vnum, vnum);
      ], args);

      terminated = false;

      if (vector?(fval))
        [
          | scan |
          scan = fval;
          loop
            [
              | il, ins, lbl_num |
              il = dget(scan);

              if (il[mc:il_label])
                [
                  lbl_num = il[mc:il_label][mc:l_number];
                  if (!terminated)
                    writer:format(w, "  br label %%L_%d\n", lbl_num);
                  writer:format(w, "L_%d:\n", lbl_num);
                  terminated = false;
                ];

              ins = il[mc:il_ins];
              if (ins != null && !terminated)
                gen_ins(ins, w);

              scan = dnext(scan);
              if (scan == fval) exit 0
            ]
        ];

      if (!terminated)
        writer:write_line(w, "  ret i64 1");

      writer:write_line(w, "}\n");
    ];

  gen_ins = fn (vector ins, w)
    [
      | class |
      class = ins[mc:i_class];

      if (class == mc:i_compute)
        [
          | dest_var, op, args |
          dest_var = ins[mc:i_adest];
          op = ins[mc:i_aop];
          args = ins[mc:i_aargs];

          if (op == mc:b_iadd || op == mc:b_add)
            [
              | a1, a2, t1, t2 |
              a1 = llvm_read_var(car(args), w);
              a2 = llvm_read_var(cadr(args), w);
              tmp_seq = tmp_seq + 1;
              t1 = format("%%add_%d", tmp_seq);
              t2 = format("%%res_%d", tmp_seq);
              writer:format(w, "  %s = add i64 %s, %s\n", t1, a1, a2);
              writer:format(w, "  %s = sub i64 %s, 1\n", t2, t1);
              llvm_write_var(dest_var, t2, w);
            ]
          else if (op == mc:b_subtract)
            [
              | a1, a2, t1, t2 |
              a1 = llvm_read_var(car(args), w);
              a2 = llvm_read_var(cadr(args), w);
              tmp_seq = tmp_seq + 1;
              t1 = format("%%sub_%d", tmp_seq);
              t2 = format("%%res_%d", tmp_seq);
              writer:format(w, "  %s = sub i64 %s, %s\n", t1, a1, a2);
              writer:format(w, "  %s = add i64 %s, 1\n", t2, t1);
              llvm_write_var(dest_var, t2, w);
            ]
          else if (op == mc:b_multiply)
            [
              | a1, a2, u1, u2, m1, res |
              a1 = llvm_read_var(car(args), w);
              a2 = llvm_read_var(cadr(args), w);
              tmp_seq = tmp_seq + 1;
              u1 = format("%%u1_%d", tmp_seq);
              u2 = format("%%u2_%d", tmp_seq);
              m1 = format("%%m1_%d", tmp_seq);
              res = format("%%res_%d", tmp_seq);
              writer:format(w, "  %s = ashr i64 %s, 1\n", u1, a1);
              writer:format(w, "  %s = sub i64 %s, 1\n", u2, a2);
              writer:format(w, "  %s = mul i64 %s, %s\n", m1, u1, u2);
              writer:format(w, "  %s = add i64 %s, 1\n", res, m1);
              llvm_write_var(dest_var, res, w);
            ]
          else if (op == mc:b_eq)
            [
              | a1, a2, cmp, res |
              a1 = llvm_read_var(car(args), w);
              a2 = llvm_read_var(cadr(args), w);
              tmp_seq = tmp_seq + 1;
              cmp = format("%%cmp_%d", tmp_seq);
              res = format("%%res_%d", tmp_seq);
              writer:format(w, "  %s = icmp eq i64 %s, %s\n", cmp, a1, a2);
              writer:format(w, "  %s = select i1 %s, i64 3, i64 1\n", res, cmp);
              llvm_write_var(dest_var, res, w);
            ]
          else if (op == mc:b_ne)
            [
              | a1, a2, cmp, res |
              a1 = llvm_read_var(car(args), w);
              a2 = llvm_read_var(cadr(args), w);
              tmp_seq = tmp_seq + 1;
              cmp = format("%%cmp_%d", tmp_seq);
              res = format("%%res_%d", tmp_seq);
              writer:format(w, "  %s = icmp ne i64 %s, %s\n", cmp, a1, a2);
              writer:format(w, "  %s = select i1 %s, i64 3, i64 1\n", res, cmp);
              llvm_write_var(dest_var, res, w);
            ]
          else if (op == mc:b_lt)
            [
              | a1, a2, cmp, res |
              a1 = llvm_read_var(car(args), w);
              a2 = llvm_read_var(cadr(args), w);
              tmp_seq = tmp_seq + 1;
              cmp = format("%%cmp_%d", tmp_seq);
              res = format("%%res_%d", tmp_seq);
              writer:format(w, "  %s = icmp slt i64 %s, %s\n", cmp, a1, a2);
              writer:format(w, "  %s = select i1 %s, i64 3, i64 1\n", res, cmp);
              llvm_write_var(dest_var, res, w);
            ]
          else if (op == mc:b_car)
            [
              | arg, ptr_val, gptr, res |
              arg = llvm_read_var(car(args), w);
              tmp_seq = tmp_seq + 1;
              ptr_val = format("%%ptr_%d", tmp_seq);
              gptr = format("%%gptr_%d", tmp_seq);
              res = format("%%res_%d", tmp_seq);
              writer:format(w, "  %s = inttoptr i64 %s to ptr\n", ptr_val, arg);
              writer:format(w, "  %s = getelementptr inbounds i8, ptr %s, i64 8\n", gptr, ptr_val);
              writer:format(w, "  %s = load i64, ptr %s\n", res, gptr);
              llvm_write_var(dest_var, res, w);
            ]
          else if (op == mc:b_cdr)
            [
              | arg, ptr_val, gptr, res |
              arg = llvm_read_var(car(args), w);
              tmp_seq = tmp_seq + 1;
              ptr_val = format("%%ptr_%d", tmp_seq);
              gptr = format("%%gptr_%d", tmp_seq);
              res = format("%%res_%d", tmp_seq);
              writer:format(w, "  %s = inttoptr i64 %s to ptr\n", ptr_val, arg);
              writer:format(w, "  %s = getelementptr inbounds i8, ptr %s, i64 16\n", gptr, ptr_val);
              writer:format(w, "  %s = load i64, ptr %s\n", res, gptr);
              llvm_write_var(dest_var, res, w);
            ]
          else if (op == mc:b_assign)
            [
              | a1 |
              a1 = llvm_read_var(car(args), w);
              llvm_write_var(dest_var, a1, w);
            ]
          else
            [
              | a1 |
              a1 = llvm_read_var(car(args), w);
              llvm_write_var(dest_var, a1, w);
            ]
        ]
      else if (class == mc:i_branch)
        [
          | op, dest_lbl, args |
          op = ins[mc:i_bop];
          dest_lbl = ins[mc:i_bdest][mc:l_number];
          args = ins[mc:i_bargs];

          if (op == mc:branch_always)
            [
              writer:format(w, "  br label %%L_%d\n", dest_lbl);
              terminated = true;
            ]
          else
            [
              | cmp, seq, v1, v2 |
              tmp_seq = tmp_seq + 1;
              seq = tmp_seq;
              cmp = format("%%brcmp_%d", seq);

              if (op == mc:branch_true)
                [
                  v1 = llvm_read_var(car(args), w);
                  writer:format(w, "  %s = icmp ne i64 %s, 1\n", cmp, v1);
                ]
              else if (op == mc:branch_false)
                [
                  v1 = llvm_read_var(car(args), w);
                  writer:format(w, "  %s = icmp eq i64 %s, 1\n", cmp, v1);
                ]
              else if (op == mc:branch_eq)
                [
                  v1 = llvm_read_var(car(args), w);
                  v2 = llvm_read_var(cadr(args), w);
                  writer:format(w, "  %s = icmp eq i64 %s, %s\n", cmp, v1, v2);
                ]
              else if (op == mc:branch_ne)
                [
                  v1 = llvm_read_var(car(args), w);
                  v2 = llvm_read_var(cadr(args), w);
                  writer:format(w, "  %s = icmp ne i64 %s, %s\n", cmp, v1, v2);
                ]
              else if (op == mc:branch_lt)
                [
                  v1 = llvm_read_var(car(args), w);
                  v2 = llvm_read_var(cadr(args), w);
                  writer:format(w, "  %s = icmp slt i64 %s, %s\n", cmp, v1, v2);
                ]
              else if (op == mc:branch_ge)
                [
                  v1 = llvm_read_var(car(args), w);
                  v2 = llvm_read_var(cadr(args), w);
                  writer:format(w, "  %s = icmp sge i64 %s, %s\n", cmp, v1, v2);
                ]
              else if (op == mc:branch_le)
                [
                  v1 = llvm_read_var(car(args), w);
                  v2 = llvm_read_var(cadr(args), w);
                  writer:format(w, "  %s = icmp sle i64 %s, %s\n", cmp, v1, v2);
                ]
              else if (op == mc:branch_gt)
                [
                  v1 = llvm_read_var(car(args), w);
                  v2 = llvm_read_var(cadr(args), w);
                  writer:format(w, "  %s = icmp sgt i64 %s, %s\n", cmp, v1, v2);
                ]
              else if (op >= mc:branch_type? && op < mc:branch_ntype?)
                [
                  | type_idx, bit_and |
                  v1 = llvm_read_var(car(args), w);
                  type_idx = op - mc:branch_type?;
                  bit_and = format("%%tag_%d", seq);
                  if (type_idx == 0) // integer
                    [
                      writer:format(w, "  %s = and i64 %s, 1\n", bit_and, v1);
                      writer:format(w, "  %s = icmp ne i64 %s, 0\n", cmp, bit_and);
                    ]
                  else
                    [
                      writer:format(w, "  %s = and i64 %s, 1\n", bit_and, v1);
                      writer:format(w, "  %s = icmp eq i64 %s, 0\n", cmp, bit_and);
                    ]
                ]
              else
                [
                  v1 = llvm_read_var(car(args), w);
                  writer:format(w, "  %s = icmp ne i64 %s, 1\n", cmp, v1);
                ];

              writer:format(w, "  br i1 %s, label %%L_%d, label %%L_next_%d\n", cmp, dest_lbl, seq);
              writer:format(w, "L_next_%d:\n", seq);
            ];
        ]
      else if (class == mc:i_call)
        [
          | dest_var, fn_var, call_args, cname, res, arg_vstrs, fptr, prefix |
          dest_var = ins[mc:i_cdest];
          call_args = ins[mc:i_cargs];
          fn_var = car(call_args);
          call_args = cdr(call_args);

          if (fn_var[mc:v_class] == mc:v_function)
            cname = format("@fn_%d", fn_var[mc:v_fvalue][mc:c_fnumber])
          else
            [
              cname = llvm_read_var(fn_var, w);
              tmp_seq = tmp_seq + 1;
              fptr = format("%%fptr_%d", tmp_seq);
              writer:format(w, "  %s = inttoptr i64 %s to ptr\n", fptr, cname);
              cname = fptr;
            ];

          arg_vstrs = lmap(fn (arg) llvm_read_var(arg, w), call_args);

          tmp_seq = tmp_seq + 1;
          res = format("%%call_%d", tmp_seq);
          writer:format(w, "  %s = call i64 %s(", res, cname);
          prefix = "";
          lforeach(fn (vstr) [
            writer:format(w, "%si64 %s", prefix, vstr);
            prefix = ", ";
          ], arg_vstrs);
          writer:write_line(w, ")");
          llvm_write_var(dest_var, res, w);
        ]
      else if (class == mc:i_closure)
        [
          | dest_var, ifn, res |
          dest_var = ins[mc:i_fdest];
          ifn = ins[mc:i_ffunction];
          tmp_seq = tmp_seq + 1;
          res = format("%%cls_%d", tmp_seq);
          writer:format(w, "  %s = call i64 @mudlle_alloc(i64 32, i64 1) ; newclosure fn_%d\n", res, ifn[mc:c_fnumber]);
          llvm_write_var(dest_var, res, w);
        ]
      else if (class == mc:i_return)
        [
          | rval |
          rval = llvm_read_var(ins[mc:i_rvalue], w);
          writer:format(w, "  ret i64 %s\n", rval);
          terminated = true;
        ]
      else if (class == mc:i_trap)
        [
          writer:write_line(w, "  ; trap check");
        ]
      else if (class == mc:i_nop)
        [
          writer:write_line(w, "  ; nop");
        ];
    ];

  mc:gen_llvm_function = gen_function;

  mc:gen_llvm_ir = fn "mod, {writer,null} w -> . Generates LLVM IR for module" (mod, {vector,null} w = null)
    [
      | fns, created_w |
      globals_seen = make_table();

      if (w == null)
        [
          w = writer:new_string();
          created_w = true;
        ]
      else
        created_w = false;

      writer:write_line(w, "; Target datalayout & triple");
      writer:write_line(w, "target datalayout = \"e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128\"");
      writer:write_line(w, "target triple = \"x86_64-unknown-linux-gnu\"\n");

      writer:write_line(w, "; Runtime declarations");
      writer:write_line(w, "declare i64 @mudlle_alloc(i64, i64)");
      writer:write_line(w, "declare i64 @mudlle_pcons(i64, i64)");
      writer:write_line(w, "declare i64 @mudlle_make_vector(i64)");
      writer:write_line(w, "declare i64 @mudlle_call_closure(i64, i64, ptr)");
      writer:write_line(w, "declare void @mudlle_error(i64)\n");

      fns = mc:all_functions(mod[mc:m_body]);
      lforeach(fn (ifn) gen_function(ifn, w), fns);

      table_foreach(fn (@<gname = _>) [
        writer:format(w, "@g_%s = global i64 1\n", gname);
      ], globals_seen);

      if (created_w)
        writer:get_string(w)
      else
        true
    ];

];
