/* Error diagnostics for calls through constant globals and builtins, compared
 * between LLVM builds by comparing stdout and stderr. */
[
  | compile, try |
  compile = fn (source, name) [ | tree, linked |
    tree = mudlle_parse(source, name, false);
    linked = mc:linkrun(mc:compile(tree, false, 1, mc:source_code(source)), 1, true);
    if (!pair?(linked)) error(error_bad_value);
    car(linked)
  ];
  try = fn (f, args) [
    dformat("%s\n", trap_error(fn () apply(f, args), fn (x) x, 0, "try"))
  ];
  try(compile("fn (x) pair?(x)", "d1.mud"), vector(1));
  try(compile("fn (x) car(x)", "d2.mud"), vector(1));
  try(compile("fn (x, y) make_vector(x, y)", "d3.mud"), vector(1, 2));
  try(compile("fn (x) make_vector(x)", "d4.mud"), vector("a"));
  try(compile("fn (x) cons(x, x) + 1", "d5.mud"), vector(1));
  try(compile("fn (x) list_to_vector(x)", "d6.mud"), vector(7));
  try(compile("fn (x) fadd(x, 1.5)", "d7.mud"), vector("s"));
  try(compile("fn (x) x < 1.5", "d8.mud"), vector(2.5));
  try(compile("fn (x) x < 1.5", "d9.mud"), vector("q"));
  try(compile("fn (x) vector_to_list(x)", "d10.mud"), vector(null));
  display("call-diagnostics-done\n");
]
