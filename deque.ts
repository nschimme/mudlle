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

// Double-ended queue (Deque) library in TypeScript for Mudlle

interface Deque {
  push_front: (val: any) => void;
  push_back: (val: any) => void;
  pop_front: () => any;
  pop_back: () => any;
  peek_front: () => any;
  peek_back: () => any;
  size: () => number;
  is_empty: () => boolean;
};

function create_deque(): Deque {
  let items: vector = make_vector(0);
  let count: number = 0;

  let push_back = (val: any): void => {
    let new_items: vector = make_vector(count + 1);
    for (let i: number = 0; i < count; i = i + 1) {
      new_items[i] = items[i];
    };
    new_items[count] = val;
    items = new_items;
    count = count + 1;
  };

  let push_front = (val: any): void => {
    let new_items: vector = make_vector(count + 1);
    new_items[0] = val;
    for (let i: number = 0; i < count; i = i + 1) {
      new_items[i + 1] = items[i];
    };
    items = new_items;
    count = count + 1;
  };

  let pop_back = (): any => {
    if (count == 0) {
      return null;
    };
    let val: any = items[count - 1];
    count = count - 1;
    let new_items: vector = make_vector(count);
    for (let i: number = 0; i < count; i = i + 1) {
      new_items[i] = items[i];
    };
    items = new_items;
    return val;
  };

  let pop_front = (): any => {
    if (count == 0) {
      return null;
    };
    let val: any = items[0];
    count = count - 1;
    let new_items: vector = make_vector(count);
    for (let i: number = 0; i < count; i = i + 1) {
      new_items[i] = items[i + 1];
    };
    items = new_items;
    return val;
  };

  let peek_front = (): any => {
    if (count == 0) {
      return null;
    };
    return items[0];
  };

  let peek_back = (): any => {
    if (count == 0) {
      return null;
    };
    return items[count - 1];
  };

  let get_size = (): number => count;
  let is_empty = (): boolean => count == 0;

  return {
    push_front: push_front,
    push_back: push_back,
    pop_front: pop_front,
    pop_back: pop_back,
    peek_front: peek_front,
    peek_back: peek_back,
    size: get_size,
    is_empty: is_empty
  };
};

// Return factory function for Mudlle export
create_deque;
