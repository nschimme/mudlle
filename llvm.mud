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
 * THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF NILS SCHIMMELMANN HAVE BEEN ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 *
 * NILS SCHIMMELMANN SPECIFICALLY DISCLAIM ANY WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS" BASIS, AND NILS
 * SCHIMMELMANN HAVE NO OBLIGATION TO PROVIDE MAINTENANCE, SUPPORT, UPDATES,
 * ENHANCEMENTS, OR MODIFICATIONS.
 */

library mp
requires allvm, genllvm, ins3, mllvm
defines mp:nscratch, mp:ncaller, mp:ncallee, mp:nregargs, mp:new_label,
  mp:ins_list, mp:assemble, mp:mgen_preamble, mp:mgen_instruction,
  mp:select_registers, mp:migrate, mp:uses_regclass, mp:reset_counters
[
  mp:nscratch = 0;
  mp:ncaller = 0;
  mp:ncallee = 0;
  mp:nregargs = 0;

  mp:new_label = fn (code) null;
  mp:ins_list = llvm:ins_list;
  mp:assemble = llvm:assemble;
  mp:mgen_preamble = fn (ifn, ainfo) null;
  mp:mgen_instruction = fn (code, ifn, ainfo, il) null;
  mp:select_registers = fn (ifn, ainfo) ainfo;
  mp:migrate = fn () null;
  mp:uses_regclass = fn (var, regclass) false;

  mp:reset_counters = fn ()
    [
      llvm:reset_counters();
      mc:reset_ins_count();
    ];
];
