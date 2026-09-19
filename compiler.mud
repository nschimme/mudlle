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

library compiler
requires vars, misc, sequences

defines

  mc:c_freturn_itype, mc:c_fvar,
  mc:c_flocals, mc:c_flocals_write, mc:c_fclosure, mc:c_fclosure_write,
  mc:c_fglobals, mc:c_fglobals_write, mc:c_fnoescape, mc:c_fnargs_var,
  mc:c_fnumber, mc:c_fmisc, mc:c_fnvars, mc:c_fallvars,

  mc:c_fm_argsbase, mc:c_fm_closurebase, mc:c_fm_globalsbase,
  mc:c_fm_regs_callee,

  mc:b_car, mc:b_cdr,
  mc:b_slength, mc:b_vlength, mc:b_iadd, mc:b_typeof, mc:b_loop_count,
  mc:b_max_loop_count, mc:b_symbol_name, mc:b_symbol_get, mc:b_vector,
  mc:b_sequence, mc:b_pcons, mc:b_ffs, mc:b_funcarg,
  mc:builtins, mc:builtin_names, mc:builtin_long_name,

  mc:a_builtins, mc:a_constants, mc:a_subfns, mc:a_globals, mc:a_kglobals,
  mc:a_primitives, mc:a_primops, mc:a_linenos, mc:a_npcrel, mc:a_seclevs,
  mc:a_kglobal_code, mc:a_info_fields,
  mc:subfn_closure, mc:subfn_code, mc:subfn_called,

  mc:fname, mc:error, mc:warning, mc:note, mc:handle_messages,
  mc:markup_fn, mc:markup_number, mc:markup_type, mc:markup_var,

  mc:mv_gidx, mc:mv_name, mc:mv_used, mc:mv_loc,
  mc:muse_read, mc:muse_write,

  mc:register_call_check, mc:lookup_call_check,

  mc:register_display_fn,

  mc:apply_functions,

  mc:register_inference_fns, mc:infer_types, mc:show_type_info,

  mc:function_closure_args,

  mc:vainfo_scratch, mc:vainfo_caller, mc:vainfo_callee, mc:vainfo_spill,

  mc:source_code, mc:source_file,

  mc:regclass_none, mc:regclass_scratch, mc:regclass_early_scratch,
  mc:regclass_caller

reads mc:this_filenames, mc:this_module, mc:this_function
writes mc:erred

[
  | message, m_filename, m_nicename, simple_fname, c_loc, c_ffilename,
    c_fnicename, c_fvar, v_name, pending_messages,
    message_count, infer_types, show_type_info |

  infer_types = show_type_info = fn (x) 0;

  message_count = 0;

  // the variable lists above are lists of (name . type) from mudlle_parse,
  // and vector(gidx, name, used) after mstart()
  mc:mv_gidx = 0;
  mc:mv_name = 1;
  mc:mv_used = 2;
    // flags in mc:mv_used
    mc:muse_read  = 1;
    mc:muse_write = 2;
  mc:mv_loc = 3;                // (line . column)


  // Component structure:
  //   It is a vector whose first element is one of mc:c_assign, c_recall, etc.
  //   See FOR_COMPONENT_CLASSES in tree.h
  //   The remaining elements depend on the value of the first, as follows:

  // mc:c_class			// class of component
  // mc:c_loc			// location (line . column) of component

  // mc:c_assign - assignment statement
  //  mc:c_asymbol		// var name (string, after phase1: var)
  //  mc:c_avalue		// value (component)

  // mc:c_recall - value of a variable
  //  mc:c_rsymbol		// var name (string, after phase1: var)

  // mc:c_constant - a constant
  //  mc:c_cvalue		// value of constant (any type)

  // mc:c_closure - a function
  //  mc:c_freturn_typeset	// return value typeset
  //  mc:c_fhelp		// help string (string or null)
  //  mc:c_fargs		// argument names (list of [string, type, loc]
  //				//     after phase1: list of var)
  //  mc:c_fvalue		// function value (component)
  //  mc:c_ffilename		// filename on disk (string)
  //  mc:c_fnicename		// pretty-printed filename (string)
  //  mc:c_fendloc		// function end location (return type check)

   // Added by phase1
   | ccf |
   ccf = mc:c_closure_fields;
   mc:c_freturn_itype  = ccf + 0; // return value itypes
   mc:c_fvar           = ccf + 1; // variable in which function is stored
   mc:c_flocals        = ccf + 2; // local variables (list of var)
   mc:c_flocals_write  = ccf + 3; // local variables (list of var) (those
                                  // written)
   mc:c_fclosure       = ccf + 4; // closure variables (list of var)
   mc:c_fclosure_write = ccf + 5; // closure variables (list of var) (those
                                  // written)
   mc:c_fglobals       = ccf + 6; // the global variables used (list of var)
   mc:c_fglobals_write = ccf + 7; // the global variables written (list of var)

   mc:c_fnoescape      = ccf + 8; // true if no calls from here escapes (does
                                  // not call op_noescape); may still write
                                  // closure variables in mc:c_fclosure_write
   mc:c_fnargs_var     = ccf + 9; // variable holding the number of arguments

   // Set by phase2:
   mc:c_fnumber = 0;		// a unique number for this closure (int)

   // Set by phase 4:
   mc:c_fmisc = ccf + 10;	// miscellaneous info
    mc:c_fm_argsbase = 0;	// true if function needs arguments base
    mc:c_fm_closurebase = 1;	// true if function needs closure base
    mc:c_fm_globalsbase = 2;	// true if function needs globals base
    mc:c_fm_regs_callee = 3;	// callee registers used by the backend
   mc:c_fnvars = ccf + 11;	// number of vars (global, closure, local)
				// used (int, phase3)
   mc:c_fallvars = ccf + 12;	// all vars (global, closure, local) used
				// (vector, phase3)

  // mc:c_execute - execute a function
  //  mc:c_efnargs		// list of function, followed by arguments
  //				// (list of component)

  // mc:c_builtin - execute a primitive
  //  mc:c_bfn			// number of primitive (integer, see below)
  //  mc:c_bargs		// arguments (list of component)

  // mc:c_block - a block
  //  mc:c_klocals		// local variables (list of string)
  //  mc:c_ksequence		// code (list of component)

  // mc:c_labeled - labeled expression
  //  mc:c_lname		// label name (string)
  //  mc:c_lexpression		// expression value (component)

  // mc:c_exit
  //  mc:c_ename		// label name (string or null)
  //  mc:c_eexpression		// exit expression (component)

  // language primitives, some are functions, others are control structures

  // Compiler generated ops
  mc:b_car            = mc:parser_builtins + 0;
  mc:b_cdr            = mc:parser_builtins + 1;
  mc:b_slength        = mc:parser_builtins + 2;
  mc:b_vlength        = mc:parser_builtins + 3;
  mc:b_iadd           = mc:parser_builtins + 4;
  mc:b_typeof         = mc:parser_builtins + 5;
  mc:b_loop_count     = mc:parser_builtins + 6;
  mc:b_max_loop_count = mc:parser_builtins + 7;
  mc:b_symbol_name    = mc:parser_builtins + 8;
  mc:b_symbol_get     = mc:parser_builtins + 9;
  mc:b_vector         = mc:parser_builtins + 10;
  mc:b_sequence       = mc:parser_builtins + 11;
  mc:b_pcons          = mc:parser_builtins + 12;
  mc:b_ffs            = mc:parser_builtins + 13;
  mc:b_funcarg        = mc:parser_builtins + 14;
  mc:builtins         = mc:parser_builtins + 15;

  mc:builtin_names = indexed_sequence(
    mc:b_logical_or     . "||",
    mc:b_logical_and    . "&&",
    mc:b_eq             . "==",
    mc:b_ne             . "!=",
    mc:b_lt             . "<",
    mc:b_ge             . ">=",
    mc:b_le             . "<=",
    mc:b_gt             . ">",
    mc:b_bitor          . "|",
    mc:b_bitxor         . "^",
    mc:b_bitand         . "&",
    mc:b_shift_left     . "<<",
    mc:b_shift_right    . ">>",
    mc:b_add            . "+",
    mc:b_subtract       . "-",
    mc:b_multiply       . "*",
    mc:b_divide         . "/",
    mc:b_remainder      . "%",
    mc:b_negate         . "-",
    mc:b_logical_not    . "!",
    mc:b_bitnot         . "~",
    mc:b_ifelse         . "if-else",
    mc:b_if             . "if",
    mc:b_while          . "while",
    mc:b_loop           . "loop",
    mc:b_ref            . "ref",
    mc:b_set            . "set",
    mc:b_cons           . ".",
    mc:b_logical_xor    . "^^",
    mc:b_paren          . "()",
    mc:b_assign         . "=",
    // end of mc:parser_builtins
    mc:b_car            . "car",
    mc:b_cdr            . "cdr",
    mc:b_slength        . "slength",
    mc:b_vlength        . "vlength",
    mc:b_iadd           . "i+",
    mc:b_typeof         . "typeof",
    mc:b_loop_count     . "loop_count",
    mc:b_max_loop_count . "max_loop_count",
    mc:b_symbol_name    . "symbol_name",
    mc:b_symbol_get     . "symbol_get",
    mc:b_vector         . "vector",
    mc:b_sequence       . "sequence",
    mc:b_pcons          . "pcons",
    mc:b_ffs            . "ffs",
    mc:b_funcarg        . "funcarg");
  assert(vlength(mc:builtin_names) == mc:builtins);
  assert(vforall?(string?, mc:builtin_names));

  | fmarkup, long_names |
  fmarkup = fn (string s) fn () mc:markup_fn(s) + "()";

  long_names = indexed_sequence(
    mc:b_logical_or     . "logical OR (||)",
    mc:b_logical_and    . "logical AND (&&)",
    mc:b_eq             . "equal to (==)",
    mc:b_ne             . "not equal to (!=)",
    mc:b_lt             . "less than (<)",
    mc:b_ge             . "less than or equal to (<=)",
    mc:b_le             . "greater than (>)",
    mc:b_gt             . "greater than or equal to (>=)",
    mc:b_bitor          . "bitwise inclusive OR (|)",
    mc:b_bitxor         . "bitwise exclusive OR (^)",
    mc:b_bitand         . "bitwise AND (&)",
    mc:b_shift_left     . "bitwise shift left (<<)",
    mc:b_shift_right    . "bitwise shift right (>>)",
    mc:b_add            . "addition (+)",
    mc:b_subtract       . "subtraction (-)",
    mc:b_multiply       . "multiplication (*)",
    mc:b_divide         . "division (/)",
    mc:b_remainder      . "remainder (%)",
    mc:b_negate         . "negation (-)",
    mc:b_logical_not    . "logical NOT (!)",
    mc:b_bitnot         . "bitwise NOT (~)",
    mc:b_ifelse         . "if-else",
    mc:b_if             . "if",
    mc:b_while          . "while",
    mc:b_loop           . "loop",
    mc:b_ref            . "lookup index ([...])",
    mc:b_set            . "indexed assignment",
    mc:b_cons           . fmarkup("cons"),
    mc:b_logical_xor    . "logical exclusive OR (^^)",
    mc:b_paren          . "parentheses",
    mc:b_assign         . "assignment (=)",
    // end of mc:parser_builtins
    mc:b_car            . fmarkup("car"),
    mc:b_cdr            . fmarkup("cdr"),
    mc:b_slength        . fmarkup("slength"),
    mc:b_vlength        . fmarkup("vlength"),
    mc:b_iadd           . "addition (+)",
    mc:b_typeof         . fmarkup("typeof"),
    mc:b_loop_count     . fmarkup("loop_count"),
    mc:b_max_loop_count . fmarkup("max_loop_count"),
    mc:b_symbol_name    . fmarkup("symbol_name"),
    mc:b_symbol_get     . fmarkup("symbol_get"),
    mc:b_vector         . fmarkup("vector"),
    mc:b_sequence       . fmarkup("sequence"),
    mc:b_pcons          . fmarkup("pcons"),
    mc:b_ffs            . fmarkup("ffs"),
    mc:b_funcarg        . "funcarg");
  assert(vlength(long_names) == mc:builtins);
  assert(vforall?(fn (x) string?(x) || function?(x), mc:builtin_names));

  mc:builtin_long_name = fn (int bop)
    [
      assert(bop >= 0);
      match! (long_names[bop])
        [
          {string} s => s;
          {function} f => f()
        ];
    ];

  // Format of information returned with assembled code
  mc:a_builtins       = 0;
  mc:a_constants      = 1;
  mc:a_subfns         = 2;      // list of vector(tgt, ofs, mc:subfn_xxx)
    mc:subfn_closure = 0;
    mc:subfn_code    = 1;
    mc:subfn_called  = 2;
  mc:a_globals        = 3;
  mc:a_kglobals       = 4;
  mc:a_primitives     = 5;
  mc:a_primops        = 6;
  mc:a_linenos        = 7;
  mc:a_npcrel         = 8;
  mc:a_seclevs        = 9;
  mc:a_kglobal_code   = 10;
  mc:a_info_fields    = 11;

  // register allocation info
  mc:vainfo_scratch = 0;
  mc:vainfo_caller  = 1;
  mc:vainfo_callee  = 2;
  mc:vainfo_spill   = 3;

  // strange unload effects (see comment before linkun in link.mud)
  m_filename  = mc:m_filename;
  m_nicename  = mc:m_nicename;
  c_loc       = mc:c_loc;
  c_ffilename = mc:c_ffilename;
  c_fnicename = mc:c_fnicename;
  c_fvar      = mc:c_fvar;
  v_name      = mc:v_name;

  // [ function f-index argv-index ] where argv-index null means no arguments;
  // argument indices are one-based
  mc:apply_functions = '[
    [,apply                    1 2]
    [,session                  1 ()]
    [,with_forbid              2 ()]
    [,with_maxseclevel         2 ()]
    [,with_minlevel            2 ()]
    [,with_output              2 ()]
    [,with_unlimited_execution 1 ()]
  ];
  vforeach(fn (@[p ...]) [
    assert(primitive_flags(p) & OP_APPLY);
    lforeach(fn (sig) assert(sig[-1] == ?x), primitive_type(p))
  ], mc:apply_functions);

  simple_fname = fn (ifn)
    if (c_fvar < vlength(ifn) && ifn[c_fvar])
      ifn[c_fvar][v_name]
    else
      "fn";

  mc:fname = fn (ifn)
    // Types: ifn: intemediate function
    // Returns: A printable name for ifn
    [
      | fname |
      if (use_nicename())
        fname = ifn[c_fnicename];
      if (!string?(fname))
        fname = ifn[c_ffilename];
      format("%s[%s:%d]", simple_fname(ifn), fname,
             mc:loc_line(ifn[c_loc]))
    ];

  | get_line |

  mc:source_code = fn (string str) fn (int pos)
    [
      | nl |
      nl = string_index_offset(str, ?\n, pos);
      if (nl < 0)
        string_tail(str, pos)
      else
        substring(str, pos, nl - pos)
    ];

  mc:source_file = fn (string fname) fn (int pos)
    [
      | op, ppos |
      op = make_string_port();
      ppos = 0;
      for (;;)
        [
          | str, nread, nl, toread |
          toread = 512;
          print_file_part(op, fname, pos, toread);
          nread = string_port_length(op) - ppos;
          str = port_substring(op, ppos, nread);
          nl = string_index(str, ?\n);
          if (nl >= 0)
            exit<function> port_substring(op, 0, ppos + nl);
          if (nread < toread)
            exit<function> port_string(op);
          ppos += nread
        ];
    ];

  | compiler_display |
  compiler_display = fn (string s)
    [
      display(s);
      newline()
    ];

  mc:register_display_fn = fn """`f -> . Register `f(`s) as the display\
 function for compiler messages.""" (function f)
    [
      assert(minlevel() >= seclevel());
      assert(callable?(f, 1));
      compiler_display = f;
    ];

  // 'type' is null for errors
  message = fn ({null,string} type, string fmt, vector args, append?)
    [
      | msg, filename, loc, func, nicename |

      loc = mc:no_loc;
      if (vector?(mc:this_function))
        [
          filename = mc:this_function[c_ffilename];
          nicename = mc:this_function[c_fnicename];
          loc = mc:get_loc();
          if (mc:loc_line(loc) <= 0)
            loc = mc:this_function[c_loc];
          func = mc:markup_fn(simple_fname(mc:this_function))
        ]
      else if (vector?(mc:this_module))
        [
          filename = mc:this_module[m_filename];
          nicename = mc:this_module[m_nicename];
          loc = mc:get_loc()
        ]
      else if (pair?(mc:this_filenames))
        @(filename . nicename) = mc:this_filenames;

      if (!string?(filename))
        filename = "?";

      | use_fname? |
      use_fname? = ((!use_nicename() || !string?(nicename))
                    && string_cmp(filename, nicename) != 0);

      msg = make_string_port();

      | col |
      col = mc:loc_column(loc);
      if (mc:loc_line(loc) >= 0 && col > 0 && get_line != null
          && port_interactive?(stdout()))
        [
          | line, col0 |
          col0 = col - 1;
          line = get_line(mc:loc_pos(loc) - col0);
          if (line != null && slength(line) > 0)
            [
              pprint(msg, line);
              pputc(msg, ?\n);
              // copy space characters verbatim in case they contain tabs
              for (| i, c | i = 0; i < col0; ++i)
                pputc(msg, if (cspace?(c = line[i])) c else ?\ );
              pprint(msg, "^\n");
            ];
        ];

      | locstr |
      locstr = if (use_fname?) filename else nicename;
      locstr += ":";
      if (mc:loc_line(loc) >= 0)
        [
          locstr += format("%d:", mc:loc_line(loc));
          if (col > 0)
            locstr += format("%d:", col);
        ];
      pprint(msg, mc:markup_str_loc(locstr));

      if (type == null)
        pputc(msg, ?\ )
      else
        pformat(msg, " %s: ", type);
      if (use_fname?)
        pformat(msg, "[%s] ", nicename);
      if (func != null)
        pformat(msg, "%s: ", func);

      | msgstr |
      msgstr = apply(format, fmt, args);
      if (type == null)
        msgstr = mc:markup_str_error(msgstr);
      pprint(msg, msgstr);
      msg = port_string(msg);

      if (get_line == null)
        compiler_display(msg)
      else if (append?)
        [
          | prev |
          prev = car(pending_messages)[3];
          if (!pair?(prev))
            prev = list(prev);
          car(pending_messages)[3] = msg . prev;
        ]
      else
        pending_messages = vector(filename, loc, message_count++, msg)
          . pending_messages
    ];

  mc:error = fn (string fmt, args...)
    [
      message(null, fmt, args, false);
      mc:erred = true;
    ];

  mc:warning = fn (string fmt, args...)
    message("warning", fmt, args, false);

  mc:note = fn (string fmt, args...)
    message("note", fmt, args, true);

  mc:handle_messages = fn ({function,null} linef)
    [
      get_line = linef;
      if (linef != null)
        exit<function> null;

      | last |
      lforeach(fn (v) [
        | msg |
        msg = v[3];
        if (equal?(msg, last))
          exit<function> null;
        last = msg;
        if (pair?(msg))
          lforeach(compiler_display, lreverse!(msg))
        else
          compiler_display(msg)
      ], lqsort(fn (a, b) [
        | c |
        c = string_cmp(a[0], b[0]);
        if (c != 0)
          exit<function> c < 0;
        c = mc:loc_line(a[1]) - mc:loc_line(b[1]);
        if (c != 0)
          exit<function> c < 0;
        c = mc:loc_column(a[1]) - mc:loc_column(b[1]);
        if (c != 0)
          exit<function> c < 0;
        a[2] < b[2]
      ], pending_messages));
      pending_messages = null;
    ];

  | call_checks |

  call_checks = make_table();

  mc:register_call_check = fn """`f0 `f1 -> . Register `f1 as a call\
 verification function for function `f0.
When the compiler detects a call to `f0 (as identified by its function name),\
 `f1(`f2, `l) is called, where `f2 is the called function (likely the same as\
 `f0) and `l is the list of arguments in the call.
Each argument is either a bitwise OR of `itype_xxx constants (for an argument\
 where the value is not known), or cons(`itype_xxx, `x) when the value is\
 known to be `x.
`f1 should return a warning string, or `false if the call seems correct.
N.b., this function is called from `with_unlimited_execution(), so take care\
 not to write infinite loops or recursions.""" (function f, function test)
    call_checks[function_name(f)] = test;

  mc:lookup_call_check = fn (function f)
    [
      | n |
      if (n = function_name(f))
        call_checks[n]
      else
        null
    ];

  mc:register_inference_fns = fn (function inftypes, function showtypes)
    [
      infer_types = inftypes;
      show_type_info = showtypes;
    ];

  mc:infer_types = fn (x) infer_types(x);
  mc:show_type_info = fn (x) show_type_info(x);

  // returns function_arguments(f)
  mc:function_closure_args = fn (vector f)
    [
      | fullargs, v |
      fullargs = f[mc:c_ffullargs];
      v = make_vector(llength(fullargs));
      for (|i| i = 0; fullargs != null; ++i)
        [
          | farg, var, ts, name |
          @(farg . fullargs) = fullargs;
          @[var ts _] = farg[mc:fullarg_arg];
          name = var[mc:v_name];
          if (slength(name) == 0 || name[0] == ?%)
            name = false;
          v[i] = '(,name . ,ts);
        ];

      check_immutable(protect(v))
    ];

  mc:markup_fn = fn ({function,string} x)
    [
      if (function?(x))
        x = function_name(x);
      mc:markup_str_fn(x)
    ];
  mc:markup_number = fn ({string,int} x)
    [
      if (integer?(x))
        x = itoa(x);
      mc:markup_str_number(x);
    ];
  mc:markup_var = mc:markup_str_var;
  mc:markup_type = mc:markup_str_type;

  mc:regclass_none          = 0; // no additional registers used
  mc:regclass_scratch       = 1; // clobbers scratch registers
  mc:regclass_early_scratch = 2; // inputs must not be in scratch
  mc:regclass_caller        = 3; // clobbers caller-save registers

];
