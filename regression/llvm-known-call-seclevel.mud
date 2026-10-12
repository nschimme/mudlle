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
// Known calls do not touch the security-level state; the level a primitive
// sees must still be that of the module that makes the call.

[
  | compile, src, run, level, r |
  compile = fn (source, name, level) [ | tree, prelinked, linked |
    tree = mudlle_parse(source, name, false);
    prelinked = mc:compile(tree, false, level, mc:source_code(source));
    assert(vector?(prelinked));
    linked = mc:linkrun(prelinked, level, true);
    assert(pair?(linked));
    car(linked)
  ];

  src = """fn () [ | f, g, h, before, inner, after |
  f = fn () seclevel();
  g = fn (x) [ | a | a = f(); a . seclevel() ];
  h = fn (n) if (n == 0) f() else h(n - 1);
  before = seclevel();
  inner = g(1);
  after = seclevel();
  list(before, car(inner), cdr(inner), after, h(5)) ]""";

  level = 1;
  while (level <= 1)
    [
      run = compile(src, format("known-seclevel-%d.mud", level), level);
      r = run();
      assert(equal?(r, list(level, level, level, level, level)));
      level = level + 1;
    ];

  display("KNOWN_CALL_SECLEVEL_OK\n");
];
