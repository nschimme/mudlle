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

library mllvm
requires compiler, dlist, misc, vars
defines llvm:ins_list, llvm:print_ins, llvm:new_code, llvm:vcode_ilpos,
  llvm:select_registers, llvm:migrate, llvm:uses_regclass, llvm:new_label
[
  llvm:vcode_ilpos = 0;
  llvm:new_code = fn () vector(null);
  llvm:ins_list = fn (code, {vector,null} w = null) null;
  llvm:print_ins = fn (ins, {vector,null} w = null) null;
  llvm:new_label = fn (code) null;
  llvm:select_registers = fn (ifn, ainfo) ainfo;
  llvm:migrate = fn (ifn, vars, notspilt, spilt, locals, temps) null;
  llvm:uses_regclass = fn (ins) mc:regclass_none;
];
