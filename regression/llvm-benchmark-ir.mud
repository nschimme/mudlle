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

/* Write the compiled integer-loop benchmark's pre-optimization LLVM IR to
   /tmp for inspection with LLVM's optional `opt` utility. */
[
  | source, tree, ir, w |
  source = "fn (n) [ | sum, i | sum = 0; i = 0; while (i < n) [ sum = iadd(sum, i); i = iadd(i, 1); ]; sum ]";
  tree = mudlle_parse(source, "benchmark-kernel.mud", false);
  ir = mc:compile_llvm(tree, 1, mc:source_code(source));
  if (!string?(ir)) error(error_bad_value);
  w = writer:new_file("/tmp/mudlle-benchmark.ll");
  writer:write(w, ir);
  writer:close(w);
];
