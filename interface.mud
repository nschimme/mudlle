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

eval = fn (s)
  [
    | prelinked, tree |
    tree = mudlle_parse(s, null, false);
    if (!tree)
      false
    else if (prelinked = mc:compile(tree, false, 1, mc:source_code(s)))
      mc:linkrun(prelinked, 1, true)
    else
      false
  ];

lcompile = fn (s, protect)
  [
    | objname, dot |

    objname = basename(s);
    dot = string_index(objname, ?.);
    if (dot >= 0)
      objname = substring(objname, 0, dot);
    objname += ".obj";
    if (string?(dstdir))
      objname = dstdir + objname;

    silent == true || dformat("compiling %s\n", s);
    | cs, tree, prelinked |
    prelinked = false;
    cs = "compiler/" + basename(s);
    tree = mudlle_parse_file(s, cs, cs, false);
    if (!tree)
      null
    else if (tree == true)
      dformat("%s does not contain code\n", s)
    else if (prelinked = mc:compile(tree, protect, 1, mc:source_file(s)))
      save_data(objname, prelinked);
    !!prelinked
  ];

fcompile = fn (s) lcompile(s, false);
pcompile = fn (s) lcompile(s, true);
fload = fn (s) mc:linkrun(load_data(s), 1, true);
test = fn (s) mc:compile(mudlle_parse(s, null, false),
                         false, 1, mc:source_code(s));
ftest = fn (s) mc:compile(mudlle_parse_file(s, s, s, false),
                          false, 1, mc:source_file(s));

protect_compiler_libs = fn ()
[
  vforeach(fn (name) [
    match! (module_status(name))
      [
        ,module_loaded    => module_set!(name, module_protected, 1);
        ,module_protected => null;
        ,module_unloaded  => null;
      ]
  ], all_modules());

  detect_immutability();
];
