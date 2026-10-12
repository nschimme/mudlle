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

// Load compiled compiler
// Bootstrap via interpreter (load minimum for linker)
garbage_collect(700000);

if (!string?(objdir)) objdir = "./";

load(srcdir + "lib.mud") &&
load(srcdir + "link.mud") &&
load(srcdir + "interface.mud") &&

[
  load_library = fn (s)
    [
      silent == true || dformat("loading %s\n", s);
      fload(objdir + s + ".obj");
    ];
] &&

// reload compiled modules
fload(objdir + "dlist.obj") &&
fload(objdir + "sequences.obj") &&
fload(objdir + "misc.obj") &&
fload(objdir + "vars.obj") &&
fload(objdir + "compiler.obj") &&
fload(objdir + "link.obj") &&

fload(objdir + "noinf.obj") &&
fload(objdir + mc:archname + ".obj") &&
fload(objdir + (if (string_equal?(mc:archname, "llvm"))
                   "llvmcompile" else "compile") + ".obj");
mc:verbose = 0;
