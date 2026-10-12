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

// Exercise dynamic calls from LLVM code into independently interpreted closures.
[
  | compile, call0, call1, call2, call3, call4, call5, call6,
    sum0, sum1, sum2, sum3, sum4, sum5, sum6, optional, vararg,
    heap_callee, heap_args, err |
  compile = fn (source, name) [ | tree, prelinked, linked |
    tree = mudlle_parse(source, name, false);
    prelinked = mc:compile(tree, false, 1, mc:source_code(source));
    assert(vector?(prelinked));
    linked = mc:linkrun(prelinked, 1, true);
    assert(pair?(linked));
    car(linked)
  ];

  call0 = compile("fn (f) f()", "llvm-interpreter-call0.mud");
  call1 = compile("fn (f,a) f(a)", "llvm-interpreter-call1.mud");
  call2 = compile("fn (f,a,b) f(a,b)", "llvm-interpreter-call2.mud");
  call3 = compile("fn (f,a,b,c) f(a,b,c)", "llvm-interpreter-call3.mud");
  call4 = compile("fn (f,a,b,c,d) f(a,b,c,d)", "llvm-interpreter-call4.mud");
  call5 = compile("fn (f,a,b,c,d,e) f(a,b,c,d,e)", "llvm-interpreter-call5.mud");
  call6 = compile("fn (f,a,b,c,d,e,g) f(a,b,c,d,e,g)",
                  "llvm-interpreter-call6.mud");

  sum0 = fn () 30;
  sum1 = fn (a) a;
  sum2 = fn (a,b) a+b;
  sum3 = fn (a,b,c) a+b+c;
  sum4 = fn (a,b,c,d) a+b+c+d;
  sum5 = fn (a,b,c,d,e) a+b+c+d+e;
  sum6 = fn (a,b,c,d,e,g) a+b+c+d+e+g;
  assert(call0(sum0) == 30);
  assert(call1(sum1, 1) == 1);
  assert(call2(sum2, 1, 2) == 3);
  assert(call3(sum3, 1, 2, 3) == 6);
  assert(call4(sum4, 1, 2, 3, 4) == 10);
  assert(call5(sum5, 1, 2, 3, 4, 5) == 15);
  assert(call6(sum6, 1, 2, 3, 4, 5, 6) == 21);

  optional = fn (a, b = 7) a+b;
  assert(call1(optional, 5) == 12);
  assert(call2(optional, 5, 8) == 13);
  vararg = fn (a, rest...)
    [ garbage_collect(0); list(a, rest[0], rest[1]) ];
  assert(equal?(call3(vararg, 1, 2, 3), list(1, 2, 3)));

  heap_callee = fn (a,b,c,d,e,g)
    [ garbage_collect(0); a[0]+b[0]+c[0]+d[0]+e[0]+g[0] ];
  heap_args = vector(vector(1), vector(2), vector(3), vector(4),
                     vector(5), vector(6));
  assert(call6(heap_callee, heap_args[0], heap_args[1], heap_args[2],
               heap_args[3], heap_args[4], heap_args[5]) == 21);

  err = trap_error(fn () call1(fn (x) 1/0, 9), fn (n) n,
                   call_trace_off, null);
  assert(err == error_divide_by_zero);
  err = trap_error(fn () call0(sum1), fn (n) n, call_trace_off, null);
  assert(err == error_wrong_parameters);
  err = trap_error(fn () call2(sum1, 1, 2), fn (n) n, call_trace_off, null);
  assert(err == error_wrong_parameters);
  garbage_collect(0);
  assert(call6(heap_callee, heap_args[0], heap_args[1], heap_args[2],
               heap_args[3], heap_args[4], heap_args[5]) == 21);
  display("LLVM_INTERPRETER_CALLS_OK\n");
];
