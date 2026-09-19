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

library mx64 // mudlle assembler for x86-64
requires compiler, dlist, misc, vars
defines x64:l_ins, x64:l_alias, x64:l_number, x64:il_label, x64:il_ins,
  x64:il_node, x64:il_number, x64:il_offset, x64:il_loc, x64:i_op,
  x64:i_arg1, x64:i_arg2, x64:lvar, x64:lreg, x64:lidx, x64:lridx, x64:limm,
  x64:limm64, x64:lcst, x64:lfunction, x64:lcalled, x64:lcalled_global,
  x64:lclosure, x64:lglobal,
  x64:lglobal_constant, x64:lglobal_index, x64:gl_c, x64:gl_mudlle,
  x64:lprimitive, x64:lprimop, x64:lindirect, x64:lnone,
  x64:lbuiltin, x64:lseclev, x64:sl_c, x64:sl_mudlle, x64:sl_maxlev,
  x64:nregs, x64:reg_rax, x64:reg_rbx, x64:reg_rcx, x64:reg_rdx, x64:reg_rsp,
  x64:reg_rbp, x64:reg_rsi, x64:reg_rdi, x64:reg_r8, x64:reg_r9, x64:reg_r10,
  x64:reg_r11, x64:reg_r12, x64:reg_r13, x64:reg_r14, x64:reg_r15, x64:reg_rip,
  x64:bne, x64:be, x64:bg, x64:ble, x64:bge,
  x64:bl, x64:ba, x64:bbe, x64:bae, x64:bb, x64:bno, x64:bo, x64:bns, x64:bs,
  x64:bnp, x64:bp, x64:balways, x64:op_push, x64:op_pop, x64:op_call,
  x64:op_ret, x64:op_jmp, x64:op_jcc, x64:op_lea, x64:op_lea32, x64:op_mov,
  x64:op_add, x64:op_add32, x64:op_sub, x64:op_cmp, x64:op_cmpbyte, x64:op_or,
  x64:op_xor, x64:op_and, x64:op_test,
  x64:op_dec, x64:op_inc, x64:op_neg, x64:op_not,
  x64:op_shl, x64:op_shr, x64:op_imul,
  x64:op_setcc, x64:op_cmovcc, x64:op_cmovcc32,
  x64:op_movzxbyte, x64:op_movbyte,
  x64:op_movzxword, x64:op_movzx32,
  x64:op_orbyte, x64:op_xorbyte, x64:op_xchg, x64:op_bsf, x64:op_bt,
  x64:ops, x64:new_code,
  x64:set_instruction, x64:get_instructions, x64:rem_instruction,
  x64:copy_instruction, x64:mudlleint, x64:doubleint, x64:push, x64:pop,
  x64:call, x64:ret, x64:jmp, x64:jcc, x64:lea, x64:lea32, x64:mov,
  x64:add, x64:add32, x64:sub, x64:cmp, x64:cmpbyte, x64:or, x64:xor,
  x64:and, x64:test,
  x64:dec, x64:inc, x64:neg, x64:not,
  x64:shl, x64:shr, x64:setcc, x64:cmovcc, x64:cmovcc32,
  x64:movzxbyte, x64:movbyte, x64:movzxword, x64:movzx32,
  x64:orbyte, x64:xorbyte, x64:imul, x64:xchg, x64:bsf, x64:bt,
  x64:new_label,
  x64:label, x64:set_label, x64:skip_label_alias, x64:ins_list, x64:print_ins,
  x64:resolve, x64:trap,
  x64:op_jmp32, x64:op_jcc32, x64:sar, x64:op_sar,
  x64:leave, x64:op_leave, x64:lqidx,
  x64:reset_ins_count,

  x64:reg_globals, x64:reg_closure,

  x64:vcode_ilpos, x64:vcode_nlabel, x64:vcode_traps, x64:vcode_leaf?

[
x64:vcode_ilpos  = 0;           // current insertion point
x64:vcode_nlabel = 1;           // label for next instruction
x64:vcode_traps  = 2;           // list of error traps
x64:vcode_leaf?  = 3;           // true if function is a leaf function

// labels:

x64:l_ins    = 0;               // instruction pointed to
x64:l_alias  = 1;               // we are an alias to this label
x64:l_number = 2;               // unique number (for display)

// An instruction list is a list of the following vectors:

x64:il_label  = 0;              // label of this instruction, or false
x64:il_ins    = 1;              // the actual instruction
x64:il_node   = 2;              // basic block of this instruction
x64:il_number = 3;              // a unique number (for display)
x64:il_offset = 4;              // instruction offset (int)
x64:il_loc    = 5;              // source code location

// An instruction is a vector:
// (all instructins must represent legal x64 instructions)

x64:i_op = 0;   // op
x64:i_arg1 = 1; // upto 2 arguments (unused ones set to null)
x64:i_arg2 = 2;

// arguments are pairs: mode . arguments, except for labels and ccs
// modes/arguments are:
//   x64:lreg: register
//   x64:lidx: register . offset
//   x64:lridx: register1 . scale . register2 . disp
//     (register1 * scale + register2 + disp)
//   x64:lqidx: register1 . scale . disp
//     (register1 * scale + disp)
//   x64:limm: immediate
//   x64:lcst: mudlle constant
//   x64:lfunction: magic
//   x64:lclosure: for functions without closure variables
//   x64:lglobal: global name
//   x64:lglobal_constant: global name
//   x64:lprimitive / x64:lprimop: primitive name
//   x64:lseclev: seclevel-related; arg is one of x64:xl_xxx
// accepted on input, but converted: lvar: variable
// arguments to x64:limm are integers or pairs:
//   x . 0 for 2*x and x . 1 for 2*x+1
// (to work around 31-bit integer limitations)
// each instruction can contains at most one non-x64:lreg argument
x64:lvar             = 0;
x64:lreg             = 1;
x64:lidx             = 2;
x64:lridx            = 3;
x64:lqidx            = 4;
x64:limm             = 5;       // 32-bit immediate
x64:lcst             = 6;       // mudlle constant
x64:lfunction        = 7;       // code object for local function
x64:lcalled          = 8;       // name of global or local function vector
x64:lcalled_global   = 9;       // name of global or local function vector
x64:lprimitive       = 10;
x64:lclosure         = 11;
x64:lglobal          = 12;
x64:lglobal_constant = 13;
x64:lglobal_index    = 14;
 x64:gl_c            = 0;
 x64:gl_mudlle       = 1;
x64:lseclev          = 15;
 x64:sl_c            = 0;       // function_seclevel() as C int
 x64:sl_mudlle       = 1;       // function_seclevel() as mudlle int
 x64:sl_maxlev       = 2;       // function's maxseclevel cap
x64:lindirect        = 16;      // 32-bit rip-relative offset to 64-bit
                                // value
x64:limm64           = 17;      // 64-bit immediate; only with x64:mov
x64:lprimop          = 18;      // address to struct prim_op
x64:lbuiltin         = 19;      // name of builtin
x64:lnone            = 20;      // keep this last

x64:nregs = 16;

x64:reg_rax = 0;
x64:reg_rbx = 3;
x64:reg_rcx = 1;
x64:reg_rdx = 2;
x64:reg_rsp = 4;
x64:reg_rbp = 5;
x64:reg_rsi = 6;
x64:reg_rdi = 7;
x64:reg_r8  = 8;
x64:reg_r9  = 9;
x64:reg_r10 = 10;
x64:reg_r11 = 11;
x64:reg_r12 = 12;
x64:reg_r13 = 13;
x64:reg_r14 = 14;
x64:reg_r15 = 15;

x64:reg_rip = 16;               // treated differently from the other regs

x64:reg_globals = x64:reg_rbx;
x64:reg_closure = x64:reg_r15;

| spillregs |
spillregs = indexed_sequence(
  mc:spill_closure . x64:reg_closure,
  mc:spill_args    . x64:reg_rbp,
  mc:spill_spill   . x64:reg_rbp);

// branches, using x64 encoding
x64:bo  = 0;                    // OF = 1
x64:bno = 1;                    // OF = 0
x64:bb  = 2;                    // CF = 1
x64:bae = 3;                    // CF = 0
x64:be  = 4;                    // ZF = 0
x64:bne = 5;                    // ZF = 1
x64:bbe = 6;                    // CF = 1 or ZF = 1
x64:ba  = 7;                    // CF = 0 and ZF = 0
x64:bs  = 8;                    // SF = 1
x64:bns = 9;                    // SF = 0
x64:bp  = 10;                   // PF = 1
x64:bnp = 11;                   // PF = 0
x64:bl  = 12;                   // SF != OF
x64:bge = 13;                   // SF = OF
x64:ble = 14;                   // ZF = 1 or SF != OF
x64:bg  = 15;                   // ZF = 0 and SF = OF

x64:balways = -1; // special value, used for x64:trap

// operations
x64:op_push  = 0;
x64:op_pop   = 1;
x64:op_leave = 2;

x64:op_call  = 3;
x64:op_ret   = 4;
x64:op_jmp   = 5;
x64:op_jcc   = 6;
x64:op_jmp32 = 7;
x64:op_jcc32 = 8;

x64:op_lea   = 9;
x64:op_lea32 = 10;
x64:op_mov   = 11;

x64:op_add     = 12;
x64:op_add32   = 13;
x64:op_and     = 14;
x64:op_cmp     = 15;
x64:op_cmpbyte = 16;
x64:op_or      = 17;
x64:op_orbyte  = 18;
x64:op_sar     = 19;
x64:op_shl     = 20;
x64:op_shr     = 21;
x64:op_sub     = 22;
x64:op_test    = 23;
x64:op_xchg    = 24;
x64:op_xor     = 25;
x64:op_xorbyte = 26;

x64:op_dec = 27;
x64:op_inc = 28;
x64:op_neg = 29;
x64:op_not = 30;

x64:op_setcc     = 31;
x64:op_cmovcc    = 32;
x64:op_cmovcc32  = 33;
x64:op_movzxbyte = 34;
x64:op_movbyte   = 35;
x64:op_movzxword = 36;
x64:op_movzx32   = 37;
x64:op_bsf       = 38;
x64:op_bt        = 39;

x64:op_imul = 40;

x64:ops = 41;

| int31? |
int31? = fn (int n) n >= -0x40000000 && n <= 0x3fffffff;

[
  | ins_index, label_index, rnames64, rnames32, rnames16, rnames8, cnames,
    mode, eastr, slabel, opname, add_ins,
    generic_op0, generic_op1, generic_op2 |

  x64:new_code = fn (leaf?)
    // Returns: Structure in which instructions can be generated
    [
      indexed_vector(
        x64:vcode_ilpos  . null,
        x64:vcode_nlabel . false,
        x64:vcode_traps  . null,
        x64:vcode_leaf?  . leaf?)
    ];

  x64:set_instruction = fn """fncode ilist -> . Sets the current instruction\
 insert position to ilist""" (fcode, pos)
    [
      assert(!fcode[x64:vcode_nlabel]);
      fcode[x64:vcode_ilpos] = pos;
    ];

  x64:get_instructions = fn """fncode -> ilist. Returns instruction list of\
 ilist""" (fcode)
    [
      assert(!fcode[x64:vcode_nlabel]);
      fcode[x64:vcode_ilpos]
    ];

  x64:rem_instruction = fn (fcode, il)
    [
      fcode[x64:vcode_ilpos] = dremove!(il, fcode[x64:vcode_ilpos]);
    ];

  x64:copy_instruction = fn (fcode, il)
    [
      add_ins(fcode, il[x64:il_ins]);
    ];

  ins_index = 0;

  x64:reset_ins_count = fn () label_index = ins_index = 0;

  add_ins = fn (fcode, ins)
    // Types: fcode : x64code
    //        ins : instruction
    // Effects: Adds ins to the instructions in fcode, setting the label
    //   if necessary.
    //   Clears the current label
    [
      | newins |

      // Add instruction
      newins = vector(fcode[x64:vcode_nlabel], ins, null,
                      ++ins_index, 0, mc:get_loc());

      // This is a strange hack:
      //   When code is initially generated, fcode[x64:vcode_ilpos] starts at
      //   null, then gets set to the first instruction with subsequent
      //   instructions inserted before it (and because of the circular nature
      //   of the list, actually at the end).
      //   Later, when code needs patching, x64:set_instruction is called to
      //   set the insertion point, before which new instructions are added.
      if (fcode[x64:vcode_ilpos] == null)
        fcode[x64:vcode_ilpos] = dcons!(newins, null)
      else
        // insert before fcode[x64:vcode_ilpos]
        dcons!(newins, fcode[x64:vcode_ilpos]);

      // Set label if any
      if (fcode[x64:vcode_nlabel])
        fcode[x64:vcode_nlabel][x64:l_ins] = newins;
      fcode[x64:vcode_nlabel] = false;
    ];

  x64:resolve = fn (type, arg)
    [
      <cst> if (type == x64:lvar)
        exit<function> [
          | loc |

          if (mc:in_reg(arg))
            x64:lreg . mc:get_reg(arg)
          else if (loc = arg[mc:v_location])
            x64:lidx . (spillregs[loc[mc:v_lstype]] . loc[mc:v_lsoffset])
          else			// no location: global or constant
            [
              | cls |
              cls = arg[mc:v_class];
              if (cls == mc:v_constant)
                [
                  type = x64:lcst;
                  arg = arg[mc:v_kvalue];
                  exit<cst> null;
                ]
              else if (cls == mc:v_global || cls == mc:v_global_define)
                x64:lglobal . arg[mc:v_name]
              else if (cls == mc:v_global_constant)
                [
                  | val |
                  val = global_value(arg[mc:v_goffset]);
                  if (val == null)
                    x64:limm . 0
                  else if (immutable?(val))
                    x64:lglobal_constant . arg[mc:v_name]
                  else
                    x64:lglobal . arg[mc:v_name]
                ]
              else if (cls == mc:v_function)
                x64:lfunction . arg[mc:v_fvalue]
              else
                fail()
            ]
        ];

      if (type == x64:lcst)
        [
          if (arg == null)
            exit<function> x64:limm . 0;
          if (integer?(arg))
            exit<function> cons(if (int31?(arg)) x64:limm else x64:limm64,
                                x64:mudlleint(arg));
        ];

      type . arg
    ];

  x64:mudlleint = fn (x) x . 1;
  x64:doubleint = fn (x) x . 0;

  // actual instructions

  generic_op0 = fn (op)
    fn (fcode)
      add_ins(fcode, vector(op, null, null));

  generic_op1 = fn (op)
    fn (fcode, m1, a1)
      add_ins(fcode, vector(op, x64:resolve(m1, a1), null));

  generic_op2 = fn (op)
    fn (fcode, m1, a1, m2, a2)
        add_ins(fcode, vector(op, x64:resolve(m1, a1), x64:resolve(m2, a2)));

  x64:push = generic_op1(x64:op_push);
  x64:pop = generic_op1(x64:op_pop);
  x64:leave = generic_op0(x64:op_leave);

  x64:call = fn (fcode, m1, a1, noreturn?)
    add_ins(fcode, vector(x64:op_call, x64:resolve(m1, a1), noreturn?));
  x64:ret = generic_op0(x64:op_ret);
  x64:jmp = fn (fcode, l)
    add_ins(fcode, vector(x64:op_jmp, l, null));
  x64:jcc = fn (fcode, cc, l)
    add_ins(fcode, vector(x64:op_jcc, l, cc));

  x64:lea = generic_op2(x64:op_lea);   // dest must be reg
  x64:lea32 = generic_op2(x64:op_lea32); // dest must be reg

  x64:mov = generic_op2(x64:op_mov);
  x64:movbyte = generic_op2(x64:op_movbyte);

  x64:imul = fn (fcode, m1, a1, m2, a2, m3, imm)
    [
      assert(m2 == x64:lreg);
      assert(m3 == x64:limm);
      // special case for ternary instruction
      add_ins(fcode, vector(x64:op_imul, x64:resolve(m1, a1),
                            x64:lidx . (a2 . imm)))
    ];

  x64:add = generic_op2(x64:op_add);
  x64:add32 = generic_op2(x64:op_add32);
  x64:sub = generic_op2(x64:op_sub);
  x64:cmp = generic_op2(x64:op_cmp);
  x64:cmpbyte = generic_op2(x64:op_cmpbyte);
  x64:or = generic_op2(x64:op_or);
  x64:orbyte = generic_op2(x64:op_orbyte);
  x64:xor = generic_op2(x64:op_xor);
  x64:xorbyte = generic_op2(x64:op_xorbyte);
  x64:and = generic_op2(x64:op_and);
  x64:test = generic_op2(x64:op_test);
  x64:xchg = generic_op2(x64:op_xchg);

  x64:dec = generic_op1(x64:op_dec);
  x64:inc = generic_op1(x64:op_inc);
  x64:neg = generic_op1(x64:op_neg);
  x64:not = generic_op1(x64:op_not);

  x64:shl = generic_op2(x64:op_shl); // many restrictions on arg1
  x64:shr = generic_op2(x64:op_shr); // many restrictions on arg1
  x64:sar = generic_op2(x64:op_sar); // many restrictions on arg1
  x64:setcc = fn (fcode, cc, m1, a1)
    add_ins(fcode, vector(x64:op_setcc, x64:lnone . cc, x64:resolve(m1, a1)));

  | add_cmovcc |
  add_cmovcc = fn (op) fn (fcode, cc, m1, a1, m2, a2)
    [
      assert(m2 == x64:lreg);
      add_ins(fcode, vector(op, x64:resolve(m1, a1),
                            x64:resolve(x64:lidx, a2 . cc)));
    ];
  x64:cmovcc   = add_cmovcc(x64:op_cmovcc);
  x64:cmovcc32 = add_cmovcc(x64:op_cmovcc32);

  x64:movzxbyte = generic_op2(x64:op_movzxbyte); // dest must be register
  x64:movzxword = generic_op2(x64:op_movzxword); // dest must be register
  x64:movzx32 = generic_op2(x64:op_movzx32); // dest must be register

  x64:bsf = generic_op2(x64:op_bsf);         // dest must be register
  x64:bt = generic_op2(x64:op_bt);           // src must be imm8 or register

  // labels

  label_index = 0;
  x64:new_label = fn """x64code -> label. Returns a new unassigned label in\
 x64code"""
    (fcode)
      vector(false, false, ++label_index);

  x64:label = fn "x64code label -> . Makes label point at the next\
 instruction to be generated in x64code" (fcode, label)
    [
      if (fcode[x64:vcode_nlabel])
        label[x64:l_alias] = fcode[x64:vcode_nlabel]
      else
        fcode[x64:vcode_nlabel] = label;
    ];

  x64:skip_label_alias = fn (vector label)
    [
      | nlabel |
      while (vector?(nlabel = label[x64:l_alias]))
        label = nlabel;
      label
    ];

  x64:set_label = fn """label ilist -> . Sets label to point to ilist. Might\
 make it an alias of existing label""" (vector l, vector il)
    [
      | lab |

      if (lab = il[x64:il_label]) // make it an alias
        [
          l[x64:l_alias] = lab;
          l[x64:l_ins] = false;
        ]
      else
        [
          l[x64:l_ins] = il;
          l[x64:l_alias] = false;
          il[x64:il_label] = l;
        ]
    ];

  // traps

  x64:trap = fn """x64code cc n -> Cause error n with arguments args if cc is\
 true"""
    (fcode, cc, n, args)
    [
      | l |

      // fcode[x64:vcode_traps] is a list of [ errno loc label args label2 ]
      //   errno    an error_xxx
      //   loc      trap code location
      //   label    jump label for this error trampoline
      // where args and label2 are null except for error_bad_type:
      //   args     vector(typeset, argnum, move_func, move_arg)
      //   label2   if typeset is null, this is the label to jump to after
      //            moving var to arg0; if typeset is not null, the "tail"
      //            label for moving typeset to arg1 and jumping to the
      //            berror_xxx trampoline
      // move_func(code, move_arg, dstloc, dstlocarg) should generate code to
      // move the bad type argument into dstloc:dstlocarg.

      <found> [
        for ( | tl | tl = fcode[x64:vcode_traps]; tl != null; tl = cdr(tl))
          match (car(tl))
            [
              [ ,n ,(mc:get_loc()) label oargs label2 ] => [
                if (equal?(args, oargs))
                  [
                    l = label;
                    exit<found> null;
                  ];

                assert(n == error_bad_type || n == error_no_match);
                | otype, type |
                @[otype ...] = oargs;
                @[type ...] = args;
                if (equal?(type, otype))
                  [
                    | l2 |
                    l = x64:new_label(fcode);
                    if (label2)
                      l2 = label2
                    else
                      car(tl)[4] = l2 = x64:new_label(fcode);
                    args[0] = null;
                    fcode[x64:vcode_traps] = cons(
                      vector(n, mc:get_loc(), l, args, l2),
                      fcode[x64:vcode_traps]);
                    exit<found> null
                  ];
              ]
            ];

        // new trap
        l = x64:new_label(fcode);
        fcode[x64:vcode_traps] = vector(n, mc:get_loc(), l, args, false)
          . fcode[x64:vcode_traps];
      ];

      if (cc == x64:balways)
	x64:jmp(fcode, l)
      else
	x64:jcc(fcode, cc, l);
    ];

  // code display

  x64:ins_list = fn "x64code -> . Prints instruction list" (fcode)
    [
      | scan, ilist |
      ilist = fcode[x64:vcode_ilpos];
      scan = ilist;
      loop
        [
          | il |

          il = dget(scan);
          if (il[x64:il_label])
            dformat("%s:", slabel(il[x64:il_label]));
          | loc |
          loc = il[x64:il_loc];
          dformat("\t%d:%d\t(%s) ", mc:loc_line(loc), mc:loc_column(loc),
                  il[x64:il_number]);

          x64:print_ins(il[x64:il_ins]);

          newline();
          scan = dnext(scan);
          if (scan == ilist) exit 0
        ];
    ];

  opname = indexed_sequence(
    x64:op_add       . "add",
    x64:op_add32     . "add32",
    x64:op_and       . "and",
    x64:op_bsf       . "bsf",
    x64:op_bt        . "bt",
    x64:op_call      . "call",
    x64:op_cmovcc    . "cmovcc",
    x64:op_cmovcc32  . "cmovcc32",
    x64:op_cmp       . "cmp",
    x64:op_cmpbyte   . "cmp8",
    x64:op_dec       . "dec",
    x64:op_imul      . "imul",
    x64:op_inc       . "inc",
    x64:op_jcc       . "jcc",
    x64:op_jcc32     . "jcc32",
    x64:op_jmp       . "jmp",
    x64:op_jmp32     . "jmp32",
    x64:op_lea       . "lea",
    x64:op_lea32     . "lea",
    x64:op_leave     . "leave",
    x64:op_mov       . "mov",
    x64:op_movbyte   . "mov8",
    x64:op_movzx32   . "movzx32",
    x64:op_movzxbyte . "movzx8",
    x64:op_movzxword . "movzx16",
    x64:op_neg       . "neg",
    x64:op_not       . "not",
    x64:op_or        . "or",
    x64:op_orbyte    . "or8",
    x64:op_pop       . "pop",
    x64:op_push      . "push",
    x64:op_ret       . "ret",
    x64:op_sar       . "sar",
    x64:op_setcc     . "setcc",
    x64:op_shl       . "shl",
    x64:op_shr       . "shr",
    x64:op_sub       . "sub",
    x64:op_test      . "test",
    x64:op_xchg      . "xchg",
    x64:op_xor       . "xor",
    x64:op_xorbyte   . "xor8");
  assert(vlength(opname) == x64:ops);

  cnames = indexed_sequence(
    x64:ba  . "a",
    x64:bae . "ae",
    x64:bb  . "b",
    x64:bbe . "be",
    x64:be  . "e",
    x64:bg  . "g",
    x64:bge . "ge",
    x64:bl  . "l",
    x64:ble . "le",
    x64:bne . "ne",
    x64:bno . "no",
    x64:bnp . "np",
    x64:bns . "ns",
    x64:bo  . "o",
    x64:bp  . "p",
    x64:bs  . "s");
  assert(vlength(cnames) == 16);

  rnames64 = '["rax" "rcx" "rdx" "rbx" "rsp" "rbp" "rsi" "rdi"
               "r8" "r9" "r10" "r11" "r12" "r13" "r14" "r15" "rip"];
  rnames32 = '["eax" "ecx" "edx" "ebx" "esp" "ebp" "esi" "edi"
               "r8d" "r9d" "r10d" "r11d" "r12d" "r13d" "r14d" "r15d"];
  rnames16 = '["ax" "cx" "dx" "bx" "sp" "bp" "si" "di"
               "r8w" "r9w" "r10w" "r11w" "r12w" "r13w" "r14w" "r15w"];
  rnames8 = '["al" "cl" "dl" "bl" "spl" "bpl" "sil" "dil"
              "r8b" "r9b" "r10b" "r11b" "r12b" "r13b" "r14b" "r15b"];

  mode = indexed_sequence(
    x64:lcst             . "cst",
    x64:lfunction        . "fn",
    x64:lcalled          . "code",
    x64:lcalled_global   . "code",
    x64:lprimitive       . "prim",
    x64:lclosure         . "closure",
    x64:lglobal          . "gbl",
    x64:lglobal_constant . "gcst",
    x64:lglobal_index    . "gidx",
    x64:lseclev          . "seclvl",
    x64:lindirect        . "indirect",
    x64:lprimop          . "primop",
    x64:lbuiltin         . "builtin");

  eastr = fn (@(m . a), rnames)
    [
      | itoea |

      itoea = fn (n)
        if (n >= -1024 && n <= 1024)
          itoa(n)
        else
          format("%#x", n);

      if (m == x64:lreg)
        rnames[a]
      else if (m == x64:lidx)
        [
          | r, disp |
          @(r . disp) = a;
          disp = if (function?(disp))
            disp(2)
          else
            itoea(disp);
          format("%s[%s]", disp, rnames64[r])
        ]
      else if (m == x64:lridx)
        [
          | ridx, scale, rbase, disp |
          @(ridx scale rbase . disp) = a;
          format("%s[%s*%d+%s]", itoea(disp), rnames64[ridx], scale,
                 rnames64[rbase])
        ]
      else if (m == x64:lqidx)
        [
          | ridx, scale, disp |
          @(ridx scale . disp) = a;
          format("%s[%s*%d]", itoea(disp), rnames64[ridx], scale)
        ]
      else if (m == x64:limm || m == x64:limm64)
        if (integer?(a))
          itoea(a)
        else if (cdr(a))
          format("2*%s+1", itoea(car(a)))
        else
          format("2*%s", itoea(car(a)))
      else if (m == x64:lfunction)
        format("fn[%s]", if (string?(a)) a else mc:fname(a))
      else if (m == x64:lcalled)
        format("code[%s]", if (string?(a)) a else mc:fname(a))
      else if (m == x64:lclosure)
        format("closure[%s]", mc:fname(a))
      else if (m == x64:lseclev)
        match! (a) [
          ,x64:sl_c => "seclev";
          ,x64:sl_mudlle => "seclev*2+1";
          ,x64:sl_maxlev => "maxseclev*2+1";
        ]
      else if (m == x64:lcst)
        format(if (integer?(a)) "%s[%#x]" else "%s[%0w]", mode[m], a)
      else if (m == x64:lglobal_index)
        match! (a) [
          (name . ,x64:gl_c) => format("%s[%s]", mode[m], name);
          (name . ,x64:gl_mudlle) => format("%s[%s]*2+1", mode[m], name);
        ]
      else if (m == x64:lindirect)
        format("%s[%s]", mode[m], eastr(a, rnames))
      else
        format("%s[%s]", mode[m], a);
    ];

  slabel = fn (label)
    itoa(x64:skip_label_alias(label)[x64:l_number]);

  x64:print_ins = fn (ins)
    [
      | op, a1, a2 |

      op = ins[x64:i_op];
      a1 = ins[x64:i_arg1];
      a2 = ins[x64:i_arg2];

      if (op == x64:op_jmp || op == x64:op_jmp32)
        dformat("%s %s", opname[op], slabel(a1))
      else if (op == x64:op_jcc)
        dformat("j%s %s", cnames[a2], slabel(a1))
      else if (op == x64:op_jcc32)
        dformat("j%s32 %s", cnames[a2], slabel(a1))
      else if (op == x64:op_setcc)
        dformat("set%s %s", cnames[cdr(a1)], eastr(a2, rnames8))
      else if (op == x64:op_cmovcc || op == x64:op_cmovcc32)
        [
          | r2, cc, rnames |
          @(,x64:lidx . (r2 . cc)) = a2;
          rnames = if (op == x64:op_cmovcc) rnames64 else rnames32;
          dformat("cmov%s %s,%s", cnames[cc], eastr(a1, rnames), rnames[r2])
        ]
      else if (op == x64:op_mov)
        [
          | rn2 |
          rn2 = match (car(a1))
            [
              ,x64:lseclev || ,x64:lglobal_index => rnames32;
              ,x64:limm => [
                if (match! (cdr(a1))
                    [
                      (n . _) => n & (1 << 30);
                      n => n & (1 << 31);
                    ])
                  rnames64
                else
                  rnames32;
              ];
              ,x64:limm64 => [
                if ((match! (cdr(a1))
                     [
                       (n . _) => n >> 31;
                       n => n >> 32;
                     ]) == 0)
                  rnames32
                else
                  rnames64;
              ];
              _ => rnames64;
            ];
          dformat("%s %s,%s", opname[op],
                  eastr(a1, rnames64), eastr(a2, rn2));
        ]
      else if (op == x64:op_movbyte || op == x64:op_orbyte
               || op == x64:op_xorbyte)
        dformat("%s %s,%s", opname[op], eastr(a1, rnames8),
                eastr(a2, rnames8))
      else if (op == x64:op_movzxbyte)
        dformat("%s %s,%s", opname[op], eastr(a1, rnames8),
                eastr(a2, rnames32))
      else if (op == x64:op_movzxword)
        dformat("%s %s,%s", opname[op], eastr(a1, rnames16),
                eastr(a2, rnames32))
      else if (op == x64:op_movzx32)
        dformat("%s %s,%s", opname[op], eastr(a1, rnames32),
                eastr(a2, rnames32))
      else if (op == x64:op_imul)
        [
          | imm2, r2 |
          @(,x64:lidx . (r2 . imm2)) = a2;
          dformat("%s %d,%s,%s", opname[op], imm2, eastr(a1, rnames64),
                  rnames64[r2]);
        ]
      else if (op == x64:op_lea32 || op == x64:op_add32)
        dformat("%s %s,%s", opname[op],
                eastr(a1, rnames64), eastr(a2, rnames32))
      else if (a1 == null)
        dformat("%s", opname[op])
      else if (a2 == null || op == x64:op_call)
        dformat("%s %s", opname[op], eastr(a1, rnames64))
      else
        dformat("%s %s,%s", opname[op],
                eastr(a1, rnames64), eastr(a2, rnames64));
    ];

];

];
