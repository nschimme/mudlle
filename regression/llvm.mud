/*
 * Regression test for asmwriter and genllvm
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

display("Testing genllvm...\n");

| test_llvm |
test_llvm = fn (string code_str)
  [
    | tree, ir |
    tree = mudlle_parse(code_str, null, false);
    ir = mc:compile_llvm(tree, 1, mc:source_code(code_str));
    assert(string?(ir) && slength(ir) > 0);
    assert(string_search(ir, "target datalayout") >= 0);
    assert(string_search(ir, "define i64 @fn_") >= 0);
    assert(string_search(ir, "alloca i64") >= 0);
    assert(string_search(ir, "ret i64") >= 0);
    ir
  ];

[
  test_llvm("fn (a, b) a + b");
  display("genllvm test 1 passed\n");

  test_llvm("fn (a, b) [ if (a < b) a * b else a - b ]");
  display("genllvm test 2 passed\n");

  test_llvm("fn (x) [ | sum, i | sum = 0; i = 0; while (i < x) [ sum = sum + i; i = i + 1; ]; sum ]");
  display("genllvm test 3 passed\n");
];

display("ALL LLVM & ASMWRITER TESTS PASSED SUCCESSFULLY\n");
