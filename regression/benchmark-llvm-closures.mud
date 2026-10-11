// Fresh-process probe for temporary bytecode builders created by LLVM closures.
// Set closure_iterations before loading; the default bounds the baseline leak.
if (!integer?(closure_iterations)) closure_iterations = 20000;
load("xc.mud");
[
  | run |
  run = car(eval("fn (n) [ | i, f | i = 0; while (i < n) [ f = fn () i; assert(f() == i); i += 1; ]; garbage_collect(0); assert(f() == n); n ]"));
  assert(run(closure_iterations) == closure_iterations);
  display("LLVM_CLOSURES_OK\n");
];
