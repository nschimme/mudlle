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
 * End-to-end regression test for asmwriter, LLVM IR generator, and mc:compile pipeline
 */

load("xc.mud");

display("Testing asmwriter...\n");

[
  | w, str |
  w = writer:new_string();
  writer:format(w, "Hello %s %d\n", "world", 42);
  writer:write_line(w, "Line 2");
  str = writer:get_string(w);
  assert(equal?(str, "Hello world 42\nLine 2\n"));
  display("asmwriter string test passed\n");
];

[
  | w, f, line |
  w = writer:new_file("test_asmwriter_tmp.txt");
  writer:format(w, "File output %d\n", 123);
  writer:close(w);

  f = file_open("test_asmwriter_tmp.txt", "r");
  line = file_read(f);
  file_close(f);
  remove("test_asmwriter_tmp.txt");

  assert(equal?(line, "File output 123\n"));
  display("asmwriter file test passed\n");
];

display("Testing genllvm IR output...\n");

| test_genllvm |
test_genllvm = fn (string code_str)
  [
    | tree, ir |
    tree = mudlle_parse(code_str, "test.mud", false);
    ir = mc:gen_llvm_ir(tree);
    assert(string?(ir) && slength(ir) > 0);
    assert(string_search(ir, "target datalayout") < 0);
    assert(string_search(ir, "define i64 @fn_") >= 0);
    assert(string_search(ir, "alloca i64") >= 0);
    assert(string_search(ir, "ret i64") >= 0);
    ir
  ];

[
  | ir |
  test_genllvm("fn (a, b) a + b");
  display("genllvm test 1 passed\n");

  test_genllvm("fn (a, b) [ if (a < b) a * b else a - b ]");
  display("genllvm test 2 passed\n");

  ir = test_genllvm("fn (x) [ | sum, i | sum = 0; i = 0; while (i < x) [ sum = sum + i; i = i + 1; ]; sum ]");
  assert(string_search(ir, "load atomic volatile i64, ptr @internal_xcount") >= 0);
  assert(string_search(ir, "store atomic volatile i64") >= 0);
  assert(string_search(ir, "icmp sgt i64 %loop_count_new_") >= 0);
  assert(string_search(ir, "call void @llvm_check_type") >= 0);
  assert(string_search(ir, "call void @llvm_loop_slow_path()") >= 0);
  assert(string_search(ir, "call void @llvm_loop_check()") >= 0);
  assert(string_search(ir, "store i64 %env, ptr %env_slot_") >= 0);
  assert(string_search(ir, "= call ptr @llvm_gc_roots_enter(ptr %root_slots_data_") >= 0);
  assert(string_search(ir, "alloca [4 x ptr]") >= 0);
  display("genllvm test 3 passed\n");
];

display("Testing LLVM mc:compile pipeline...\n");
[
  | source, tree, prelinked, result, values |
  // Readonly constant vectors can still contain movable objects. Publishing
  // their parent as immutable would leave stale pointers after a minor GC.
  source = "'[ [,apply 1 2] [,session 1 ()] [,with_forbid 2 ()] [,with_maxseclevel 2 ()] [,with_minlevel 2 ()] [,with_output 2 ()] ]";
  tree = mudlle_parse(source, "test-readonly-constants.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  result = mc:linkrun(prelinked, 1, true);
  values = car(result);
  assert(readonly?(values));
  assert(!immutable?(values) || immutable?(values[0]));
  garbage_collect(0);
  garbage_collect(0);
  assert(vlength(values) == 6 && values[0][0] == apply);
  assert(values[5][0] == with_output);
  display("LLVM readonly constant vector GC test passed\n");
];

[
  | source, tree, prelinked, result, function |
  // Unused arguments may share a local slot after Phase 3.
  source = "fn (a, b, c, d) d";
  tree = mudlle_parse(source, "test-coalesced-args.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  result = mc:linkrun(prelinked, 1, true);
  function = car(result);
  assert(function(11, 22, 33, 44) == 44);
  display("LLVM coalesced argument test passed\n");
];

[
  | source, tree, prelinked, function |
  source = "fn (x) if (compiler_stable_closure?(x)) 1 else 0";
  tree = mudlle_parse(source, "test-stable-closure-predicate.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  assert(vector?(prelinked));
  function = car(mc:linkrun(prelinked, 1, true));
  assert(function(null) == 0);
  display("LLVM stable closure predicate test passed\n");
];

[
  | source, tree, prelinked, result, function, values |
  source = "fn () [ assert(compiled?()); (fn (x) [ garbage_collect(0); garbage_collect(0); vector(compiled?(), x) ])(vector(7)) ]";
  tree = mudlle_parse(source, "test-native-call-gc.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  result = mc:linkrun(prelinked, 1, true);
  function = car(result);
  values = function();
  assert(values[0] == true && values[1][0] == 7);
  display("LLVM native call frame GC test passed\n");
];

[
  | source, tree, prelinked, result |
  source = "3 + 5";
  tree = mudlle_parse(source, "test.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  assert(vector?(prelinked));
  result = mc:linkrun(prelinked, 1, true);
  assert(pair?(result) && car(result) == 8);
  display("LLVM mc:compile/linkrun test passed\n");
];

[
  | source, tree, prelinked, result, fn_value, call_result |
  source = "fn (a, b) a + b";
  tree = mudlle_parse(source, "test-function.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  assert(vector?(prelinked));
  result = mc:linkrun(prelinked, 1, true);
  assert(pair?(result));
  fn_value = car(result);
  call_result = fn_value(3, 5);
  display(format("LLVM closure result: %s\n", call_result));
  assert(readonly?(fn_value) && !immutable?(fn_value));
  assert(compiler_stable_closure?(fn_value));
  assert(call_result == 8);
  garbage_collect(0);
  garbage_collect(0);
  assert(fn_value(3, 5) == 8);
  display("LLVM generated closure call test passed\n");
];

[
  | source, tree, prelinked, result, fn_value |
  source = "fn (a, b) iadd(a, b)";
  tree = mudlle_parse(source, "test-iadd.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  assert(vector?(prelinked));
  result = mc:linkrun(prelinked, 1, true);
  fn_value = car(result);
  assert(fn_value(3, 5) == 8);
  display("LLVM checked integer-add helper test passed\n");
];

[
  | source, tree, ir, fn_start, entry_start, fn_ir |
  source = "fn (n) [ | sum, i | sum = 0; i = 0; while (i < n) [ sum = iadd(sum, i); i = iadd(i, 1); ]; sum ]";
  tree = mudlle_parse(source, "test-scalar-roots.mud", false);
  ir = mc:compile_llvm(tree, 1, mc:source_code(source));
  assert(string?(ir));
  fn_start = string_search(ir, "define i64 @fn_1(");
  entry_start = string_search_offset(ir, fn_start, "define i64 @entry_1(");
  assert(fn_start >= 0 && entry_start > fn_start);
  fn_ir = substring(ir, fn_start, entry_start - fn_start);
  assert(string_search(fn_ir, "llvm_gc_roots_enter") < 0);
  assert(string_search(fn_ir, "mudlle_check_integer_pair") >= 0);
  display("LLVM scalar loop root-elision IR test passed\n");
];

[
  | source, tree, prelinked, result, fn_value, opt_default, opt_provided |
  source = "fn (a, b = 7) a + b";
  tree = mudlle_parse(source, "test-optional.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  assert(vector?(prelinked));
  result = mc:linkrun(prelinked, 1, true);
  fn_value = car(result);
  opt_default = fn_value(3);
  opt_provided = fn_value(3, 5);
  assert(opt_default == 10);
  assert(opt_provided == 8);
  display("LLVM optional argument test passed\n");
];

[
  | source, tree, prelinked, result, fn_value, rest, ir,
    fn_start, entry_start, fn_ir |
  source = "fn (a, rest...) rest";
  tree = mudlle_parse(source, "test-varargs.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  assert(vector?(prelinked));
  result = mc:linkrun(prelinked, 1, true);
  fn_value = car(result);
  rest = fn_value(10, 20, 30);
  assert(vlength(rest) == 2 && rest[0] == 20 && rest[1] == 30);
  source = "fn (a, rest...) a";
  tree = mudlle_parse(source, "test-varargs-roots.mud", false);
  ir = mc:compile_llvm(tree, 1, mc:source_code(source));
  fn_start = string_search(ir, "define i64 @fn_1(");
  entry_start = string_search_offset(ir, fn_start, "define i64 @entry_1(");
  assert(fn_start >= 0 && entry_start > fn_start);
  fn_ir = substring(ir, fn_start, entry_start - fn_start);
  assert(string_search(fn_ir, "llvm_gc_roots_enter") >= 0);
  display("LLVM variadic argument test passed\n");
];

[
  | source, tree, prelinked, result, fn_value, float_result |
  source = "fn () 1.0 + 2.5";
  tree = mudlle_parse(source, "test-float.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  assert(vector?(prelinked));
  result = mc:linkrun(prelinked, 1, true);
  fn_value = car(result);
  float_result = fn_value();
  assert(equal?(float_result, 3.5));
  display("LLVM floating point arithmetic test passed\n");
];

[
  | source, tree, prelinked, result, fn_value, ir |
  source = "fn () 1.0 < 2.0";
  tree = mudlle_parse(source, "test-float-compare.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  assert(vector?(prelinked));
  result = mc:linkrun(prelinked, 1, true);
  fn_value = car(result);
  assert(fn_value() == true);
  display("LLVM floating point comparison test passed\n");
];

[
  | source, tree, prelinked, result, fn_value, bigint_result |
  source = "fn () itobi(4611686018427387903) + itobi(1)";
  tree = mudlle_parse(source, "test-bigint.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  assert(vector?(prelinked));
  result = mc:linkrun(prelinked, 1, true);
  fn_value = car(result);
  bigint_result = fn_value();
  assert(equal?(bigint_result, biadd(itobi(4611686018427387903), itobi(1))));
  display("LLVM bigint arithmetic test passed\n");
];

[
  | source, tree, prelinked, result, fn_value, length_result |
  source = "fn (s) slength(s)";
  tree = mudlle_parse(source, "test-primitive-fallback.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  assert(vector?(prelinked));
  result = mc:linkrun(prelinked, 1, true);
  fn_value = car(result);
  length_result = fn_value("llvm");
  assert(length_result == 4);
  display("LLVM primitive fallback test passed\n");
];

[
  | source, tree, ir, prelinked, result, fn_value, set_result, clear_result |
  source = "fn (s, n) if (bit_set?(s, n)) 1 else 0";
  tree = mudlle_parse(source, "test-bit-set.mud", false);
  ir = mc:compile_llvm(tree, 1, mc:source_code(source));
  assert(string?(ir) && string_search(ir, "llvm_call_global") >= 0);

  tree = mudlle_parse(source, "test-bit-set.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  assert(vector?(prelinked));
  result = mc:linkrun(prelinked, 1, true);
  fn_value = car(result);
  set_result = fn_value("\x55", 2);
  clear_result = fn_value("\x55", 1);
  assert(set_result == 1 && clear_result == 0);
  display("LLVM bit-set branch test passed\n");
];

[
  | source, tree, prelinked, result, fn_value, bad_type |
  source = "fn (s, n) if (bit_clear?(s, n)) 1 else 0";
  tree = mudlle_parse(source, "test-bit-clear.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  assert(vector?(prelinked));
  result = mc:linkrun(prelinked, 1, true);
  fn_value = car(result);
  assert(!fn_value("\x55", 2));
  assert(fn_value("\x55", 1));
  display("LLVM bit-clear branch test passed\n");
];

[
  | source, tree, prelinked, result, fn_value, bad_type |
  source = "fn (a, b) if (a & b) 1 else 0";
  tree = mudlle_parse(source, "test-branch-bitand.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  assert(vector?(prelinked));
  result = mc:linkrun(prelinked, 1, true);
  fn_value = car(result);
  assert(fn_value(6, 2));
  assert(!fn_value(4, 2));
  bad_type = trap_error(fn () fn_value("six", 2), fn (n) n,
                        call_trace_off, null);
  assert(bad_type != null);
  assert(fn_value(6, 2));
  display("LLVM bit-and branch test passed\n");
];

[
  | source, tree, prelinked, result, fn_value, haystack |
  source = "fn (needle, haystack) if (vfind?(needle, haystack)) 1 else 0";
  tree = mudlle_parse(source, "test-branch-vfind.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  assert(vector?(prelinked));
  result = mc:linkrun(prelinked, 1, true);
  fn_value = car(result);
  haystack = vector(1, 2, 3);
  assert(fn_value(2, haystack));
  assert(!fn_value(9, haystack));
  display("LLVM vector-find branch test passed\n");
];

[
  | source, tree, prelinked, result, outer, inner, inner_result |
  source = "fn (a) fn (b) a + b";
  tree = mudlle_parse(source, "test-nested-closure.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  assert(vector?(prelinked));
  result = mc:linkrun(prelinked, 1, true);
  outer = car(result);
  inner = outer(3);
  inner_result = inner(4);
  assert(integer?(inner_result) && inner_result - 7 == 0);
  display("LLVM nested closure capture test passed\n");
];

[
  | source, tree, prelinked, result, outer, inner, captured |
  source = "fn () [ | x | x = vector(7); fn () [ garbage_collect(0); garbage_collect(0); x ] ]";
  tree = mudlle_parse(source, "test-moving-env.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  assert(vector?(prelinked));
  result = mc:linkrun(prelinked, 1, true);
  outer = car(result);
  inner = outer();
  captured = inner();
  assert(vector?(captured) && captured[0] == 7);
  display("LLVM moving closure environment test passed\n");
];

[
  | source, tree, ir, prelinked, result, outer, closures, getter, setter |
  source = "fn () [ | x | x = 0; vector(fn () x, fn (v) [x = v; x]) ]";
  tree = mudlle_parse(source, "test-shared-capture.mud", false);
  ir = mc:compile_llvm(tree, 1, mc:source_code(source));
  assert(string?(ir));
  tree = mudlle_parse(source, "test-shared-capture.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  assert(vector?(prelinked));
  result = mc:linkrun(prelinked, 1, true);
  outer = car(result);
  closures = outer();
  getter = closures[0];
  setter = closures[1];
  assert(getter() == 0);
  setter(7);
  assert(getter() == 7);
  display("LLVM shared mutable capture test passed\n");
];

[
  | source, tree, prelinked, result, outer, factorial, factorial_result,
    recursion_error |
  source = "fn () [ | factorial | factorial = fn (n) if (n == 0) 1 else n * factorial(n - 1); factorial ]";
  tree = mudlle_parse(source, "test-recursive-closure.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  assert(vector?(prelinked));
  result = mc:linkrun(prelinked, 1, true);
  outer = car(result);
  factorial = outer();
  factorial_result = factorial(5);
  assert(integer?(factorial_result) && factorial_result - 120 == 0);
  recursion_error = trap_error(fn () factorial(100000), null,
                                call_trace_off, null);
  assert(recursion_error == error_recurse);
  display("LLVM recursive closure test passed\n");
];

[
  | source, tree, prelinked, result, divide, error |
  source = "fn (a, b) a / b";
  tree = mudlle_parse(source, "test-integer-divide-zero.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  assert(vector?(prelinked));
  result = mc:linkrun(prelinked, 1, true);
  divide = car(result);
  error = trap_error(fn () divide(5, 0), null, call_trace_off, null);
  assert(error == error_divide_by_zero);
  result = divide(10, 2);
  assert(integer?(result) && result - 5 == 0);
  display("LLVM integer division error test passed\n");
];

[
  | source, tree, prelinked, result, remainder, error |
  source = "fn (a, b) a % b";
  tree = mudlle_parse(source, "test-integer-remainder-zero.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  assert(vector?(prelinked));
  result = mc:linkrun(prelinked, 1, true);
  remainder = car(result);
  error = trap_error(fn () remainder(5, 0), null, call_trace_off, null);
  assert(error == error_divide_by_zero);
  result = remainder(11, 3);
  assert(integer?(result) && result - 2 == 0);
  display("LLVM integer remainder error test passed\n");
];

[
  | gtab |
  gtab = global_table();
  assert(gtab["system_cmd"] == null);
  assert(gtab["llvm_load_function"] == null);
  assert(gtab["llvm_call_function"] == null);
  assert(gtab["llvm_function_closure"] == null);
  display("LLVM removed primitives undefined test passed\n");
];

[
  | ir, err |
  ir = "define i64 @test_sec(i64 %env, ptr %args, i64 %nargs) {\nentry:\n  ret i64 42\n}\n";
  err = with_maxseclevel(0, fn () [
    trap_error(
      fn () llvm_load_ir_closure(ir, "test_sec", 0, 0, vector(vector(), vector())),
      fn (n) n, call_trace_off, null)
  ]);
  assert(err == error_security_violation);
  display("LLVM low-seclevel llvm_load_ir_closure security test passed\n");
];

[
  | ir, f, err |
  ir = "declare i32 @system(ptr)\ndefine i64 @test_sys(i64 %env, ptr %args, i64 %nargs) {\nentry:\n  %r = call i32 @system(ptr null)\n  ret i64 0\n}\n";
  f = llvm_load_ir_closure(ir, "test_sys", 0, 1, vector(vector(), vector()));
  err = trap_error(
    fn () f(),
    fn (n) n, call_trace_off, null);
  assert(err == error_bad_value);
  display("LLVM restricted symbol resolution test passed\n");
];

display("ALL LLVM & ASMWRITER TESTS PASSED SUCCESSFULLY\n");
