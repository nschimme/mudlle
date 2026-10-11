/*
 * Interpreter baseline for regression/benchmark.mud: the same loop, run
 * without loading the compiler. Run: ./mudlle -e regression/benchmark-interpreter.mud
 */
[
  | kernel, work, runs, start, elapsed, i |
  kernel = fn (n) [ | sum, i | sum = 0; i = 0; while (i < n) [ sum = iadd(sum, i); i = iadd(i, 1); ]; sum ];
  work = 50000; runs = 2000;
  if (kernel(work) != work * (work - 1) / 2) error(error_bad_value);
  start = ctime(); i = 0;
  while (i < runs) [ kernel(work); i = i + 1; ];
  elapsed = ctime() - start;
  display(format("backend=interpreter cpu_ms=%d\n", elapsed));
];
