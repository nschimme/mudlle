/*
 * Copyright (c) 2026 Nils Schimmelmann
 * All rights reserved.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose, without fee, and without written agreement is hereby granted,
 * provided that the above copyright notice and the following two paragraphs
 * appear in all copies of this software and its documentation.
 *
 * IN NO EVENT SHALL NILS SCHIMMELMANN BE LIABLE TO ANY PARTY FOR DIRECT,
 * INDIRECT, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OF
 * THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF NILS SCHIMMELMANN HAS BEEN
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * NILS SCHIMMELMANN SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 * PARTICULAR PURPOSE. THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS" BASIS,
 * AND NILS SCHIMMELMANN HAS NO OBLIGATION TO PROVIDE MAINTENANCE, SUPPORT,
 * UPDATES, ENHANCEMENTS, OR MODIFICATIONS.
 */

/* Three independent numeric kernels. References execute through the interpreter;
 * compiled kernels are linked before CPU timing. Every timed result is checked
 * afterward, outside the timer. No fast-math tolerance hides bigint errors. */
[
  | compile, close, check, reference, kernel, expected, result, start, elapsed,
    iteration, runs, timed_calls, timed_calls_env |
  timed_calls = 5;
  timed_calls_env = getenv("MUDLLE_BENCH_TIMED_CALLS");
  if (timed_calls_env) [
    timed_calls = atoi(timed_calls_env);
    if (!integer?(timed_calls) || timed_calls < 1 || timed_calls > 1000
        || !string_equal?(format("%d", timed_calls), timed_calls_env))
      error(error_bad_value);
  ];
  runs = timed_calls;
  compile = fn (source, name) [ | tree, linked |
    tree = mudlle_parse(source, name, false);
    linked = mc:linkrun(mc:compile(tree, false, 1, mc:source_code(source)), 1, true);
    if (!pair?(linked)) error(error_bad_value);
    car(linked)
  ];
  close = fn (a, b) fcmp(fabs(fsub(a, b)), fmul(0.0000000001, fadd(1.0, fabs(b)))) <= 0;
  check = fn (kind, actual, wanted) [
    assert(vlength(actual) == vlength(wanted));
    if (string_equal?(kind, "float")) [
      assert(close(actual[0], wanted[0]));
      assert(close(actual[1], wanted[1]));
      assert(close(actual[2], wanted[2]));
    ] else if (string_equal?(kind, "bigint"))
      assert(equal?(actual, wanted))
    else [ assert(equal?(actual[0], wanted[0]));
           assert(close(actual[1], wanted[1])); ];
  ];
  reference = fn (n) [ | i, x, y, z, old |
  i = 0; x = 0.25; y = 0.5; z = 0.75;
  while (i < n) [
    old = vector(x, y, z);
    x = fadd(old[0], fmul(fadd(fmul(fsub(old[1], old[0]), 0.125), fdiv(old[2], fadd(1.0, fmul(old[0], old[0])))), 0.001));
    y = fadd(old[1], fmul(fsub(fmul(fsub(old[2], old[1]), 0.25), fdiv(old[0], fadd(1.0, fmul(old[1], old[1])))), 0.001));
    z = fadd(old[2], fmul(fadd(fmul(fsub(old[0], old[2]), 0.0625), fdiv(old[1], fadd(1.0, fmul(old[2], old[2])))), 0.001));
    i = iadd(i, 1);
  ]; vector(x, y, z)
];
  kernel = compile("""fn (n) [ | i, x, y, z, old |
  i = 0; x = 0.25; y = 0.5; z = 0.75;
  while (i < n) [
    old = vector(x, y, z);
    x = fadd(old[0], fmul(fadd(fmul(fsub(old[1], old[0]), 0.125), fdiv(old[2], fadd(1.0, fmul(old[0], old[0])))), 0.001));
    y = fadd(old[1], fmul(fsub(fmul(fsub(old[2], old[1]), 0.25), fdiv(old[0], fadd(1.0, fmul(old[1], old[1])))), 0.001));
    z = fadd(old[2], fmul(fadd(fmul(fsub(old[0], old[2]), 0.0625), fdiv(old[1], fadd(1.0, fmul(old[2], old[2])))), 0.001));
    i = iadd(i, 1);
  ]; vector(x, y, z)
]""", "numeric-float-primitives.mud");
  expected = reference(100000);
  result = kernel(100000);
  garbage_collect(0); garbage_collect(0);
  check("float", result, expected);
  iteration = 0; elapsed = 0;
  while (iteration < runs) [
    start = ctime(); result = kernel(100000); elapsed = iadd(elapsed, ctime() - start);
    check("float", result, expected);
    iteration = iadd(iteration, 1);
  ];
  display(format("backend=%s workload=float-primitives work=100000 runs=%d cpu_ms=%d checksum=%w\n",
                 mc:archname, runs, elapsed, result));
  reference = fn (n) [ | i, seed, modulus, x, y, three, five, eleven, old |
  seed = itobi(MAXINT); modulus = biadd(bimul(bimul(bimul(seed, seed), seed), seed), itobi(159));
  x = biadd(bimul(seed, seed), itobi(17)); y = biadd(seed, itobi(29));
  three = itobi(3); five = itobi(5); eleven = itobi(11); i = 0;
  while (i < n) [
    old = vector(x, y);
    x = bimod(biadd(biadd(bimul(old[0], old[0]), bimul(three, old[1])), itobi(i)), modulus);
    y = bimod(biadd(biadd(bimul(old[1], old[1]), bimul(five, x)), eleven), modulus);
    i = iadd(i, 1);
  ]; vector(x, y)
];
  kernel = compile("""fn (n) [ | i, seed, modulus, x, y, three, five, eleven, old |
  seed = itobi(MAXINT); modulus = biadd(bimul(bimul(bimul(seed, seed), seed), seed), itobi(159));
  x = biadd(bimul(seed, seed), itobi(17)); y = biadd(seed, itobi(29));
  three = itobi(3); five = itobi(5); eleven = itobi(11); i = 0;
  while (i < n) [
    old = vector(x, y);
    x = bimod(biadd(biadd(bimul(old[0], old[0]), bimul(three, old[1])), itobi(i)), modulus);
    y = bimod(biadd(biadd(bimul(old[1], old[1]), bimul(five, x)), eleven), modulus);
    i = iadd(i, 1);
  ]; vector(x, y)
]""", "numeric-bigint-primitives.mud");
  expected = reference(20000);
  result = kernel(20000);
  garbage_collect(0); garbage_collect(0);
  check("bigint", result, expected);
  iteration = 0; elapsed = 0;
  while (iteration < runs) [
    start = ctime(); result = kernel(20000); elapsed = iadd(elapsed, ctime() - start);
    check("bigint", result, expected);
    iteration = iadd(iteration, 1);
  ];
  display(format("backend=%s workload=bigint-primitives work=20000 runs=%d cpu_ms=%d checksum=%w\n",
                 mc:archname, runs, elapsed, result));
  reference = fn (n) [ | i, seed, modulus, x, scale, factor, total, old, residue |
  seed = itobi(MAXINT); modulus = biadd(bimul(bimul(bimul(seed, seed), seed), seed), itobi(159));
  x = biadd(bimul(seed, seed), itobi(17)); scale = itobi(104729);
  total = 0.0; i = 0;
  while (i < n) [
    old = vector(x, total, i);
    x = bimod(biadd(biadd(bimul(old[0], old[0]), itobi(old[2])), itobi(11)), modulus);
    residue = bimod(x, scale);
    factor = fdiv(bitof(residue), 104729.0);
    total = fdiv(fadd(old[1], fmul(factor, factor)), fadd(1.0, fmul(factor, 0.000001)));
    i = iadd(i, 1);
  ]; vector(x, total)
];
  kernel = compile("""fn (n) [ | i, seed, modulus, x, scale, factor, total, old, residue |
  seed = itobi(MAXINT); modulus = biadd(bimul(bimul(bimul(seed, seed), seed), seed), itobi(159));
  x = biadd(bimul(seed, seed), itobi(17)); scale = itobi(104729);
  total = 0.0; i = 0;
  while (i < n) [
    old = vector(x, total, i);
    x = bimod(biadd(biadd(bimul(old[0], old[0]), itobi(old[2])), itobi(11)), modulus);
    residue = bimod(x, scale);
    factor = fdiv(bitof(residue), 104729.0);
    total = fdiv(fadd(old[1], fmul(factor, factor)), fadd(1.0, fmul(factor, 0.000001)));
    i = iadd(i, 1);
  ]; vector(x, total)
]""", "numeric-mixed.mud");
  expected = reference(20000);
  result = kernel(20000);
  garbage_collect(0); garbage_collect(0);
  check("mixed", result, expected);
  iteration = 0; elapsed = 0;
  while (iteration < runs) [
    start = ctime(); result = kernel(20000); elapsed = iadd(elapsed, ctime() - start);
    check("mixed", result, expected);
    iteration = iadd(iteration, 1);
  ];
  display(format("backend=%s workload=mixed work=20000 runs=%d cpu_ms=%d checksum=%w\n",
                 mc:archname, runs, elapsed, result));
  display("benchmark-numeric-success\n");
];
