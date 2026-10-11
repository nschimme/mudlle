/*
 * Copyright (c) 2026 Nils Schimmelmann
 * All rights reserved.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose, without fee, and without written agreement is hereby granted,
 * provided that the above copyright notice and the following two paragraphs
 * appear in all copies of this software.
 *
 * IN NO EVENT SHALL NILS SCHIMMELMANN BE LIABLE TO ANY PARTY FOR DIRECT, INDIRECT,
 * SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OF
 * THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF NILS SCHIMMELMANN HAS BEEN ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 *
 * NILS SCHIMMELMANN SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS" BASIS, AND NILS
 * SCHIMMELMANN HAS NO OBLIGATION TO PROVIDE MAINTENANCE, SUPPORT, UPDATES,
 * ENHANCEMENTS, OR MODIFICATIONS.
 */

/*
 * Compare compiled loop execution after compiling and linking once.
 * Load xc.mud first so mc:compile selects the active backend.
 */
[
  | source, tree, prelinked, linked, kernel, runs, work, start, elapsed, i |
  source = "fn (n) [ | sum, i | sum = 0; i = 0; while (i < n) [ sum = iadd(sum, i); i = iadd(i, 1); ]; sum ]";
  tree = mudlle_parse(source, "benchmark-kernel.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  if (!vector?(prelinked)) error(error_bad_value);
  linked = mc:linkrun(prelinked, 1, true);
  if (!pair?(linked)) error(error_bad_value);
  kernel = car(linked);

  work = 50000;
  runs = 2000;
  if (kernel(work) != (work * (work - 1) / 2))
    error(error_bad_value);

  start = ctime();
  i = 0;
  while (i < runs) [ kernel(work); i = i + 1; ];
  elapsed = ctime() - start;
  display(format("backend=%s workload=loop-sum work=%d runs=%d cpu_ms=%d\n",
                 mc:archname, work, runs, elapsed));
];
