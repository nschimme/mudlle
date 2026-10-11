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

[
  | compile, add, subtract, multiply, divide, remainder, ref, length,
    heap, values, empty, err |
  compile = fn (source, name) [ | tree, prelinked, linked |
    tree = mudlle_parse(source, name, false);
    prelinked = mc:compile(tree, false, 1, mc:source_code(source));
    assert(vector?(prelinked));
    linked = mc:linkrun(prelinked, 1, true);
    assert(pair?(linked));
    car(linked)
  ];

  add = compile("fn (a,b) a+b", "llvm-fast-add.mud");
  subtract = compile("fn (a,b) a-b", "llvm-fast-subtract.mud");
  multiply = compile("fn (a,b) a*b", "llvm-fast-multiply.mud");
  divide = compile("fn (a,b) a/b", "llvm-fast-divide.mud");
  remainder = compile("fn (a,b) a%b", "llvm-fast-remainder.mud");
  ref = compile("fn (v,i) v[i]", "llvm-fast-ref.mud");
  length = compile("fn (v) vlength(v)", "llvm-fast-vlength.mud");

  assert(add(-9, 4) == -5);
  assert(add(MAXINT, 1) == MININT);
  assert(add(MININT, -1) == MAXINT);
  assert(subtract(-9, 4) == -13);
  assert(subtract(MAXINT, -1) == MININT);
  assert(subtract(MININT, 1) == MAXINT);
  assert(multiply(-7, 6) == -42);
  assert(multiply(MAXINT, 2) == -2);
  assert(multiply(MININT, 2) == 0);
  assert(divide(-7, 3) == -2);
  assert(divide(MININT, -1) == MININT);
  assert(remainder(-7, 3) == -1);
  assert(remainder(MININT, -1) == 0);

  assert(equal?(add("fast", " path"), "fast path"));
  assert(equal?(add(1.25, 2.25), 3.5));
  assert(equal?(add(itobi(4611686018427387903), itobi(1)),
                 biadd(itobi(4611686018427387903), itobi(1))));
  err = trap_error(fn () divide(5, 0), fn (n) n, call_trace_off, null);
  assert(err == error_divide_by_zero);
  err = trap_error(fn () remainder(5, 0), fn (n) n, call_trace_off, null);
  assert(err == error_divide_by_zero);
  err = trap_error(fn () add("fast", 1), fn (n) n, call_trace_off, null);
  assert(err == error_bad_type);

  heap = vector(7, 8);
  values = vector(10, heap, 30);
  empty = make_vector(0);
  assert(length(values) == 3);
  assert(length(empty) == 0);
  assert(ref(values, 0) == 10);
  assert(ref(values, 1) == heap);
  assert(ref(values, 2) == 30);
  assert(ref(values, -1) == 30);
  assert(ref(values, -2) == heap);
  assert(ref(values, -3) == 10);
  assert(ref("blurb", 0) == 98);
  assert(ref("blurb", -1) == 98);
  err = trap_error(fn () ref(empty, 0), fn (n) n,
                   call_trace_off, null);
  assert(err == error_bad_index);
  err = trap_error(fn () ref(values, 3), fn (n) n,
                   call_trace_off, null);
  assert(err == error_bad_index);
  err = trap_error(fn () ref(values, -4), fn (n) n,
                   call_trace_off, null);
  assert(err == error_bad_index);
  err = trap_error(fn () ref(values, "1"), fn (n) n,
                   call_trace_off, null);
  assert(err == error_bad_type);
  err = trap_error(fn () length("blurb"), fn (n) n,
                   call_trace_off, null);
  assert(err == error_bad_type);

  display("LLVM_FAST_PATHS_OK\n");
];
