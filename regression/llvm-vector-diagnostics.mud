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

// Compare this output against the baseline with xc.mud loaded first.
[
  | source, compile, length, ref |
  compile = fn (source, name) [ | tree |
    tree = mudlle_parse(source, name, false);
    car(mc:linkrun(mc:compile(tree, false, 1, mc:source_code(source)), 1, true))
  ];
  length = compile("fn (v) vlength(v)", "vector-diagnostic-length.mud");
  ref = compile("fn (v,i) v[i]", "vector-diagnostic-ref.mud");
  trap_error(fn () length(null), null, call_trace_off, null);
  trap_error(fn () length(7), null, call_trace_off, null);
  trap_error(fn () length(cons(1, null)), null, call_trace_off, null);
  trap_error(fn () length("abc"), null, call_trace_off, null);
  trap_error(fn () ref(null, 0), null, call_trace_off, null);
  trap_error(fn () ref(vector(1), 2), null, call_trace_off, null);
  trap_error(fn () ref(vector(1), "bad"), null, call_trace_off, null);
  source = "fn (n) [ | before, i, v | before = loop_count(); i = 0; while (i < n) [ v = vector(i, i + 1); i = i + 1; ]; vector(before - loop_count(), v[0], v[1]) ]";
  ref = compile(source, "vector-loop-accounting.mud");
  display(format("LOOP_ACCOUNTING=%w\n", ref(100)));
  display("VECTOR_DIAGNOSTICS_OK\n");
];
