/*
 * Copyright (c) 1993-2012 David Gay
 * All rights reserved.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose, without fee, and without written agreement is hereby granted,
 * provided that the above copyright notice and the following two paragraphs
 * appear in all copies of this software.
 *
 * IN NO EVENT SHALL DAVID GAY BE LIABLE TO ANY PARTY FOR DIRECT, INDIRECT,
 * SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OF
 * THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF DAVID GAY HAVE BEEN ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 *
 * DAVID GAY SPECIFICALLY DISCLAIM ANY WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS" BASIS, AND DAVID
 * GAY HAVE NO OBLIGATION TO PROVIDE MAINTENANCE, SUPPORT, UPDATES,
 * ENHANCEMENTS, OR MODIFICATIONS.
 */

| srcdir |
if (INTBITS != 63) error(error_bad_value);
srcdir = dirname(loading_file()) + "/";

// Load interpreted compiler
garbage_collect(700000);
load(srcdir + "lib.mud") &&
load(srcdir + "noinf.mud");
if (string_equal?(mc:archname, "x64"))
  [ load(srcdir + "x64.mud") && load(srcdir + "compile.mud") ]
else
  [ load(srcdir + "llvm.mud") && load(srcdir + "llvmcompile.mud") ];

load(srcdir + "interface.mud") &&
protect_compiler_libs();
mc:verbose = 0;
