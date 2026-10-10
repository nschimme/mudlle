/* Write the compiled integer-loop benchmark's pre-optimization LLVM IR to
   /tmp for inspection with LLVM's optional `opt` utility. */
[
  | source, tree, ir, w |
  source = "fn (n) [ | sum, i | sum = 0; i = 0; while (i < n) [ sum = iadd(sum, i); i = iadd(i, 1); ]; sum ]";
  tree = mudlle_parse(source, "benchmark-kernel.mud", false);
  ir = mc:compile_llvm(tree, 1, mc:source_code(source));
  if (!string?(ir)) error(error_bad_value);
  w = writer:new_file("/tmp/mudlle-benchmark.ll");
  writer:write(w, ir);
  writer:close(w);
];
