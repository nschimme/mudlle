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

// Manual stress script (not part of all.mud, since it prints an expected
// error trace). Run: ./mudlle -e xc.mud -e regression/stress/known-call-trace.mud
// Expect the trace to show f(a="helloxyz", b='[0 [1 2 3] "heap"]) and
// outer(s="hello", v='[1 2 3]) with intact arguments, then STRESS_DONE.
// A known callee allocates enough to collect while its frame is live.
// Do not wrap the body in reval("""..."""): that fails before running.

[
  | outer |
  outer = fn (s, v) [
    | f, i |
    f = fn (a, b) [ | l, n | l = null; n = 0;
      while (n < 20000) [ l = n . l; n = iadd(n, 1) ];
      error(error_bad_value) ];
    i = 0;
    while (i < 3) [ f(s + "xyz", vector(i, v, "heap")); i = i + 1 ];
  ];
  trap_error(fn () outer("hello", vector(1, 2, 3)), fn (n) n, call_trace_on, null);
  garbage_collect(0);
];
display("STRESS_DONE\n");
