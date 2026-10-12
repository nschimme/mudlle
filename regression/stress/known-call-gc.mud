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

// Manual stress script. Run: ./mudlle -e xc.mud -e regression/stress/known-call-gc.mud
// Expect SUM=6003 then STRESS_DONE: a known callee is called three times from
// a loop with a full collection between calls, so cached closures and the
// call frame's arguments must survive GC movement.

[
  | outer, r |
  outer = fn (n) [
    | f, i, sum, junk |
    f = fn (a) [ | l, k | l = null; k = 0;
      while (k < 2000) [ l = k . l; k = iadd(k, 1) ];
      a + llength(l) ];
    i = 0; sum = 0;
    while (i < 3) [
      sum = sum + f(i);
      junk = make_vector(5000);
      garbage_collect(0);
      i = i + 1 ];
    sum
  ];
  r = outer(3);
  display(format("SUM=%d\n", r));
  if (r != 6003) display("BAD_SUM\n");
];
display("STRESS_DONE\n");
