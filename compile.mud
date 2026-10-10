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

library compile // call actual compiler
requires compiler, flow, genllvm, ins3, link, phase1, phase2, phase3, phase4,
  sequences, vars
defines mc:compile, mc:compile_llvm, mc:compile_llvm_to_asm
reads mc:compile_llvm_asm
writes mc:verbose, mc:erred, mc:this_module, mc:disassemble
[
  mc:verbose = 2; // default verbosity level
  mc:disassemble = false;

  | do_compile |
  do_compile = fn (mod, protect, seclev, global_syms)
    [
      if (mc:verbose >= 1)
        [
          display("PHASE1\n");
        ];
      mc:phase1(mod, seclev, global_syms);
      if (mc:erred) exit<function> false;

      if (global_syms != null)
        exit<function> false;

      if (mc:verbose >= 1)
        display("PHASE2\n");
      mc:phase2(mod);
      if (mc:erred) exit<function> false;

      if (mc:verbose >= 4)
        [
          mc:ins_list(mod[mc:m_body]);
          newline();
        ];

      | fns |
      fns = mc:all_functions(mod[mc:m_body]);

      if (mc:verbose >= 1)
        [
          display("PHASE3\n");
        ];
      mc:phase3(fns);

      | remaining_fns |
      remaining_fns = mc:all_functions(mod[mc:m_body]);
      fns = lfilter!(fn (f) lfind?(f, remaining_fns), fns);

      if (mc:verbose >= 1)
        [
          display("PHASE4\n");
        ];
      mc:phase4(fns);

      mc:prelink(mod, protect)
    ];

  // if 'global_syms' is a dihash, stop after parsing and add global
  // symbol usage to it; see gsym_use() in phase1.mud
  mc:compile = fn (vector mod, protect, int seclev, function get_source,
                   {vector,null} global_syms = null)
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
        fn () do_compile(mod, protect, seclev, global_syms),
        fn (n) false,
        call_trace_on, null);

      mc:handle_messages(null);

      mc:reset_var_cache();

      result
    ];

  mc:compile_llvm_to_asm = fn (vector mod, int seclev, function get_source,
                               string asm_filename)
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
          mc:phase1(mod, seclev, null);
          if (mc:erred) exit<function> false;
          mc:phase2(mod);
          if (mc:erred) exit<function> false;
          | fns |
          fns = mc:all_functions(mod[mc:m_body]);
          mc:phase3(fns);
          mc:compile_llvm_asm(mod, asm_filename)
        ],
        fn (n) false,
        call_trace_on, null);

      mc:handle_messages(null);

      mc:reset_var_cache();

      result
    ];

  mc:compile_llvm = fn (vector mod, int seclev, function get_source,
                        {vector,null} w = null)
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
          mc:phase1(mod, seclev, null);
          if (mc:erred) exit<function> false;
          mc:phase2(mod);
          if (mc:erred) exit<function> false;
          | fns |
          fns = mc:all_functions(mod[mc:m_body]);
          mc:phase3(fns);
          mc:gen_llvm_ir(mod, w)
        ],
        fn (n) false,
        call_trace_on, null);

      mc:handle_messages(null);

      mc:reset_var_cache();

      result
    ];

];
