/*
 * Copyright (c) 2026 Nils Schimmelmann
 * All rights reserved.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose, without fee, and without written agreement is hereby granted,
 * provided that the above copyright notice and the following two paragraphs
 * appear in all copies of this software.
 *
 * IN NO EVENT SHALL NILS SCHIMMELMANN BE LIABLE TO ANY PARTY FOR DIRECT,
 * INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE
 * USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF NILS SCHIMMELMANN HAS
 * BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * NILS SCHIMMELMANN SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 * PARTICULAR PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS"
 * BASIS, AND NILS SCHIMMELMANN HAS NO OBLIGATION TO PROVIDE MAINTENANCE,
 * SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.
 */

/*
 * LLVM IR Generator for Mudlle
 */

library genllvm
requires asmwriter, compiler, dlist, flow, graph, ins3, misc, optimise, phase1,
  phase2, phase3, sequences, vars

defines mc:gen_llvm_ir, mc:gen_llvm_function,
  mc:llvm_constants, mc:llvm_global_relocations,
  llvm:mgen_preamble, llvm:mgen_instruction, llvm:assemble

reads mc:c_fnumber, mc:c_flocals, mc:update_maxseclev

[
    | llvm_read_var, llvm_write_var, gen_ins, gen_function, tmp_seq,
    globals_seen, current_ifn, capture_indices, llvm_constant_list,
    llvm_constant_index,
    llvm_emit_closure, llvm_check_integer_args, llvm_emit_loop_check,
    llvm_emit_integer_type_check, llvm_integer_comparison?,
    llvm_check_comparison_types, llvm_check_typed_integer_args,
    llvm_args_immutable?,
    llvm_emit_vector, llvm_emit_concat, llvm_emit_builtin,
    llvm_emit_binary_builtin, llvm_emit_ref, llvm_emit_set,
    llvm_read_var_storage, llvm_read_env,
    llvm_emit_rooted_arguments, llvm_emit_copying_arguments,
    llvm_constant_values, llvm_global_relocation_values,
    function_roots_required,
    llvm_function_may_allocate?, llvm_allocate_slots, llvm_slot_number,
    slot_indices, llvm_instruction_may_allocate?, root_slot_indices, nonallocating_ops, nonallocating_branches, vector_find_required |

  tmp_seq = 0;
  globals_seen = make_table();
  current_ifn = null;
  function_roots_required = false;
  slot_indices = make_table();
  root_slot_indices = null;
  capture_indices = make_table();
  llvm_constant_list = null;
  llvm_constant_values = null;
  llvm_global_relocation_values = null;
  mc:llvm_constants = fn () llvm_constant_values;
  mc:llvm_global_relocations = fn () llvm_global_relocation_values;

  nonallocating_ops = list(mc:b_iadd, mc:b_bitand, mc:b_bitor, mc:b_bitxor,
                  mc:b_shift_left, mc:b_shift_right, mc:b_bitnot,
                  mc:b_logical_xor, mc:b_assign, mc:b_funcarg,
                  mc:b_car, mc:b_cdr);
  nonallocating_branches = list(mc:branch_never, mc:branch_always,
                       mc:branch_true, mc:branch_false,
                       mc:branch_eq, mc:branch_ne,
                       mc:branch_bitand, mc:branch_nbitand,
                       mc:branch_xor, mc:branch_xnor);

  llvm_slot_number = fn (var)
    [
      | slot |
      slot = slot_indices[itoa(var[mc:v_number])];
      if (integer?(slot)) slot else var[mc:v_number]
    ];

  // GC-visible slots escape to C, so LLVM cannot reuse their stack storage.
  // Color the compiler's interference graph before flattening its blocks.
  // Indirect variables keep exclusive slots because their cells are created
  // at entry and may be used by closures throughout the function.
  llvm_allocate_slots = fn (ifn)
    [
      | vars, neighbors, add_edges, all, args, color, live_roots, entry_allocates, immediate_vars, immediate_ops,
        root_variables |
      slot_indices = make_table();
      root_slot_indices = null;
      if (!pair?(ifn[mc:c_fvalue])) exit<function> null;
      mc:recompute_vars(ifn, false);
      mc:flow_live(ifn);
      vars = ifn[mc:c_flocals];
      neighbors = make_table();
      all = mc:new_varset(ifn);
      live_roots = mc:new_varset(ifn);
      immediate_vars = make_table();
      immediate_ops = list(mc:b_iadd, mc:b_bitand, mc:b_bitor, mc:b_bitxor,
                           mc:b_shift_left, mc:b_shift_right, mc:b_bitnot,
                           mc:b_logical_xor, mc:b_logical_not,
                           mc:b_eq, mc:b_ne, mc:b_lt, mc:b_le,
                           mc:b_gt, mc:b_ge);
      entry_allocates = ifn[mc:c_fnargs_var]
        || ifn[mc:c_farginfo][mc:arginfo_vararg]
        || lexists?(fn (v) v[mc:v_indirect], vars)
        || lexists?(fn (fa) fa[0][0][mc:v_indirect], ifn[mc:c_ffullargs]);
      lforeach(fn (v) [
        neighbors[itoa(v[mc:v_number])] = mc:new_varset(ifn);
        immediate_vars[itoa(v[mc:v_number])] = true;
        set_bit!(all, v[mc:v_number]);
      ], vars);
      add_edges = fn (live)
        bforeach(fn (n) [
          | edges |
          edges = neighbors[itoa(n)];
          if (edges != null) bunion!(edges, live);
        ], live);
      graph_nodes_apply(fn (node) [
        mc:rscan_live(fn (il, live_in, live_out, x) [
          | ins, dest |
          ins = il[mc:il_ins];
          if (ins != null) [
            dest = mc:defined_var(ins);
            if (dest && (ins[mc:i_class] != mc:i_compute
                || (!lexists?(fn (op) op == ins[mc:i_aop], immediate_ops)
                    && !(ins[mc:i_aop] == mc:b_assign
                         && car(ins[mc:i_aargs])[mc:v_class] == mc:v_constant
                         && (integer?(car(ins[mc:i_aargs])[mc:v_kvalue])
                             || car(ins[mc:i_aargs])[mc:v_kvalue] == null)))))
              immediate_vars[itoa(dest[mc:v_number])] = false;
            // This optional instruction has a destination outside defined_var.
            if (ins[mc:i_class] == mc:i_maybe_sconcat)
              immediate_vars[itoa(ins[mc:i_scdest][mc:v_number])] = false;
          ];
          add_edges(live_in);
          add_edges(live_out);
          if (il[mc:il_ins] != null
              && llvm_instruction_may_allocate?(il[mc:il_ins]))
            bunion!(live_roots, live_in);
          null
        ], null, graph_node_get(node));
      ], cdr(ifn[mc:c_fvalue]));
      // All arguments are loaded at entry, before the first instruction.
      args = mc:new_varset(ifn);
      lforeach(fn (fa) [
        set_bit!(args, fa[0][0][mc:v_number]);
        immediate_vars[itoa(fa[0][0][mc:v_number])] = false;
      ], ifn[mc:c_ffullargs]);
      if (ifn[mc:c_fnargs_var])
        set_bit!(args, ifn[mc:c_fnargs_var][mc:vl_var][mc:v_number]);
      add_edges(args);
      lforeach(fn (v) [
        if (v[mc:v_indirect])
          [
            bunion!(neighbors[itoa(v[mc:v_number])], all);
            bforeach(fn (n) set_bit!(neighbors[itoa(n)], v[mc:v_number]), all);
          ];
      ], vars);
      root_variables = make_table();
      lforeach(fn (v) [
        root_variables[itoa(v[mc:v_number])] = entry_allocates
          || v[mc:v_indirect]
          || (bit_set?(live_roots, v[mc:v_number])
              && !immediate_vars[itoa(v[mc:v_number])]);
      ], vars);
      lforeach(fn (v) [
        | used |
        used = make_table();
        bforeach(fn (n) [
          color = slot_indices[itoa(n)];
          if (integer?(color)) used[itoa(color)] = true;
        ], neighbors[itoa(v[mc:v_number])]);
        // Variable zero is the compiler's discarded-value slot. Entry setup
        // can still write it (e.g. an unused argument-count variable).
        // Keep GC-visible and private slots in separate color classes. A
        // scalar must not escape merely because it shares storage with a
        // heap reference whose lifetime does not overlap its own.
        color = if (root_variables[itoa(v[mc:v_number])]) 1 else 2;
        while (used[itoa(color)] == true) color = color + 2;
        slot_indices[itoa(v[mc:v_number])] = color;
      ], vars);
      // Publish each physical GC-visible slot once; multiple rooted
      // variables can share it when their lifetimes do not overlap.
      root_slot_indices = make_table();
      lforeach(fn (v) [
        if (root_variables[itoa(v[mc:v_number])])
          root_slot_indices[itoa(llvm_slot_number(v))] = true;
      ], vars);
      mc:clear_dataflow(ifn);
    ];

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
                "  %s = call i64 @llvm_constant_get(i64 %s, i64 %d)\n",
                result, llvm_read_env(w), index);
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
            "  %s = call i64 @llvm_closure_capture_get(i64 %s, i64 %d)\n",
            res, llvm_read_env(w), cidx);
          res
        ]
      else if (class == mc:v_global || class == mc:v_global_constant
          || class == mc:v_global_define)
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
          vnum = llvm_slot_number(var);
          tmp_seq = tmp_seq + 1;
          tname = format("%%rd_%d_%d", vnum, tmp_seq);
          writer:format(w, "  %s = load i64, ptr %%slot_%d\n", tname, vnum);
          tname
        ]
    ];

  // A runtime helper may trigger moving GC, so reload the closure environment
  // from its registered root instead of reusing the incoming SSA parameter.
  llvm_read_env = fn (w)
    [
      | env_value |
      if (!function_roots_required)
        "%env"
      else
        [
          tmp_seq = tmp_seq + 1;
          env_value = format("%%env_value_%d", tmp_seq);
          writer:format(w, "  %s = load i64, ptr %%env_slot_%d\n",
                        env_value, current_ifn[mc:c_fnumber]);
          env_value
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
            "  %s = call i64 @llvm_closure_capture_get(i64 %s, i64 %d)\n",
            result, llvm_read_env(w), cidx);
          result
        ]
      else
        [
          tmp_seq = tmp_seq + 1;
          result = format("%%cell_ptr_%d", tmp_seq);
          writer:format(w, "  %s = load i64, ptr %%slot_%d\n",
                        result, llvm_slot_number(var));
          result
        ]
    ];

  llvm_write_var = fn (vector var, string val_str, w)
    [
      | class |
      class = var[mc:v_class];
      if (class == mc:v_global || class == mc:v_global_constant
          || class == mc:v_global_define)
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
              "  call void @llvm_closure_capture_set(i64 %s, i64 %d, i64 %s)\n",
              llvm_read_env(w), cidx, val_str);
        ]
      else if (class != mc:v_constant && class != mc:v_function)
        [
          | vnum, cell |
          vnum = llvm_slot_number(var);
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
      "  call void @mudlle_check_integer(i64 %s)\n",
      llvm_read_var(arg, w)), args);

  llvm_emit_integer_type_check = fn (arg, w)
    [
      | value |
      value = llvm_read_var(arg, w);
      writer:format(w, "  call void @mudlle_check_integer(i64 %s)\n", value);
    ];

  llvm_integer_comparison? = fn (types)
    types && llength(types) == 2
      && (car(types) & itype_integer) != 0
      && (cadr(types) & itype_integer) != 0;

  // Shared conservative safepoint classification for frame elision and
  // per-slot liveness. Unknown instructions and function materialization
  // must stay collecting until their runtime helpers have been audited.
  llvm_instruction_may_allocate? = fn (ins)
    [
      | class, op, args |
      class = ins[mc:i_class];
      args = mc:arguments(ins, null);
      if (lexists?(fn (v) v[mc:v_class] == mc:v_function, args))
        exit<function> true;
      if (class == mc:i_call || class == mc:i_closure
          || class == mc:i_maybe_sconcat)
        exit<function> true;
      if (class == mc:i_compute)
        [
          op = ins[mc:i_aop];
          if (lexists?(fn (safe_op) safe_op == op, nonallocating_ops))
            null
          else if ((op == mc:b_lt || op == mc:b_le
                    || op == mc:b_gt || op == mc:b_ge)
                   && llvm_integer_comparison?(ins[mc:i_atypes]))
            null
          else
            exit<function> true;
        ];
      if (class == mc:i_branch)
        [
          op = ins[mc:i_bop];
          if (lexists?(fn (safe_op) safe_op == op, nonallocating_branches))
            null
          else if (op == mc:branch_lt || op == mc:branch_le
                   || op == mc:branch_gt || op == mc:branch_ge)
            null
          else
            exit<function> true;
        ];
      if (class != mc:i_compute && class != mc:i_memory
          && class != mc:i_branch && class != mc:i_return
          && class != mc:i_trap && class != mc:i_nop)
        exit<function> true;
      false
    ];

  llvm_function_may_allocate? = fn (ifn)
    [
      | scan, ins |
      if (ifn[mc:c_fnargs_var]
          || ifn[mc:c_farginfo][mc:arginfo_vararg]
          || lexists?(fn (v) v[mc:v_indirect], ifn[mc:c_flocals])
          || lexists?(fn (fa) fa[0][0][mc:v_indirect], ifn[mc:c_ffullargs]))
        exit<function> true;
      if (pair?(ifn[mc:c_fvalue])) mc:flatten_blocks(ifn);
      scan = ifn[mc:c_fvalue];
      if (!vector?(scan)) exit<function> true;
      loop [
        ins = dget(scan)[mc:il_ins];
        if (ins != null && llvm_instruction_may_allocate?(ins))
          exit<function> true;
        scan = dnext(scan);
        if (scan == ifn[mc:c_fvalue]) exit false;
      ]
    ];

  llvm_check_comparison_types = fn (args, types, w)
    [
      if ((car(types) & ~itype_integer) != 0)
        llvm_emit_integer_type_check(car(args), w);
      if ((cadr(types) & ~itype_integer) != 0)
        llvm_emit_integer_type_check(cadr(args), w);
    ];

  llvm_check_typed_integer_args = fn (args, types, w)
    if (!types || llength(types) != llength(args))
      llvm_check_integer_args(args, w)
    else
      [
        | arg, itypeset |
        @(arg . args) = args;
        @(itypeset . types) = types;
        if ((itypeset & itype_integer) == 0)
          writer:format(w,
            "  call void @mudlle_check_integer(i64 %s)\n",
            llvm_read_var(arg, w))
        else if ((itypeset & ~itype_integer) != 0)
          llvm_emit_integer_type_check(arg, w);
        if (args != null)
          llvm_check_typed_integer_args(args, types, w);
      ];

  llvm_emit_loop_check = fn (w)
    [
      | id, old_count, decremented, in_budget, slow_label, continue_label |
      tmp_seq = tmp_seq + 1;
      id = tmp_seq;
      old_count = format("%%loop_count_old_%d", id);
      decremented = format("%%loop_count_new_%d", id);
      in_budget = format("%%loop_in_budget_%d", id);
      slow_label = format("loop_limit_%d", id);
      continue_label = format("loop_continue_%d", id);
      writer:format(w,
        "  %s = load atomic volatile i64, ptr @internal_xcount monotonic,\
 align 8\n",
        old_count);
      writer:format(w, "  %s = sub i64 %s, 1\n", decremented, old_count);
      writer:format(w,
        "  store atomic volatile i64 %s, ptr @internal_xcount monotonic, align\
 8\n",
        decremented);
      writer:format(w, "  %s = icmp sgt i64 %s, 0\n",
                    in_budget, decremented);
      writer:format(w,
        "  br i1 %s, label %%%s, label %%%s\n",
        in_budget, continue_label, slow_label);
      writer:format(w, "%s:\n", slow_label);
      writer:write_line(w, "  call void @llvm_loop_slow_path()");
      writer:format(w, "  br label %%%s\n", continue_label);
      writer:format(w, "%s:\n", continue_label);
    ];

  // Materialize values one at a time into GC-visible slots. A later
  // argument or the consuming runtime helper may trigger a moving collection.
  llvm_emit_rooted_arguments = fn (args, prefix, w)
    [
      | count, id, values_array, slots_array, records_array, stack_mark,
        root_token, slots_data, records_data, i, slot, slot_ptr,
        values_ptr |
      count = llength(args);
      if (count == 0)
        vector("null", "null", "null", 0)
      else
        [
          tmp_seq = tmp_seq + 1;
          id = tmp_seq;
          values_array = format("%%%s_values_%d", prefix, id);
          slots_array = format("%%%s_root_slots_%d", prefix, id);
          records_array = format("%%%s_root_records_%d", prefix, id);
          stack_mark = format("%%%s_stack_%d", prefix, id);
          root_token = format("%%%s_roots_token_%d", prefix, id);
          writer:format(w, "  %s = call ptr @llvm.stacksave()\n", stack_mark);
          writer:format(w, "  %s = alloca [%d x i64]\n", values_array, count);
          writer:format(w, "  %s = alloca [%d x ptr]\n", slots_array, count);
          writer:format(w, "  %s = alloca [%d x { ptr, ptr }]\n", records_array,
                        count);
          i = 0;
          while (i < count)
            [
              slot = format("%%%s_value_slot_%d_%d", prefix, id, i);
              slot_ptr = format("%%%s_root_slot_ptr_%d_%d", prefix, id, i);
              writer:format(w,
                "  %s = getelementptr inbounds [%d x i64], ptr %s, i64 0, i64\
 %d\n",
                slot, count, values_array, i);
              writer:format(w, "  store i64 0, ptr %s\n", slot);
              writer:format(w,
                "  %s = getelementptr inbounds [%d x ptr], ptr %s, i64 0, i64\
 %d\n",
                slot_ptr, count, slots_array, i);
              writer:format(w, "  store ptr %s, ptr %s\n", slot, slot_ptr);
              i = i + 1;
            ];
          slots_data = format("%%%s_root_slots_data_%d", prefix, id);
          records_data = format("%%%s_root_records_data_%d", prefix, id);
          writer:format(w,
            "  %s = getelementptr inbounds [%d x ptr], ptr %s, i64 0, i64 0\n",
            slots_data, count, slots_array);
          writer:format(w,
            "  %s = getelementptr inbounds [%d x { ptr, ptr }], ptr %s, i64 0,\
 i64 0\n",
            records_data, count, records_array);
          writer:format(w,
            "  %s = call ptr @llvm_gc_roots_enter(ptr %s,\
 i64 %d, ptr %s)\n",
            root_token, slots_data, count, records_data);
          i = 0;
          lforeach(fn (arg) [
            | item_slot, item_value |
            item_value = llvm_read_var(arg, w);
            item_slot = format("%%%s_value_slot_%d_%d", prefix, id, i);
            writer:format(w, "  store i64 %s, ptr %s\n", item_value, item_slot);
            i = i + 1;
          ], args);
          values_ptr = format("%%%s_values_data_%d", prefix, id);
          writer:format(w,
            "  %s = getelementptr inbounds [%d x i64], ptr %s, i64 0, i64 0\n",
            values_ptr, count, values_array);
          vector(values_ptr, stack_mark, root_token, count)
        ]
    ];

  // build_vector and call_global copy and root their input values before
  // allocating. Their caller buffer is never read after the call. Only
  // function materialization can collect while evaluating these arguments;
  // retain the full temporary frame for that case. concat_strings instead
  // reads its caller buffer after allocation and must keep the rooted path.
  llvm_emit_copying_arguments = fn (args, prefix, w)
    [
      | id, count, values, mark, ptr, i, slot, item |
      if (lexists?(fn (arg) arg[mc:v_class] == mc:v_function, args))
        exit<function> llvm_emit_rooted_arguments(args, prefix, w);
      count = llength(args);
      if (count == 0) exit<function> vector("null", "null", "null", 0);
      tmp_seq = tmp_seq + 1;
      id = tmp_seq;
      values = format("%%%s_values_%d", prefix, id);
      mark = format("%%%s_stack_%d", prefix, id);
      ptr = format("%%%s_values_data_%d", prefix, id);
      writer:format(w, "  %s = call ptr @llvm.stacksave()\n", mark);
      writer:format(w, "  %s = alloca [%d x i64]\n", values, count);
      i = 0;
      lforeach(fn (arg) [
        item = llvm_read_var(arg, w);
        slot = format("%%%s_value_slot_%d_%d", prefix, id, i);
        writer:format(w,
          "  %s = getelementptr [%d x i64], ptr %s, i64 0, i64 %d\n",
          slot, count, values, i);
        writer:format(w, "  store i64 %s, ptr %s\n", item, slot);
        i = i + 1;
      ], args);
      writer:format(w,
        "  %s = getelementptr [%d x i64], ptr %s, i64 0, i64 0\n",
        ptr, count, values);
      vector(ptr, mark, "null", count)
    ];

  llvm_emit_closure = fn (ifn, w)
    [
      | cvars, ncaptures, tmp, res, captures_array, captures_ptr,
        capture_index, parent_var, capture_value, parent_class, self_capture,
        stack_mark, entry_address, args_index, args_metadata, root_slots,
        root_records, root_slots_data, root_records_data, root_token,
        slot_ptr, slot_index, capture_ptr |
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
          root_slots = format("%%closure_root_slots_%d", tmp);
          root_records = format("%%closure_root_records_%d", tmp);
          root_token = format("%%closure_roots_token_%d", tmp);
          writer:format(w, "  %s = call ptr @llvm.stacksave()\n", stack_mark);
          writer:format(w, "  %s = alloca [%d x i64]\n",
                        captures_array, ncaptures);
          writer:format(w, "  %s = alloca [%d x ptr]\n",
                        root_slots, ncaptures);
          writer:format(w, "  %s = alloca [%d x { ptr, ptr }]\n",
                        root_records, ncaptures);
          slot_index = 0;
          while (slot_index < ncaptures)
            [
              capture_ptr = format("%%closure_capture_ptr_%d_%d", tmp,
                                   slot_index);
              slot_ptr = format("%%closure_root_slot_ptr_%d_%d", tmp,
                                slot_index);
              writer:format(w,
                "  %s = getelementptr inbounds [%d x i64], ptr %s, i64 0, i64\
 %d\n",
                capture_ptr, ncaptures, captures_array, slot_index);
              writer:format(w, "  store i64 1, ptr %s\n", capture_ptr);
              writer:format(w,
                "  %s = getelementptr inbounds [%d x ptr], ptr %s, i64 0, i64\
 %d\n",
                slot_ptr, ncaptures, root_slots, slot_index);
              writer:format(w, "  store ptr %s, ptr %s\n", capture_ptr,
                            slot_ptr);
              slot_index = slot_index + 1;
            ];
          root_slots_data = format("%%closure_root_slots_data_%d", tmp);
          root_records_data = format("%%closure_root_records_data_%d", tmp);
          writer:format(w,
            "  %s = getelementptr inbounds [%d x ptr], ptr %s, i64 0, i64 0\n",
            root_slots_data, ncaptures, root_slots);
          writer:format(w,
            "  %s = getelementptr inbounds [%d x { ptr, ptr }], ptr %s, i64 0,\
 i64 0\n",
            root_records_data, ncaptures, root_records);
          writer:format(w,
            "  %s = call ptr @llvm_gc_roots_enter(ptr %s,\
 i64 %d, ptr %s)\n",
            root_token, root_slots_data, ncaptures, root_records_data);
          capture_index = 0;
          lforeach(fn (capture) [
            parent_var = capture[mc:v_cparent];
            capture_ptr = format("%%closure_capture_ptr_%d_%d",
                                 tmp, capture_index);
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
      args_index = llvm_constant_index(mc:function_closure_args(ifn));
      args_metadata = format("%%closure_args_%d", tmp);
      writer:format(w,
        "  %s = call i64 @llvm_constant_get(i64 %s, i64 %d)\n",
        args_metadata, llvm_read_env(w), args_index);
      writer:format(w,
        "  %s = call i64 @llvm_make_function_closure(i64 %s, i64 %d, ptr %s,\
 i64 %d, i64 %d, i64 %s, i64 %s, i64 %d)\n",
        res, entry_address, llength(ifn[mc:c_ffullargs]), captures_ptr,
        ncaptures, self_capture, llvm_read_env(w), args_metadata,
        ifn[mc:c_freturn_typeset]);
      if (ncaptures != 0)
        [
          writer:format(w, "  call void @llvm_gc_roots_leave(ptr %s)\n",
                        root_token);
          writer:format(w, "  call void @llvm.stackrestore(ptr %s)\n",
                        stack_mark);
        ];
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
      | rooted, ptr, stack_mark, root_token, count, result, immutable |
      rooted = llvm_emit_copying_arguments(args, "vector", w);
      ptr = rooted[0];
      stack_mark = rooted[1];
      root_token = rooted[2];
      count = rooted[3];
      immutable = readonly && llvm_args_immutable?(args, types);
      tmp_seq = tmp_seq + 1;
      result = format("%%vector_result_%d", tmp_seq);
      writer:format(w,
        "  %s = call i64 @llvm_build_vector(ptr %s, i64 %d, i64 %d, i64 %d)\n",
        result, ptr, count, if (readonly) 1 else 0,
        if (immutable) 1 else 0);
      if (count != 0)
        [
          if (!string_equal?(root_token, "null"))
            writer:format(w, "  call void @llvm_gc_roots_leave(ptr %s)\n",
                          root_token);
          writer:format(w, "  call void @llvm.stackrestore(ptr %s)\n",
                        stack_mark);
        ];
      result
    ];

  llvm_emit_concat = fn (args, w)
    [
      | rooted, ptr, count, result, stack_mark, root_token |
      rooted = llvm_emit_rooted_arguments(args, "concat", w);
      ptr = rooted[0];
      stack_mark = rooted[1];
      root_token = rooted[2];
      count = rooted[3];
      tmp_seq = tmp_seq + 1;
      result = format("%%concat_result_%d", tmp_seq);
      writer:format(w,
        "  %s = call i64 @llvm_concat_strings(ptr %s, i64 %d)\n",
        result, ptr, count);
      if (count != 0)
        [
          writer:format(w, "  call void @llvm_gc_roots_leave(ptr %s)\n",
                        root_token);
          writer:format(w, "  call void @llvm.stackrestore(ptr %s)\n",
                        stack_mark);
        ];
      result
    ];

  llvm_emit_builtin = fn (op, args, w)
    [
      | name, name_index, name_value, caller, rooted, count, ptr,
        stack_mark, root_token, result |
      name = if (string?(op)) op
        else if (op == mc:b_negate) "negate" else mc:builtin_names[op];
      name_index = llvm_constant_index(name);
      rooted = llvm_emit_copying_arguments(args, "builtin", w);
      count = rooted[3];
      ptr = rooted[0];
      stack_mark = rooted[1];
      root_token = rooted[2];
      tmp_seq = tmp_seq + 1;
      name_value = format("%%builtin_name_%d", tmp_seq);
      caller = llvm_read_env(w);
      writer:format(w,
        "  %s = call i64 @llvm_constant_get(i64 %s, i64 %d)\n",
        name_value, llvm_read_env(w), name_index);
      result = format("%%builtin_result_%d", tmp_seq);
      writer:format(w,
        "  %s = call i64 @llvm_call_global(i64 %s, i64 %s, ptr %s, i64 %d)\n",
        result, caller, name_value, ptr, count);
      if (count != 0)
        [
          if (!string_equal?(root_token, "null"))
            writer:format(w, "  call void @llvm_gc_roots_leave(ptr %s)\n",
                          root_token);
          writer:format(w, "  call void @llvm.stackrestore(ptr %s)\n",
                        stack_mark);
        ];
      result
    ];

  // Preserve the dynamic primitive fallback, but expose tagged integer
  // arithmetic to LLVM. Integer arithmetic wraps exactly like x64; no nsw
  // flags are valid here. Divisor zero must take the ordinary error path.
  llvm_emit_binary_builtin = fn (op, args, w)
    [
      | a, b, id, tag, both, valid, nonzero, fast_label, slow_label,
        join_label, first, second, raw, tagged, fast, slow, result |
      if (lexists?(fn (v) v[mc:v_class] == mc:v_function, args))
        exit<function> llvm_emit_builtin(op, args, w);
      a = llvm_read_var(car(args), w);
      b = llvm_read_var(cadr(args), w);
      tmp_seq = tmp_seq + 1;
      id = tmp_seq;
      tag = format("%%ib_tag_%d", id);
      both = format("%%ib_both_%d", id);
      valid = format("%%ib_valid_%d", id);
      fast_label = format("ib_fast_%d", id);
      slow_label = format("ib_slow_%d", id);
      join_label = format("ib_join_%d", id);
      writer:format(w, "  %s = and i64 %s, %s\n", both, a, b);
      writer:format(w, "  %s = and i64 %s, 1\n", tag, both);
      writer:format(w, "  %s = icmp eq i64 %s, 1\n", valid, tag);
      if (op == mc:b_divide || op == mc:b_remainder)
        [
          nonzero = format("%%ib_nonzero_%d", id);
          both = format("%%ib_div_valid_%d", id);
          writer:format(w, "  %s = icmp ne i64 %s, 1\n", nonzero, b);
          writer:format(w, "  %s = and i1 %s, %s\n", both, valid, nonzero);
          valid = both;
        ];
      writer:format(w, "  br i1 %s, label %%%s, label %%%s\n",
                    valid, fast_label, slow_label);
      writer:format(w, "%s:\n", fast_label);
      raw = format("%%ib_raw_%d", id);
      fast = format("%%ib_fast_value_%d", id);
      if (op == mc:b_add || op == mc:b_subtract)
        [
          writer:format(w, "  %s = %s i64 %s, %s\n", raw,
                        if (op == mc:b_add) "add" else "sub", a, b);
          writer:format(w, "  %s = %s i64 %s, 1\n", fast,
                        if (op == mc:b_add) "sub" else "add", raw);
        ]
      else
        [
          first = format("%%ib_first_%d", id);
          second = format("%%ib_second_%d", id);
          tagged = format("%%ib_tagged_%d", id);
          writer:format(w, "  %s = ashr i64 %s, 1\n", first, a);
          writer:format(w, "  %s = ashr i64 %s, 1\n", second, b);
          writer:format(w, "  %s = %s i64 %s, %s\n", raw,
                        if (op == mc:b_multiply) "mul"
                        else if (op == mc:b_divide) "sdiv" else "srem",
                        first, second);
          writer:format(w, "  %s = shl i64 %s, 1\n", tagged, raw);
          writer:format(w, "  %s = or i64 %s, 1\n", fast, tagged);
        ];
      writer:format(w, "  br label %%%s\n", join_label);
      writer:format(w, "%s:\n", slow_label);
      slow = llvm_emit_builtin(op, args, w);
      writer:format(w, "  br label %%%s\n", join_label);
      writer:format(w, "%s:\n", join_label);
      result = format("%%ib_result_%d", id);
      writer:format(w, "  %s = phi i64 [ %s, %%%s ], [ %s, %%%s ]\n",
                    result, fast, fast_label, slow, slow_label);
      result
    ];

  // Dynamic vector indexing keeps string/other reference semantics and all
  // bounds/type failures on the existing runtime path. No interior address
  // survives a collecting call: the fast path contains only a type query,
  // arithmetic and a load.
  llvm_emit_ref = fn (args, w)
    [
      | array, index, id, type_ok, tag, int_ok, valid, object, size,
        bytes, length, raw_index, negative, from_end, normalized, in_bounds,
        data, address, fast, slow, result, check_label, load_label,
        slow_label, join_label |
      if (lexists?(fn (v) v[mc:v_class] == mc:v_function, args))
        exit<function> llvm_emit_builtin(mc:b_ref, args, w);
      array = llvm_read_var(car(args), w);
      index = llvm_read_var(cadr(args), w);
      tmp_seq = tmp_seq + 1;
      id = tmp_seq;
      type_ok = format("%%vr_type_%d", id);
      tag = format("%%vr_tag_%d", id);
      int_ok = format("%%vr_int_%d", id);
      valid = format("%%vr_valid_%d", id);
      check_label = format("vr_check_%d", id);
      load_label = format("vr_load_%d", id);
      slow_label = format("vr_slow_%d", id);
      join_label = format("vr_join_%d", id);
      writer:format(w, "  %s = call i32 @mudlle_vector_matches(i64 %s)\n",
                    type_ok, array);
      writer:format(w, "  %s = icmp ne i32 %s, 0\n", valid, type_ok);
      writer:format(w, "  %s = and i64 %s, 1\n", tag, index);
      writer:format(w, "  %s = icmp eq i64 %s, 1\n", int_ok, tag);
      type_ok = format("%%vr_both_%d", id);
      writer:format(w, "  %s = and i1 %s, %s\n", type_ok, valid, int_ok);
      writer:format(w, "  br i1 %s, label %%%s, label %%%s\n",
                    type_ok, check_label, slow_label);
      writer:format(w, "%s:\n", check_label);
      object = format("%%vr_object_%d", id);
      size = format("%%vr_size_%d", id);
      bytes = format("%%vr_bytes_%d", id);
      length = format("%%vr_length_%d", id);
      raw_index = format("%%vr_index_%d", id);
      negative = format("%%vr_negative_%d", id);
      from_end = format("%%vr_from_end_%d", id);
      normalized = format("%%vr_normalized_%d", id);
      in_bounds = format("%%vr_bounds_%d", id);
      writer:format(w, "  %s = inttoptr i64 %s to ptr\n", object, array);
      writer:format(w, "  %s = load i64, ptr %s, align 8\n", size, object);
      writer:format(w, "  %s = sub i64 %s, 16\n", bytes, size);
      writer:format(w, "  %s = lshr i64 %s, 3\n", length, bytes);
      writer:format(w, "  %s = ashr i64 %s, 1\n", raw_index, index);
      writer:format(w, "  %s = icmp slt i64 %s, 0\n", negative, raw_index);
      writer:format(w, "  %s = add i64 %s, %s\n", from_end, raw_index, length);
      writer:format(w, "  %s = select i1 %s, i64 %s, i64 %s\n",
                    normalized, negative, from_end, raw_index);
      writer:format(w, "  %s = icmp ult i64 %s, %s\n",
                    in_bounds, normalized, length);
      writer:format(w, "  br i1 %s, label %%%s, label %%%s\n",
                    in_bounds, load_label, slow_label);
      writer:format(w, "%s:\n", load_label);
      data = format("%%vr_data_%d", id);
      address = format("%%vr_address_%d", id);
      fast = format("%%vr_fast_value_%d", id);
      writer:format(w, "  %s = getelementptr i8, ptr %s, i64 16\n", data, object);
      writer:format(w, "  %s = getelementptr i64, ptr %s, i64 %s\n",
                    address, data, normalized);
      writer:format(w, "  %s = load i64, ptr %s, align 8\n", fast, address);
      writer:format(w, "  br label %%%s\n", join_label);
      writer:format(w, "%s:\n", slow_label);
      slow = llvm_emit_builtin(mc:b_ref, args, w);
      writer:format(w, "  br label %%%s\n", join_label);
      writer:format(w, "%s:\n", join_label);
      result = format("%%vr_result_%d", id);
      writer:format(w, "  %s = phi i64 [ %s, %%%s ], [ %s, %%%s ]\n",
                    result, fast, load_label, slow, slow_label);
      result
    ];

  llvm_emit_set = fn (args, w)
    [
      | array, index, id, type_ok, tag, int_ok, valid, object, size,
        bytes, length, raw_index, negative, from_end, normalized, in_bounds,
        data, address, fast, slow, result, check_label, load_label,
        slow_label, join_label, masked, newval, flagptr, flags, ro, rw_label |
      if (lexists?(fn (v) v[mc:v_class] == mc:v_function, args))
        exit<function> llvm_emit_builtin(mc:b_set, args, w);
      array = llvm_read_var(car(args), w);
      index = llvm_read_var(cadr(args), w);
      newval = llvm_read_var(caddr(args), w);
      tmp_seq = tmp_seq + 1;
      id = tmp_seq;
      type_ok = format("%%vs_type_%d", id);
      tag = format("%%vs_tag_%d", id);
      int_ok = format("%%vs_int_%d", id);
      valid = format("%%vs_valid_%d", id);
      check_label = format("vs_check_%d", id);
      load_label = format("vs_load_%d", id);
      slow_label = format("vs_slow_%d", id);
      join_label = format("vs_join_%d", id);
      writer:format(w, "  %s = call i32 @mudlle_vector_matches(i64 %s)\n",
                    type_ok, array);
      writer:format(w, "  %s = icmp ne i32 %s, 0\n", valid, type_ok);
      writer:format(w, "  %s = and i64 %s, 1\n", tag, index);
      writer:format(w, "  %s = icmp eq i64 %s, 1\n", int_ok, tag);
      type_ok = format("%%vs_both_%d", id);
      writer:format(w, "  %s = and i1 %s, %s\n", type_ok, valid, int_ok);
      writer:format(w, "  br i1 %s, label %%%s, label %%%s\n",
                    type_ok, check_label, slow_label);
      writer:format(w, "%s:\n", check_label);
      object = format("%%vs_object_%d", id);
      size = format("%%vs_size_%d", id);
      bytes = format("%%vs_bytes_%d", id);
      length = format("%%vs_length_%d", id);
      raw_index = format("%%vs_index_%d", id);
      negative = format("%%vs_negative_%d", id);
      from_end = format("%%vs_from_end_%d", id);
      normalized = format("%%vs_normalized_%d", id);
      in_bounds = format("%%vs_bounds_%d", id);
      writer:format(w, "  %s = inttoptr i64 %s to ptr\n", object, array);
      writer:format(w, "  %s = load i64, ptr %s, align 8\n", size, object);
      writer:format(w, "  %s = sub i64 %s, 16\n", bytes, size);
      writer:format(w, "  %s = lshr i64 %s, 3\n", length, bytes);
      writer:format(w, "  %s = ashr i64 %s, 1\n", raw_index, index);
      writer:format(w, "  %s = icmp slt i64 %s, 0\n", negative, raw_index);
      writer:format(w, "  %s = add i64 %s, %s\n", from_end, raw_index, length);
      writer:format(w, "  %s = select i1 %s, i64 %s, i64 %s\n",
                    normalized, negative, from_end, raw_index);
      writer:format(w, "  %s = icmp ult i64 %s, %s\n",
                    in_bounds, normalized, length);
      flagptr = format("%%vs_flagptr_%d", id);
      flags = format("%%vs_flags_%d", id);
      ro = format("%%vs_ro_%d", id);
      rw_label = format("vs_rw_%d", id);
      writer:format(w, "  br i1 %s, label %%%s, label %%%s\n",
                    in_bounds, rw_label, slow_label);
      writer:format(w, "%s:\n", rw_label);
      writer:format(w, "  %s = getelementptr i8, ptr %s, i64 10\n", flagptr, object);
      writer:format(w, "  %s = load i16, ptr %s, align 2\n", flags, flagptr);
      masked = format("%%vs_masked_%d", id);
      writer:format(w, "  %s = and i16 %s, 1\n", masked, flags);
      writer:format(w, "  %s = icmp eq i16 %s, 0\n", ro, masked);
      writer:format(w, "  br i1 %s, label %%%s, label %%%s\n",
                    ro, load_label, slow_label);
      writer:format(w, "%s:\n", load_label);
      data = format("%%vs_data_%d", id);
      address = format("%%vs_address_%d", id);
      fast = format("%%vs_fast_value_%d", id);
      writer:format(w, "  %s = getelementptr i8, ptr %s, i64 16\n", data, object);
      writer:format(w, "  %s = getelementptr i64, ptr %s, i64 %s\n",
                    address, data, normalized);
      writer:format(w, "  store i64 %s, ptr %s, align 8\n", newval, address);
      writer:format(w, "  br label %%%s\n", join_label);
      writer:format(w, "%s:\n", slow_label);
      slow = llvm_emit_builtin(mc:b_set, args, w);
      writer:format(w, "  br label %%%s\n", join_label);
      writer:format(w, "%s:\n", join_label);
      result = format("%%vs_result_%d", id);
      writer:format(w, "  %s = phi i64 [ %s, %%%s ], [ %s, %%%s ]\n",
                    result, newval, load_label, slow, slow_label);
      result
    ];

  llvm:mgen_preamble = fn (ifn, ainfo)
    [
      | fname, args, vars_seen, root_vars_seen, add_var, w, code, root_vars,
        root_count, root_slots, root_records, root_slots_data,
        root_records_data,
        env_slot_ptr,
        root_token, root_index, arg_no, scan, il, ins, defvar, args_seen |

      w = writer:new_string();
      fname = format("fn_%d", ifn[mc:c_fnumber]);
      args = lmap(fn (fa) fa[0][0], ifn[mc:c_ffullargs]);

      // Function header
      writer:format(w, "define i64 @%s(i64 %%env, ptr %%argv, i64 %%nargs",
                    fname);
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
      root_vars_seen = make_table();
      root_vars = null;

      add_var = fn (v)
        [
          if (vector?(v))
            [
              | class |
              class = v[mc:v_class];
              if (class == mc:v_global || class == mc:v_global_constant
          || class == mc:v_global_define)
                globals_seen[v[mc:v_name]] = v
              else if (class != mc:v_constant && class != mc:v_function
                       && class != mc:v_closure)
                [
                  | vnum |
                  vnum = itoa(llvm_slot_number(v));
                  vars_seen[vnum] = v;
                  if (root_vars_seen[vnum] == null
                      && (root_slot_indices == null
                          || root_slot_indices[vnum] == true
                          || !integer?(slot_indices[itoa(v[mc:v_number])])))
                    [
                      root_vars_seen[vnum] = true;
                      root_vars = v . root_vars;
                    ];
                ];
            ]
        ];

      args_seen = make_table();
      lforeach(fn (arg) [
        add_var(arg);
        args_seen[itoa(llvm_slot_number(arg))] = true;
      ], args);
      if (ifn[mc:c_fnargs_var])
        add_var(ifn[mc:c_fnargs_var][mc:vl_var]);
      if (ifn[mc:c_flocals] != null)
        lforeach(add_var, ifn[mc:c_flocals]);
      if (pair?(ifn[mc:c_fvalue])) mc:flatten_blocks(ifn);
      if (vector?(ifn[mc:c_fvalue]))
        [
          // Some temporaries (notably memory-read results) are not in
          // c_flocals.
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
        writer:format(w, "  %%slot_%d = alloca i64\n", llvm_slot_number(var));
        writer:format(w, "  store i64 1, ptr %%slot_%d\n",
                      llvm_slot_number(var));
      ], vars_seen);

      // Keep Mudlle values in local slots visible to the garbage collector.
      // The incoming closure environment can move during any allocating
      // helper call, so keep it in the same GC-visible root set as locals.
      if (function_roots_required)
        [
          root_count = llength(root_vars) + 1;
          root_token = format("%%roots_token_%d", ifn[mc:c_fnumber]);
          writer:format(w, "  %%env_slot_%d = alloca i64\n",
                        ifn[mc:c_fnumber]);
          writer:format(w, "  store i64 %%env, ptr %%env_slot_%d\n",
                        ifn[mc:c_fnumber]);
          root_slots = format("%%root_slots_%d", ifn[mc:c_fnumber]);
          root_records = format("%%root_records_%d", ifn[mc:c_fnumber]);
          writer:format(w, "  %s = alloca [%d x ptr]\n",
                        root_slots, root_count);
          writer:format(w, "  %s = alloca [%d x { ptr, ptr }]\n",
                        root_records, root_count);
          root_index = 0;
          env_slot_ptr = format("%%root_slot_ptr_%d_%d",
                                ifn[mc:c_fnumber], root_index);
          writer:format(w,
            "  %s = getelementptr inbounds [%d x ptr], ptr %s, i64 0, i64 %d\n",
            env_slot_ptr, root_count, root_slots, root_index);
          writer:format(w, "  store ptr %%env_slot_%d, ptr %s\n",
                        ifn[mc:c_fnumber], env_slot_ptr);
          root_index = root_index + 1;
          lforeach(fn (root_var) [
            | slot_ptr |
            slot_ptr = format("%%root_slot_ptr_%d_%d",
                              ifn[mc:c_fnumber], root_index);
            writer:format(w,
              "  %s = getelementptr inbounds [%d x ptr], ptr %s, i64 0, i64\
 %d\n",
              slot_ptr, root_count, root_slots, root_index);
            writer:format(w, "  store ptr %%slot_%d, ptr %s\n",
                          llvm_slot_number(root_var), slot_ptr);
            root_index = root_index + 1;
          ], root_vars);
          root_slots_data = format("%%root_slots_data_%d", ifn[mc:c_fnumber]);
          root_records_data = format("%%root_records_data_%d",
                                     ifn[mc:c_fnumber]);
          writer:format(w,
            "  %s = getelementptr inbounds [%d x ptr], ptr %s, i64 0, i64 0\n",
            root_slots_data, root_count, root_slots);
          writer:format(w,
            "  %s = getelementptr inbounds [%d x { ptr, ptr }], ptr %s, i64 0,\
 i64 0\n",
            root_records_data, root_count, root_records);
          writer:format(w,
            "  %s = call ptr @llvm_gc_roots_enter(ptr %s,\
 i64 %d, ptr %s)\n",
            root_token, root_slots_data, root_count, root_records_data);
        ];

      // Load arguments only after local slots have been registered as roots.
      arg_no = 0;
      lforeach(fn (arg) [
        | vnum, arg_value |
        vnum = llvm_slot_number(arg);
        if (arg_no == llength(args) - 1
            && last_element(ifn[mc:c_ffullargs])[mc:fullarg_arg][1] == null)
          [
            arg_value = format("%%varargs_%d", ifn[mc:c_fnumber]);
            writer:format(w,
              "  %s = call i64 @llvm_make_varargs(ptr %%argv, i64 %%nargs, i64\
 %d)\n",
              arg_value, ifn[mc:c_farginfo][mc:arginfo_nargs] - 1);
          ]
        else
          [
            // Phase 3 can coalesce argument variables into the same slot.
            // Each incoming load still needs its own LLVM SSA name.
            arg_value = format("%%argvalue_%d_%d", ifn[mc:c_fnumber], arg_no);
            writer:format(w,
              "  %s = call i64 @llvm_argument_get(ptr %%argv, i64 %%nargs, i64\
 %d)\n",
              arg_value, arg_no);
          ];
        writer:format(w, "  store i64 %s, ptr %%slot_%d\n", arg_value, vnum);
        arg_no = arg_no + 1;
      ], args);
      if (ifn[mc:c_fnargs_var])
        [
          | nv, tagged_nargs, tagged_nargs_value |
          nv = llvm_slot_number(ifn[mc:c_fnargs_var][mc:vl_var]);
          tagged_nargs = format("%%tagged_nargs_%d", ifn[mc:c_fnumber]);
          tagged_nargs_value = format("%%tagged_nargs_value_%d",
                                      ifn[mc:c_fnumber]);
          writer:format(w, "  %s = shl i64 %%nargs, 1\n", tagged_nargs);
          writer:format(w, "  %s = or i64 %s, 1\n", tagged_nargs_value,
                        tagged_nargs);
          writer:format(w, "  store i64 %s, ptr %%slot_%d\n",
                        tagged_nargs_value, nv);
        ];

      // Box variables whose address escapes into a closure. Arguments retain
      // their incoming value; other locals begin as null, like x64's allocator.
      table_foreach(fn (@<_ = var>) [
        if (var[mc:v_indirect])
          [
            | raw, cell |
            if (args_seen[itoa(llvm_slot_number(var))])
              [
                raw = format("%%indirect_initial_%d", var[mc:v_number]);
                writer:format(w, "  %s = load i64, ptr %%slot_%d\n",
                              raw, llvm_slot_number(var));
              ]
            else
              raw = "0";
            cell = format("%%indirect_cell_%d", var[mc:v_number]);
            writer:format(w,
              "  %s = call i64 @llvm_variable_new(i64 %s)\n", cell, raw);
            writer:format(w, "  store i64 %s, ptr %%slot_%d\n",
                          cell, llvm_slot_number(var));
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
              (ins[mc:i_class] == mc:i_branch
               && ins[mc:i_bop] == mc:branch_always) ||
              (ins[mc:i_class] == mc:i_trap &&
               (ins[mc:i_top] == mc:trap_always
                || mc:trap_is_unreachable?(ins))))
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
      if (pair?(ifn[mc:c_fvalue]) && string?(car(ifn[mc:c_fvalue]))
          && string_search(car(ifn[mc:c_fvalue]), "define i64") >= 0)
        [
          writer:write(w, car(ifn[mc:c_fvalue]));
          exit<function> null;
        ];

      current_ifn = ifn;
      llvm_allocate_slots(ifn);
      if (pair?(ifn[mc:c_fvalue])) mc:flatten_blocks(ifn);
      function_roots_required = llvm_function_may_allocate?(ifn);
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
      writer:format(w,
                    "  %%entry_result = call i64 @fn_%d(i64 %%env, ptr %%args,\
 i64 %%nargs",
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
          | dest_var, op, args, types, integer_compare |
          dest_var = ins[mc:i_adest];
          op = ins[mc:i_aop];
          args = ins[mc:i_aargs];
          types = ins[mc:i_atypes];
          integer_compare = (op == mc:b_lt || op == mc:b_le
                             || op == mc:b_gt || op == mc:b_ge)
            && llvm_integer_comparison?(types);
          if (integer_compare)
            llvm_check_comparison_types(args, types, w);
          if (op == mc:b_iadd)
            writer:format(w,
              "  call void @mudlle_check_integer_pair(i64 %s, i64 %s)\n",
              llvm_read_var(car(args), w),
              llvm_read_var(cadr(args), w));
          if (op == mc:b_bitand || op == mc:b_bitor || op == mc:b_bitxor
              || op == mc:b_shift_left || op == mc:b_shift_right
              || op == mc:b_bitnot)
            llvm_check_integer_args(args, w);
          if (op == mc:b_add || op == mc:b_subtract
              || op == mc:b_multiply || op == mc:b_divide
              || op == mc:b_remainder)
            [
              llvm_write_var(dest_var, llvm_emit_binary_builtin(op, args, w), w);
              exit<function> null;
            ];
          if (op == mc:b_add || op == mc:b_subtract
              || op == mc:b_multiply || op == mc:b_divide
              || op == mc:b_remainder || op == mc:b_negate
              || ((op == mc:b_lt || op == mc:b_le
                   || op == mc:b_gt || op == mc:b_ge)
                  && !integer_compare))
            [
              llvm_write_var(dest_var, llvm_emit_builtin(op, args, w), w);
              exit<function> null;
            ];
          if (op == mc:b_vector || op == mc:b_sequence)
            [
              llvm_write_var(dest_var,
                llvm_emit_vector(args, op == mc:b_sequence,
                                 ins[mc:i_atypes], w), w);
              exit<function> null;
            ];
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
              exit<function> null;
            ];
          if (op == mc:b_subtract)
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
              exit<function> null;
            ];
          if (op == mc:b_multiply)
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
              exit<function> null;
            ];
          if (op == mc:b_divide)
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
              exit<function> null;
            ];
          if (op == mc:b_bitand)
            [
              | a1, a2, res |
              a1 = llvm_read_var(car(args), w);
              a2 = llvm_read_var(cadr(args), w);
              tmp_seq = tmp_seq + 1;
              res = format("%%res_%d", tmp_seq);
              writer:format(w, "  %s = and i64 %s, %s\n", res, a1, a2);
              llvm_write_var(dest_var, res, w);
              exit<function> null;
            ];
          if (op == mc:b_bitor)
            [
              | a1, a2, res |
              a1 = llvm_read_var(car(args), w);
              a2 = llvm_read_var(cadr(args), w);
              tmp_seq = tmp_seq + 1;
              res = format("%%res_%d", tmp_seq);
              writer:format(w, "  %s = or i64 %s, %s\n", res, a1, a2);
              llvm_write_var(dest_var, res, w);
              exit<function> null;
            ];
          if (op == mc:b_bitxor)
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
              exit<function> null;
            ];
          if (op == mc:b_eq)
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
              exit<function> null;
            ];
          if (op == mc:b_ne)
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
              exit<function> null;
            ];
          if (op == mc:b_lt || op == mc:b_le
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
              exit<function> null;
            ];
          if (op == mc:b_remainder)
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
              exit<function> null;
            ];
          if (op == mc:b_shift_left || op == mc:b_shift_right)
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
              exit<function> null;
            ];
          if (op == mc:b_negate || op == mc:b_bitnot)
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
              exit<function> null;
            ];
          if (op == mc:b_logical_not)
            [
              | arg, cmp, res |
              arg = llvm_read_var(car(args), w);
              tmp_seq = tmp_seq + 1;
              cmp = format("%%cmp_%d", tmp_seq);
              res = format("%%res_%d", tmp_seq);
              writer:format(w, "  %s = icmp eq i64 %s, 1\n", cmp, arg);
              writer:format(w, "  %s = select i1 %s, i64 3, i64 1\n", res, cmp);
              llvm_write_var(dest_var, res, w);
              exit<function> null;
            ];
          if (op == mc:b_logical_xor)
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
              writer:format(w, "  %s = select i1 %s, i64 3, i64 1\n", res,
                            xorv);
              llvm_write_var(dest_var, res, w);
              exit<function> null;
            ];
          if (op == mc:b_car || op == mc:b_cdr)
            [
              | arg, res, helper |
              arg = llvm_read_var(car(args), w);
              tmp_seq = tmp_seq + 1;
              res = format("%%res_%d", tmp_seq);
              writer:format(w,
                "  %s = call i64 @mudlle_pair_field(i64 %s, i64 %d)\n",
                res, arg, if (op == mc:b_car) 16 else 24);
              llvm_write_var(dest_var, res, w);
              exit<function> null;
            ];
          if (op == mc:b_funcarg)
            [
              | arg_index, arg_value |
              arg_index = car(args)[mc:v_kvalue];
              tmp_seq = tmp_seq + 1;
              arg_value = format("%%funcarg_%d", tmp_seq);
              writer:format(w,
                "  %s = call i64 @llvm_argument_get(ptr %%argv, i64 %%nargs,\
 i64 %d)\n",
                arg_value, arg_index);
              llvm_write_var(dest_var, arg_value, w);
              exit<function> null;
            ];
          if (op == mc:b_assign)
            [
              | a1 |
              a1 = llvm_read_var(car(args), w);
              llvm_write_var(dest_var, a1, w);
              exit<function> null;
            ];
          if (op == mc:b_ref)
            [
              llvm_write_var(dest_var, llvm_emit_ref(args, w), w);
              exit<function> null;
            ];
          if (op == mc:b_set)
            [
              llvm_write_var(dest_var, llvm_emit_set(args, w), w);
              exit<function> null;
            ];
          if (op == mc:b_vlength)
            [
              | value, result |
              value = llvm_read_var(car(args), w);
              tmp_seq = tmp_seq + 1;
              result = format("%%vlength_%d", tmp_seq);
              writer:format(w,
                "  %s = call i64 @mudlle_vector_length(i64 %s)\n",
                result, value);
              llvm_write_var(dest_var, result, w);
              exit<function> null;
            ];
          if (op == mc:b_cons || op == mc:b_pcons)
            [
              | a, b, res |
              a = llvm_read_var(car(args), w);
              b = llvm_read_var(cadr(args), w);
              tmp_seq = tmp_seq + 1;
              res = format("%%cons_%d", tmp_seq);
              writer:format(w, "  %s = call i64 @llvm_cons(i64 %s, i64 %s, i64 %d)\n",
                            res, a, b, if (op == mc:b_pcons) 1 else 0);
              llvm_write_var(dest_var, res, w);
              exit<function> null;
            ];
          if (op == mc:b_slength || op == mc:b_vlength
                   || op == mc:b_typeof || op == mc:b_loop_count
                   || op == mc:b_max_loop_count
                   || op == mc:b_symbol_name || op == mc:b_symbol_get
                   || op == mc:b_cons || op == mc:b_pcons
                   || op == mc:b_ref || op == mc:b_set
                   || op == mc:b_ffs)
            [
              llvm_write_var(dest_var, llvm_emit_builtin(op, args, w), w);
              exit<function> null;
            ];
          error(error_bad_value)
        ]
      else if (class == mc:i_memory)
        [
          | array, array_ptr, field_ptr, value_str, offset |
          tmp_seq = tmp_seq + 1;
          array_ptr = format("%%array_%d", tmp_seq);
          field_ptr = format("%%field_%d", tmp_seq);
          offset = 16 + 8 * ins[mc:i_mindex];

          if (ins[mc:i_mop] == mc:memory_read)
            [
              array = llvm_read_var(ins[mc:i_marray], w);
              writer:format(w, "  %s = inttoptr i64 %s to ptr\n",
                            array_ptr, array);
              writer:format(w,
                            "  %s = getelementptr inbounds i8, ptr %s,\
 i64 %d\n",
                            field_ptr, array_ptr, offset);
              value_str = format("%%mem_%d", tmp_seq);
              writer:format(w, "  %s = load i64, ptr %s\n", value_str,
                            field_ptr);
              llvm_write_var(ins[mc:i_mscalar], value_str, w);
            ]
          else if (ins[mc:i_mop] == mc:memory_write
                   || ins[mc:i_mop] == mc:memory_write_safe)
            [
              if (ins[mc:i_mop] == mc:memory_write_safe)
                [
                  array = llvm_read_var(ins[mc:i_marray], w);
                  writer:format(w,
                    "  call void @llvm_check_mutable(i64 %s)\n", array);
                ];
              value_str = llvm_read_var(ins[mc:i_mscalar], w);
              array = llvm_read_var(ins[mc:i_marray], w);
              writer:format(w, "  %s = inttoptr i64 %s to ptr\n",
                            array_ptr, array);
              writer:format(w,
                            "  %s = getelementptr inbounds i8, ptr %s,\
 i64 %d\n",
                            field_ptr, array_ptr, offset);
              writer:format(w, "  store i64 %s, ptr %s\n", value_str,
                            field_ptr);
            ]
          else
            error(error_bad_value);
        ]
      else if (class == mc:i_branch)
        [
          | op, dest_lbl, args, types |
          op = ins[mc:i_bop];
          dest_lbl = ins[mc:i_bdest][mc:l_number];
          args = ins[mc:i_bargs];
          types = ins[mc:i_btypes];
          if (op == mc:branch_lt || op == mc:branch_ge
              || op == mc:branch_le || op == mc:branch_gt)
            if (llvm_integer_comparison?(types))
              llvm_check_comparison_types(args, types, w)
            else
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
                    "  call void @mudlle_check_integer(i64 %s)\n",
                    llvm_read_var(car(args), w));
                  writer:format(w,
                    "  call void @mudlle_check_integer(i64 %s)\n",
                    llvm_read_var(cadr(args), w));
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
                  writer:format(w, "  %s = xor i1 %s, %s\n", xorv, truth1,
                                truth2);
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
                  vector_find_required = true;
                  found = format("%%vfind_%d", seq);
                  writer:format(w,
                    "  %s = call i32 @mudlle_vector_find(i64 %s, i64 %s)\n",
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
                  // Plain object types are a pointer test and a type byte
                  // compare; typesets and immediates keep the runtime query.
                  if (type_idx == type_pair || type_idx == type_vector
                      || type_idx == type_string)
                    writer:format(w,
                      "  %s = call i32 @mudlle_has_type(i64 %s, i64 %d)\n",
                      matched_value, v1, type_idx)
                  else
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
                  writer:format(w, "  %s = icmp ne i32 %s, 0\n", cmp,
                                matched_value);
                ]
              else
                error(error_bad_value);

              writer:format(w, "  br i1 %s, label %%L_%d, label %%L_next_%d\n",
                            cmp, dest_lbl, seq);
              writer:format(w, "L_next_%d:\n", seq);
            ];
        ]
      else if (class == mc:i_call)
        [
          | dest_var, fn_var, called_ifn, call_args, cname, res,
            arg_array, arg_ptr, arg_index, stack_mark, root_count,
            root_slots, root_records, root_token, root_slot_ptr,
            root_slots_data, root_records_data, arg_count,
            arg_slot, root_index, call_id, secure_call, floatop, floatres |
          dest_var = ins[mc:i_cdest];
          call_args = ins[mc:i_cargs];
          fn_var = car(call_args);
          call_args = cdr(call_args);
          arg_count = llength(call_args);
          secure_call = fn_var[mc:v_class] == mc:v_global_constant;
          called_ifn = if (fn_var[mc:v_class] == mc:v_function)
            fn_var[mc:v_fvalue] else null;

          tmp_seq = tmp_seq + 1;
          call_id = tmp_seq;
          res = format("%%call_%d", call_id);
          if (secure_call && arg_count == 3
              && string_equal?(fn_var[mc:v_name], "set!"))
            [
              llvm_write_var(dest_var, llvm_emit_set(call_args, w), w);
              exit<function> null;
            ];
          floatop = if (secure_call && arg_count == 2
                        && !lexists?(fn (v) v[mc:v_class] == mc:v_function,
                                     call_args))
            [
              | nm |
              nm = fn_var[mc:v_name];
              if (string_equal?(nm, "fadd")) 0
              else if (string_equal?(nm, "fsub")) 1
              else if (string_equal?(nm, "fmul")) 2
              else if (string_equal?(nm, "fdiv")) 3
              else -1
            ]
          else -1;
          if (floatop >= 0)
            [
              // Direct float arithmetic; non-numeric operands fall through
              // to the generic call so errors are unchanged.
              | fa, fb, fid |
              fa = llvm_read_var(car(call_args), w);
              fb = llvm_read_var(cadr(call_args), w);
              fid = call_id;
              floatres = format("%%fl_fast_%d", fid);
              writer:format(w, "  br label %%fl_start_%d\nfl_start_%d:\n",
                            fid, fid);
              writer:format(w,
                "  %s = call i64 @llvm_float_binop(i64 %d, i64 %s, i64 %s)\n",
                floatres, floatop, fa, fb);
              writer:format(w,
                "  %%fl_ok_%d = icmp ne i64 %s, 0\n  br i1 %%fl_ok_%d, label %%fl_join_%d, label %%fl_slow_%d\nfl_slow_%d:\n",
                fid, floatres, fid, fid, fid, fid);
            ];
          if (secure_call)
            [
              // A constant global callee is read by the runtime after the
              // arguments are copied; primitives need no generated roots.
              | copied |
              copied = llvm_emit_copying_arguments(call_args, "gcall", w);
              writer:format(w,
                "  %s = call i64 @llvm_call_global_constant(i64 %d, i64 %s,\
 ptr %s, i64 %d)\n",
                res, fn_var[mc:v_goffset], llvm_read_env(w), copied[0],
                copied[3]);
              if (copied[3] != 0)
                [
                  if (!string_equal?(copied[2], "null"))
                    writer:format(w, "  call void @llvm_gc_roots_leave(ptr %s)\n",
                                  copied[2]);
                  writer:format(w, "  call void @llvm.stackrestore(ptr %s)\n",
                                copied[1]);
                ];
              if (floatop >= 0)
                [
                  writer:format(w,
                    "  br label %%fl_join_%d\nfl_join_%d:\n  %%fl_res_%d = phi i64 [ %s, %%fl_start_%d ], [ %s, %%fl_slow_%d ]\n",
                    call_id, call_id, call_id, floatres, call_id, res, call_id);
                  res = format("%%fl_res_%d", call_id);
                ];
              llvm_write_var(dest_var, res, w);
              exit<function> null;
            ];
          [
              root_count = arg_count + 1;
              arg_array = format("%%call_values_%d", call_id);
              stack_mark = format("%%call_stack_%d", call_id);
              root_slots = format("%%call_root_slots_%d", call_id);
              root_records = format("%%call_root_records_%d", call_id);
              root_token = format("%%call_roots_token_%d", call_id);
              writer:format(w, "  %s = call ptr @llvm.stacksave()\n",
                            stack_mark);
              writer:format(w, "  %s = alloca [%d x i64]\n", arg_array,
                            root_count);
              writer:format(w, "  %s = alloca [%d x ptr]\n", root_slots,
                            root_count);
              writer:format(w, "  %s = alloca [%d x { ptr, ptr }]\n",
                            root_records, root_count);
              root_index = 0;
              while (root_index < root_count)
                [
                  arg_slot = format("%%call_value_slot_%d_%d", call_id,
                                    root_index);
                  root_slot_ptr = format("%%call_root_slot_ptr_%d_%d", call_id,
                                         root_index);
                  writer:format(w,
                    "  %s = getelementptr inbounds [%d x i64], ptr %s, i64 0,\
 i64 %d\n",
                    arg_slot, root_count, arg_array, root_index);
                  writer:format(w, "  store i64 0, ptr %s\n", arg_slot);
                  writer:format(w,
                    "  %s = getelementptr inbounds [%d x ptr], ptr %s, i64 0,\
 i64 %d\n",
                    root_slot_ptr, root_count, root_slots, root_index);
                  writer:format(w, "  store ptr %s, ptr %s\n", arg_slot,
                                root_slot_ptr);
                  root_index = root_index + 1;
                ];
              root_slots_data = format("%%call_root_slots_data_%d", call_id);
              root_records_data = format("%%call_root_records_data_%d",
                                         call_id);
              writer:format(w,
                "  %s = getelementptr inbounds [%d x ptr], ptr %s, i64 0, i64\
 0\n",
                root_slots_data, root_count, root_slots);
              writer:format(w,
                "  %s = getelementptr inbounds [%d x { ptr, ptr }], ptr %s,\
 i64 0, i64 0\n",
                root_records_data, root_count, root_records);
              writer:format(w,
                "  %s = call ptr @llvm_gc_roots_enter(ptr %s,\
 i64 %d, ptr %s)\n",
                root_token, root_slots_data, root_count, root_records_data);

              cname = if (called_ifn != null)
                llvm_emit_closure(called_ifn, w)
              else
                llvm_read_var(fn_var, w);
              arg_slot = format("%%call_value_slot_%d_0", call_id);
              writer:format(w, "  store i64 %s, ptr %s\n", cname, arg_slot);
              arg_index = 0;
              lforeach(fn (arg) [
                | value_slot, value_str |
                value_str = llvm_read_var(arg, w);
                value_slot = format("%%call_value_slot_%d_%d", call_id,
                                    arg_index + 1);
                writer:format(w, "  store i64 %s, ptr %s\n", value_str,
                              value_slot);
                arg_index = arg_index + 1;
              ], call_args);
              cname = format("%%call_callee_reloaded_%d", call_id);
              writer:format(w, "  %s = load i64, ptr %%call_value_slot_%d_0\n",
                            cname, call_id);
              if (arg_count == 0)
                arg_ptr = "null"
              else
                [
                  arg_ptr = format("%%call_args_data_%d", call_id);
                  writer:format(w,
                    "  %s = getelementptr inbounds [%d x i64], ptr %s, i64 0,\
 i64 1\n",
                    arg_ptr, root_count, arg_array);
                ];
              writer:format(w,
                "  %s = call i64 @llvm_call_value(i64 %s, i64 %s, ptr %s, i64\
 %d, i64 %d)\n",
                res, llvm_read_env(w), cname, arg_ptr, arg_count,
                if (secure_call) 1 else 0);
              writer:format(w,
                "  call void @llvm_gc_roots_leave(ptr %s)\n", root_token);
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
          if (function_roots_required)
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
            llvm_emit_loop_check(w)
          else if (ins[mc:i_top] == mc:trap_type)
            [
              args = ins[mc:i_targs];
              argument = llvm_read_var(car(args), w);
              nerror = cadr(args)[mc:v_kvalue];
              writer:format(w,
                "  call void @%s(i64 %s, i64 %d)\n",
                if (nerror == type_vector) "mudlle_check_vector" else "llvm_check_type",
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
          else if (ins[mc:i_top] == mc:trap_global_read)
            [
              if (mc:update_maxseclev == true)
                writer:format(w,
                  "  call void @llvm_check_global_read(i64 %d)\n",
                  car(ins[mc:i_targs])[mc:v_goffset]);
            ]
          else if (ins[mc:i_top] == mc:trap_global_write)
            [
              args = ins[mc:i_targs];
              argument = llvm_read_var(cadr(args), w);
              writer:format(w,
                "  call void @llvm_check_global_write(i64 %d, i64 %s)\n",
                car(args)[mc:v_goffset], argument);
            ]
          else if (ins[mc:i_top] == mc:trap_never)
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

  mc:gen_llvm_ir = fn "mod, {writer,null} w, functions -> . Generates LLVM IR\
 for module" (mod, {vector,null} w = null, fns = null)
    [
      | created_w |
      vector_find_required = false;
      globals_seen = make_table();
      llvm_constant_list = null;
      llvm_constant_values = null;
      llvm_global_relocation_values = null;

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

      // ORC supplies the host target and data layout when it loads this IR.

      writer:write_line(w, "; Runtime declarations");
      writer:write_line(w, "declare i64 @alloc(i64, i64)");
      writer:write_line(w, "declare i64 @pcons(i64, i64)");
      writer:write_line(w, "declare i64 @make_vector(i64)");
      writer:write_line(w, "declare void @error(i64)\n");
      writer:write_line(w,
                        "declare i64 @llvm_call_value(i64, i64, ptr, i64,\
 i64)\n");
      writer:write_line(w,
                        "declare i64 @llvm_call_global(i64, i64, ptr, i64)\n");
      writer:write_line(w,
                        "declare i64 @llvm_call_global_constant(i64, i64, ptr,\
 i64)\n");
      writer:write_line(w, "declare i64 @llvm_argument_get(ptr, i64, i64)\n");
      writer:write_line(w, "declare i64 @llvm_make_varargs(ptr, i64, i64)\n");
      writer:write_line(w, "declare void @llvm_check_arity(i64, i64, i64)\n");
      writer:write_line(w,
                        "declare i64 @llvm_build_vector(ptr, i64, i64, i64)\n");
      writer:write_line(w, "declare i64 @llvm_concat_strings(ptr, i64)\n");
      writer:write_line(w,
                        "declare i64 @llvm_make_function_closure(i64, i64,\
 ptr, i64, i64, i64, i64, i64)\n");
      writer:write_line(w, "declare i64 @llvm_constant_get(i64, i64)\n");
      writer:write_line(w, "declare i64 @llvm_closure_capture_get(i64, i64)\n");
      writer:write_line(w,
                        "declare void @llvm_closure_capture_set(i64, i64,\
 i64)\n");
      writer:write_line(w, "declare i64 @llvm_variable_new(i64)\n");
      writer:write_line(w, "declare i64 @llvm_variable_get(i64)\n");
      writer:write_line(w, "declare void @llvm_variable_set(i64, i64)\n");
      writer:write_line(w, "declare void @llvm_raise_error(i64, i64)\n");
      writer:write_line(w, "declare void @llvm_loop_check()\n");
      writer:write_line(w, "declare void @llvm_loop_slow_path()\n");
      writer:write_line(w, "@internal_xcount = external global i64\n");
      writer:write_line(w, "declare void @llvm_check_type(i64, i64)\n");
      // Test pointer tags before reading the object header. Failure retains
      // the runtime diagnostic path and its offending value.
      writer:format(w, """
define internal i32 @mudlle_vector_matches(i64 %%value) {
entry:
  %%tag = and i64 %%value, 1
  %%even = icmp eq i64 %%tag, 0
  %%nonnull = icmp ne i64 %%value, 0
  %%pointer = and i1 %%even, %%nonnull
  br i1 %%pointer, label %%header, label %%no
header:
  %%object = inttoptr i64 %%value to ptr
  %%typeptr = getelementptr i8, ptr %%object, i64 9
  %%type = load i8, ptr %%typeptr, align 1
  %%matches = icmp eq i8 %%type, %d
  %%result = zext i1 %%matches to i32
  ret i32 %%result
no:
  ret i32 0
}
""", type_vector);
      writer:format(w, """
define internal i32 @mudlle_has_type(i64 %%value, i64 %%expected) {
entry:
  %%tag = and i64 %%value, 1
  %%even = icmp eq i64 %%tag, 0
  %%nonnull = icmp ne i64 %%value, 0
  %%pointer = and i1 %%even, %%nonnull
  br i1 %%pointer, label %%header, label %%no
header:
  %%object = inttoptr i64 %%value to ptr
  %%typeptr = getelementptr i8, ptr %%object, i64 9
  %%type = load i8, ptr %%typeptr, align 1
  %%want = trunc i64 %%expected to i8
  %%matches = icmp eq i8 %%type, %%want
  %%result = zext i1 %%matches to i32
  ret i32 %%result
no:
  ret i32 0
}
""");
      // Pair access and vector length: tag and type test, then a direct load.
      // Failures call the runtime helpers, which raise the usual diagnostics.
      writer:format(w, """
define internal i64 @mudlle_pair_field(i64 %%value, i64 %%offset) {
entry:
  %%tag = and i64 %%value, 1
  %%even = icmp eq i64 %%tag, 0
  %%nonnull = icmp ne i64 %%value, 0
  %%pointer = and i1 %%even, %%nonnull
  br i1 %%pointer, label %%header, label %%slow
header:
  %%object = inttoptr i64 %%value to ptr
  %%typeptr = getelementptr i8, ptr %%object, i64 9
  %%type = load i8, ptr %%typeptr, align 1
  %%matches = icmp eq i8 %%type, %d
  br i1 %%matches, label %%fast, label %%slow
fast:
  %%fieldptr = getelementptr i8, ptr %%object, i64 %%offset
  %%field = load i64, ptr %%fieldptr, align 8
  ret i64 %%field
slow:
  %%isdr = icmp eq i64 %%offset, 24
  br i1 %%isdr, label %%slow_cdr, label %%slow_car
slow_car:
  %%c0 = call i64 @llvm_pair_car(i64 %%value)
  ret i64 %%c0
slow_cdr:
  %%c1 = call i64 @llvm_pair_cdr(i64 %%value)
  ret i64 %%c1
}
define internal i64 @mudlle_vector_length(i64 %%value) {
entry:
  %%matches = call i32 @mudlle_vector_matches(i64 %%value)
  %%ok = icmp ne i32 %%matches, 0
  br i1 %%ok, label %%fast, label %%slow
fast:
  %%object = inttoptr i64 %%value to ptr
  %%size = load i64, ptr %%object, align 8
  %%bytes = sub i64 %%size, 16
  %%length = lshr i64 %%bytes, 3
  %%shifted = shl i64 %%length, 1
  %%tagged = or i64 %%shifted, 1
  ret i64 %%tagged
slow:
  %%r = call i64 @llvm_object_length(i64 %%value, i64 0)
  ret i64 %%r
}
""", type_pair);
      writer:format(w, """
define internal void @mudlle_check_vector(i64 %%value, i64 %%expected) {
entry:
  %%matches = call i32 @mudlle_vector_matches(i64 %%value)
  %%ok = icmp ne i32 %%matches, 0
  br i1 %%ok, label %%done, label %%slow
slow:
  call void @llvm_check_type(i64 %%value, i64 %%expected)
  unreachable
done:
  ret void
}
""");
      writer:write_line(w, "declare void @llvm_check_integer_pair(i64, i64)\n");
      writer:write_line(w,
        "define internal void @mudlle_check_integer(i64 %value) {");
      writer:write_line(w, "entry:");
      writer:write_line(w, "  %tag = and i64 %value, 1");
      writer:write_line(w, "  %ok_test = icmp eq i64 %tag, 1");
      writer:write_line(w, "  br i1 %ok_test, label %ok, label %slow");
      writer:write_line(w, "slow:");
      writer:write_line(w,
        "  call void @llvm_check_type(i64 %value, i64 7)");
      writer:write_line(w, "  unreachable");
      writer:write_line(w, "ok:");
      writer:write_line(w, "  ret void");
      writer:write_line(w, "}\n");
      writer:write_line(w,
        "define internal void @mudlle_check_integer_pair(i64 %a, i64 %b) {");
      writer:write_line(w, "entry:");
      writer:write_line(w, "  %a_tag = and i64 %a, 1");
      writer:write_line(w, "  %a_ok = icmp eq i64 %a_tag, 1");
      writer:write_line(w, "  %b_tag = and i64 %b, 1");
      writer:write_line(w, "  %b_ok = icmp eq i64 %b_tag, 1");
      writer:write_line(w, "  %both_ok = and i1 %a_ok, %b_ok");
      writer:write_line(w, "  br i1 %both_ok, label %ok, label %slow");
      writer:write_line(w, "slow:");
      writer:write_line(w,
        "  call void @llvm_check_integer_pair(i64 %a, i64 %b)");
      writer:write_line(w, "  unreachable");
      writer:write_line(w, "ok:");
      writer:write_line(w, "  ret void");
      writer:write_line(w, "}\n");
      writer:write_line(w, "declare void @llvm_check_typeset(i64, i64, i64)\n");
      writer:write_line(w, "declare void @llvm_check_mutable(i64)\n");
      writer:write_line(w, "declare i32 @llvm_type_matches(i64, i64)\n");
      writer:write_line(w, "declare i64 @llvm_object_length(i64, i64)\n");
      writer:write_line(w, "declare i32 @llvm_predicate(i64, i64)\n");
      writer:write_line(w, "declare i32 @llvm_vector_find(i64, i64)\n");
      writer:write_line(w, "declare i64 @llvm_pair_car(i64)\n");
      writer:write_line(w, "declare i64 @llvm_cons(i64, i64, i64)\n");
      writer:write_line(w, "declare i64 @llvm_float_binop(i64, i64, i64)\n");
      writer:write_line(w, "declare i64 @llvm_pair_cdr(i64)\n");
      writer:write_line(w, "declare i32 @llvm_equal(i64, i64)\n");
      writer:write_line(w, "declare ptr @llvm_gc_roots_enter(ptr, i64, ptr)\n");
      writer:write_line(w, "declare void @llvm_gc_roots_leave(ptr)\n");
      writer:write_line(w, "declare i64 @llvm_global_read(i64)\n");
      writer:write_line(w, "declare void @llvm_check_global_read(i64)\n");
      writer:write_line(w, "declare void @llvm_global_write(i64, i64)\n");
      writer:write_line(w, "declare void @llvm_check_global_write(i64, i64)\n");
      writer:write_line(w, "declare ptr @llvm.stacksave()\n");
      writer:write_line(w, "declare void @llvm.stackrestore(ptr)\n");

      lforeach(fn (ifn) gen_function(ifn, w), fns);
      // A bounded, call-free OR reduction gives LLVM a real SIMD opportunity
      // without changing language-loop accounting. Stop after each 32-word
      // chunk, retaining short-circuit behavior between chunks and in the tail.
      if (vector_find_required)
        writer:write_line(w, """
define internal i1 @mudlle_vector_find_chunk(ptr %data, i64 %needle) {
entry:
  br label %scan
scan:
  %i = phi i64 [ 0, %entry ], [ %next, %scan ]
  %found = phi i1 [ false, %entry ], [ %combined, %scan ]
  %address = getelementptr i64, ptr %data, i64 %i
  %value = load i64, ptr %address, align 8
  %match = icmp eq i64 %value, %needle
  %combined = or i1 %found, %match
  %next = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %next, 32
  br i1 %done, label %exit, label %scan
exit:
  ret i1 %combined
}
define internal i32 @mudlle_vector_find(i64 %needle, i64 %haystack) {
entry:
  %tagged_length = call i64 @llvm_object_length(i64 %haystack, i64 0)
  %length = lshr i64 %tagged_length, 1
  %object = inttoptr i64 %haystack to ptr
  %data = getelementptr i8, ptr %object, i64 16
  %chunks_end = and i64 %length, -32
  br label %chunks
chunks:
  %offset = phi i64 [ 0, %entry ], [ %next_chunk, %chunk_miss ]
  %has_chunk = icmp ult i64 %offset, %chunks_end
  br i1 %has_chunk, label %chunk_body, label %tail
chunk_body:
  %chunk_data = getelementptr i64, ptr %data, i64 %offset
  %chunk_found = call i1 @mudlle_vector_find_chunk(ptr %chunk_data, i64 %needle)
  br i1 %chunk_found, label %found, label %chunk_miss
chunk_miss:
  %next_chunk = add i64 %offset, 32
  br label %chunks
tail:
  %index = phi i64 [ %offset, %chunks ], [ %next_tail, %tail_miss ]
  %has_tail = icmp ult i64 %index, %length
  br i1 %has_tail, label %tail_body, label %absent
tail_body:
  %tail_address = getelementptr i64, ptr %data, i64 %index
  %tail_value = load i64, ptr %tail_address, align 8
  %tail_match = icmp eq i64 %tail_value, %needle
  br i1 %tail_match, label %found, label %tail_miss
tail_miss:
  %next_tail = add i64 %index, 1
  br label %tail
found:
  ret i32 1
absent:
  ret i32 0
}
""");

      llvm_constant_values = lmap(fn (entry) car(entry),
                                  lreverse!(llvm_constant_list));
      table_foreach(fn (@<name = var>) [
        llvm_global_relocation_values =
          vector(var[mc:v_goffset], name) . llvm_global_relocation_values;
      ], globals_seen);

      if (created_w)
        writer:get_string(w)
      else
        true
    ];

];
