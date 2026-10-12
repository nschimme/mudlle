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
  | create_deque, dq |
  create_deque = load_ts("deque.ts");

  dq = create_deque();

  // Test empty state
  regress("deque.ts initial is_empty", dq["is_empty"](), true);
  regress("deque.ts initial size", dq["size"](), 0);
  regress("deque.ts empty peek_front", dq["peek_front"](), null);
  regress("deque.ts empty peek_back", dq["peek_back"](), null);
  regress("deque.ts empty pop_front", dq["pop_front"](), null);
  regress("deque.ts empty pop_back", dq["pop_back"](), null);

  // Push elements
  dq["push_back"]("first");
  dq["push_back"]("second");
  dq["push_front"]("zero"); // Deque order: ["zero", "first", "second"]

  regress("deque.ts size after pushes", dq["size"](), 3);
  regress("deque.ts is_empty after pushes", dq["is_empty"](), false);
  regress("deque.ts peek_front value", dq["peek_front"](), "zero");
  regress("deque.ts peek_back value", dq["peek_back"](), "second");

  // Pop elements
  regress("deque.ts pop_front 1", dq["pop_front"](), "zero");
  regress("deque.ts pop_back 1", dq["pop_back"](), "second");
  regress("deque.ts size after 2 pops", dq["size"](), 1);
  regress("deque.ts peek_front remaining", dq["peek_front"](), "first");
  regress("deque.ts peek_back remaining", dq["peek_back"](), "first");

  regress("deque.ts pop_front last", dq["pop_front"](), "first");
  regress("deque.ts final size", dq["size"](), 0);
  regress("deque.ts final is_empty", dq["is_empty"](), true);

  true
];
