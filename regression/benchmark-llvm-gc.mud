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
 * Compile each kernel once, verify it, then time only compiled calls.
 * Load xc.mud first so mc:compile selects the active backend.
 */
[
  | compile, measure_member, churn_source, walk_source, member_source, churn, walk, member,
    work, runs, expected, start, elapsed, i, vec |
  compile = fn (source, name) [ | tree, prelinked, linked |
    tree = mudlle_parse(source, name, false);
    prelinked = mc:compile(tree, false, 1, mc:source_code(source));
    if (!vector?(prelinked)) error(error_bad_value);
    linked = mc:linkrun(prelinked, 1, true);
    if (!pair?(linked)) error(error_bad_value);
    car(linked)
  ];

  churn_source = "fn (n) [ | i, sum, scratch | i = 0; sum = 0; while (i < n) [ scratch = vector(i, sum, i + 1, sum + 1); sum = iadd(sum, iadd(scratch[0], scratch[2])); i = iadd(i, 1); ]; sum ]";
  walk_source = "fn (v, n) [ | i, sum, scratch | i = 0; sum = 0; while (i < n) [ sum = iadd(sum, v[i % vlength(v)]); if ((i % 32) == 0) scratch = vector(i, sum, i + sum); i = iadd(i, 1); ]; sum ]";
  member_source = "fn (needle, haystack) if (vfind?(needle, haystack)) 1 else 0";
  churn = compile(churn_source, "benchmark-llvm-gc-churn.mud");
  walk = compile(walk_source, "benchmark-llvm-gc-walk.mud");
  member = compile(member_source, "benchmark-llvm-gc-vfind.mud");
  measure_member = fn (needle, expected, name) [ | checksum, start, elapsed, i |
    if (member(needle, vec) != expected) error(error_bad_value);
    checksum = 0;
    start = ctime();
    i = 0;
    while (i < runs) [ checksum = iadd(checksum, member(needle, vec)); i = i + 1; ];
    elapsed = ctime() - start;
    if (checksum != runs * expected) error(error_bad_value);
    display(format("backend=%s workload=vector-find case=%s needle=%d work=%d runs=%d cpu_ms=%d checksum=%d\n",
                   mc:archname, name, needle, vlength(vec), runs, elapsed, checksum));
  ];

  work = 10000;
  runs = 100;
  expected = work * work;
  if (churn(work) != expected) error(error_bad_value);
  start = ctime();
  i = 0;
  while (i < runs) [ churn(work); i = i + 1; ];
  elapsed = ctime() - start;
  display(format("backend=%s workload=scalar-alloc work=%d runs=%d cpu_ms=%d\n",
                 mc:archname, work, runs, elapsed));

  /* A fixed integer vector makes element reads dominate this traversal. */
  vec = make_vector(256);
  i = 0;
  while (i < vlength(vec)) [ vec[i] = i % 97; i = i + 1; ];
  work = 10000;
  runs = 100;
  expected = 0;
  i = 0;
  while (i < work) [ expected = iadd(expected, vec[i % vlength(vec)]); i = i + 1; ];
  if (walk(vec, work) != expected) error(error_bad_value);
  start = ctime();
  i = 0;
  while (i < runs) [ walk(vec, work); i = i + 1; ];
  elapsed = ctime() - start;
  display(format("backend=%s workload=vector-walk work=%d runs=%d cpu_ms=%d\n",
                 mc:archname, work, runs, elapsed));

  /* Separate full scans from early exits in the compiled membership helper. */
  vec = make_vector(4096);
  i = 0;
  while (i < vlength(vec)) [ vec[i] = i + 1; i = i + 1; ];
  runs = 100000;
  measure_member(-1, 0, "absent");
  measure_member(4096, 1, "late-hit");
  measure_member(1, 1, "early-hit");
];
