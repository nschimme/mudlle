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
  load_ts("deque.ts");

  | dq |
  dq = deque_new();

  // Test empty state
  regress("deque.ts initial is_empty", deque_is_empty(dq), true);
  regress("deque.ts initial size", deque_size(dq), 0);
  regress("deque.ts empty peek_front", deque_peek_front(dq), null);
  regress("deque.ts empty peek_back", deque_peek_back(dq), null);
  regress("deque.ts empty pop_front", deque_pop_front(dq), null);
  regress("deque.ts empty pop_back", deque_pop_back(dq), null);

  // Push elements
  deque_push_back(dq, "first");
  deque_push_back(dq, "second");
  deque_push_front(dq, "zero"); // Deque order: ["zero", "first", "second"]

  regress("deque.ts size after pushes", deque_size(dq), 3);
  regress("deque.ts is_empty after pushes", deque_is_empty(dq), false);
  regress("deque.ts peek_front value", deque_peek_front(dq), "zero");
  regress("deque.ts peek_back value", deque_peek_back(dq), "second");

  // Push more items to trigger capacity resizing (> 8 elements)
  | i |
  i = 1;
  while (i <= 10)
    [
      deque_push_back(dq, i);
      i = i + 1;
    ];
  regress("deque.ts size after 10 additional pushes", deque_size(dq), 13);

  // Pop elements
  regress("deque.ts pop_front 1", deque_pop_front(dq), "zero");
  regress("deque.ts pop_back 1", deque_pop_back(dq), 10);
  regress("deque.ts size after 2 pops", deque_size(dq), 11);

  // Test Sliding Window Maximum O(N) algorithm
  | arr, sw_res |
  arr = ' [ 1 3 -1 -3 5 3 6 7 ];
  sw_res = sliding_window_max(arr, 3);
  regress("sliding_window_max result", sw_res, ' [ 3 3 5 5 6 7 ]);

  // Test BFS Shortest Path O(V + E) algorithm
  | graph, path_len |
  graph = make_table();
  graph["A"] = ' [ "B" "C" ];
  graph["B"] = ' [ "A" "D" ];
  graph["C"] = ' [ "A" "D" "E" ];
  graph["D"] = ' [ "B" "C" "E" ];
  graph["E"] = ' [ "C" "D" ];

  path_len = bfs_shortest_path(graph, "A", "E");
  regress("bfs_shortest_path A -> E", path_len, 2);

  // Test Deque class instance
  | dq_obj |
  dq_obj = Deque["new"]();
  dq_obj[ "pushBack" ](dq_obj, 100);
  dq_obj[ "pushFront" ](dq_obj, 50);
  regress("Deque class size", dq_obj[ "size" ](dq_obj), 2);
  regress("Deque class peekFront", dq_obj[ "peekFront" ](dq_obj), 50);
  regress("Deque class peekBack", dq_obj[ "peekBack" ](dq_obj), 100);
  regress("Deque class popFront", dq_obj[ "popFront" ](dq_obj), 50);
  regress("Deque class size after pop", dq_obj[ "size" ](dq_obj), 1);

  true
];
