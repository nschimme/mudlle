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

[
  // 1. Basic arithmetic and evaluation
  regress("ts_eval arithmetic", ts_eval("10 + 20 * 3 - 5;"), 65);
  regress("ts_eval modulus", ts_eval("17 % 5;"), 2);

  // 2. Spaceship operator <=>
  regress("ts_eval spaceship lt", ts_eval("10 <=> 20;"), -1);
  regress("ts_eval spaceship eq", ts_eval("20 <=> 20;"), 0);
  regress("ts_eval spaceship gt", ts_eval("30 <=> 20;"), 1);

  // 3. Nullish coalescing ??
  regress("ts_eval nullish non-null", ts_eval("let a = 42; a ?? 100;"), 42);
  regress("ts_eval nullish null", ts_eval("let a = null; a ?? 100;"), 100);

  // 4. Template literal string interpolation
  regress("ts_eval template interpolation",
          ts_eval("let name = \"World\"; `Hello ${name}!`;"), "Hello World!");

  // 5. Variable declarations with type annotations
  regress("ts_eval let/const/var",
          ts_eval("let a: number = 5; const b: string = \"hello\"; var c: boolean = true; a + slength(b);"), 10);

  // 6. Control flow
  regress("ts_eval if-else",
          ts_eval("let x: number = 10; if (x > 5) { 100; } else { 200; };"), 100);
  regress("ts_eval while",
          ts_eval("let sum: number = 0; let i: number = 1; while (i <= 5) { sum = sum + i; i = i + 1; }; sum;"), 15);
  regress("ts_eval for",
          ts_eval("let sum: number = 0; for (let i: number = 1; i <= 5; i = i + 1) { sum = sum + i; }; sum;"), 15);

  // 7. Try / Catch and Throw
  regress("ts_eval try/catch",
          ts_eval("let res = 0; try { throw 99; } catch (err) { res = 99; }; res;"), 99);

  // 8. Functions and Arrow functions
  regress("ts_eval function decl",
          ts_eval("function add(a: number, b: number): number { return a + b; }; add(12, 30);"), 42);
  regress("ts_eval arrow function",
          ts_eval("let mul = (a: number, b: number): number => a * b; mul(6, 7);"), 42);

  // 9. Object literals and member access
  | obj_res |
  obj_res = ts_eval("let o = { x: 10, y: \"test\" }; o.x + slength(o.y);");
  regress("ts_eval object literal", obj_res, 14);

  // 10. Array literals and indexing
  | arr_res |
  arr_res = ts_eval("let a = [10, 20, 30]; a[0] + a[1] + a[2];");
  regress("ts_eval array literal", arr_res, 60);

  // 11. TS calling Mudlle APIs
  regress("ts_eval Mudlle format API",
          ts_eval("format(\"Value: %d\", 42);"), "Value: 42");

  // 12. Mudlle calling exported TS function
  | ts_fn |
  ts_fn = ts_eval("function ts_factorial(n: number): number { if (n <= 1) { return 1; } else { return n * ts_factorial(n - 1); }; }; ts_factorial;");
  regress("Mudlle calling TS factorial", ts_fn(5), 120);

  // 13. Source location tracking verification
  | ast, loc |
  ast = ts_parse("let x = 42;", "test_loc.ts");
  loc = ast[mc:m_body][mc:c_loc];
  regress("ts_parse source location line", loc[0], 1);
  regress("ts_parse source location column", loc[1], 1);
  regress("ts_parse source location pos", loc[2], 0);

  true
];
