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

/* Library conversions and the same algorithms compiled inside the kernel.
 * Each round copies list/vector containers, mutates scalar slots and shared
 * child contents, and mutates a list cell without changing its copied vector.
 * Explicit collection stress is checked before, outside CPU measurements. */
[
  | compile, check, kernel, result, runs, iteration, elapsed, start,
    timed_calls, timed_calls_env |
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
  check = fn (actual, n, width)
    assert(equal?(actual, vector(n * (n - 1) / 2 + 17 * n, n - 1, width, true)));
  kernel = compile("""fn (n, width, collect) [ | to_vector, to_list, child, v, old, lst, i, j, sum, previous |
  to_vector = list_to_vector; to_list = vector_to_list;
  child = vector(-1); v = make_vector(width); j = 0;
  while (j < width) [ v[j] = j; j = iadd(j, 1); ];
  v[0] = child; v[1] = -1; i = 0; sum = 0;
  while (i < n) [
    old = v; previous = old[1];
    lst = to_list(old); v = to_vector(lst);
    if (v[0] != child || car(lst) != child || vlength(v) != width)
      error(error_bad_value);
    v[1] = i; v[-1] = iadd(i, 17);
    child[0] = i;
    if (old[1] != previous || car(cdr(lst)) != previous || car(lst)[0] != i)
      error(error_bad_value);
    set_car!(cdr(lst), -999);
    if (v[1] != i) error(error_bad_value);
    if (collect && i % 127 == 0) [
      garbage_collect(0); garbage_collect(0);
      if (v[0] != child || car(lst) != child || child[0] != i)
        error(error_bad_value);
    ];
    sum = iadd(sum, v[-1]); i = iadd(i, 1);
  ]; vector(sum, child[0], vlength(v), car(lst) == child)
]""", "list-vector-library-32.mud");
  check(kernel(1000, 32, true), 1000, 32);
  check(kernel(10000, 32, false), 10000, 32);
  iteration = 0; elapsed = 0;
  while (iteration < runs) [
    start = ctime(); result = kernel(10000, 32, false); elapsed = iadd(elapsed, ctime() - start);
    check(result, 10000, 32); iteration = iadd(iteration, 1);
  ];
  display(format("backend=%s workload=list-vector-library-32 work=10000 width=32 runs=%d cpu_ms=%d checksum=%w\n",
                 mc:archname, runs, elapsed, result));
  kernel = compile("""fn (n, width, collect) [ | to_vector, to_list, child, v, old, lst, i, j, sum, previous |
  to_vector = fn (list lst) [ | scan, len, v, j |
    scan = lst; len = 0;
    while (pair?(scan)) [ len = iadd(len, 1); scan = cdr(scan); ];
    v = make_vector(len); j = 0;
    while (pair?(lst)) [ v[j] = car(lst); j = iadd(j, 1); lst = cdr(lst); ];
    v
  ];
  to_list = fn (vector v) [ | len, lst |
    len = vlength(v);
    while (len > 0) [ len = iadd(len, -1); lst = cons(v[len], lst); ];
    lst
  ];
  child = vector(-1); v = make_vector(width); j = 0;
  while (j < width) [ v[j] = j; j = iadd(j, 1); ];
  v[0] = child; v[1] = -1; i = 0; sum = 0;
  while (i < n) [
    old = v; previous = old[1];
    lst = to_list(old); v = to_vector(lst);
    if (v[0] != child || car(lst) != child || vlength(v) != width)
      error(error_bad_value);
    v[1] = i; v[-1] = iadd(i, 17);
    child[0] = i;
    if (old[1] != previous || car(cdr(lst)) != previous || car(lst)[0] != i)
      error(error_bad_value);
    set_car!(cdr(lst), -999);
    if (v[1] != i) error(error_bad_value);
    if (collect && i % 127 == 0) [
      garbage_collect(0); garbage_collect(0);
      if (v[0] != child || car(lst) != child || child[0] != i)
        error(error_bad_value);
    ];
    sum = iadd(sum, v[-1]); i = iadd(i, 1);
  ]; vector(sum, child[0], vlength(v), car(lst) == child)
]""", "list-vector-native-32.mud");
  check(kernel(1000, 32, true), 1000, 32);
  check(kernel(10000, 32, false), 10000, 32);
  iteration = 0; elapsed = 0;
  while (iteration < runs) [
    start = ctime(); result = kernel(10000, 32, false); elapsed = iadd(elapsed, ctime() - start);
    check(result, 10000, 32); iteration = iadd(iteration, 1);
  ];
  display(format("backend=%s workload=list-vector-native-32 work=10000 width=32 runs=%d cpu_ms=%d checksum=%w\n",
                 mc:archname, runs, elapsed, result));
  kernel = compile("""fn (n, width, collect) [ | to_vector, to_list, child, v, old, lst, i, j, sum, previous |
  to_vector = fn (list lst) [ | scan, len, v, j |
    scan = lst; len = 0;
    while (pair?(scan)) [ len = iadd(len, 1); scan = cdr(scan); ];
    v = make_vector(len); j = 0;
    while (pair?(lst)) [ v[j] = car(lst); j = iadd(j, 1); lst = cdr(lst); ];
    v
  ];
  to_list = fn (vector v) [ | len, lst |
    len = vlength(v);
    while (len > 0) [ len = iadd(len, -1); lst = cons(v[len], lst); ];
    lst
  ];
  child = vector(-1); v = make_vector(width); j = 0;
  while (j < width) [ v[j] = j; j = iadd(j, 1); ];
  v[0] = child; v[1] = -1; i = 0; sum = 0;
  while (i < n) [
    old = v; previous = old[1];
    lst = to_list(old); v = to_vector(lst);
    if (v[0] != child || car(lst) != child || vlength(v) != width)
      error(error_bad_value);
    v[1] = i; v[-1] = iadd(i, 17);
    child[0] = i;
    if (old[1] != previous || car(cdr(lst)) != previous || car(lst)[0] != i)
      error(error_bad_value);
    set_car!(cdr(lst), -999);
    if (v[1] != i) error(error_bad_value);
    if (collect && i % 127 == 0) [
      garbage_collect(0); garbage_collect(0);
      if (v[0] != child || car(lst) != child || child[0] != i)
        error(error_bad_value);
    ];
    sum = iadd(sum, v[-1]); i = iadd(i, 1);
  ]; vector(sum, child[0], vlength(v), car(lst) == child)
]""", "list-vector-native-257.mud");
  check(kernel(1000, 257, true), 1000, 257);
  check(kernel(2000, 257, false), 2000, 257);
  iteration = 0; elapsed = 0;
  while (iteration < runs) [
    start = ctime(); result = kernel(2000, 257, false); elapsed = iadd(elapsed, ctime() - start);
    check(result, 2000, 257); iteration = iadd(iteration, 1);
  ];
  display(format("backend=%s workload=list-vector-native-257 work=2000 width=257 runs=%d cpu_ms=%d checksum=%w\n",
                 mc:archname, runs, elapsed, result));
  display("benchmark-sequences-success\n");
];
