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

library mp
requires ax64, genx64, mx64
defines mp:nscratch, mp:ncaller, mp:ncallee, mp:nregargs, mp:new_label,
  mp:ins_list, mp:assemble, mp:mgen_preamble, mp:mgen_instruction,
  mp:select_registers, mp:migrate, mp:uses_regclass, mp:reset_counters
[
  mp:nscratch = x64:nscratch;
  mp:ncaller = x64:ncaller;
  mp:ncallee = x64:ncallee;
  mp:nregargs = x64:nregargs;

  mp:new_label = x64:new_label;
  mp:ins_list = x64:ins_list;
  mp:assemble = x64:gassemble;
  mp:mgen_preamble = x64:mgen_preamble;
  mp:mgen_instruction = x64:mgen_instruction;
  mp:select_registers = x64:select_registers;
  mp:migrate = x64:migrate;
  mp:uses_regclass = x64:uses_regclass;

  mp:reset_counters = fn ()
    [
      x64:reset_counters();
      x64:reset_ins_count();
    ];
];
