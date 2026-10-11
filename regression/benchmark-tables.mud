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

/* The table kernel uses string lookup and inserted symbol keys, replaces all
 * values, deletes and reinserts every third key, then iterates all entries.
 * Collection stress runs before timing and checks a child shared by all
 * payloads and the table itself. Timed calls check exact independent sums. */
[
  | compile, make_case, kernel, run_case, case32, case257 |
  compile = fn (source, name) [ | tree, linked |
    tree = mudlle_parse(source, name, false);
    linked = mc:linkrun(mc:compile(tree, false, 1, mc:source_code(source)), 1, true);
    if (!pair?(linked)) error(error_bad_value);
    car(linked)
  ];
  make_case = fn (n, rounds) [
    | keys, symbols, original, replacement, reinsertion, child, shared_key,
      base_sum, third_sum, i, key, payload |
    keys = make_vector(n); symbols = make_vector(n);
    original = make_vector(n); replacement = make_vector(n);
    reinsertion = make_vector(n);
    child = vector(123456, 654321);
    shared_key = "table-shared-child";
    base_sum = 0; third_sum = 0; i = 0;
    while (i < n) [
      key = format("table-key-%d", i);
      payload = iadd(i, 1);
      keys[i] = key;
      original[i] = vector(payload, child);
      replacement[i] = vector(payload * 2, child);
      reinsertion[i] = vector(payload * 3, child);
      symbols[i] = make_symbol(key, original[i]);
      base_sum = iadd(base_sum, payload);
      if (i % 3 == 0) third_sum = iadd(third_sum, payload);
      i = iadd(i, 1);
    ];
    vector(keys, symbols, original, replacement, reinsertion, child,
           shared_key, base_sum, third_sum, rounds, n)
  ];
  kernel = compile("""fn (keys, symbols, original, replacement, reinsertion,
                       child, shared_key, rounds, stress) [
    | n, table, i, round, payload, lookup_sum, replace_sum, repeat_sum,
      iteration_sum,
      entries, entry_count, shared_count, j, sym, name, data |
    n = vlength(keys); lookup_sum = 0; replace_sum = 0; repeat_sum = 0;
    iteration_sum = 0; entry_count = 0; shared_count = 0; round = 0;
    while (round < rounds) [
      table = make_ctable(); i = 0;
      while (i < n) [
        if (i % 2 == 0)
          table_set!(table, keys[i], original[i])
        else [
          symbol_set!(symbols[i], original[i]);
          table_add_symbol!(table, symbols[i]);
        ];
        i = iadd(i, 1);
      ];
      table_set!(table, shared_key, child);
      if (stress && round % 4 == 0) [
        garbage_collect(0); garbage_collect(0);
        if (table_ref(table, shared_key) != child
            || child[0] != 123456 || child[1] != 654321
            || table_ref(table, keys[0])[1] != child
            || symbol_get(table_lookup(table, keys[1]))[1] != child)
          error(error_bad_value);
      ];
      i = 0;
      while (i < n) [
        if (i % 2 == 0)
          payload = table_ref(table, keys[i])
        else
          payload = symbol_get(table_lookup(table, keys[i]));
        if (payload != original[i] || payload[0] != iadd(i, 1)
            || payload[1] != child)
          error(error_bad_value);
        lookup_sum = iadd(lookup_sum, payload[0]);
        i = iadd(i, 1);
      ];
      i = 0;
      while (i < n) [
        if (i % 2 == 0)
          table_set!(table, keys[i], replacement[i])
        else
          symbol_set!(table_lookup(table, keys[i]), replacement[i]);
        i = iadd(i, 1);
      ];
      i = 0;
      while (i < n) [
        payload = table_ref(table, keys[i]);
        if (payload != replacement[i] || payload[0] != iadd(i, 1) * 2
            || payload[1] != child)
          error(error_bad_value);
        replace_sum = iadd(replace_sum, payload[0]);
        i = iadd(i, 1);
      ];
      i = 0;
      while (i < n) [
        if (i % 2 == 0)
          table_set!(table, keys[i], original[i])
        else
          symbol_set!(table_lookup(table, keys[i]), original[i]);
        i = iadd(i, 1);
      ];
      i = 0;
      while (i < n) [
        payload = table_ref(table, keys[i]);
        if (payload != original[i] || payload[0] != iadd(i, 1)
            || payload[1] != child)
          error(error_bad_value);
        repeat_sum = iadd(repeat_sum, payload[0]);
        i = iadd(i, 1);
      ];
      i = 0;
      while (i < n) [
        if (i % 3 == 0) [
          if (!table_remove!(table, keys[i])
              || table_lookup(table, keys[i]) != false)
            error(error_bad_value);
        ];
        i = iadd(i, 1);
      ];
      i = 0;
      while (i < n) [
        if (i % 3 == 0) [
          if (i % 2 == 0)
            table_set!(table, keys[i], reinsertion[i])
          else [
            symbol_set!(symbols[i], reinsertion[i]);
            table_add_symbol!(table, symbols[i]);
          ];
          if (table_ref(table, keys[i]) != reinsertion[i])
            error(error_bad_value);
        ];
        i = iadd(i, 1);
      ];
      if (stress && round % 4 == 0) [
        garbage_collect(0); garbage_collect(0);
        if (table_ref(table, shared_key) != child
            || child[0] != 123456 || child[1] != 654321
            || table_ref(table, keys[0])[1] != child
            || symbol_get(table_lookup(table, keys[1]))[1] != child)
          error(error_bad_value);
      ];
      entries = table_vector(table);
      if (vlength(entries) != iadd(n, 1)) error(error_bad_value);
      j = 0; i = 0;
      while (j < vlength(entries)) [
        sym = entries[j]; name = symbol_name(sym); data = symbol_get(sym);
        if (table_lookup(table, name) != sym) error(error_bad_value);
        if (string_equal?(name, shared_key)) [
          if (data != child || data[0] != 123456 || data[1] != 654321)
            error(error_bad_value);
          shared_count = iadd(shared_count, 1);
        ] else [
          if (data[1] != child) error(error_bad_value);
          iteration_sum = iadd(iteration_sum, data[0]);
          i = iadd(i, 1);
        ];
        j = iadd(j, 1);
      ];
      if (i != n) error(error_bad_value);
      entry_count = iadd(entry_count, vlength(entries));
      round = iadd(round, 1);
    ];
    vector(lookup_sum, replace_sum, repeat_sum, iteration_sum, entry_count,
           child[0], child[1], shared_count)
  ]""", "table-mixed-keys.mud");
  run_case = fn (data) [
    | keys, symbols, original, replacement, reinsertion, child, shared_key,
      base_sum, third_sum, rounds, n, expected, result, iteration, elapsed,
      start, timed_runs |
    keys = data[0]; symbols = data[1]; original = data[2];
    replacement = data[3]; reinsertion = data[4]; child = data[5];
    shared_key = data[6]; base_sum = data[7]; third_sum = data[8];
    rounds = data[9]; n = data[10];
    expected = vector(base_sum * rounds, base_sum * 2 * rounds,
                      base_sum * rounds,
                      (base_sum + third_sum * 2) * rounds,
                      (n + 1) * rounds, 123456, 654321, rounds);
    result = kernel(keys, symbols, original, replacement, reinsertion,
                    child, shared_key, rounds, true);
    assert(equal?(result, expected));
    iteration = 0; elapsed = 0; timed_runs = 5;
    while (iteration < timed_runs) [
      start = ctime();
      result = kernel(keys, symbols, original, replacement, reinsertion,
                      child, shared_key, rounds, false);
      elapsed = iadd(elapsed, ctime() - start);
      assert(equal?(result, expected));
      iteration = iadd(iteration, 1);
    ];
    display(format("backend=%s workload=table-mixed-%d work=%d width=%d runs=%d cpu_ms=%d checksum=%w\n",
                   mc:archname, n, n * rounds, n, timed_runs, elapsed,
                   result));
  ];
  case32 = make_case(32, 256);
  case257 = make_case(257, 32);
  run_case(case32);
  run_case(case257);
  display("benchmark-tables-success\n");
];
