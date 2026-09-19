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

library ax64 // The x64 assembler
requires mx64, dlist, sequences, misc, compiler, vars
defines x64:assemble, x64:reset_counters, x64:ltype_may_indirect
reads mc:verbose, mc:disassemble
writes mc:nins, mc:nbytes, mc:jccjmp_count, mc:labeled_jmp
[
  | remove_aliases, resize_branches, increase_branches,
    assemble, ins_size, iops, ins_gen,
    int7?, int8?, uint8?, int31?, int32?, uint32?, immediate8?,
    immval8, immval32,
    immediate_low32, immediate_high32,
    register?, regval,
    peephole,
    rex_op, rex_w, rex_b, rex_x, rex_r, reg8_rex, reg_hi, rax?,
    imm_jmp8, imm_jmp32,
    word_size |

  word_size = 8;

  rex_op = 0x40;
  rex_w  = 8;                   // 64-bit operand; access all byte registers
  rex_r  = 4;                   // ModR/M reg field
  rex_x  = 2;                   // SIB index
  rex_b  = 1;                   // ModR/M r/m, SIB base, or Opcode reg field

  reg_hi = 8;                   // high bit of register number

  mc:jccjmp_count = mc:labeled_jmp = 0;

  // rex prefix needed to access byte registers except for %[abcd]l
  reg8_rex = fn (arg)
    match (arg)
      [
        (,x64:lreg . r) && r >= 4 => rex_op;
        _ => 0;
      ];

  // special cases
  imm_jmp8   = "jmp8";
  imm_jmp32  = "jmp32";

  rax? = fn (arg)
    match (arg)
      [
        (,x64:lreg . ,x64:reg_rax) => true
      ];

  int7? = fn (int n) n >= -64 && n <= 63;
  int8? = fn (int n) n >= -128 && n <= 127;
  uint8? = fn (int n) (n & ~0xff) == 0;

  int31? = fn (int n) n >= -0x40000000 && n <= 0x3fffffff;
  int32? = fn (int n) n >= -0x80000000 && n <= 0x7fffffff;
  uint32? = fn (int n) (n & ~0xffffffff) == 0;

  x64:reset_counters = fn ()
    [
      mc:nins = mc:nbytes = 0;
    ];

  x64:reset_counters();

  | simple_equal?, high_int_equal? |
  simple_equal? = fn (a, b) a == b;

  // only accept numbers whose immediate_high32() is non-zero; the
  // others can be loaded using 32-bit mov
  high_int_equal? = fn (a, b)
    [
      | fromint |
      fromint = fn (n) (n >> 1) . (n & 1);
      if (integer?(a))
        a = fromint(a);
      if (integer?(b))
        b = fromint(b);
      (car(a) == car(b) && cdr(a) == cdr(b)
       && ((car(a) >> 31) & 0xffffffff) != 0)
    ];

  // indices into x64:ltype_info entries
  | ltype_info, lti_size, lti_aidx, lti_eq? |
  lti_size = 0;               // size in bytes of operand
  lti_aidx = 1;               // mc:a_xxx list where operand is stored
  lti_eq?  = 2;               // equality check for operands

  ltype_info = indexed_sequence(
    x64:limm             . '[4 ()                 ()],
    x64:lcst             . '[8 ,mc:a_constants    ,simple_equal?],
    x64:lfunction        . '[8 ()                 ()],
    x64:lcalled          . '[8 ()                 ()],
    x64:lcalled_global   . '[8 ,mc:a_kglobal_code ,string_iequal?],
    x64:lprimitive       . '[8 ,mc:a_primitives   ,string_iequal?],
    x64:lclosure         . '[8 ()                 ()],
    x64:lglobal          . '[4 ,mc:a_globals      ()],
    x64:lglobal_constant . '[8 ,mc:a_kglobals     ,simple_equal?],
    x64:lglobal_index    . '[4 ,mc:a_globals      ()],
    x64:lseclev          . '[4 ,mc:a_seclevs      ()],
    x64:lindirect        . '[4 ()                 ()],
    x64:limm64           . '[8 ()                 ,high_int_equal?],
    x64:lbuiltin         . '[8 ,mc:a_builtins     ,string_equal?],
    x64:lprimop          . '[8 ,mc:a_primops      ,string_iequal?],
    x64:lnone . null);

  // true if 'ltype' (x64:lxxx) may be converted to a move to %r11 and
  // then a register access
  x64:ltype_may_indirect = fn (int ltype)
    [
      | linfo |
      linfo = ltype_info[ltype];
      linfo != null && linfo[lti_eq?] != null
    ];

  | make_ilpos_indirect, make_ilpos_direct |
  make_ilpos_indirect = fn (ilpos)
    [
      | il, ins, op |
      il = dget(ilpos);
      ins = il[x64:il_ins];
      op = ins[x64:i_op];

      if (op == x64:op_mov)
        assert(car(ins[x64:i_arg2]) == x64:lreg);
      | arg1 |
      arg1 = ins[x64:i_arg1];
      assert(car(arg1) != x64:lindirect);
      ins[x64:i_arg1] = x64:lindirect . arg1;
    ];

  make_ilpos_direct = fn (fcode, ilpos)
    [
      | il, ins |
      il = dget(ilpos);
      ins = il[x64:il_ins];

      // insert mov <arg>,%r11 before this instruction and change our
      // argument to be %r11
      | treg, old_insert, old_loc |
      old_insert = x64:get_instructions(fcode);
      old_loc = mc:get_loc();

      mc:set_loc(il[x64:il_loc]);
      x64:set_instruction(fcode, dnext(ilpos));

      x64:copy_instruction(fcode, il);
      treg = x64:lreg . x64:reg_r11;
      il[x64:il_ins] = vector(x64:op_mov, ins[x64:i_arg1], treg);
      ins[x64:i_arg1] = treg;

      x64:set_instruction(fcode, old_insert);
      mc:set_loc(old_loc);
    ];

  | finish_indirect |
  finish_indirect = fn (fcode)
    [
      | idata, ilist, ilpos |
      idata = make_vector(x64:lbuiltin + 1);
      ilist = x64:get_instructions(fcode);
      ilpos = ilist;
      loop
        [
          | il, ins, arg1, ltype, linfo, eq?, op |
          il = dget(ilpos);
          ins = il[x64:il_ins];
          arg1 = ins[x64:i_arg1];
          op = ins[x64:i_op];

          <done> [
            | no_arg1_ops |
            no_arg1_ops = sequence(
              x64:op_jmp, x64:op_jcc, x64:op_jmp32, x64:op_jcc32);
            if (arg1 == null || vfind?(op, no_arg1_ops))
              exit<done> null;

            ltype = car(arg1);
            linfo = ltype_info[ltype];
            if (linfo == null) exit<done> null;
            eq? = linfo[lti_eq?];
            if (eq? == null) exit<done> null;

            | entry, aval, mov? |
            aval = cdr(arg1);
            entry = lexists?(fn (@[v ...]) eq?(v, aval), idata[ltype]);
            mov? = ins[x64:i_op] == x64:op_mov;
            if (!entry)
              idata[ltype] = vector(
                aval, if (mov?) ilpos else null,
                if (mov?) null else list(ilpos)) . idata[ltype]
            else if (entry[1] == null && mov?)
              entry[1] = ilpos
            else
              entry[2] = ilpos . entry[2];
          ];

          ilpos = dnext(ilpos);
          if (ilpos == ilist) exit null;
        ];

      vforeach(fn (entries) [
        lforeach(fn (@[_ mov seen]) [
          if (mov == null)
            [
              @(mov . seen) = lreverse!(seen);
              make_ilpos_direct(fcode, mov);
            ];
          lforeach(make_ilpos_indirect, seen)
        ], entries)
      ], idata);
    ];

  x64:assemble = fn "x64code -> x64asm" (fcode)
    [
      | ilist |

      ilist = x64:get_instructions(fcode);
      remove_aliases(ilist);
      if (mc:verbose >= 5)
	[
	  x64:ins_list(fcode);
	  newline();
	];

      ilist = peephole(ilist);
      finish_indirect(fcode);

      if (mc:verbose >= 4 || mc:disassemble)
	[
	  x64:ins_list(fcode);
	  newline();
	];
      mc:nins += dlength(ilist);

      dreduce(fn (il, ofs) [
        | ins, op, arg1, arg2, ops, size |
        ins = il[x64:il_ins];
        op = ins[x64:i_op];
        arg1 = ins[x64:i_arg1];
        arg2 = ins[x64:i_arg2];
        ops = iops[op](arg1, arg2);
        size = ins_size(ops);
        il[x64:il_offset] = vector(ofs, size, ops);
        ofs + size
      ], 0, ilist);

      resize_branches(ilist);

      assemble(ilist)
    ];

  remove_aliases = fn (ilist)
    // Types: ilist: list of x64 instructions
    // Effects: Removes aliased labels from ilist
    dforeach(fn (il) [
      | ins |
      ins = il[x64:il_ins];

      if (ins[x64:i_op] == x64:op_jmp || ins[x64:i_op] == x64:op_jcc)
        ins[x64:i_arg1] = x64:skip_label_alias(ins[x64:i_arg1]);
    ], ilist);

  | cmovcc_src? |
  // safe as cmovcc source: reg or memory that must not trigger segv
  cmovcc_src? = fn (arg)
    match (arg)
      [
        ((,x64:lreg || ,x64:lindirect) . _) => true;
        (,x64:lidx . ((,x64:reg_rsp || ,x64:reg_rbp) . _)) => true;
      ];

  | cc_unops, cc_binops, no_cc_ops |
  // these operations set condition codes (ZF, PF, SF at least)
  cc_unops = '[,x64:op_dec ,x64:op_inc ,x64:op_neg];
  cc_binops = '[,x64:op_add ,x64:op_and ,x64:op_or ,x64:op_sub ,x64:op_xor];
  // these don't change conditions codes (but write to a destination)
  no_cc_ops = '[,x64:op_mov ,x64:op_lea];

  | same_reg? |
  same_reg? = fn (@(ca . va), @(cb . vb))
    ca == x64:lreg && cb == x64:lreg && va == vb;

  peephole = fn (ilist)
    // Types: ilist: list of x64 instructions
    // Requires: ilist != null, no aliased labels
    // Returns: list of x64 instructions
    // Effects: Performs peephole optimisation - replaces
    //   jcc x/jmp y/x: with jncc y/x
    //   jcc 0f; mov x,%reg; 0: with cmovcc x,%reg
    [

      | iscan, jcc, jmp, noreturn, aliased_label |

      aliased_label = false;
      iscan = ilist;
      loop
	[
	  | il, ins, op, ilabel |
	  il = dget(iscan);
	  ins = il[x64:il_ins];
          op = ins[x64:i_op];
          ilabel = il[x64:il_label];

	  if (op == x64:op_jmp && ilabel)
	    [
	      if (mc:verbose >= 3)
		[
		  display("PEEPHOLE labeled jmp: ");
		  x64:print_ins(ins);
		  newline();
		];
	      // make label alias jump destination
              | label |
	      label = x64:skip_label_alias(ins[x64:i_arg1]);
	      x64:set_label(ilabel, label[x64:l_ins]);
	      il[x64:il_label] = ilabel = false;
	      aliased_label = true; // will need to remove aliases
	      ++mc:labeled_jmp;
	    ];

          if (op == x64:op_test
              && !ilabel && jmp == null && jcc == null && noreturn == null
              && same_reg?(ins[x64:i_arg1], ins[x64:i_arg2]))
            <skip> [
              // this is 'test %reg,%reg'; remove if the previous instruction
              // was an arithmetic instruction with %reg as destination, and
              // the following instruction is a suitable jcc or cmovcc
              | previ, previl, previns, prevop, reg |
              reg = ins[x64:i_arg1];
              previ = iscan;
              loop
                [
                  previ = dprev(previ);
                  previl = dget(previ);
                  previns = previl[x64:il_ins];
                  prevop = previns[x64:i_op];
                  if (!vfind?(prevop, no_cc_ops))
                    exit null;
                  if (previl[x64:il_label])
                    exit<skip> null;
                  if (same_reg?(reg, previns[x64:i_arg2]))
                    exit<skip> null;
                ];

              if (((vfind?(prevop, cc_binops)
                    // special case below
                    || (prevop == x64:op_orbyte
                        && car(previns[x64:i_arg1]) == x64:limm))
                   && same_reg?(reg, previns[x64:i_arg2]))
                  || (vfind?(prevop, cc_unops)
                      && same_reg?(reg, previns[x64:i_arg1])))
                <skip> [
                  | nextins, nextop, cop |
                  nextins = dget(dnext(iscan))[x64:il_ins];
                  nextop = nextins[x64:i_op];
                  if (nextop == x64:op_jcc)
                    cop = nextins[x64:i_arg2]
                  else if (nextop == x64:op_cmovcc)
                    @(,x64:lidx . (_ . cop)) = nextins[x64:i_arg2];

                  if (cop == null
                      || !vfind?(cop, '[ ,x64:be ,x64:bne ,x64:bs ,x64:bns ]))
                    [
                      // unsupported trailing instruction; branch ops cannot
                      // use OF/CF which are cleared by 'test'
                      if (mc:verbose > 0)
                        [
                          display("UNEXPECTED next instruction after ");
                          x64:print_ins(ins);
                          display(" : ");
                          x64:print_ins(nextins);
                          newline();
                        ];
                      exit<skip> null;
                    ];

                  if (prevop == x64:op_orbyte)
                    [
                      // upgrade 'or8 <imm>,%reg' to 'or <imm>,%reg'
                      previns[x64:i_op] = x64:op_or;
                      previns[x64:i_arg1] =
                        x64:limm . immval8(previns[x64:i_arg1]);
                    ];

                  // remove this unnecessary test instruction
                  dremove!(iscan, ilist);
                  iscan = previ;
                ];
            ]
          else if (!ilabel && (jmp != null || noreturn != null))
            [
              dremove!(iscan, ilist);
              iscan = if (noreturn != null) noreturn else jmp;
              if (mc:verbose >= 3)
                [
                  display("UNREACHABLE after ");
                  x64:print_ins(dget(iscan)[x64:il_ins]);
                  display(" : ");
                  x64:print_ins(ins);
                  newline();
                ];
            ]
          else if (jmp != null && ilabel == dget(jmp)[x64:il_ins][x64:i_arg1])
            [
              if (mc:verbose >= 3)
                [
                  display("USELESS jmp: ");
                  x64:print_ins(dget(jmp)[x64:il_ins]);
                  newline();
                ];
              dremove!(jmp, ilist);
              jmp = null
            ]
          else if (jcc == null) // nojcc state
	    [
              if (op == x64:op_jmp)
                jmp = iscan
              else
                [
                  jmp = null;
                  if (op == x64:op_jcc)
                    jcc = ins; // to jcc state
		]
	    ]
	  else if (jmp == null) // jcc state
	    [
	      // jmp must be unlabeled, but mc:labeled_jmp optimisation
	      // deals with that.
	      if (op == x64:op_jmp)
		jmp = iscan     // to jcc/jmp state
	      else if (op == x64:op_mov
                       && !ilabel
                       && car(ins[x64:i_arg2]) == x64:lreg
                       && dget(dnext(iscan))[x64:il_label] == jcc[x64:i_arg1]
                       && cmovcc_src?(ins[x64:i_arg1]))
                [
                  // jcc 0f; mov reg/mem,%reg; 0:
                  if (mc:verbose >= 3)
                    [
                      display("REPLACE jcc over mov with cmovcc: ");
                      x64:print_ins(jcc);
                      display("; ");
                      x64:print_ins(ins);
                    ];

                  [
                    | previ |
                    previ = dprev(iscan);
                    dremove!(iscan, ilist);
                    iscan = previ;
                  ];

                  | cc |
                  cc = jcc[x64:i_arg2] ^ 1; // inverse cc
                  jcc[x64:i_op] = x64:op_cmovcc;
                  jcc[x64:i_arg1] = ins[x64:i_arg1];
                  jcc[x64:i_arg2] = x64:lidx . (cdr(ins[x64:i_arg2]) . cc);

                  if (mc:verbose >= 3)
                    [
                      display(" -> ");
                      x64:print_ins(jcc);
                      newline();
                    ];

                  jcc = null;
                ]
              else
		jcc = null; // back to nojcc
	    ]
	  else // jcc/jmp state
	    [
	      if (ilabel == jcc[x64:i_arg1]) // peephole time!
		[
		  ++mc:jccjmp_count;
		  if (mc:verbose >= 3)
		    [
		      display("PEEPHOLE jcc over jmp: ");
		      x64:print_ins(jcc);
		      newline();
		    ];
		  jcc[x64:i_arg1] = dget(jmp)[x64:il_ins][x64:i_arg1];
		  jcc[x64:i_arg2] ^= 1; // reverse sense.
		  // remove jmp
		  dremove!(jmp, ilist);
		];

              jmp = jcc = null; // back to nojcc
	    ];

          noreturn = null;
          if (op == x64:op_ret
              || (op == x64:op_call && ins[x64:i_arg2]))
            noreturn = iscan;

	  iscan = dnext(iscan);
	  if (iscan == ilist) exit 0;
	];

      if (aliased_label)
	remove_aliases(ilist);
      ilist
    ];

  increase_branches = fn (ilist)
    dreduce(fn (il, delta) [
      | ins, op |

      ins = il[x64:il_ins];
      op = ins[x64:i_op];
      if (delta)
        il[x64:il_offset][0] += delta;
      if (op == x64:op_jmp || op == x64:op_jcc)
        [
          | ofsv, ofs, size, dofs, dest |
          @[ofs size ...] = ofsv = il[x64:il_offset];
          dest = ins[x64:i_arg1];
          dofs = (dest[x64:l_ins][x64:il_offset][0]
                  - (ofs + size));
          if (!int8?(dofs))
            [
              ins[x64:i_op] = op = if (op == x64:op_jmp)
                x64:op_jmp32
              else
                x64:op_jcc32;
              | nops, nsize |
              ofsv[2] = nops = iops[op](dest, ins[x64:i_arg2]);
              ofsv[1] = nsize = ins_size(nops);
              delta += nsize - size
            ]
        ];
      delta
    ], 0, ilist);

  resize_branches = fn (ilist)
    while (increase_branches(ilist))
      null;

  | insert_int |
  insert_int = fn (code, offset, nbytes, val)
    while (nbytes > 0)
      [
        code[offset++] = val;
        val >>= 8;
        --nbytes;
      ];

  | pri_used, pri_ofs, pri_absv, pri_indv |
  // data for PC-relatative (%rip-relative) addressing
  pri_used = 0;                 // number of slots used
  pri_ofs  = 1;                 // code offset of the first slot
  pri_absv = 2;                 // vector of offsets for immediate uses
  pri_indv = 3;                 // vector of offsets for %rip-relative uses

  | patch_indirects |
  patch_indirects = fn (code, info, pcrel_info)
    [
      vforeachi(fn (ltype, l) [
        if (l == null) exit<function> null;

        | linfo, eq?, absv |
        linfo = ltype_info[ltype];
        eq? = linfo[lti_eq?];
        assert(eq? != null);
        absv = pcrel_info[pri_absv][ltype];

        lforeach(fn (@(x . offset)) [
          | absofs |
          absofs = cdr(lexists?(fn (@(v . _)) eq?(x, v), absv));
          insert_int(code, offset, 4, absofs - (offset + 4))
        ], l);
      ], pcrel_info[pri_indv]);
    ];

  assemble = fn (ilist)
    [
      | last, code, info |
      last = dget(dprev(ilist));

      | code_end, reloc_start, lofs, lsize |
      @[lofs lsize ...] = last[x64:il_offset];
      code_end = lofs + lsize;

      reloc_start = (code_end + word_size - 1) & -word_size;

      mc:nbytes += code_end;
      code = make_string(code_end);

      info = make_vector(mc:a_info_fields);

      | pcrel_info |
      pcrel_info = indexed_vector(
        pri_used . 0,
        pri_ofs  . reloc_start,
        pri_absv . make_vector(x64:lnone),
        pri_indv . make_vector(x64:lnone));

      | last_line, linenos |

      dforeach(fn (il) [
        | ofs, size, ops, line |
        @[ofs size ops] = il[x64:il_offset];
        line = mc:loc_line(il[x64:il_loc]);
        if (line > 0 && line != last_line)
          [
            linenos = (ofs . line) . linenos;
            last_line = line;
          ];
        ins_gen(code, il, ops, ofs, size, info, pcrel_info);
      ], ilist);
      linenos = (code_end . last_line) . linenos;
      dforeach(fn (il) il[x64:il_offset] = il[x64:il_offset][0], ilist);

      patch_indirects(code, info, pcrel_info);

      info[mc:a_linenos] = vreverse!(list_to_vector(linenos));
      info[mc:a_npcrel] = pcrel_info[pri_used];

      code . info
    ];

  immval8 = fn (arg)
    match! (cdr(arg))
      [
        {int} i => [
          assert(int8?(i));
          i
        ];
        ({int} i . e) => [
          assert(int7?(i));
          i * 2 + e
        ];
      ];

  immval32 = fn (arg)
    match! (cdr(arg))
      [
        {int} i => [
          assert(int32?(i));
          i
        ];
        ({int} i . e) => [
          assert(int31?(i));
          i * 2 + e
        ];
      ];

  immediate_low32 = fn (arg)
    (match! (cdr(arg))
     [
       {int} i => i;
       ({int} i . e) => (i * 2) + e
     ]) & 0xffffffff;

  immediate_high32 = fn (arg)
    (match! (cdr(arg))
     [
       {int} i => i >> 32;
       ({int} i . _) => i >> 31;
     ]) & 0xffffffff;

  immediate8? = fn (arg)
    if (car(arg) != x64:limm)
      false
    else
      match! (cdr(arg))
        [
          {int} i => int8?(i);
          ({int} i . _) => int7?(i);
        ];

  register? = fn (arg) car(arg) == x64:lreg;
  regval = cdr;

  iops = make_vector(x64:ops);
  // iops return values of (nbytes << 32) | value or (nested) vectors thereof

  | op_int8, op_int16, op_int32 |
  op_int8  = fn (n) (1 << 32) | (n & 0xff);
  op_int16 = fn (n) (2 << 32) | (n & 0xffff);
  op_int32 = fn (n) (4 << 32) | (n & 0xffffffff);

  | iop_op, iop_rex, iop_rex_reg |
  iop_rex = fn (int op, int rex)
    [
      | cnt, r |
      cnt = 1;
      r = op;
      if ((op & 0xff) == 0x0f)
        cnt = 2;
      if (rex)
        [
          r = rex | (r << 8);
          ++cnt
        ];
      (cnt << 32) | r
    ];

  iop_op = fn (op) iop_rex(op, 0);

  iop_rex_reg = fn (int op, int rex, int reg)
    [
      if (reg & reg_hi)
        [
          rex |= rex_op | rex_b;
          reg ^= reg_hi;
        ];
      iop_rex(op | reg, rex)
    ];

  | iop_rex_reg_modrm |
  iop_rex_reg_modrm = fn (op, rex, reg1, a2)
    [
      | iop_rex_modrm, iop_rex_modrm_sib |
      iop_rex_modrm = fn (op, rex, mod, reg0, reg1)
        [
          if (reg0 & reg_hi)
            [
              rex |= rex_op | rex_r;
              reg0 ^= reg_hi;
            ];
          if (reg1 & reg_hi)
            [
              rex |= rex_op | rex_b;
              reg1 ^= reg_hi;
            ];
          vector(iop_rex(op, rex), op_int8(mod | (reg0 << 3) | reg1))
        ];

      iop_rex_modrm_sib = fn (op, rex, mod, reg, scale, idx, base)
        [
          if (reg & reg_hi)
            [
              rex |= rex_op | rex_r;
              reg ^= reg_hi;
            ];
          if (idx & reg_hi)
            [
              rex |= rex_op | rex_x;
              idx ^= reg_hi;
            ];
          if (base & reg_hi)
            [
              rex |= rex_op | rex_b;
              base ^= reg_hi;
            ];

          vector(iop_rex(op, rex),
                 op_int16(mod | (reg << 3)
                          | ((scale | (idx << 3) | base) << 8)))
        ];

      | scale_ss, sib_scale_8, sib_scale_4, sib_scale_2, sib_scale_1 |
      sib_scale_8 = 0xc0;
      sib_scale_4 = 0x80;
      sib_scale_2 = 0x40;
      sib_scale_1 = 0x00;

      scale_ss = fn (scale)
        match! (scale)
          [
            1 => sib_scale_1;
            2 => sib_scale_2;
            4 => sib_scale_4;
            8 => sib_scale_8;
          ];

      match! (car(a2))
        [
          ,x64:lreg => iop_rex_modrm(op, rex, 0xc0, reg1, regval(a2));
          ,x64:lidx => [
            | r, disp, opx, val, mod |
            @(r . disp) = cdr(a2);

            if (r == x64:reg_rip)
              [
                val = if (function?(disp))
                  disp
                else
                  [
                    assert(int32?(disp));
                    op_int32(disp);
                  ];
                exit<function> vector(iop_rex_modrm(op, rex, 0, reg1, 5), val);
              ];

	    if (disp == 0 && (r & 7) != 5)
	      [
		// must use index with %rbp and %r13
		mod = 0;
	      ]
	    else if (int8?(disp))
              [
                val = op_int8(disp);
                mod = 0x40;
              ]
            else
              [
                assert(int32?(disp));
                val = op_int32(disp);
                mod = 0x80;
              ];

            opx = if ((r & 7) == 4)
              [
                // must use sib for %rsp and %r12
                iop_rex_modrm_sib(op, rex, mod | 4, reg1, sib_scale_1, 4, r);
              ]
	    else
              iop_rex_modrm(op, rex, mod, reg1, r);

            if (val != null)
	      vector(opx, val)
	    else
	      opx
          ];
          ,x64:lqidx => [
            | ridx, scale, disp |
            @(ridx scale . disp) = cdr(a2);
            assert(ridx != x64:reg_rsp); // cannot be encoded
            scale = scale_ss(scale);
            vector(iop_rex_modrm_sib(op, rex, 0x04, reg1, scale, ridx, 5),
                   op_int32(disp))
          ];
          ,x64:lridx => [
            | ridx, scale, rbase, disp |
            @(ridx scale rbase . disp) = cdr(a2);
            scale = scale_ss(scale);
            assert(ridx != x64:reg_rsp); // cannot be encoded
	    | mod, val |
	    if (disp == 0 && (ridx & 7) != 5)
	      [
		// must use displacement with %rbp and %r13
		mod = 0x04;
	      ]
	    else if (int8?(disp))
	      [
		mod = 0x44;
		val = op_int8(disp);
	      ]
	    else
	      [
		mod = 0x84;
		val = op_int32(disp);
	      ];
	    | opx |
	    opx = iop_rex_modrm_sib(0x8d, rex, mod, reg1, scale, ridx, rbase);
	    if (val != null)
	      vector(opx, val)
	    else
	      opx
          ];
          ,x64:lglobal => [
            vector(iop_rex_modrm(op, rex, 0x80, reg1, x64:reg_globals), a2)
          ];
          ,x64:lindirect => [
            // %rip-relative addressing
            vector(iop_rex_modrm(op, rex, 0, reg1, 5), a2)
          ];
        ]
    ];

  iops[x64:op_push] = fn (a1, a2)
    match (car(a1))
      [
        ,x64:lreg => iop_rex_reg(0x50, 0, regval(a1));
        ,x64:limm => [
          | imm |
          imm = immval32(a1);
          if (int8?(imm))
            vector(iop_op(0x6a), op_int8(imm))
          else
            vector(iop_op(0x68), op_int32(imm))
        ];
        _ => iop_rex_reg_modrm(0xff, 0, 6, a1);
      ];

  iops[x64:op_pop] = fn (a1, a2)
    if (register?(a1))
      iop_rex_reg(0x58, 0, regval(a1))
    else
      iop_rex_reg_modrm(0x8f, 0, 0, a1);

  iops[x64:op_leave] = fn (a1, a2) iop_op(0xc9);
  iops[x64:op_ret] = fn (a1, a2) iop_op(0xc3);

  iops[x64:op_bsf] = fn (a1, a2)
    [
      assert(register?(a2));
      iop_rex_reg_modrm(0xbc0f, rex_op | rex_w, regval(a2), a1);
    ];

  iops[x64:op_bt] = fn (a1, a2)
    [
      if (immediate8?(a1))
        [
          | v, rex |
          v = immval8(a1);
          assert(v >= 0 && v < 64);
          rex = if (v < 32) 0 else rex_op | rex_w;
          vector(iop_rex_reg_modrm(0xba0f, rex, 4, a2), op_int8(v))
        ]
      else
        [
          assert(register?(a1));
          iop_rex_reg_modrm(0xa30f, rex_op | rex_w, regval(a1), a2);
        ]
    ];

  iops[x64:op_movzxbyte] = fn (a1, a2)
    [
      assert(register?(a2));
      iop_rex_reg_modrm(0xb60f, reg8_rex(a1), regval(a2), a1);
    ];

  iops[x64:op_movzxword] = fn (a1, a2)
    [
      assert(register?(a2));
      iop_rex_reg_modrm(0xb70f, 0, regval(a2), a1);
    ];

  iops[x64:op_movzx32] = fn (a1, a2)
    [
      assert(register?(a2));
      iop_rex_reg_modrm(0x89, 0, regval(a1), a2);
    ];

  iops[x64:op_mov] = fn (a1, a2)
    match (car(a1))
      [
        ,x64:lreg => iop_rex_reg_modrm(0x89, rex_op | rex_w, regval(a1), a2);
        ,x64:limm64 && immediate_high32(a1) == 0 => [
          // 32-bit zero-extended immediate mov
          assert(register?(a2));
          vector(iop_rex_reg(0xb8, 0, regval(a2)),
                 op_int32(immediate_low32(a1)))
        ];
        ,x64:lcst || ,x64:lglobal_constant || ,x64:lclosure || ,x64:lbuiltin
          || ,x64:lfunction || ,x64:lcalled || ,x64:lcalled_global
          || ,x64:lprimitive || ,x64:lprimop || ,x64:limm64 => [
            // 64-bit immediate mov
            assert(register?(a2));
            vector(iop_rex_reg(0xb8, rex_op | rex_w, regval(a2)), a1)
          ];
        ,x64:limm || ,x64:lseclev || ,x64:lglobal_index => [
          // 32-bit immediate mov
          if (register?(a2)
              && !(car(a1) == x64:limm && (immval32(a1) & (1 << 31))))
            [
              // zero-extends
              vector(iop_rex_reg(0xb8, 0, regval(a2)), a1)
            ]
          else
            [
              // sign-extends
              vector(iop_rex_reg_modrm(0xc7, rex_op | rex_w, 0, a2), a1)
            ]
        ];
        ,x64:lidx || ,x64:lindirect || ,x64:lglobal => [
          assert(register?(a2));
          iop_rex_reg_modrm(0x8b, rex_op | rex_w, regval(a2), a1);
        ];
        _ => fail_message(format("invalid mov %w, %w", a1, a2))
      ];

  | iop_math, iop_unary_math, iop_math_byte |
  iop_math = fn (modrm_reg, dflt_rex) fn (a1, a2)
    match (car(a1))
      [
        ,x64:limm => [
          | imm, rex |
          rex = dflt_rex;

          // 'and' immediate can be unsigned 32-bit
          imm = if (modrm_reg == 4 && immediate_high32(a1) == 0)
            immediate_low32(a1)
          else
            immval32(a1);

          // special-case and $imm,%rXd
          if (modrm_reg == 4 && register?(a2) && uint32?(imm))
            rex = 0;

          if (int8?(imm))
            vector(iop_rex_reg_modrm(0x83, rex, modrm_reg, a2), op_int8(imm))
          else if (imm == 128 && (modrm_reg == 0 || modrm_reg == 5))
            // convert add/sub $128,r/m to sub/add $-128,r/m
            vector(iop_rex_reg_modrm(0x83, rex, modrm_reg ^ 5, a2),
                   op_int8(-imm))
          else
            [
              imm = op_int32(imm);
              if (rax?(a2))
                vector(iop_rex(0x05 + (modrm_reg << 3), rex), imm)
              else
                vector(iop_rex_reg_modrm(0x81, rex, modrm_reg, a2), imm)
            ]
        ];
        ,x64:lreg => [
          | r1, rex |
          r1 = regval(a1);
          rex = dflt_rex;
          // special-case xor %rX,%rX to xor %rXd,%rXd
          if (modrm_reg == 6)
            match (a2)
              [
                (,x64:lreg . ,r1) => rex = 0;
              ];
          iop_rex_reg_modrm(0x01 + (modrm_reg << 3), rex, r1, a2)
        ];
        _ => [
          assert(register?(a2));
          iop_rex_reg_modrm(0x03 + (modrm_reg << 3), dflt_rex, regval(a2), a1)
        ];
      ];

  iops[x64:op_add]   = iop_math(0, rex_op | rex_w);
  iops[x64:op_add32] = iop_math(0, 0);
  iops[x64:op_and]   = iop_math(4, rex_op | rex_w);
  iops[x64:op_cmp]   = iop_math(7, rex_op | rex_w);
  iops[x64:op_or]    = iop_math(1, rex_op | rex_w);
  iops[x64:op_sub]   = iop_math(5, rex_op | rex_w);
  iops[x64:op_xor]   = iop_math(6, rex_op | rex_w);

  iop_math_byte = fn (modrm_reg) fn (a1, a2)
    [
      | rex |
      rex = reg8_rex(a1) | reg8_rex(a2);
      if (immediate8?(a1))
        [
          | imm |
          imm = op_int8(immval8(a1));
          if (rax?(a2))
            vector(iop_op(0x04 + (modrm_reg << 3)), op_int8(imm))
          else
            vector(iop_rex_reg_modrm(0x80, rex, modrm_reg, a2), imm)
        ]
      else if (register?(a1))
        iop_rex_reg_modrm(modrm_reg << 3, rex, regval(a1), a2)
      else
        [
          assert(register?(a2));
          iop_rex_reg_modrm(2 + (modrm_reg << 3), rex, regval(a2), a1)
        ];
    ];

  iops[x64:op_orbyte] = iop_math_byte(1);
  iops[x64:op_xorbyte] = iop_math_byte(6);
  iops[x64:op_cmpbyte] = iop_math_byte(7);

  iop_unary_math = fn (op, modrm_reg) fn (a1, a2)
    iop_rex_reg_modrm(op, rex_op | rex_w, modrm_reg, a1);

  iops[x64:op_dec] = iop_unary_math(0xff, 1);
  iops[x64:op_inc] = iop_unary_math(0xff, 0);
  iops[x64:op_not] = iop_unary_math(0xf7, 2);
  iops[x64:op_neg] = iop_unary_math(0xf7, 3);

  iops[x64:op_imul] = fn (a1, a2)
    [
      | imm, r2 |
      @(,x64:lidx . (r2 . imm)) = a2;
      if (int8?(imm))
        vector(iop_rex_reg_modrm(0x6b, rex_op | rex_w, r2, a1),
               op_int8(imm))
      else
        [
          assert(int32?(imm));
          vector(iop_rex_reg_modrm(0x69, rex_op | rex_w, r2, a1),
                 op_int32(imm))
        ]
    ];

  iops[x64:op_xchg] = fn (a1, a2)
    [
      if (car(a2) != x64:lreg || register?(a1) && rax?(a2))
        [
          | tmp |
          tmp = a1;
          a1 = a2;
          a2 = tmp;
        ];
      | r2 |
      assert(register?(a2));
      r2 = regval(a2);
      if (rax?(a1))
        iop_rex_reg(0x90, rex_op | rex_w, r2)
      else
        iop_rex_reg_modrm(0x87, rex_op | rex_w, r2, a1)
    ];

  iops[x64:op_movbyte] = fn (a1, a2)
    [
      | rex |
      rex = reg8_rex(a1) | reg8_rex(a2);
      if (car(a1) == x64:limm)
        [
          | op, val |
          val = immval32(a1);
          assert(val >= -128 && val <= 255);
          op = if (register?(a2))
            iop_rex_reg(0xb0, rex, regval(a2))
          else
            iop_rex_reg_modrm(0xc6, rex, 0, a2);
          vector(op, op_int8(val))
        ]
      else
        [
          assert(register?(a1));
          iop_rex_reg_modrm(0x88, rex, regval(a1), a2);
        ]
    ];

  iops[x64:op_test] = fn (a1, a2)
    [
      if (car(a1) == x64:limm)
        [
          | iop, val, rax |
          rax = rax?(a2);
          val = if (immediate_high32(a1) == 0)
            immediate_low32(a1)
          else
            immval32(a1);
          if (uint8?(val))
            [
              iop = if (rax)
                iop_op(0xa8)
              else
                iop_rex_reg_modrm(0xf6, reg8_rex(a2), 0, a2);
              val = op_int8(val)
            ]
          else
            [
              | rex |
              rex = if (uint32?(val)) 0 else rex_op | rex_w;
              iop = if (rax)
                iop_rex(0xa9, rex)
              else
                iop_rex_reg_modrm(0xf7, rex, 0, a2);
              val = op_int32(val);
            ];
          vector(iop, val)
        ]
      else
        [
          assert(register?(a1));
          iop_rex_reg_modrm(0x85, rex_op | rex_w, regval(a1), a2);
        ]
    ];

  iops[x64:op_lea] = fn (a1, a2)
    [
      assert(register?(a2));
      iop_rex_reg_modrm(0x8d, rex_op | rex_w, regval(a2), a1);
    ];

  iops[x64:op_lea32] = fn (a1, a2)
    [
      assert(register?(a2));
      iop_rex_reg_modrm(0x8d, 0, regval(a2), a1);
    ];

  iops[x64:op_setcc] = fn (@(,x64:lnone . a1), a2)
    iop_rex_reg_modrm(0x900f | (a1 << 8), reg8_rex(a2), 0, a2);

  | iop_cmovcc |
  iop_cmovcc = fn (rex) fn (a1, a2)
    [
      | r2, cc |
      @(,x64:lidx . (r2 . cc)) = a2;
      iop_rex_reg_modrm(0x400f | (cc << 8), rex, r2, a1);
    ];

  iops[x64:op_cmovcc]   = iop_cmovcc(rex_op | rex_w);
  iops[x64:op_cmovcc32] = iop_cmovcc(0);

  iops[x64:op_jmp] = fn (a1, a2)
    vector(iop_op(0xeb), imm_jmp8);
  iops[x64:op_jmp32] = fn (a1, a2)
    vector(iop_op(0xe9), imm_jmp32);
  iops[x64:op_jcc] = fn (a1, a2)
    vector(iop_op(0x70 | a2), imm_jmp8);
  iops[x64:op_jcc32] = fn (a1, a2)
    vector(iop_op(0x800f | (a2 << 8)), imm_jmp32);

  iops[x64:op_call] = fn (a1, a2)
    iop_rex_reg_modrm(0xff, 0, 2, a1);

  | iop_shift |
  iop_shift = fn (op) fn (a1, a2)
    [
      if (register?(a1))
        [
          assert(regval(a1) == x64:reg_rcx);
          exit<function> iop_rex_reg_modrm(0xd3, rex_op | rex_w, op, a2);
        ];

      assert(immediate8?(a1));
      match (immval8(a1))
        [
          1 => iop_rex_reg_modrm(0xd1, rex_op | rex_w, op, a2);
          n => vector(iop_rex_reg_modrm(0xc1, rex_op | rex_w, op, a2),
                      op_int8(n))
        ]
    ];

  iops[x64:op_shl] = iop_shift(4);
  iops[x64:op_shr] = iop_shift(5);
  iops[x64:op_sar] = iop_shift(7);

  | ltype_to_subfn |
  ltype_to_subfn = indexed_sequence(
    x64:lclosure  . mc:subfn_closure,
    x64:lfunction . mc:subfn_code,
    x64:lcalled   . mc:subfn_called);

  ins_size = fn (val)
    [
      if (vector?(val))
        exit<function> vreduce(fn (e, n) n + ins_size(e), 0, val);

      if (integer?(val))
        val >> 32
      else if (val == imm_jmp8)
        1
      else if (val == imm_jmp32)
        4
      else if (function?(val))
        val(0)
      else
        ltype_info[car(val)][lti_size]
    ];

  ins_gen = fn (code, il, ops, offset, size, info, pcrel_info)
    [
      | iter, oofs |
      oofs = offset;

      iter = fn (val, offset)
        [
          if (vector?(val))
            [
              for (|l, i| [ l = vlength(val); i = 0 ]; i < l; ++i)
                offset = iter(val[i], offset);
              exit<function> offset;
            ];

          | v, nbytes |
          v = 0;
          nbytes = match (val)
            [
              {int} n => [
                v = n;
                nbytes = n >> 32;
                assert(nbytes >= 0 && nbytes <= 4);
                nbytes
              ];
              {function} f => [
                v = f(1);
                nbytes = f(0);
                assert(nbytes >= 0 && nbytes <= 4);
                nbytes
              ];
              x && x == imm_jmp8 => [
                | dest |
                dest = il[x64:il_ins][x64:i_arg1];
                v = dest[x64:l_ins][x64:il_offset][0] - (offset + 1);
                1
              ];
              x && x == imm_jmp32 => [
                | dest |
                dest = il[x64:il_ins][x64:i_arg1];
                v = dest[x64:l_ins][x64:il_offset][0] - (offset + 4);
                4
              ];
              (vop . varg) => [
                match! (vop) [
                  ,x64:lindirect => [
                    | ltype, x |
                    @(ltype . x) = varg;
                    pcrel_info[pri_indv][ltype]
                      = (x . offset) . pcrel_info[pri_indv][ltype];
                    4
                  ];
                  ,x64:limm => [
                    v = immediate_low32(val);
                    4
                  ];
                  ,x64:limm64 => [
                    pcrel_info[pri_absv][x64:limm64]
                      = (varg . offset) . pcrel_info[pri_absv][x64:limm64];

                    insert_int(code, offset, 4, immediate_low32(val));
                    offset += 4;
                    v = immediate_high32(val);
                    4
                  ];
                  ,x64:lclosure || ,x64:lfunction || ,x64:lcalled => [
                    info[mc:a_subfns] = vector(
                      varg, offset, ltype_to_subfn[vop]) . info[mc:a_subfns];
                    8
                  ];
                  ltype => [
                    | linfo, aidx |
                    linfo = ltype_info[ltype];
                    aidx = linfo[lti_aidx];
                    pcrel_info[pri_absv][ltype]
                      = (varg . offset) . pcrel_info[pri_absv][ltype];
                    info[aidx] = (varg . offset) . info[aidx];
                    linfo[lti_size]
                  ];
                ]
              ];
              x => fail_message(format("unknown op %w", x))
            ];

          insert_int(code, offset, nbytes, v);
          offset + nbytes;
        ];

      offset = iter(ops, oofs);

      if (oofs + size != offset)
        [
          x64:print_ins(il[x64:il_ins]); newline();
          fail_message(format("bad size; expected %d got %d",
                              size, offset - oofs))
        ]
    ];
];
