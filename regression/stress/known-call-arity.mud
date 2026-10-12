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

// Manual stress script. Run: ./mudlle -e xc.mud -e regression/stress/known-call-arity.mud
// Known calls with 0 to 4 arguments and nested calls in one function share
// one static argument buffer; callees allocate and collect. Expect SUM=244,
// then an error trace with intact arguments, then STRESS_DONE.

[
  | outer, r, alloc |
  outer = fn (n) [
    | f0, f1, f2, f3, g, h, k, bad, i, s, v |
    f0 = fn () [ | l, j | l = null; j = 0; while (j < 3000) [ l = j . l; j = iadd(j, 1) ]; 7 ];
    f1 = fn (a) [ | l, j | l = null; j = 0; while (j < 3000) [ l = j . l; j = iadd(j, 1) ]; a + 1 ];
    f2 = fn (a, b) [ | l, j | l = null; j = 0; while (j < 3000) [ l = j . l; j = iadd(j, 1) ]; a * 10 + b ];
    f3 = fn (a, b, c) [ | l, j | l = null; j = 0; while (j < 3000) [ l = j . l; j = iadd(j, 1) ]; a * 100 + b * 10 + c ];
    g = fn (a, b) [ | l | l = make_vector(2000); garbage_collect(0); a + b ];
    h = fn (a) [ | l | l = make_vector(2000); garbage_collect(0); a * 2 ];
    k = fn (a, b, c, d) a + b + c + d;
    bad = fn (a, b, c) [ | l, j | l = null; j = 0; while (j < 3000) [ l = j . l; j = iadd(j, 1) ];
      if (a == 2) error(error_bad_value); a ];
    s = 0;
    s = s + f0() + f1(1) + f2(1, 2) + f3(1, 2, 3);   // 7+2+12+123 = 144
    s = s + f2(g(1, 2), h(3));                        // f2(3,6)=36
    s = s + f1(f2(f1(1), f0()));                      // f1(f2(2,7)=27)=28
    s = s + k(f0(), f1(1), f2(1, 1), f3(0, 0, 1));    // 7+2+11+1=21
    s = s + f0() + f1(f0());                          // 7+8 = 15
    v = vector(s, "keep", 1.5); display(format("SUM=%d\n", s));
    i = 0;
    while (i < 4) [ bad(i, vector(i, "x"), "str" + "ing"); i = i + 1 ];
    s
  ];
  r = trap_error(fn () outer(1), fn (n) [ display(format("HANDLED %d\n", n)); 0 ], call_trace_on, null);
  display(format("R=%d\n", r));
  display("EXPECT_SUM=144+36+28+21+15=244\n");
];
display("STRESS_DONE\n");
