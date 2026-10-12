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

/* Compile and link kernels before starting each timed loop. */
[
  | compile, scalar_source, roots1_source, roots4_source, roots16_source,
    scalar, roots0, control0, roots1, roots4, roots16, refs, work, runs, i, start, elapsed,
    checksum, expected, call1, call4, call16, control1, control4, control16,
    noalloc1, noalloc4, noalloc16 |
  compile = fn (source, name) [ | tree, prelinked, linked |
    tree = mudlle_parse(source, name, false);
    prelinked = mc:compile(tree, false, 1, mc:source_code(source));
    if (!vector?(prelinked)) error(error_bad_value);
    linked = mc:linkrun(prelinked, 1, true);
    if (!pair?(linked)) error(error_bad_value);
    car(linked)
  ];

  scalar_source = "fn (n) [ | i, sum | i = 0; sum = 0; while (i < n) [ sum = iadd(sum, i); i = iadd(i, 1); ]; sum ]";
  roots1_source = "fn (n, a) [ | i, sum, hold | i = 0; sum = 0; while (i < n) [ hold = vector(i, sum, i + 1, sum + 1); sum = iadd(sum, iadd(hold[0], iadd(hold[2], a[0]))); i = iadd(i, 1); ]; if (a[0] != 1 || hold[0] != n - 1 || hold[2] != n) error(error_bad_value); sum ]";
  roots4_source = "fn (n, a, b, c, d) [ | i, sum, hold | i = 0; sum = 0; while (i < n) [ hold = vector(i, sum, i + 1, sum + 1); sum = iadd(sum, iadd(hold[0], iadd(hold[2], iadd(a[0], iadd(b[0], iadd(c[0], d[0])))))); i = iadd(i, 1); ]; if (a[0] != 1 || b[0] != 2 || c[0] != 3 || d[0] != 4 || hold[0] != n - 1 || hold[2] != n) error(error_bad_value); sum ]";
  roots16_source = "fn (n, a, b, c, d, e, f, g, h, j, k, l, m, o, p, q, r) [ | i, sum, hold | i = 0; sum = 0; while (i < n) [ hold = vector(i, sum, i + 1, sum + 1); sum = iadd(sum, iadd(hold[0], iadd(hold[2], iadd(a[0], iadd(b[0], iadd(c[0], iadd(d[0], iadd(e[0], iadd(f[0], iadd(g[0], iadd(h[0], iadd(j[0], iadd(k[0], iadd(l[0], iadd(m[0], iadd(o[0], iadd(p[0], iadd(q[0], r[0])))))))))))))))))); i = iadd(i, 1); ]; if (a[0] != 1 || b[0] != 2 || c[0] != 3 || d[0] != 4 || e[0] != 5 || f[0] != 6 || g[0] != 7 || h[0] != 8 || j[0] != 9 || k[0] != 10 || l[0] != 11 || m[0] != 12 || o[0] != 13 || p[0] != 14 || q[0] != 15 || r[0] != 16 || hold[0] != n - 1 || hold[2] != n) error(error_bad_value); sum ]";
  roots0 = compile("fn (n) [ | i, sum, scratch | i = 0; sum = 0; while (i < n) [ scratch = vector(i, sum, i + 1, sum + 1); sum = iadd(sum, iadd(scratch[0], scratch[2])); i = iadd(i, 1); ]; sum ]", "benchmark-llvm-roots-0.mud");
  control0 = compile("fn (n) [ | i, sum | i = 0; sum = 0; while (i < n) [ sum = iadd(sum, iadd(i, iadd(i, 1))); i = iadd(i, 1); ]; sum ]", "benchmark-llvm-roots-control-0.mud");
  scalar = compile(scalar_source, "benchmark-llvm-roots-scalar.mud");
  roots1 = compile(roots1_source, "benchmark-llvm-roots-1.mud");
  roots4 = compile(roots4_source, "benchmark-llvm-roots-4.mud");
  roots16 = compile(roots16_source, "benchmark-llvm-roots-16.mud");
  control1 = compile("fn (n, a) [ | i, sum | i = 0; sum = 0; while (i < n) [ sum = iadd(sum, iadd(i, iadd(i + 1, a[0]))); i = iadd(i, 1); ]; sum ]", "benchmark-llvm-roots-control-1.mud");
  control4 = compile("fn (n, a, b, c, d) [ | i, sum | i = 0; sum = 0; while (i < n) [ sum = iadd(sum, iadd(i, iadd(i + 1, iadd(a[0], iadd(b[0], iadd(c[0], d[0])))))); i = iadd(i, 1); ]; sum ]", "benchmark-llvm-roots-control-4.mud");
  control16 = compile("fn (n, a, b, c, d, e, f, g, h, j, k, l, m, o, p, q, r) [ | i, sum | i = 0; sum = 0; while (i < n) [ sum = iadd(sum, iadd(i, iadd(i + 1, iadd(a[0], iadd(b[0], iadd(c[0], iadd(d[0], iadd(e[0], iadd(f[0], iadd(g[0], iadd(h[0], iadd(j[0], iadd(k[0], iadd(l[0], iadd(m[0], iadd(o[0], iadd(p[0], iadd(q[0], r[0])))))))))))))))))); i = iadd(i, 1); ]; sum ]", "benchmark-llvm-roots-control-16.mud");

  /* Distinct heap vectors remain live in this caller across each compiled call. */
  refs = make_vector(16);
  i = 0;
  while (i < 16) [ refs[i] = vector(i + 1); i = iadd(i, 1); ];
  work = 1000000;
  runs = 10;

  expected = work * (work - 1) / 2;
  if (scalar(work) != expected) error(error_bad_value);
  start = ctime();
  i = 0; checksum = 0;
  while (i < runs) [ checksum = iadd(checksum, scalar(work)); i = iadd(i, 1); ];
  elapsed = ctime() - start;
  if (checksum != expected * runs) error(error_bad_value);
  display(format("backend=%s workload=scalar-noalloc work=%d runs=%d cpu_ms=%d checksum=%d\n",
                 mc:archname, work, runs, elapsed, checksum));

  expected = work * work;
  if (control0(work) != expected || roots0(work) != expected) error(error_bad_value);
  start = ctime(); i = 0; checksum = 0;
  while (i < runs) [ checksum = iadd(checksum, control0(work)); i = iadd(i, 1); ];
  elapsed = ctime() - start;
  if (checksum != expected * runs) error(error_bad_value);
  display(format("backend=%s workload=scalar-live-roots roots=0 work=%d runs=%d cpu_ms=%d checksum=%d\n", mc:archname, work, runs, elapsed, checksum));
  start = ctime(); i = 0; checksum = 0;
  while (i < runs) [ checksum = iadd(checksum, roots0(work)); i = iadd(i, 1); ];
  elapsed = ctime() - start;
  if (checksum != expected * runs) error(error_bad_value);
  display(format("backend=%s workload=vector-alloc-live-roots roots=0 work=%d runs=%d cpu_ms=%d checksum=%d\n", mc:archname, work, runs, elapsed, checksum));

  call1 = fn (n) roots1(n, refs[0]);
  noalloc1 = fn (n) control1(n, refs[0]);
  expected = work * work + work;
  if (noalloc1(work) != expected) error(error_bad_value);
  start = ctime(); i = 0; checksum = 0;
  while (i < runs) [ checksum = iadd(checksum, noalloc1(work)); i = iadd(i, 1); ];
  elapsed = ctime() - start;
  if (checksum != expected * runs) error(error_bad_value);
  display(format("backend=%s workload=scalar-live-roots roots=1 work=%d runs=%d cpu_ms=%d checksum=%d\n", mc:archname, work, runs, elapsed, checksum));
  expected = work * work + work;
  if (call1(work) != expected) error(error_bad_value);
  start = ctime();
  i = 0;
  checksum = 0;
  while (i < runs) [ checksum = iadd(checksum, call1(work)); i = iadd(i, 1); ];
  elapsed = ctime() - start;
  if (checksum != expected * runs) error(error_bad_value);
  display(format("backend=%s workload=vector-alloc-live-roots roots=1 work=%d runs=%d cpu_ms=%d checksum=%d\n",
                 mc:archname, work, runs, elapsed, checksum));

  call4 = fn (n) roots4(n, refs[0], refs[1], refs[2], refs[3]);
  noalloc4 = fn (n) control4(n, refs[0], refs[1], refs[2], refs[3]);
  expected = work * work + work * 10;
  if (noalloc4(work) != expected) error(error_bad_value);
  start = ctime(); i = 0; checksum = 0;
  while (i < runs) [ checksum = iadd(checksum, noalloc4(work)); i = iadd(i, 1); ];
  elapsed = ctime() - start;
  if (checksum != expected * runs) error(error_bad_value);
  display(format("backend=%s workload=scalar-live-roots roots=4 work=%d runs=%d cpu_ms=%d checksum=%d\n", mc:archname, work, runs, elapsed, checksum));
  expected = work * work + work * 10;
  if (call4(work) != expected) error(error_bad_value);
  start = ctime();
  i = 0;
  checksum = 0;
  while (i < runs) [ checksum = iadd(checksum, call4(work)); i = iadd(i, 1); ];
  elapsed = ctime() - start;
  if (checksum != expected * runs) error(error_bad_value);
  display(format("backend=%s workload=vector-alloc-live-roots roots=4 work=%d runs=%d cpu_ms=%d checksum=%d\n",
                 mc:archname, work, runs, elapsed, checksum));

  call16 = fn (n) roots16(n, refs[0], refs[1], refs[2], refs[3], refs[4], refs[5], refs[6], refs[7], refs[8], refs[9], refs[10], refs[11], refs[12], refs[13], refs[14], refs[15]);
  noalloc16 = fn (n) control16(n, refs[0], refs[1], refs[2], refs[3], refs[4], refs[5], refs[6], refs[7], refs[8], refs[9], refs[10], refs[11], refs[12], refs[13], refs[14], refs[15]);
  expected = work * work + work * 136;
  if (noalloc16(work) != expected) error(error_bad_value);
  start = ctime(); i = 0; checksum = 0;
  while (i < runs) [ checksum = iadd(checksum, noalloc16(work)); i = iadd(i, 1); ];
  elapsed = ctime() - start;
  if (checksum != expected * runs) error(error_bad_value);
  display(format("backend=%s workload=scalar-live-roots roots=16 work=%d runs=%d cpu_ms=%d checksum=%d\n", mc:archname, work, runs, elapsed, checksum));
  expected = work * work + work * 136;
  if (call16(work) != expected) error(error_bad_value);
  start = ctime();
  i = 0;
  checksum = 0;
  while (i < runs) [ checksum = iadd(checksum, call16(work)); i = iadd(i, 1); ];
  elapsed = ctime() - start;
  if (checksum != expected * runs) error(error_bad_value);
  display(format("backend=%s workload=vector-alloc-live-roots roots=16 work=%d runs=%d cpu_ms=%d checksum=%d\n",
                 mc:archname, work, runs, elapsed, checksum));
  display("benchmark-llvm-roots-success\n");
];
