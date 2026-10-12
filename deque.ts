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

// Optimal O(1) Circular Ring Buffer Deque and Algorithms in TypeScript for Mudlle

// Representation: d = [buffer_vector, head_index, count, capacity]

export function deque_new(): vector {
  let cap: number = 8;
  return [make_vector(cap), 0, 0, cap];
};

export function deque_size(d: vector): number {
  return d[2];
};

export function deque_is_empty(d: vector): boolean {
  return d[2] == 0;
};

// Private internal helper function - unexported to prevent global namespace pollution
function deque_resize(d: vector): void {
  let old_buf: vector = d[0];
  let head: number = d[1];
  let count: number = d[2];
  let old_cap: number = d[3];
  let new_cap: number = old_cap * 2;
  let new_buf: vector = make_vector(new_cap);

  for (let i: number = 0; i < count; i = i + 1) {
    let idx: number = (head + i) % old_cap;
    new_buf[i] = old_buf[idx];
  };

  d[0] = new_buf;
  d[1] = 0;
  d[3] = new_cap;
};

export function deque_push_back(d: vector, val: any): void {
  let count: number = d[2];
  let cap: number = d[3];
  if (count == cap) {
    deque_resize(d);
    cap = d[3];
  };
  let buf: vector = d[0];
  let head: number = d[1];
  let idx: number = (head + count) % cap;
  buf[idx] = val;
  d[2] = count + 1;
};

export function deque_push_front(d: vector, val: any): void {
  let count: number = d[2];
  let cap: number = d[3];
  if (count == cap) {
    deque_resize(d);
    cap = d[3];
  };
  let buf: vector = d[0];
  let head: number = d[1];
  let new_head: number = (head - 1 + cap) % cap;
  buf[new_head] = val;
  d[0] = buf;
  d[1] = new_head;
  d[2] = count + 1;
};

export function deque_pop_front(d: vector): any {
  let count: number = d[2];
  if (count == 0) {
    return null;
  };
  let buf: vector = d[0];
  let head: number = d[1];
  let cap: number = d[3];
  let val: any = buf[head];
  buf[head] = null;
  d[1] = (head + 1) % cap;
  d[2] = count - 1;
  return val;
};

export function deque_pop_back(d: vector): any {
  let count: number = d[2];
  if (count == 0) {
    return null;
  };
  let buf: vector = d[0];
  let head: number = d[1];
  let cap: number = d[3];
  let last_idx: number = (head + count - 1) % cap;
  let val: any = buf[last_idx];
  buf[last_idx] = null;
  d[2] = count - 1;
  return val;
};

export function deque_peek_front(d: vector): any {
  let count: number = d[2];
  if (count == 0) {
    return null;
  };
  let buf: vector = d[0];
  let head: number = d[1];
  return buf[head];
};

export function deque_peek_back(d: vector): any {
  let count: number = d[2];
  if (count == 0) {
    return null;
  };
  let buf: vector = d[0];
  let head: number = d[1];
  let cap: number = d[3];
  let last_idx: number = (head + count - 1) % cap;
  return buf[last_idx];
};

// O(N) Sliding Window Maximum using Monotonic Deque
export function sliding_window_max(arr: vector, k: number): vector {
  let n: number = vlength(arr);
  if (n == 0 || k <= 0) {
    return make_vector(0);
  };
  let res_size: number = n - k + 1;
  if (res_size <= 0) {
    return make_vector(0);
  };
  let res: vector = make_vector(res_size);
  let dq: vector = deque_new();

  for (let i: number = 0; i < n; i = i + 1) {
    // Remove indices out of current window
    while (!deque_is_empty(dq) && deque_peek_front(dq) <= i - k) {
      deque_pop_front(dq);
    };

    // Maintain decreasing order in deque
    while (!deque_is_empty(dq) && arr[deque_peek_back(dq)] <= arr[i]) {
      deque_pop_back(dq);
    };

    deque_push_back(dq, i);

    if (i >= k - 1) {
      res[i - k + 1] = arr[deque_peek_front(dq)];
    };
  };

  return res;
};

// O(V + E) Shortest Path BFS using Deque
export function bfs_shortest_path(graph: object, start: string, target: string): number {
  if (string_cmp(start, target) == 0) {
    return 0;
  };

  let dq: vector = deque_new();
  let visited: object = make_table();

  // Enqueue [node, dist]
  deque_push_back(dq, [start, 0]);
  visited[start] = true;

  while (!deque_is_empty(dq)) {
    let item: vector = deque_pop_front(dq);
    let curr: string = item[0];
    let dist: number = item[1];

    if (string_cmp(curr, target) == 0) {
      return dist;
    };

    let neighbors: vector = graph[curr];
    if (neighbors != null) {
      let n_len: number = vlength(neighbors);
      for (let i: number = 0; i < n_len; i = i + 1) {
        let neighbor: string = neighbors[i];
        if (visited[neighbor] == null) {
          visited[neighbor] = true;
          deque_push_back(dq, [neighbor, dist + 1]);
        };
      };
    };
  };

  return -1; // Unreachable
};

export class Deque {
  d: vector;

  constructor() {
    this.d = deque_new();
  }

  size(): number {
    return deque_size(this.d);
  }

  isEmpty(): boolean {
    return deque_is_empty(this.d);
  }

  pushBack(val: any): void {
    deque_push_back(this.d, val);
  }

  pushFront(val: any): void {
    deque_push_front(this.d, val);
  }

  popFront(): any {
    return deque_pop_front(this.d);
  }

  popBack(): any {
    return deque_pop_back(this.d);
  }

  peekFront(): any {
    return deque_peek_front(this.d);
  }

  peekBack(): any {
    return deque_peek_back(this.d);
  }
}
