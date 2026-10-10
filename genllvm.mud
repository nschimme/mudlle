/*
 * Copyright (c) 2026 Nils Schimmelmann
 * All rights reserved.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose, without fee, and without written agreement is hereby granted,
 * provided that the above copyright notice and the following two paragraphs
 * appear in all copies of this software.
 *
 * IN NO EVENT SHALL NILS SCHIMMELMANN BE LIABLE TO ANY PARTY FOR DIRECT, INDIRECT,
 * SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OF
 * THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF NILS SCHIMMELMANN HAVE BEEN ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 *
 * NILS SCHIMMELMANN SPECIFICALLY DISCLAIM ANY WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS" BASIS, AND NILS
 * SCHIMMELMANN HAVE NO OBLIGATION TO PROVIDE MAINTENANCE, SUPPORT, UPDATES,
 * ENHANCEMENTS, OR MODIFICATIONS.
 */

/*
 * LLVM IR Generator for Mudlle
 */

library genllvm
requires asmwriter, compiler, dlist, flow, ins3, misc, phase1, phase2, phase3, sequences, vars

defines mc:gen_llvm_ir, mc:gen_llvm_function, mc:compile_llvm_asm,
  mc:llvm_constants, llvm:mgen_preamble, llvm:mgen_instruction, llvm:assemble

reads mc:c_fnumber, mc:c_flocals, system_cmd

[
  | llvm_read_var, llvm_write_var, gen_ins, gen_function, tmp_seq, globals_seen,
    current_ifn, capture_indices, llvm_constant_list, llvm_constant_index,
    llvm_emit_closure, llvm_check_integer_args, llvm_args_immutable?,
    llvm_emit_vector, llvm_emit_concat, llvm_emit_builtin,
    llvm_read_var_storage,
    llvm_constant_values |

  tmp_seq = 0;
  globals_seen = make_table();
  current_ifn = null;
  capture_indices = make_table();
  llvm_constant_list = null;
  llvm_constant_values = null;
  mc:llvm_constants = fn () llvm_constant_values;

  llvm_constant_index = fn (value)
    [
      | found, index |
      found = assq(value, llvm_constant_list);
      if (found)
        cdr(found)
      else
        [
          index = llength(llvm_constant_list);
          llvm_constant_list = (value . index) . llvm_constant_list;
          index
        ]
    ];

  llvm_read_var = fn (vector var, w)
    [
      | class |
      class = var[mc:v_class];
      if (class == mc:v_constant)
        [
          | val, index, result, raw, tagged |
          val = var[mc:v_kvalue];
          if (val == false)
            "1"
          else if (val == true)
            "3"
          else if (val == null)
            "0"
          else if (integer?(val))
            [
              tmp_seq = tmp_seq + 1;
              raw = format("%%integer_raw_%d", tmp_seq);
              tagged = format("%%integer_tagged_%d", tmp_seq);
              writer:format(w, "  %s = shl i64 %d, 1\n", raw, val);
              writer:format(w, "  %s = or i64 %s, 1\n", tagged, raw);
              tagged
            ]
          else
            [
              index = llvm_constant_index(val);
              tmp_seq = tmp_seq + 1;
              result = format("%%constant_%d", tmp_seq);
              writer:format(w,
                "  %s = call i64 @llvm_constant_get(i64 %%env, i64 %d)\n",
                result, index);
              result
            ]
        ]
      else if (class == mc:v_function)
        llvm_emit_closure(var[mc:v_fvalue], w)
      else if (class == mc:v_closure)
        [
          | cidx, res |
          cidx = capture_indices[itoa(var[mc:v_number])];
          if (!integer?(cidx)) error(error_bad_value);
          tmp_seq = tmp_seq + 1;
          res = format("%%capture_%d", tmp_seq);
          writer:format(w,
            "  %s = call i64 @llvm_closure_capture_get(i64 %%env, i64 %d)\n",
            res, cidx);
          res
        ]
      else if (class == mc:v_global || class == mc:v_global_constant || class == mc:v_global_define)
        [
          | res |
          tmp_seq = tmp_seq + 1;
          res = format("%%global_%d", tmp_seq);
          writer:format(w,
            "  %s = call i64 @llvm_global_read(i64 %d)\n",
            res, var[mc:v_goffset]);
          res
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

  // Return an indirect variable's storage cell for closure capture.
  llvm_read_var_storage = fn (vector var, w)
    [
      | class, cidx, result |
      class = var[mc:v_class];
      if (class == mc:v_closure)
        [
          cidx = capture_indices[itoa(var[mc:v_number])];
          if (!integer?(cidx)) error(error_bad_value);
          tmp_seq = tmp_seq + 1;
          result = format("%%capture_cell_%d", tmp_seq);
          writer:format(w,
            "  %s = call i64 @llvm_closure_capture_get(i64 %%env, i64 %d)\n",
            result, cidx);
          result
        ]
      else
        [
          tmp_seq = tmp_seq + 1;
          result = format("%%cell_ptr_%d", tmp_seq);
          writer:format(w, "  %s = load i64, ptr %%slot_%d\n",
                        result, var[mc:v_number]);
          result
        ]
    ];

  llvm_write_var = fn (vector var, string val_str, w)
    [
      | class |
      class = var[mc:v_class];
      if (class == mc:v_global || class == mc:v_global_constant || class == mc:v_global_define)
        [
          writer:format(w,
            "  call void @llvm_global_write(i64 %d, i64 %s)\n",
            var[mc:v_goffset], val_str);
        ]
      else if (class == mc:v_closure)
        [
          | cidx, cell |
          cidx = capture_indices[itoa(var[mc:v_number])];
          if (!integer?(cidx)) error(error_bad_value);
          if (var[mc:v_indirect])
            [
              cell = llvm_read_var_storage(var, w);
              writer:format(w,
                "  call void @llvm_variable_set(i64 %s, i64 %s)\n",
                cell, val_str);
            ]
          else
            writer:format(w,
              "  call void @llvm_closure_capture_set(i64 %%env, i64 %d, i64 %s)\n",
              cidx, val_str);
        ]
      else if (class != mc:v_constant && class != mc:v_function)
        [
          | vnum, cell |
          vnum = var[mc:v_number];
          if (var[mc:v_indirect])
            [
              cell = llvm_read_var_storage(var, w);
              writer:format(w,
                "  call void @llvm_variable_set(i64 %s, i64 %s)\n",
                cell, val_str);
            ]
          else
            writer:format(w, "  store i64 %s, ptr %%slot_%d\n", val_str, vnum);
        ];
    ];

  llvm_check_integer_args = fn (args, w)
    lforeach(fn (arg) writer:format(w,
      "  call void @llvm_check_type(i64 %s, i64 %d)\n",
      llvm_read_var(arg, w), type_integer), args);

  llvm_emit_closure = fn (ifn, w)
    [
      | cvars, ncaptures, tmp, res, captures_array, captures_ptr,
        capture_index, parent_var, capture_value, parent_class, self_capture,
        stack_mark, entry_address |
      cvars = ifn[mc:c_fclosure];
      ncaptures = llength(cvars);
      tmp_seq = tmp_seq + 1;
      tmp = tmp_seq;
      res = format("%%cls_%d", tmp);
      self_capture = -1;
      if (ncaptures == 0)
        captures_ptr = "null"
      else
        [
          stack_mark = format("%%closure_stack_%d", tmp);
          captures_array = format("%%closure_captures_%d", tmp);
          writer:format(w, "  %s = call ptr @llvm.stacksave()\n", stack_mark);
          writer:format(w, "  %s = alloca [%d x i64]\n",
                        captures_array, ncaptures);
          capture_index = 0;
          lforeach(fn (capture) [
            | capture_ptr |
            parent_var = capture[mc:v_cparent];
            capture_ptr = format("%%closure_capture_ptr_%d_%d",
                                 tmp, capture_index);
            writer:format(w,
              "  %s = getelementptr inbounds [%d x i64], ptr %s, i64 0, i64 %d\n",
              capture_ptr, ncaptures, captures_array, capture_index);
            if (parent_var == mc:myself)
              [
                self_capture = capture_index;
                writer:format(w, "  store i64 1, ptr %s\n", capture_ptr);
              ]
            else
              [
                parent_class = parent_var[mc:v_class];
                if (parent_var[mc:v_indirect]
                    && parent_class != mc:v_global
                    && parent_class != mc:v_global_constant
                    && parent_class != mc:v_global_define)
                  capture_value = llvm_read_var_storage(parent_var, w)
                else
                  capture_value = llvm_read_var(parent_var, w);
                writer:format(w, "  store i64 %s, ptr %s\n",
                              capture_value, capture_ptr);
              ];
            capture_index = capture_index + 1;
          ], cvars);
          captures_ptr = format("%%closure_captures_data_%d", tmp);
          writer:format(w,
            "  %s = getelementptr inbounds [%d x i64], ptr %s, i64 0, i64 0\n",
            captures_ptr, ncaptures, captures_array);
        ];
      entry_address = format("%%closure_entry_%d", tmp);
      writer:format(w, "  %s = ptrtoint ptr @entry_%d to i64\n",
                    entry_address, ifn[mc:c_fnumber]);
      writer:format(w,
        "  %s = call i64 @llvm_make_function_closure(i64 %s, i64 %d, ptr %s, i64 %d, i64 %d, i64 %%env)\n",
        res, entry_address, llength(ifn[mc:c_ffullargs]), captures_ptr,
        ncaptures, self_capture);
      if (ncaptures != 0)
        writer:format(w, "  call void @llvm.stackrestore(ptr %s)\n", stack_mark);
      res
    ];

  llvm_args_immutable? = fn (args, types)
    [
      | type, arg |
      loop
        [
          if (args == null) exit true;
          @(arg . args) = args;
          if (types)
            [
              type = car(types);
              types = cdr(types);
            ]
          else
            [
              type = mc:const_itype(arg);
              if (!integer?(type)) type = itype_any;
            ];
          if (arg[mc:v_class] != mc:v_constant
              && (type & ~(itype_null | itype_integer
                           | itype_float | itype_bigint)) != 0)
            exit false;
        ];
    ];

  llvm_emit_vector = fn (args, readonly, types, w)
    [
      | values, count, tmp, result, array, ptr, stack_mark, index, immutable |
      values = lmap(fn (arg) llvm_read_var(arg, w), args);
      count = llength(values);
      immutable = readonly && llvm_args_immutable?(args, types);
      tmp_seq = tmp_seq + 1;
      tmp = tmp_seq;
      if (count == 0)
        ptr = "null"
      else
        [
          array = format("%%vector_args_%d", tmp);
          stack_mark = format("%%vector_stack_%d", tmp);
          writer:format(w, "  %s = call ptr @llvm.stacksave()\n", stack_mark);
          writer:format(w, "  %s = alloca [%d x i64]\n", array, count);
          index = 0;
          lforeach(fn (value) [
            ptr = format("%%vector_arg_%d_%d", tmp, index);
            writer:format(w,
              "  %s = getelementptr inbounds [%d x i64], ptr %s, i64 0, i64 %d\n",
              ptr, count, array, index);
            writer:format(w, "  store i64 %s, ptr %s\n", value, ptr);
            index = index + 1;
          ], values);
          ptr = format("%%vector_args_data_%d", tmp);
          writer:format(w,
            "  %s = getelementptr inbounds [%d x i64], ptr %s, i64 0, i64 0\n",
            ptr, count, array);
        ];
      result = format("%%vector_result_%d", tmp);
      writer:format(w,
        "  %s = call i64 @llvm_build_vector(ptr %s, i64 %d, i64 %d, i64 %d)\n",
        result, ptr, count, if (readonly) 1 else 0,
        if (immutable) 1 else 0);
      if (count != 0)
        writer:format(w, "  call void @llvm.stackrestore(ptr %s)\n", stack_mark);
      result
    ];

  llvm_emit_concat = fn (args, w)
    [
      | values, count, tmp, result, array, ptr, stack_mark, index |
      values = lmap(fn (arg) llvm_read_var(arg, w), args);
      count = llength(values);
      tmp_seq = tmp_seq + 1;
      tmp = tmp_seq;
      if (count == 0)
        ptr = "null"
      else
        [
          array = format("%%concat_args_%d", tmp);
          stack_mark = format("%%concat_stack_%d", tmp);
          writer:format(w, "  %s = call ptr @llvm.stacksave()\n", stack_mark);
          writer:format(w, "  %s = alloca [%d x i64]\n", array, count);
          index = 0;
          lforeach(fn (value) [
            ptr = format("%%concat_arg_%d_%d", tmp, index);
            writer:format(w,
              "  %s = getelementptr inbounds [%d x i64], ptr %s, i64 0, i64 %d\n",
              ptr, count, array, index);
            writer:format(w, "  store i64 %s, ptr %s\n", value, ptr);
            index = index + 1;
          ], values);
          ptr = format("%%concat_args_data_%d", tmp);
          writer:format(w,
            "  %s = getelementptr inbounds [%d x i64], ptr %s, i64 0, i64 0\n",
            ptr, count, array);
        ];
      result = format("%%concat_result_%d", tmp);
      writer:format(w,
        "  %s = call i64 @llvm_concat_strings(ptr %s, i64 %d)\n",
        result, ptr, count);
      if (count != 0)
        writer:format(w, "  call void @llvm.stackrestore(ptr %s)\n", stack_mark);
      result
    ];

  llvm_emit_builtin = fn (op, args, w)
    [
      | name, name_index, name_value, values, count, tmp, array, ptr,
        stack_mark, index, result |
      name = if (string?(op)) op
        else if (op == mc:b_negate) "negate" else mc:builtin_names[op];
      name_index = llvm_constant_index(name);
      values = lmap(fn (arg) llvm_read_var(arg, w), args);
      count = llength(values);
      tmp_seq = tmp_seq + 1;
      tmp = tmp_seq;
      name_value = format("%%builtin_name_%d", tmp);
      writer:format(w,
        "  %s = call i64 @llvm_constant_get(i64 %%env, i64 %d)\n",
        name_value, name_index);
      if (count == 0)
        ptr = "null"
      else
        [
          array = format("%%builtin_args_%d", tmp);
          stack_mark = format("%%builtin_stack_%d", tmp);
          writer:format(w, "  %s = call ptr @llvm.stacksave()\n", stack_mark);
          writer:format(w, "  %s = alloca [%d x i64]\n", array, count);
          index = 0;
          lforeach(fn (value) [
            ptr = format("%%builtin_argptr_%d_%d", tmp, index);
            writer:format(w,
              "  %s = getelementptr inbounds [%d x i64], ptr %s, i64 0, i64 %d\n",
              ptr, count, array, index);
            writer:format(w, "  store i64 %s, ptr %s\n", value, ptr);
            index = index + 1;
          ], values);
          ptr = format("%%builtin_args_data_%d", tmp);
          writer:format(w,
            "  %s = getelementptr inbounds [%d x i64], ptr %s, i64 0, i64 0\n",
            ptr, count, array);
        ];
      result = format("%%builtin_result_%d", tmp);
      writer:format(w,
        "  %s = call i64 @llvm_call_global(i64 %s, ptr %s, i64 %d)\n",
        result, name_value, ptr, count);
      if (count != 0)
        writer:format(w, "  call void @llvm.stackrestore(ptr %s)\n", stack_mark);
      result
    ];

  llvm:mgen_preamble = fn (ifn, ainfo)
    [
      | fname, args, vars_seen, add_var, w, code, root_vars, root_count,
        root_slots, root_records, root_slots_data, root_records_data,
        root_token, root_index, arg_no, scan, il, ins, defvar, args_seen |

      w = writer:new_string();
      fname = format("fn_%d", ifn[mc:c_fnumber]);
      args = lmap(fn (fa) fa[0][0], ifn[mc:c_ffullargs]);

      // Function header
      writer:format(w, "define i64 @%s(i64 %%env, ptr %%argv, i64 %%nargs", fname);
      writer:write_line(w, ") {");
      writer:write_line(w, "entry:");
      writer:format(w,
        "  call void @llvm_check_arity(i64 %%nargs, i64 %d, i64 %d)\n",
        ifn[mc:c_farginfo][mc:arginfo_nargs]
          - ifn[mc:c_farginfo][mc:arginfo_noptargs],
        if (ifn[mc:c_farginfo][mc:arginfo_vararg]) -1
        else ifn[mc:c_farginfo][mc:arginfo_nargs]);
      writer:write_line(w, "  call void @llvm_loop_check()\n");

      // Collect all variables used in function
      vars_seen = make_table();
      root_vars = null;

      add_var = fn (v)
        [
          if (vector?(v))
            [
              | class |
              class = v[mc:v_class];
              if (class == mc:v_global || class == mc:v_global_constant || class == mc:v_global_define)
                globals_seen[v[mc:v_name]] = v
              else if (class != mc:v_constant && class != mc:v_function
                       && class != mc:v_closure)
                [
                  vars_seen[itoa(v[mc:v_number])] = v;
                  root_vars = v . root_vars;
                ];
            ]
        ];

      args_seen = make_table();
      lforeach(fn (arg) [
        add_var(arg);
        args_seen[itoa(arg[mc:v_number])] = true;
      ], args);
      if (ifn[mc:c_fnargs_var])
        add_var(ifn[mc:c_fnargs_var][mc:vl_var]);
      if (ifn[mc:c_flocals] != null)
        lforeach(add_var, ifn[mc:c_flocals]);
      if (pair?(ifn[mc:c_fvalue])) mc:flatten_blocks(ifn);
      if (vector?(ifn[mc:c_fvalue]))
        [
          // Some temporaries (notably memory-read results) are not in c_flocals.
          scan = ifn[mc:c_fvalue];
          loop
            [
              il = dget(scan);
              ins = il[mc:il_ins];
              if (ins != null)
                [
                  lforeach(add_var, mc:arguments(ins, null));
                  if (ins[mc:i_class] == mc:i_memory
                      && ins[mc:i_mop] == mc:memory_read)
                    defvar = ins[mc:i_mscalar]
                  else
                    defvar = mc:defined_var(ins);
                  if (defvar) add_var(defvar);
                ];
              scan = dnext(scan);
              if (scan == ifn[mc:c_fvalue]) exit 0;
            ]
        ];

      // Allocate slots for all variables
      table_foreach(fn (@<_ = var>) [
        writer:format(w, "  %%slot_%d = alloca i64\n", var[mc:v_number]);
        writer:format(w, "  store i64 1, ptr %%slot_%d\n", var[mc:v_number]);
      ], vars_seen);

      // Keep Mudlle values in local slots visible to the garbage collector.
      root_count = llength(root_vars);
      root_token = format("%%roots_token_%d", ifn[mc:c_fnumber]);
      if (root_count == 0)
        writer:format(w,
          "  %s = call ptr @llvm_gc_roots_enter(ptr null, i64 0, ptr null)\n",
          root_token)
      else
        [
          root_slots = format("%%root_slots_%d", ifn[mc:c_fnumber]);
          root_records = format("%%root_records_%d", ifn[mc:c_fnumber]);
          writer:format(w, "  %s = alloca [%d x ptr]\n",
                        root_slots, root_count);
          writer:format(w, "  %s = alloca [%d x { ptr, ptr }]\n",
                        root_records, root_count);
          root_index = 0;
          lforeach(fn (root_var) [
            | slot_ptr |
            slot_ptr = format("%%root_slot_ptr_%d_%d",
                              ifn[mc:c_fnumber], root_index);
            writer:format(w,
              "  %s = getelementptr inbounds [%d x ptr], ptr %s, i64 0, i64 %d\n",
              slot_ptr, root_count, root_slots, root_index);
            writer:format(w, "  store ptr %%slot_%d, ptr %s\n",
                          root_var[mc:v_number], slot_ptr);
            root_index = root_index + 1;
          ], root_vars);
          root_slots_data = format("%%root_slots_data_%d", ifn[mc:c_fnumber]);
          root_records_data = format("%%root_records_data_%d", ifn[mc:c_fnumber]);
          writer:format(w,
            "  %s = getelementptr inbounds [%d x ptr], ptr %s, i64 0, i64 0\n",
            root_slots_data, root_count, root_slots);
          writer:format(w,
            "  %s = getelementptr inbounds [%d x { ptr, ptr }], ptr %s, i64 0, i64 0\n",
            root_records_data, root_count, root_records);
          writer:format(w,
            "  %s = call ptr @llvm_gc_roots_enter(ptr %s, i64 %d, ptr %s)\n",
            root_token, root_slots_data, root_count, root_records_data);
        ];

      // Load arguments only after local slots have been registered as roots.
      arg_no = 0;
      lforeach(fn (arg) [
        | vnum, arg_value |
        vnum = arg[mc:v_number];
        if (arg_no == llength(args) - 1
            && last_element(ifn[mc:c_ffullargs])[mc:fullarg_arg][1] == null)
          [
            arg_value = format("%%varargs_%d", ifn[mc:c_fnumber]);
            writer:format(w,
              "  %s = call i64 @llvm_make_varargs(ptr %%argv, i64 %%nargs, i64 %d)\n",
              arg_value, ifn[mc:c_farginfo][mc:arginfo_nargs] - 1);
          ]
        else
          [
            arg_value = format("%%argvalue_%d_%d", ifn[mc:c_fnumber], vnum);
            writer:format(w,
              "  %s = call i64 @llvm_argument_get(ptr %%argv, i64 %%nargs, i64 %d)\n",
              arg_value, arg_no);
          ];
        writer:format(w, "  store i64 %s, ptr %%slot_%d\n", arg_value, vnum);
        arg_no = arg_no + 1;
      ], args);
      if (ifn[mc:c_fnargs_var])
        [
          | nv, tagged_nargs, tagged_nargs_value |
          nv = ifn[mc:c_fnargs_var][mc:vl_var][mc:v_number];
          tagged_nargs = format("%%tagged_nargs_%d", ifn[mc:c_fnumber]);
          tagged_nargs_value = format("%%tagged_nargs_value_%d", ifn[mc:c_fnumber]);
          writer:format(w, "  %s = shl i64 %%nargs, 1\n", tagged_nargs);
          writer:format(w, "  %s = or i64 %s, 1\n", tagged_nargs_value, tagged_nargs);
          writer:format(w, "  store i64 %s, ptr %%slot_%d\n", tagged_nargs_value, nv);
        ];

      // Box variables whose address escapes into a closure. Arguments retain
      // their incoming value; other locals begin as null, like x64's allocator.
      table_foreach(fn (@<_ = var>) [
        if (var[mc:v_indirect])
          [
            | raw, cell |
            if (args_seen[itoa(var[mc:v_number])])
              [
                raw = format("%%indirect_initial_%d", var[mc:v_number]);
                writer:format(w, "  %s = load i64, ptr %%slot_%d\n",
                              raw, var[mc:v_number]);
              ]
            else
              raw = "0";
            cell = format("%%indirect_cell_%d", var[mc:v_number]);
            writer:format(w,
              "  %s = call i64 @llvm_variable_new(i64 %s)\n", cell, raw);
            writer:format(w, "  store i64 %s, ptr %%slot_%d\n",
                          cell, var[mc:v_number]);
          ];
      ], vars_seen);

      code = vector(ifn, w, false); // element 2 is terminated status
      code
    ];

  llvm:mgen_instruction = fn (code, ifn, ainfo, il)
    [
      | w, ins, lbl_num, terminated |
      w = code[1];
      terminated = code[2];

      if (il[mc:il_label])
        [
          lbl_num = il[mc:il_label][mc:l_number];
          if (!terminated)
            writer:format(w, "  br label %%L_%d\n", lbl_num);
          writer:format(w, "L_%d:\n", lbl_num);
          code[2] = false;
          terminated = false;
        ];

      ins = il[mc:il_ins];
      if (ins != null && !terminated)
        [
          gen_ins(ins, w);
          if (ins[mc:i_class] == mc:i_return ||
              (ins[mc:i_class] == mc:i_branch && ins[mc:i_bop] == mc:branch_always))
            code[2] = true;
        ];
    ];

  llvm:assemble = fn (code)
    [
      | w, terminated, ir_str, info |
      w = code[1];
      terminated = code[2];

      if (!terminated)
        error(error_bad_value);

      writer:write_line(w, "}\n");
      ir_str = writer:get_string(w);

      info = make_vector(mc:a_info_fields);
      ir_str . info
    ];

  gen_function = fn (ifn, w)
    [
      | code, fval, scan, il, fname, cidx |
      if (pair?(ifn[mc:c_fvalue]) && string?(car(ifn[mc:c_fvalue])) && string_search(car(ifn[mc:c_fvalue]), "define i64") >= 0)
        [
          writer:write(w, car(ifn[mc:c_fvalue]));
          exit<function> null;
        ];

      current_ifn = ifn;
      capture_indices = make_table();
      cidx = 0;
      lforeach(fn (cvar) [
        capture_indices[itoa(cvar[mc:v_number])] = cidx;
        cidx = cidx + 1;
      ], ifn[mc:c_fclosure]);

      code = llvm:mgen_preamble(ifn, null);
      fval = ifn[mc:c_fvalue];
      if (vector?(fval))
        [
          scan = fval;
          loop
            [
              il = dget(scan);
              llvm:mgen_instruction(code, ifn, null, il);
              scan = dnext(scan);
              if (scan == fval) exit 0
            ]
        ];
      writer:write(w, car(llvm:assemble(code)));

      // Export the native argument-vector ABI to the runtime closure bridge.
      fname = format("entry_%d", ifn[mc:c_fnumber]);
      writer:format(w,
        "define i64 @%s(i64 %%env, ptr %%args, i64 %%nargs) {\nentry:\n",
        fname);
      writer:format(w, "  %%entry_result = call i64 @fn_%d(i64 %%env, ptr %%args, i64 %%nargs",
                    ifn[mc:c_fnumber]);
      writer:write_line(w, ")");
      writer:write_line(w, "  ret i64 %entry_result");
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
          if (op == mc:b_iadd || op == mc:b_bitand
              || op == mc:b_bitor || op == mc:b_bitxor
              || op == mc:b_shift_left || op == mc:b_shift_right
              || op == mc:b_bitnot)
            llvm_check_integer_args(args, w);
          if (op == mc:b_add || op == mc:b_subtract
              || op == mc:b_multiply || op == mc:b_divide
              || op == mc:b_remainder || op == mc:b_negate
              || op == mc:b_lt || op == mc:b_le
              || op == mc:b_gt || op == mc:b_ge)
            llvm_write_var(dest_var, llvm_emit_builtin(op, args, w), w)
          else if (op == mc:b_vector || op == mc:b_sequence)
            llvm_write_var(dest_var,
              llvm_emit_vector(args, op == mc:b_sequence,
                               ins[mc:i_atypes], w), w)
          else if (op == mc:b_iadd || op == mc:b_add)
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
          else if (op == mc:b_divide)
            [
              | a1, a2, u1, u2, d1, res, tagged_res |
              a1 = llvm_read_var(car(args), w);
              a2 = llvm_read_var(cadr(args), w);
              tmp_seq = tmp_seq + 1;
              u1 = format("%%u1_%d", tmp_seq);
              u2 = format("%%u2_%d", tmp_seq);
              d1 = format("%%d1_%d", tmp_seq);
              res = format("%%res_%d", tmp_seq);
              writer:format(w, "  %s = ashr i64 %s, 1\n", u1, a1);
              writer:format(w, "  %s = ashr i64 %s, 1\n", u1, a1);
              writer:format(w, "  %s = ashr i64 %s, 1\n", u2, a2);
              writer:format(w, "  %s = sdiv i64 %s, %s\n", d1, u1, u2);
              writer:format(w, "  %s = shl i64 %s, 1\n", res, d1);
              tagged_res = format("%%tagged_div_%d", tmp_seq);
              writer:format(w, "  %s = or i64 %s, 1\n", tagged_res, res);
              llvm_write_var(dest_var, tagged_res, w);
            ]
          else if (op == mc:b_bitand)
            [
              | a1, a2, res |
              a1 = llvm_read_var(car(args), w);
              a2 = llvm_read_var(cadr(args), w);
              tmp_seq = tmp_seq + 1;
              res = format("%%res_%d", tmp_seq);
              writer:format(w, "  %s = and i64 %s, %s\n", res, a1, a2);
              llvm_write_var(dest_var, res, w);
            ]
          else if (op == mc:b_bitor)
            [
              | a1, a2, res |
              a1 = llvm_read_var(car(args), w);
              a2 = llvm_read_var(cadr(args), w);
              tmp_seq = tmp_seq + 1;
              res = format("%%res_%d", tmp_seq);
              writer:format(w, "  %s = or i64 %s, %s\n", res, a1, a2);
              llvm_write_var(dest_var, res, w);
            ]
          else if (op == mc:b_bitxor)
            [
              | a1, a2, x1, res |
              a1 = llvm_read_var(car(args), w);
              a2 = llvm_read_var(cadr(args), w);
              tmp_seq = tmp_seq + 1;
              x1 = format("%%x1_%d", tmp_seq);
              res = format("%%res_%d", tmp_seq);
              writer:format(w, "  %s = xor i64 %s, %s\n", x1, a1, a2);
              writer:format(w, "  %s = or i64 %s, 1\n", res, x1);
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
          else if (op == mc:b_lt || op == mc:b_le
                   || op == mc:b_gt || op == mc:b_ge)
            [
              | a1, a2, cmp, res, cmpop |
              a1 = llvm_read_var(car(args), w);
              a2 = llvm_read_var(cadr(args), w);
              cmpop = if (op == mc:b_lt) "slt"
                else if (op == mc:b_le) "sle"
                else if (op == mc:b_gt) "sgt" else "sge";
              tmp_seq = tmp_seq + 1;
              cmp = format("%%cmp_%d", tmp_seq);
              res = format("%%res_%d", tmp_seq);
              writer:format(w, "  %s = icmp %s i64 %s, %s\n",
                            cmp, cmpop, a1, a2);
              writer:format(w, "  %s = select i1 %s, i64 3, i64 1\n", res, cmp);
              llvm_write_var(dest_var, res, w);
            ]
          else if (op == mc:b_remainder)
            [
              | a1, a2, u1, u2, rem, res, tagged_res |
              a1 = llvm_read_var(car(args), w);
              a2 = llvm_read_var(cadr(args), w);
              tmp_seq = tmp_seq + 1;
              u1 = format("%%u1_%d", tmp_seq);
              u2 = format("%%u2_%d", tmp_seq);
              rem = format("%%rem_%d", tmp_seq);
              res = format("%%res_%d", tmp_seq);
              writer:format(w, "  %s = ashr i64 %s, 1\n", u1, a1);
              writer:format(w, "  %s = ashr i64 %s, 1\n", u2, a2);
              writer:format(w, "  %s = srem i64 %s, %s\n", rem, u1, u2);
              writer:format(w, "  %s = shl i64 %s, 1\n", res, rem);
              tagged_res = format("%%tagged_rem_%d", tmp_seq);
              writer:format(w, "  %s = or i64 %s, 1\n", tagged_res, res);
              llvm_write_var(dest_var, tagged_res, w);
            ]
          else if (op == mc:b_shift_left || op == mc:b_shift_right)
            [
              | a1, a2, u1, u2, shift_count, shifted, res, shiftop, tagged_res |
              a1 = llvm_read_var(car(args), w);
              a2 = llvm_read_var(cadr(args), w);
              tmp_seq = tmp_seq + 1;
              u1 = format("%%u1_%d", tmp_seq);
              u2 = format("%%u2_%d", tmp_seq);
              shift_count = format("%%shift_count_%d", tmp_seq);
              shifted = format("%%shift_%d", tmp_seq);
              res = format("%%res_%d", tmp_seq);
              shiftop = if (op == mc:b_shift_left) "shl" else "ashr";
              writer:format(w, "  %s = ashr i64 %s, 1\n", u1, a1);
              writer:format(w, "  %s = ashr i64 %s, 1\n", u2, a2);
              writer:format(w, "  %s = and i64 %s, 63\n", shift_count, u2);
              writer:format(w, "  %s = %s i64 %s, %s\n",
                            shifted, shiftop, u1, shift_count);
              writer:format(w, "  %s = shl i64 %s, 1\n", res, shifted);
              tagged_res = format("%%tagged_shift_%d", tmp_seq);
              writer:format(w, "  %s = or i64 %s, 1\n", tagged_res, res);
              llvm_write_var(dest_var, tagged_res, w);
            ]
          else if (op == mc:b_negate || op == mc:b_bitnot)
            [
              | arg, untagged, changed, res, tagged_res |
              arg = llvm_read_var(car(args), w);
              tmp_seq = tmp_seq + 1;
              untagged = format("%%unboxed_%d", tmp_seq);
              changed = format("%%changed_%d", tmp_seq);
              res = format("%%res_%d", tmp_seq);
              writer:format(w, "  %s = ashr i64 %s, 1\n", untagged, arg);
              if (op == mc:b_negate)
                writer:format(w, "  %s = sub i64 0, %s\n", changed, untagged)
              else
                writer:format(w, "  %s = xor i64 %s, -1\n", changed, untagged);
              writer:format(w, "  %s = shl i64 %s, 1\n", res, changed);
              tagged_res = format("%%tagged_neg_%d", tmp_seq);
              writer:format(w, "  %s = or i64 %s, 1\n", tagged_res, res);
              llvm_write_var(dest_var, tagged_res, w);
            ]
          else if (op == mc:b_logical_not)
            [
              | arg, cmp, res |
              arg = llvm_read_var(car(args), w);
              tmp_seq = tmp_seq + 1;
              cmp = format("%%cmp_%d", tmp_seq);
              res = format("%%res_%d", tmp_seq);
              writer:format(w, "  %s = icmp eq i64 %s, 1\n", cmp, arg);
              writer:format(w, "  %s = select i1 %s, i64 3, i64 1\n", res, cmp);
              llvm_write_var(dest_var, res, w);
            ]
          else if (op == mc:b_logical_xor)
            [
              | a1, a2, truth1, truth2, xorv, res |
              a1 = llvm_read_var(car(args), w);
              a2 = llvm_read_var(cadr(args), w);
              tmp_seq = tmp_seq + 1;
              truth1 = format("%%truth1_%d", tmp_seq);
              truth2 = format("%%truth2_%d", tmp_seq);
              xorv = format("%%xor_%d", tmp_seq);
              res = format("%%res_%d", tmp_seq);
              writer:format(w, "  %s = icmp ne i64 %s, 1\n", truth1, a1);
              writer:format(w, "  %s = icmp ne i64 %s, 1\n", truth2, a2);
              writer:format(w, "  %s = xor i1 %s, %s\n", xorv, truth1, truth2);
              writer:format(w, "  %s = select i1 %s, i64 3, i64 1\n", res, xorv);
              llvm_write_var(dest_var, res, w);
            ]
          else if (op == mc:b_car || op == mc:b_cdr)
            [
              | arg, res, helper |
              arg = llvm_read_var(car(args), w);
              tmp_seq = tmp_seq + 1;
              res = format("%%res_%d", tmp_seq);
              helper = if (op == mc:b_car) "llvm_pair_car" else "llvm_pair_cdr";
              writer:format(w, "  %s = call i64 @%s(i64 %s)\n",
                            res, helper, arg);
              llvm_write_var(dest_var, res, w);
            ]
          else if (op == mc:b_funcarg)
            [
              | arg_index, arg_value |
              arg_index = car(args)[mc:v_kvalue];
              tmp_seq = tmp_seq + 1;
              arg_value = format("%%funcarg_%d", tmp_seq);
              writer:format(w,
                "  %s = call i64 @llvm_argument_get(ptr %%argv, i64 %%nargs, i64 %d)\n",
                arg_value, arg_index);
              llvm_write_var(dest_var, arg_value, w);
            ]
          else if (op == mc:b_assign)
            [
              | a1 |
              a1 = llvm_read_var(car(args), w);
              llvm_write_var(dest_var, a1, w);
            ]
          else if (op == mc:b_slength || op == mc:b_vlength
                   || op == mc:b_typeof || op == mc:b_loop_count
                   || op == mc:b_max_loop_count
                   || op == mc:b_symbol_name || op == mc:b_symbol_get
                   || op == mc:b_cons || op == mc:b_pcons
                   || op == mc:b_ref || op == mc:b_set
                   || op == mc:b_ffs)
            llvm_write_var(dest_var, llvm_emit_builtin(op, args, w), w)
          else
            error(error_bad_value)
        ]
      else if (class == mc:i_memory)
        [
          | array, array_ptr, field_ptr, value_str, offset |
          array = llvm_read_var(ins[mc:i_marray], w);
          tmp_seq = tmp_seq + 1;
          array_ptr = format("%%array_%d", tmp_seq);
          field_ptr = format("%%field_%d", tmp_seq);
          offset = 16 + 8 * ins[mc:i_mindex];
          writer:format(w, "  %s = inttoptr i64 %s to ptr\n",
                        array_ptr, array);
          writer:format(w, "  %s = getelementptr inbounds i8, ptr %s, i64 %d\n",
                        field_ptr, array_ptr, offset);

          if (ins[mc:i_mop] == mc:memory_read)
            [
              value_str = format("%%mem_%d", tmp_seq);
              writer:format(w, "  %s = load i64, ptr %s\n", value_str, field_ptr);
              llvm_write_var(ins[mc:i_mscalar], value_str, w);
            ]
          else if (ins[mc:i_mop] == mc:memory_write
                   || ins[mc:i_mop] == mc:memory_write_safe)
            [
              if (ins[mc:i_mop] == mc:memory_write_safe)
                writer:format(w,
                  "  call void @llvm_check_mutable(i64 %s)\n", array);
              value_str = llvm_read_var(ins[mc:i_mscalar], w);
              writer:format(w, "  store i64 %s, ptr %s\n", value_str, field_ptr);
            ]
          else
            error(error_bad_value);
        ]
      else if (class == mc:i_branch)
        [
          | op, dest_lbl, args |
          op = ins[mc:i_bop];
          dest_lbl = ins[mc:i_bdest][mc:l_number];
          args = ins[mc:i_bargs];
          if (op == mc:branch_lt || op == mc:branch_ge
              || op == mc:branch_le || op == mc:branch_gt)
            llvm_check_integer_args(args, w);

          if (op == mc:branch_never)
            null
          else if (op == mc:branch_always)
            [
              writer:format(w, "  br label %%L_%d\n", dest_lbl);
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
              else if (op == mc:branch_bitand || op == mc:branch_nbitand)
                [
                  | u1, u2, bits, predicate |
                  writer:format(w,
                    "  call void @llvm_check_type(i64 %s, i64 %d)\n",
                    llvm_read_var(car(args), w), type_integer);
                  writer:format(w,
                    "  call void @llvm_check_type(i64 %s, i64 %d)\n",
                    llvm_read_var(cadr(args), w), type_integer);
                  v1 = llvm_read_var(car(args), w);
                  v2 = llvm_read_var(cadr(args), w);
                  u1 = format("%%branch_u1_%d", seq);
                  u2 = format("%%branch_u2_%d", seq);
                  bits = format("%%branch_bits_%d", seq);
                  writer:format(w, "  %s = ashr i64 %s, 1\n", u1, v1);
                  writer:format(w, "  %s = ashr i64 %s, 1\n", u2, v2);
                  writer:format(w, "  %s = and i64 %s, %s\n", bits, u1, u2);
                  predicate = if (op == mc:branch_bitand) "ne" else "eq";
                  writer:format(w, "  %s = icmp %s i64 %s, 0\n",
                                cmp, predicate, bits);
                ]
              else if (op == mc:branch_bitset || op == mc:branch_bitclear)
                [
                  | bit_result |
                  bit_result = llvm_emit_builtin("bit_set?", args, w);
                  writer:format(w, "  %s = icmp %s i64 %s, 1\n", cmp,
                    if (op == mc:branch_bitset) "ne" else "eq", bit_result);
                ]
              else if (op == mc:branch_xor || op == mc:branch_xnor)
                [
                  | truth1, truth2, xorv |
                  v1 = llvm_read_var(car(args), w);
                  v2 = llvm_read_var(cadr(args), w);
                  truth1 = format("%%branch_truth1_%d", seq);
                  truth2 = format("%%branch_truth2_%d", seq);
                  xorv = format("%%branch_xor_%d", seq);
                  writer:format(w, "  %s = icmp ne i64 %s, 1\n", truth1, v1);
                  writer:format(w, "  %s = icmp ne i64 %s, 1\n", truth2, v2);
                  writer:format(w, "  %s = xor i1 %s, %s\n", xorv, truth1, truth2);
                  if (op == mc:branch_xor)
                    writer:format(w, "  %s = or i1 %s, false\n", cmp, xorv)
                  else
                    writer:format(w, "  %s = xor i1 %s, true\n", cmp, xorv);
                ]
              else if (op == mc:branch_vfind? || op == mc:branch_vnfind?)
                [
                  | found |
                  v1 = llvm_read_var(car(args), w);
                  v2 = llvm_read_var(cadr(args), w);
                  found = format("%%vfind_%d", seq);
                  writer:format(w,
                    "  %s = call i32 @llvm_vector_find(i64 %s, i64 %s)\n",
                    found, v1, v2);
                  writer:format(w, "  %s = icmp %s i32 %s, 0\n", cmp,
                    if (op == mc:branch_vfind?) "ne" else "eq", found);
                ]
              else if (op == mc:branch_equal || op == mc:branch_nequal)
                [
                  | equal |
                  v1 = llvm_read_var(car(args), w);
                  v2 = llvm_read_var(cadr(args), w);
                  equal = format("%%equal_%d", seq);
                  writer:format(w,
                    "  %s = call i32 @llvm_equal(i64 %s, i64 %s)\n",
                    equal, v1, v2);
                  writer:format(w, "  %s = icmp %s i32 %s, 0\n", cmp,
                    if (op == mc:branch_equal) "ne" else "eq", equal);
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
              else if (op >= mc:branch_slength && op < mc:branch_equal)
                [
                  | length, relation, kind, lenop |
                  v1 = llvm_read_var(car(args), w);
                  v2 = llvm_read_var(cadr(args), w);
                  kind = if (op < mc:branch_vlength) 1 else 0;
                  relation = if (kind == 1)
                    op - mc:branch_slength else op - mc:branch_vlength;
                  lenop = if (relation == 0) "eq"
                    else if (relation == 1) "ne"
                    else if (relation == 2) "slt"
                    else if (relation == 3) "sge"
                    else if (relation == 4) "sle" else "sgt";
                  length = format("%%length_%d", seq);
                  writer:format(w,
                    "  %s = call i64 @llvm_object_length(i64 %s, i64 %d)\n",
                    length, v1, kind);
                  writer:format(w,
                    "  %s = icmp %s i64 %s, %s\n", cmp, lenop, length, v2);
                ]
              else if ((op >= mc:branch_type? && op < mc:branch_ntype?)
                       || (op >= mc:branch_ntype?
                           && op < mc:branch_ntype?
                             + mudlle_synthetic_types))
                [
                  | type_idx, matched_value |
                  v1 = llvm_read_var(car(args), w);
                  if (op < mc:branch_ntype?)
                    type_idx = op - mc:branch_type?
                  else
                    type_idx = op - mc:branch_ntype?;
                  matched_value = format("%%typematch_%d", seq);
                  writer:format(w,
                    "  %s = call i32 @llvm_type_matches(i64 %s, i64 %d)\n",
                    matched_value, v1, type_idx);
                  writer:format(w, "  %s = icmp %s i32 %s, 0\n", cmp,
                    if (op < mc:branch_ntype?) "ne" else "eq", matched_value);
                ]
              else if (op >= mc:branch_immutable
                       && op <= mc:branch_not_prim)
                [
                  | predicate, matched_value |
                  v1 = llvm_read_var(car(args), w);
                  predicate = op - mc:branch_immutable;
                  if (op == mc:branch_any_prim) predicate = 4;
                  if (op == mc:branch_not_prim) predicate = 5;
                  matched_value = format("%%predicate_%d", seq);
                  writer:format(w,
                    "  %s = call i32 @llvm_predicate(i64 %s, i64 %d)\n",
                    matched_value, v1, predicate);
                  writer:format(w, "  %s = icmp ne i32 %s, 0\n", cmp, matched_value);
                ]
              else
                error(error_bad_value);

              writer:format(w, "  br i1 %s, label %%L_%d, label %%L_next_%d\n", cmp, dest_lbl, seq);
              writer:format(w, "L_next_%d:\n", seq);
            ];
        ]
      else if (class == mc:i_call)
        [
          | dest_var, fn_var, called_ifn, call_args, cname, res,
            arg_vstrs, arg_array, arg_ptr, arg_index, stack_mark,
            secure_call |
          dest_var = ins[mc:i_cdest];
          call_args = ins[mc:i_cargs];
          fn_var = car(call_args);
          call_args = cdr(call_args);
          secure_call = fn_var[mc:v_class] == mc:v_global_constant;
          called_ifn = if (fn_var[mc:v_class] == mc:v_function)
            fn_var[mc:v_fvalue] else null;

          arg_vstrs = lmap(fn (arg) llvm_read_var(arg, w), call_args);

          tmp_seq = tmp_seq + 1;
          res = format("%%call_%d", tmp_seq);
          [
              cname = if (called_ifn != null)
                llvm_emit_closure(called_ifn, w)
              else
                llvm_read_var(fn_var, w);
              if (arg_vstrs == null)
                arg_ptr = "null"
              else
                [
                  arg_array = format("%%call_args_%d", tmp_seq);
                  stack_mark = format("%%call_stack_%d", tmp_seq);
                  writer:format(w, "  %s = call ptr @llvm.stacksave()\n",
                                stack_mark);
                  writer:format(w, "  %s = alloca [%d x i64]\n",
                                arg_array, llength(arg_vstrs));
                  arg_index = 0;
                  lforeach(fn (vstr) [
                    arg_ptr = format("%%call_argptr_%d_%d", tmp_seq, arg_index);
                    writer:format(w,
                      "  %s = getelementptr inbounds [%d x i64], ptr %s, i64 0, i64 %d\n",
                      arg_ptr, llength(arg_vstrs), arg_array, arg_index);
                    writer:format(w, "  store i64 %s, ptr %s\n", vstr, arg_ptr);
                    arg_index = arg_index + 1;
                  ], arg_vstrs);
                  arg_ptr = format("%%call_args_data_%d", tmp_seq);
                  writer:format(w,
                    "  %s = getelementptr inbounds [%d x i64], ptr %s, i64 0, i64 0\n",
                    arg_ptr, llength(arg_vstrs), arg_array);
                ];
              writer:format(w,
                "  %s = call i64 @llvm_call_value(i64 %s, ptr %s, i64 %d, i64 %d)\n",
                res, cname, arg_ptr, llength(arg_vstrs), if (secure_call) 1 else 0);
              if (arg_vstrs != null)
                writer:format(w,
                  "  call void @llvm.stackrestore(ptr %s)\n", stack_mark);
            ];
          llvm_write_var(dest_var, res, w);
        ]
      else if (class == mc:i_closure)
        [
          | dest_var, ifn, res |
          dest_var = ins[mc:i_fdest];
          ifn = ins[mc:i_ffunction];
          res = llvm_emit_closure(ifn, w);
          llvm_write_var(dest_var, res, w);
        ]
      else if (class == mc:i_maybe_sconcat)
        [
          | res |
          res = llvm_emit_concat(ins[mc:i_scargs], w);
          llvm_write_var(ins[mc:i_scdest], res, w);
        ]
      else if (class == mc:i_return)
        [
          | rval |
          rval = llvm_read_var(ins[mc:i_rvalue], w);
          writer:format(w,
            "  call void @llvm_gc_roots_leave(ptr %%roots_token_%d)\n",
            current_ifn[mc:c_fnumber]);
          writer:format(w, "  ret i64 %s\n", rval);
        ]
      else if (class == mc:i_trap)
        [
          | nerror, argument, args |
          if (mc:trap_is_unreachable?(ins))
            writer:write_line(w, "  unreachable")
          else if (ins[mc:i_top] == mc:trap_always)
            [
              nerror = ins[mc:i_tdest];
              argument = mc:trap_is_nomatch?(ins);
              if (argument)
                argument = llvm_read_var(argument, w)
              else
                argument = "0";
              writer:format(w,
                "  call void @llvm_raise_error(i64 %d, i64 %s)\n",
                nerror, argument);
              writer:write_line(w, "  unreachable");
            ]
          else if (ins[mc:i_top] == mc:trap_loop)
            writer:write_line(w, "  call void @llvm_loop_check()")
          else if (ins[mc:i_top] == mc:trap_type)
            [
              args = ins[mc:i_targs];
              argument = llvm_read_var(car(args), w);
              nerror = cadr(args)[mc:v_kvalue];
              writer:format(w,
                "  call void @llvm_check_type(i64 %s, i64 %d)\n",
                argument, nerror);
            ]
          else if (ins[mc:i_top] == mc:trap_typeset)
            [
              args = ins[mc:i_targs];
              argument = llvm_read_var(car(args), w);
              nerror = cadr(args)[mc:v_kvalue];
              writer:format(w,
                "  call void @llvm_check_typeset(i64 %s, i64 %d, i64 %d)\n",
                argument, nerror, caddr(args)[mc:v_kvalue]);
            ]
          else if (ins[mc:i_top] == mc:trap_global_read
                   || ins[mc:i_top] == mc:trap_global_write
                   || ins[mc:i_top] == mc:trap_never)
            null
          else
            error(error_bad_value);
        ]
      else if (class == mc:i_nop)
        [
          writer:write_line(w, "  ; nop");
        ]
      else
        error(error_bad_value);
    ];

  mc:gen_llvm_function = gen_function;

  mc:compile_llvm_asm = fn "mod, string asm_filename -> status. Compiles module to LLVM IR and runs llc to produce native assembly" (mod, string asm_filename)
    [
      | ll_filename, w, cmd, status |
      ll_filename = asm_filename + ".ll";
      w = writer:new_file(ll_filename);
      mc:gen_llvm_ir(mod, w);
      writer:close(w);

      cmd = format("llc %s -o %s", ll_filename, asm_filename);
      status = system_cmd(cmd);
      remove(ll_filename);
      status == 0
    ];

  mc:gen_llvm_ir = fn "mod, {writer,null} w, functions -> . Generates LLVM IR for module" (mod, {vector,null} w = null, fns = null)
    [
      | created_w |
      globals_seen = make_table();
      llvm_constant_list = null;
      llvm_constant_values = null;

      if (fns == null)
        if (vector?(mod[mc:m_body]) && vlength(mod[mc:m_body]) > 6
            && pair?(mod[mc:m_body][mc:c_fvalue]))
          fns = mc:all_functions(mod[mc:m_body])
        else
          [
            mc:phase1(mod, 15, null);
            mc:phase2(mod);
            fns = mc:all_functions(mod[mc:m_body]);
            mc:phase3(fns);
          ];

      if (w == null)
        [
          w = writer:new_string();
          created_w = true;
        ]
      else
        created_w = false;

      // Let llc select its host target and data layout.

      writer:write_line(w, "; Runtime declarations");
      writer:write_line(w, "declare i64 @alloc(i64, i64)");
      writer:write_line(w, "declare i64 @pcons(i64, i64)");
      writer:write_line(w, "declare i64 @make_vector(i64)");
      writer:write_line(w, "declare void @error(i64)\n");
      writer:write_line(w, "declare i64 @llvm_call_value(i64, ptr, i64, i64)\n");
      writer:write_line(w, "declare i64 @llvm_call_global(i64, ptr, i64)\n");
      writer:write_line(w, "declare i64 @llvm_argument_get(ptr, i64, i64)\n");
      writer:write_line(w, "declare i64 @llvm_make_varargs(ptr, i64, i64)\n");
      writer:write_line(w, "declare void @llvm_check_arity(i64, i64, i64)\n");
      writer:write_line(w, "declare i64 @llvm_build_vector(ptr, i64, i64, i64)\n");
      writer:write_line(w, "declare i64 @llvm_concat_strings(ptr, i64)\n");
      writer:write_line(w, "declare i64 @llvm_make_function_closure(i64, i64, ptr, i64, i64, i64)\n");
      writer:write_line(w, "declare i64 @llvm_constant_get(i64, i64)\n");
      writer:write_line(w, "declare i64 @llvm_closure_capture_get(i64, i64)\n");
      writer:write_line(w, "declare void @llvm_closure_capture_set(i64, i64, i64)\n");
      writer:write_line(w, "declare i64 @llvm_variable_new(i64)\n");
      writer:write_line(w, "declare i64 @llvm_variable_get(i64)\n");
      writer:write_line(w, "declare void @llvm_variable_set(i64, i64)\n");
      writer:write_line(w, "declare void @llvm_raise_error(i64, i64)\n");
      writer:write_line(w, "declare void @llvm_loop_check()\n");
      writer:write_line(w, "declare void @llvm_check_type(i64, i64)\n");
      writer:write_line(w, "declare void @llvm_check_typeset(i64, i64, i64)\n");
      writer:write_line(w, "declare void @llvm_check_mutable(i64)\n");
      writer:write_line(w, "declare i32 @llvm_type_matches(i64, i64)\n");
      writer:write_line(w, "declare i64 @llvm_object_length(i64, i64)\n");
      writer:write_line(w, "declare i32 @llvm_predicate(i64, i64)\n");
      writer:write_line(w, "declare i32 @llvm_vector_find(i64, i64)\n");
      writer:write_line(w, "declare i64 @llvm_pair_car(i64)\n");
      writer:write_line(w, "declare i64 @llvm_pair_cdr(i64)\n");
      writer:write_line(w, "declare i32 @llvm_equal(i64, i64)\n");
      writer:write_line(w, "declare ptr @llvm_gc_roots_enter(ptr, i64, ptr)\n");
      writer:write_line(w, "declare void @llvm_gc_roots_leave(ptr)\n");
      writer:write_line(w, "declare i64 @llvm_global_read(i64)\n");
      writer:write_line(w, "declare void @llvm_global_write(i64, i64)\n");
      writer:write_line(w, "declare ptr @llvm.stacksave()\n");
      writer:write_line(w, "declare void @llvm.stackrestore(ptr)\n");

      lforeach(fn (ifn) gen_function(ifn, w), fns);
      llvm_constant_values = lmap(fn (entry) car(entry),
                                  lreverse!(llvm_constant_list));

      if (created_w)
        writer:get_string(w)
      else
        true
    ];

];
