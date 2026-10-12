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
    heap, values, empty, err, tail_concat, captured_concat, a, b, i,
    symbol_name_call, symbol_get_call, symbol_value, primitive_call,
    dynamic_call, dynamic_result, scalar_recursion, heap_recursion,
    reassigned_checked_argument, conditional_checked_argument,
    recursive_value, conditional_value |
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
  symbol_name_call = compile("fn (s) symbol_name(s)",
                             "llvm-fast-symbol-name.mud");
  symbol_get_call = compile("fn (s) symbol_get(s)",
                            "llvm-fast-symbol-get.mud");
  primitive_call = compile("fn (a,b) iadd(a,b)",
                           "llvm-fast-primitive-call.mud");
  dynamic_call = compile("fn (f,a,b) f(a,b)",
                         "llvm-fast-dynamic-call.mud");

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

  // Symbol reads return their fields for valid symbols and preserve the
  // runtime type error through the fast path's slow branch.
  symbol_value = make_symbol("llvm-fast-path-symbol", 17);
  assert(equal?(symbol_name_call(symbol_value), "llvm-fast-path-symbol"));
  assert(symbol_get_call(symbol_value) == 17);
  symbol_set!(symbol_value, vector(4, 2));
  assert(equal?(symbol_get_call(symbol_value), vector(4, 2)));
  err = trap_error(fn () symbol_name_call(7), fn (n) n,
                   call_trace_off, null);
  assert(err == error_bad_type);
  err = trap_error(fn () symbol_get_call(null), fn (n) n,
                   call_trace_off, null);
  assert(err == error_bad_type);

  // The direct primitive call keeps its ordinary result, while an indirect
  // callee still follows the supplied function value.
  assert(primitive_call(20, 22) == 42);
  assert(primitive_call(MAXINT, 1) == MININT);
  err = trap_error(fn () primitive_call("not an integer", 1), fn (n) n,
                   call_trace_off, null);
  assert(err == error_bad_type);
  dynamic_result = dynamic_call(fn (x,y) x-y, 9, 4);
  assert(dynamic_result == 5);

  // A tail numeric builtin can allocate (string + uses the runtime fallback)
  // without keeping local roots in the leaf. Its call frame must still expose
  // arguments, and its caller must retain the inputs across that allocation.
  tail_concat = compile("""fn (a,b) [ | leaf, result |
    leaf = fn (x,y) x+y;
    result = leaf(a,b);
    garbage_collect(0);
    vector(result,a,b) ]""", "llvm-tail-builtin-gc.mud");
  // A captured destination needs its closure/cell after the allocation and
  // must retain the conservative root frame, even when returned immediately.
  captured_concat = compile("""fn (a,b) [ | state, leaf |
    state = null;
    leaf = fn (x,y) [ state = x+y; state ];
    leaf(a,b) ]""", "llvm-captured-builtin-gc.mud");
  // Recursive calls return integers while each caller keeps a heap argument
  // and local alive. The heap-return variant verifies that recursive results
  // stay rooted when used after another collection.
  scalar_recursion = compile("""fn (n, p) [ | f |
    f = fn (k, q) [ | held, child |
      held = q;
      if (k == 0) [ garbage_collect(0); assert(held[0] == 13); 13 ]
      else [ child = f(k - 1, held); garbage_collect(0);
             assert(held[0] == 13); 13 + child ] ];
    f(n, p) ]""", "llvm-scalar-recursion-gc.mud");
  heap_recursion = compile("""fn (n, p) [ | f |
    f = fn (k, q) [ | held, child |
      held = q;
      if (k == 0) [ garbage_collect(0); held ]
      else [ child = f(k - 1, held); garbage_collect(0);
             vector(child, held) ] ];
    f(n, p) ]""", "llvm-heap-recursion-gc.mud");
  // The checked argument is overwritten with a heap value, and the conditional
  // variant checks x on only one path. Both values must remain rooted at GC.
  reassigned_checked_argument = compile("""fn (x) [ | scratch |
    scratch = iadd(x, 0);
    x = vector(42);
    garbage_collect(0);
    x[0] + scratch ]""", "llvm-reassigned-checked-argument-gc.mud");
  conditional_checked_argument = compile("""fn (x, flag) [ | scratch |
    if (flag) [ scratch = iadd(x, 0) ];
    garbage_collect(0);
    x ]""", "llvm-conditional-checked-argument-gc.mud");
  i = 0;
  while (i < 32) [
    a = "left" + make_string(65536);
    b = "right" + make_string(65536);
    values = tail_concat(a,b);
    assert(equal?(values[0], a+b));
    assert(values[1] == a && values[2] == b);
    assert(equal?(captured_concat(a,b), a+b));
    i = iadd(i,1);
  ];
  recursive_value = scalar_recursion(6, vector(13));
  assert(recursive_value == 91);
  recursive_value = heap_recursion(5, vector(29));
  i = 5;
  while (i > 0) [
    assert(recursive_value[1][0] == 29);
    recursive_value = recursive_value[0];
    i = i - 1;
  ];
  assert(recursive_value[0] == 29);
  assert(reassigned_checked_argument(8) == 50);
  conditional_value = vector(73);
  assert(conditional_checked_argument(conditional_value, false)
         == conditional_value);

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
  err = trap_error(fn () length(null), fn (n) n,
                   call_trace_off, null);
  assert(err == error_bad_type);
  err = trap_error(fn () length(7), fn (n) n,
                   call_trace_off, null);
  assert(err == error_bad_type);
  err = trap_error(fn () length(cons(1, null)), fn (n) n,
                   call_trace_off, null);
  assert(err == error_bad_type);
  err = trap_error(fn () ref(null, 0), fn (n) n,
                   call_trace_off, null);
  assert(err == error_bad_type);
  err = trap_error(fn () ref(7, 0), fn (n) n,
                   call_trace_off, null);
  assert(err == error_bad_type);
  err = trap_error(fn () ref(cons(1, null), 0), fn (n) n,
                   call_trace_off, null);
  assert(err == error_bad_type);

  display("LLVM_FAST_PATHS_OK\n");
];
