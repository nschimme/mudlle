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

/* Calls through local closures, compiled and linked before timing.
 * fib: self-recursive local closure. closure-loop: a loop calling a small
 * local function. Results are checked outside the timers. */
[
  | compile, fib, calls, runs, iteration, elapsed, start, result |
  runs = 5;
  compile = fn (source, name) [ | tree, linked |
    tree = mudlle_parse(source, name, false);
    linked = mc:linkrun(mc:compile(tree, false, 1, mc:source_code(source)), 1, true);
    if (!pair?(linked)) error(error_bad_value);
    car(linked)
  ];
  fib = compile("""fn (n) [ | f |
  f = fn (k) if (k < 2) k else f(k - 1) + f(k - 2);
  f(n) ]""", "calls-fib.mud");
  calls = compile("""fn (n) [ | add, i, s |
  add = fn (a, b) a + b;
  i = 0; s = 0;
  while (i < n) [ s = add(s, i); i = iadd(i, 1); ];
  s ]""", "calls-loop.mud");
  assert(fib(20) == 6765);
  assert(calls(1000) == 499500);
  iteration = 0; elapsed = 0;
  while (iteration < runs) [
    start = ctime(); result = fib(27); elapsed = iadd(elapsed, ctime() - start);
    assert(result == 196418); iteration = iadd(iteration, 1);
  ];
  display(format("backend=%s workload=calls-fib-27 work=1 runs=%d cpu_ms=%d checksum=%w\n",
                 mc:archname, runs, elapsed, result));
  iteration = 0; elapsed = 0;
  while (iteration < runs) [
    start = ctime(); result = calls(2000000); elapsed = iadd(elapsed, ctime() - start);
    assert(result == 1999999000000); iteration = iadd(iteration, 1);
  ];
  display(format("backend=%s workload=calls-closure-loop work=2000000 runs=%d cpu_ms=%d checksum=%w\n",
                 mc:archname, runs, elapsed, result));
  display("SUCCESS\n");
];
