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

// Load xc.mud or icxc.mud before this file to select the compiler.
// Nested float calls keep intermediates as raw doubles; every result must
// match the same computation split through named (boxed) variables.

[
  | compile, chain, split, unary, usplit, mixed, mixed_split, same?, args,
    a, b, c, err, i, bigs, nan, inf, lit, lit_split, vararg_lit,
    vararg_values, vararg_count |
  compile = fn (source, name) [ | tree, prelinked, linked |
    tree = mudlle_parse(source, name, false);
    prelinked = mc:compile(tree, false, 1, mc:source_code(source));
    assert(vector?(prelinked));
    linked = mc:linkrun(prelinked, 1, true);
    assert(pair?(linked));
    car(linked)
  ];

  chain = compile("fn (a, b, c) fadd(fmul(fsub(a, b), c), fdiv(fadd(a, 1.0), fmod(fmul(b, b), fadd(c, 3.0))))",
                  "llvm-float-chain.mud");
  split = compile("fn (a, b, c) [ | t1, t2, t3, t4, t5, t6 | t1 = fsub(a, b); t2 = fmul(t1, c); t3 = fadd(a, 1.0); t4 = fmul(b, b); t5 = fadd(c, 3.0); t6 = fmod(t4, t5); fadd(t2, fdiv(t3, t6)) ]",
                  "llvm-float-split.mud");
  unary = compile("fn (a, b) fneg(fabs(fsqrt(fadd(fmul(a, a), fmul(b, b)))))",
                  "llvm-float-unary.mud");
  usplit = compile("fn (a, b) [ | t1, t2, t3, t4 | t1 = fmul(a, a); t2 = fmul(b, b); t3 = fadd(t1, t2); t4 = fsqrt(t3); fneg(fabs(t4)) ]",
                   "llvm-float-usplit.mud");
  // an intermediate that also escapes, and a loop-carried chain
  mixed = compile("fn (n, x) [ | i, v | i = 0; v = x; while (i < n) [ v = fadd(fmul(v, 0.5), fdiv(1.0, fadd(v, 2.0))); i = iadd(i, 1) ]; v ]",
                  "llvm-float-loop.mud");
  mixed_split = compile("fn (n, x) [ | i, v, t1, t2, t3 | i = 0; v = x; while (i < n) [ t1 = fmul(v, 0.5); t2 = fadd(v, 2.0); t3 = fdiv(1.0, t2); v = fadd(t1, t3); i = iadd(i, 1) ]; v ]",
                        "llvm-float-loop-split.mud");

  // literal operands: floats, small/large/negative fixnums, shared constants
  lit = compile("fn (a) fadd(fmul(a, 0.5), fsub(fdiv(3, a), fadd(-7, fmul(0.5, 4611686018427387903))))",
                "llvm-float-lit.mud");
  lit_split = compile("fn (a) [ | t1, t2, t3, t4, t5 | t1 = fmul(a, 0.5); t2 = fdiv(3, a); t3 = fmul(0.5, 4611686018427387903); t4 = fadd(-7, t3); t5 = fsub(t2, t4); fadd(t1, t5) ]",
                      "llvm-float-lit-split.mud");
  vararg_lit = compile("fn (a, rest...) if (vlength(rest) >= 0) fadd(a, 1.25) else 0",
                       "llvm-float-varargs.mud");

  same? = fn (x, y) equal?(x, y)
    || (equal?(format("%w", x), "nan") && equal?(format("%w", y), "nan"));

  bigs = itobi(4611686018427387903);
  nan = fdiv(0.0, 0.0);
  inf = fdiv(1.0, 0.0);
  args = list(list(1.5, 2.25, -3.0), list(7, 3, 2), list(0.1, 0.2, 0.3),
              list(1e300, 1e300, 1e10), list(bigs, 3, 4), list(2, bigs, 1.5),
              list(inf, 1.0, 2.0), list(nan, 1.0, 2.0), list(-0.0, 0.0, 1.0),
              list(5, 5, -3), list(1.0, 2.0, -3.0));
  lforeach(fn (t) [
    a = car(t); b = cadr(t); c = caddr(t);
    assert(same?(chain(a, b, c), split(a, b, c)));
    assert(same?(unary(a, b), usplit(a, b)));
  ], args);
  lforeach(fn (x) assert(same?(mixed(40, x), mixed_split(40, x))),
           list(0.0, 1, 2.5, -7.25, bigs));

  lforeach(fn (x) assert(same?(lit(x), lit_split(x))),
           list(1.5, 2, -3, 0.001, 1e100, bigs, 0, 0.0));

  // Vararg-vector allocation can move the active closure before its float
  // constants are loaded. Exercise varying argument counts and collection.
  i = 0;
  while (i < 200) [
    vararg_count = 64 + (i % 137);
    vararg_values = make_vector(vararg_count);
    vararg_values[0] = 3.5;
    assert(same?(apply(vararg_lit, vararg_values), 4.75));
    if (i % 8 == 0) garbage_collect(0);
    i = i + 1;
  ];

  // bad operands report the usual error from inside a chain
  err = trap_error(fn () chain("x", 1, 2), fn (n) n, call_trace_off, null);
  assert(err == error_bad_type);
  err = trap_error(fn () chain(1, 2, "x"), fn (n) n, call_trace_off, null);
  assert(err == error_bad_type);
  err = trap_error(fn () unary(null, 1), fn (n) n, call_trace_off, null);
  assert(err == error_bad_type);

  // intermediates survive collections between chains
  i = 0;
  while (i < 200)
    [
      assert(same?(chain(1.5, 2.25, i), split(1.5, 2.25, i)));
      if (i % 50 == 0) garbage_collect(0);
      i = i + 1;
    ];
  display("FLOAT_CHAINS_OK\n");
];
