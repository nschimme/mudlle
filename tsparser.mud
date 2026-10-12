/*
 * Copyright (c) 2026 Nils Schimmelmann
 * All rights reserved.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose, without fee, and without written agreement is hereby granted,
 * provided that the above copyright notice and the following two paragraphs
 * appear in all copies of this software.
 *
 * IN NO EVENT SHALL NILS SCHIMMELMANN BE LIABLE TO ANY PARTY FOR DIRECT,
 * INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE
 * USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF NILS SCHIMMELMANN HAS
 * BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * NILS SCHIMMELMANN SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 * PARTICULAR PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS"
 * BASIS, AND NILS SCHIMMELMANN HAS NO OBLIGATION TO PROVIDE MAINTENANCE,
 * SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.
 */

library tsparser
requires compiler, misc, sequences, vars

defines ts_tokenize, ts_parse_string

[
  | is_digit, is_alpha, is_alnum, ts_type_to_typeset, keywords_tab |

  is_digit = fn (c) (c >= ?0 && c <= ?9);
  is_alpha = fn (c) ((c >= ?a && c <= ?z) || (c >= ?A && c <= ?Z) || c == ?_ || c == 36);
  is_alnum = fn (c) (is_alpha(c) || is_digit(c));

  keywords_tab = make_table();
  keywords_tab["function"] = "keyword_function";
  keywords_tab["let"] = "keyword_let";
  keywords_tab["const"] = "keyword_const";
  keywords_tab["var"] = "keyword_var";
  keywords_tab["if"] = "keyword_if";
  keywords_tab["else"] = "keyword_else";
  keywords_tab["while"] = "keyword_while";
  keywords_tab["for"] = "keyword_for";
  keywords_tab["return"] = "keyword_return";
  keywords_tab["true"] = "keyword_true";
  keywords_tab["false"] = "keyword_false";
  keywords_tab["null"] = "keyword_null";
  keywords_tab["undefined"] = "keyword_undefined";
  keywords_tab["try"] = "keyword_try";
  keywords_tab["catch"] = "keyword_catch";
  keywords_tab["throw"] = "keyword_throw";
  keywords_tab["type"] = "keyword_type";
  keywords_tab["interface"] = "keyword_interface";
  keywords_tab["typeof"] = "keyword_typeof";
  keywords_tab["export"] = "keyword_export";

  ts_type_to_typeset = fn (name)
    [
      if (string_cmp(name, "number") == 0) TYPESET_ANY
      else if (string_cmp(name, "string") == 0) TSET_STR
      else if (string_cmp(name, "boolean") == 0) TSET_INT
      else if (string_cmp(name, "vector") == 0 || string_cmp(name, "Array") == 0) TSET_VEC
      else if (string_cmp(name, "object") == 0) TSET_TAB
      else TYPESET_ANY
    ];

  // Tokenizer implementation
  ts_tokenize = fn (code, fname)
    [
      | len, pos, line, col, tokens, make_tok, get_char, skip_ws_comments |

      len = slength(code);
      pos = 0;
      line = 1;
      col = 1;
      tokens = null;

      make_tok = fn (type, val, tline, tcol, tpos)
        vector(type, val, vector(tline, tcol, tpos));

      get_char = fn ()
        [
          if (pos >= len) exit<function> -1;
          | c |
          c = code[pos];
          ++pos;
          if (c == ?\n)
            [
              ++line;
              col = 1;
            ]
          else
            ++col;
          c
        ];

      skip_ws_comments = fn ()
        [
          loop
            [
              if (pos >= len) exit null;
              | c |
              c = code[pos];
              if (c == ?\  || c == ?\t || c == ?\r || c == ?\n)
                get_char()
              else if (c == ?/ && pos + 1 < len && code[pos + 1] == ?/)
                [
                  while (pos < len && code[pos] != ?\n)
                    get_char();
                ]
              else if (c == ?/ && pos + 1 < len && code[pos + 1] == ?*)
                [
                  get_char(); get_char();
                  while (pos < len && !(code[pos] == ?* && pos + 1 < len && code[pos + 1] == ?/))
                    get_char();
                  if (pos < len) [ get_char(); get_char(); ];
                ]
              else
                exit null;
            ]
        ];

      loop
        [
          skip_ws_comments();
          if (pos >= len)
            [
              tokens = make_tok("eof", null, line, col, pos) . tokens;
              exit lreverse!(tokens);
            ];

          | start_line, start_col, start_pos, c |
          start_line = line;
          start_col = col;
          start_pos = pos;
          c = get_char();

          // Identifiers and Keywords
          if (is_alpha(c))
            [
              | id_str, kw_type |
              while (pos < len && is_alnum(code[pos]))
                get_char();
              id_str = protect(substring(code, start_pos, pos - start_pos));

              kw_type = keywords_tab[id_str];
              if (kw_type == null)
                kw_type = "identifier";

              tokens = make_tok(kw_type, id_str, start_line, start_col, start_pos) . tokens;
            ]
          // Numbers
          else if (is_digit(c))
            [
              | num_str |
              while (pos < len && is_digit(code[pos]))
                get_char();
              if (pos < len && code[pos] == ?. && pos + 1 < len && is_digit(code[pos + 1]))
                [
                  get_char(); // '.'
                  while (pos < len && is_digit(code[pos]))
                    get_char();
                  num_str = substring(code, start_pos, pos - start_pos);
                  tokens = make_tok("number", atof(num_str), start_line, start_col, start_pos) . tokens;
                ]
              else
                [
                  num_str = substring(code, start_pos, pos - start_pos);
                  tokens = make_tok("number", atoi(num_str), start_line, start_col, start_pos) . tokens;
                ]
            ]
          // Strings ("..." or '...')
          else if (c == ?\" || c == ?')
            [
              | quote, str_start, str_val |
              quote = c;
              str_start = pos;
              while (pos < len && code[pos] != quote && code[pos] != ?\n)
                [
                  if (code[pos] == ?\\ && pos + 1 < len)
                    get_char();
                  get_char();
                ];
              str_val = protect(substring(code, str_start, pos - str_start));
              if (pos < len && code[pos] == quote)
                get_char();
              tokens = make_tok("string", str_val, start_line, start_col, start_pos) . tokens;
            ]
          // Template literals (`...`)
          else if (c == ?`)
            [
              | in_tmpl |
              in_tmpl = true;
              tokens = make_tok("lparen", "(", start_line, start_col, start_pos) . tokens;
              while (in_tmpl && pos < len)
                [
                  | chunk_start, chunk_val, chunk_line, chunk_col, chunk_pos |
                  chunk_line = line;
                  chunk_col = col;
                  chunk_pos = pos;
                  chunk_start = pos;
                  while (pos < len && code[pos] != ?` && !(code[pos] == 36 && pos + 1 < len && code[pos + 1] == ?\{))
                    [
                      if (code[pos] == ?\\ && pos + 1 < len)
                        get_char();
                      get_char();
                    ];
                  chunk_val = protect(substring(code, chunk_start, pos - chunk_start));
                  tokens = make_tok("string", chunk_val, chunk_line, chunk_col, chunk_pos) . tokens;

                  if (pos < len && code[pos] == ?`)
                    [
                      get_char();
                      in_tmpl = false;
                    ]
                  else if (pos < len && code[pos] == 36 && pos + 1 < len && code[pos + 1] == ?\{)
                    [
                      get_char(); get_char(); // consume '${'
                      tokens = make_tok("op_add", "+", line, col, pos) . tokens;
                      tokens = make_tok("identifier", "format", line, col, pos) . tokens;
                      tokens = make_tok("lparen", "(", line, col, pos) . tokens;
                      tokens = make_tok("string", "%s", line, col, pos) . tokens;
                      tokens = make_tok("comma", ",", line, col, pos) . tokens;

                      | brace_depth |
                      brace_depth = 1;
                      while (pos < len && brace_depth > 0)
                        [
                          skip_ws_comments();
                          if (pos >= len) exit null;
                          if (code[pos] == ?\{)
                            [ ++brace_depth; tokens = make_tok("lbrace", "{", line, col, pos) . tokens; get_char(); ]
                          else if (code[pos] == ?\})
                            [
                              --brace_depth;
                              if (brace_depth > 0)
                                tokens = make_tok("rbrace", "}", line, col, pos) . tokens;
                              get_char();
                            ]
                          else
                            [
                              // tokenize single token inside interpolation
                              | tok_start_l, tok_start_c, tok_start_p, tc |
                              tok_start_l = line; tok_start_c = col; tok_start_p = pos;
                              tc = get_char();
                              if (is_alpha(tc))
                                [
                                  while (pos < len && is_alnum(code[pos])) get_char();
                                  | id_str, kw |
                                  id_str = protect(substring(code, tok_start_p, pos - tok_start_p));
                                  kw = keywords_tab[id_str];
                                  if (kw == null) kw = "identifier";
                                  tokens = make_tok(kw, id_str, tok_start_l, tok_start_c, tok_start_p) . tokens;
                                ]
                              else if (is_digit(tc))
                                [
                                  while (pos < len && is_digit(code[pos])) get_char();
                                  | n_str |
                                  n_str = substring(code, tok_start_p, pos - tok_start_p);
                                  tokens = make_tok("number", atoi(n_str), tok_start_l, tok_start_c, tok_start_p) . tokens;
                                ]
                              else if (tc == ?\" || tc == ?')
                                [
                                  | q, s_st, s_v | q = tc; s_st = pos;
                                  while (pos < len && code[pos] != q && code[pos] != ?\n) [ if (code[pos] == ?\\ && pos + 1 < len) get_char(); get_char(); ];
                                  s_v = protect(substring(code, s_st, pos - s_st));
                                  if (pos < len && code[pos] == q) get_char();
                                  tokens = make_tok("string", s_v, tok_start_l, tok_start_c, tok_start_p) . tokens;
                                ]
                              else if (tc == ?+) tokens = make_tok("op_add", "+", tok_start_l, tok_start_c, tok_start_p) . tokens
                              else if (tc == ?-) tokens = make_tok("op_sub", "-", tok_start_l, tok_start_c, tok_start_p) . tokens
                              else if (tc == ?*) tokens = make_tok("op_mul", "*", tok_start_l, tok_start_c, tok_start_p) . tokens
                              else if (tc == ?/) tokens = make_tok("op_div", "/", tok_start_l, tok_start_c, tok_start_p) . tokens
                              else if (tc == ?.) tokens = make_tok("dot", ".", tok_start_l, tok_start_c, tok_start_p) . tokens
                              else if (tc == ?,) tokens = make_tok("comma", ",", tok_start_l, tok_start_c, tok_start_p) . tokens
                              else if (tc == ?\() tokens = make_tok("lparen", "(", tok_start_l, tok_start_c, tok_start_p) . tokens
                              else if (tc == ?\)) tokens = make_tok("rparen", ")", tok_start_l, tok_start_c, tok_start_p) . tokens
                              else tokens = make_tok("identifier", protect(substring(code, tok_start_p, 1)), tok_start_l, tok_start_c, tok_start_p) . tokens;
                            ];
                        ];
                      tokens = make_tok("rparen", ")", line, col, pos) . tokens;
                      tokens = make_tok("op_add", "+", line, col, pos) . tokens;
                    ];
                ];
              tokens = make_tok("rparen", ")", line, col, pos) . tokens;
            ]
          // Spaceship operator <=> or < / <= / <<
          else if (c == ?<)
            [
              if (pos + 1 < len && code[pos] == ?= && code[pos + 1] == ?>)
                [
                  get_char(); get_char();
                  tokens = make_tok("op_spaceship", "<=>", start_line, start_col, start_pos) . tokens;
                ]
              else if (pos < len && code[pos] == ?=)
                [
                  get_char();
                  tokens = make_tok("op_le", "<=", start_line, start_col, start_pos) . tokens;
                ]
              else if (pos < len && code[pos] == ?<)
                [
                  get_char();
                  tokens = make_tok("op_shl", "<<", start_line, start_col, start_pos) . tokens;
                ]
              else
                tokens = make_tok("op_lt", "<", start_line, start_col, start_pos) . tokens;
            ]
          // > or >= or >>
          else if (c == ?>)
            [
              if (pos < len && code[pos] == ?=)
                [
                  get_char();
                  tokens = make_tok("op_ge", ">=", start_line, start_col, start_pos) . tokens;
                ]
              else if (pos < len && code[pos] == ?>)
                [
                  get_char();
                  tokens = make_tok("op_shr", ">>", start_line, start_col, start_pos) . tokens;
                ]
              else
                tokens = make_tok("op_gt", ">", start_line, start_col, start_pos) . tokens;
            ]
          // = or == or === or =>
          else if (c == ?=)
            [
              if (pos + 1 < len && code[pos] == ?= && code[pos + 1] == ?=)
                [
                  get_char(); get_char();
                  tokens = make_tok("op_eq", "===", start_line, start_col, start_pos) . tokens;
                ]
              else if (pos < len && code[pos] == ?=)
                [
                  get_char();
                  tokens = make_tok("op_eq", "==", start_line, start_col, start_pos) . tokens;
                ]
              else if (pos < len && code[pos] == ?>)
                [
                  get_char();
                  tokens = make_tok("op_arrow", "=>", start_line, start_col, start_pos) . tokens;
                ]
              else
                tokens = make_tok("op_assign", "=", start_line, start_col, start_pos) . tokens;
            ]
          // ! or != or !==
          else if (c == ?!)
            [
              if (pos + 1 < len && code[pos] == ?= && code[pos + 1] == ?=)
                [
                  get_char(); get_char();
                  tokens = make_tok("op_ne", "!==", start_line, start_col, start_pos) . tokens;
                ]
              else if (pos < len && code[pos] == ?=)
                [
                  get_char();
                  tokens = make_tok("op_ne", "!=", start_line, start_col, start_pos) . tokens;
                ]
              else
                tokens = make_tok("op_not", "!", start_line, start_col, start_pos) . tokens;
            ]
          // & or &&
          else if (c == ?&)
            [
              if (pos < len && code[pos] == ?&)
                [
                  get_char();
                  tokens = make_tok("op_and", "&&", start_line, start_col, start_pos) . tokens;
                ]
              else
                tokens = make_tok("op_bitand", "&", start_line, start_col, start_pos) . tokens;
            ]
          // | or ||
          else if (c == ?|)
            [
              if (pos < len && code[pos] == ?|)
                [
                  get_char();
                  tokens = make_tok("op_or", "||", start_line, start_col, start_pos) . tokens;
                ]
              else
                tokens = make_tok("op_bitor", "|", start_line, start_col, start_pos) . tokens;
            ]
          // ? or ?. or ??
          else if (c == ??)
            [
              if (pos < len && code[pos] == ?.)
                [
                  get_char();
                  tokens = make_tok("op_optchain", "?.", start_line, start_col, start_pos) . tokens;
                ]
              else if (pos < len && code[pos] == ??)
                [
                  get_char();
                  tokens = make_tok("op_nullish", "??", start_line, start_col, start_pos) . tokens;
                ]
              else
                tokens = make_tok("question", "?", start_line, start_col, start_pos) . tokens;
            ]
          // Single character tokens
          else if (c == ?+) tokens = make_tok("op_add", "+", start_line, start_col, start_pos) . tokens
          else if (c == ?-) tokens = make_tok("op_sub", "-", start_line, start_col, start_pos) . tokens
          else if (c == ?*) tokens = make_tok("op_mul", "*", start_line, start_col, start_pos) . tokens
          else if (c == ?/) tokens = make_tok("op_div", "/", start_line, start_col, start_pos) . tokens
          else if (c == ?%) tokens = make_tok("op_rem", "%", start_line, start_col, start_pos) . tokens
          else if (c == ?^) tokens = make_tok("op_bitxor", "^", start_line, start_col, start_pos) . tokens
          else if (c == ?~) tokens = make_tok("op_bitnot", "~", start_line, start_col, start_pos) . tokens
          else if (c == ?\() tokens = make_tok("lparen", "(", start_line, start_col, start_pos) . tokens
          else if (c == ?\)) tokens = make_tok("rparen", ")", start_line, start_col, start_pos) . tokens
          else if (c == ?\{) tokens = make_tok("lbrace", "{", start_line, start_col, start_pos) . tokens
          else if (c == ?\}) tokens = make_tok("rbrace", "}", start_line, start_col, start_pos) . tokens
          else if (c == ?\[) tokens = make_tok("lbracket", "[", start_line, start_col, start_pos) . tokens
          else if (c == ?\]) tokens = make_tok("rbracket", "]", start_line, start_col, start_pos) . tokens
          else if (c == ?,) tokens = make_tok("comma", ",", start_line, start_col, start_pos) . tokens
          else if (c == ?:) tokens = make_tok("colon", ":", start_line, start_col, start_pos) . tokens
          else if (c == ?;) tokens = make_tok("semicolon", ";", start_line, start_col, start_pos) . tokens
          else if (c == ?.) tokens = make_tok("dot", ".", start_line, start_col, start_pos) . tokens
          else
            mc:error("unexpected character '%c' at %s:%d:%d", c, fname, start_line, start_col);
        ]
    ];

  // Parser implementation
  ts_parse_string = fn (code, fname)
    [
      | tokens, tok_pos, cur_tok, match_tok, consume_tok, tok_loc,
        parse_expr, parse_assign, parse_binary, parse_primary,
        parse_stmt_list, parse_type, gen_tmp_var, tmp_var_count,
        make_const, make_recall, make_assign, make_call, make_builtin, make_block, make_closure |

      tmp_var_count = 0;
      gen_tmp_var = fn (prefix)
        [
          ++tmp_var_count;
          format("_%s_%d", prefix, tmp_var_count)
        ];

      tokens = list_to_vector(ts_tokenize(code, fname));
      tok_pos = 0;

      cur_tok = fn () tokens[tok_pos];

      tok_loc = fn () cur_tok()[2];

      consume_tok = fn ()
        [
          | tok |
          tok = cur_tok();
          if (tok_pos + 1 < vlength(tokens))
            ++tok_pos;
          tok
        ];

      match_tok = fn (type)
        if (string_cmp(cur_tok()[0], type) == 0)
          [ consume_tok(); true ]
        else
          false;

      // AST Node constructors
      make_const = fn (loc, val)
        indexed_vector(
          mc:c_class  . mc:c_constant,
          mc:c_loc    . loc,
          mc:c_cvalue . val);

      make_recall = fn (loc, sym_str)
        indexed_vector(
          mc:c_class   . mc:c_recall,
          mc:c_loc     . loc,
          mc:c_rsymbol . sym_str);

      make_assign = fn (loc, sym_str, val_comp)
        indexed_vector(
          mc:c_class   . mc:c_assign,
          mc:c_loc     . loc,
          mc:c_asymbol . sym_str,
          mc:c_avalue  . val_comp,
          mc:c_asymloc . loc);

      make_call = fn (loc, fn_comp, args_list)
        indexed_vector(
          mc:c_class   . mc:c_execute,
          mc:c_loc     . loc,
          mc:c_efnargs . fn_comp . args_list);

      make_builtin = fn (loc, bfn, args_list)
        indexed_vector(
          mc:c_class . mc:c_builtin,
          mc:c_loc   . loc,
          mc:c_bfn   . bfn,
          mc:c_bargs . args_list);

      make_block = fn (loc, locals_list, seq_list)
        indexed_vector(
          mc:c_class     . mc:c_block,
          mc:c_loc       . loc,
          mc:c_klocals   . locals_list,
          mc:c_ksequence . seq_list);

      make_closure = fn (loc, ret_typeset, help, fullargs, body_comp, fn_name)
        [
          | nargs, nopt, vararg |
          nargs = llength(fullargs);
          nopt = 0;
          vararg = false;
          indexed_vector(
            mc:c_class           . mc:c_closure,
            mc:c_loc             . loc,
            mc:c_freturn_typeset . ret_typeset,
            mc:c_fhelp           . help,
            mc:c_ffullargs       . fullargs,
            mc:c_farginfo        . indexed_sequence(
              mc:arginfo_nargs    . nargs,
              mc:arginfo_noptargs . nopt,
              mc:arginfo_vararg   . vararg),
            mc:c_fvalue          . body_comp,
            mc:c_ffilename       . fname,
            mc:c_fnicename       . (if (string?(fn_name)) fn_name else "fn"),
            mc:c_fendloc         . loc)
        ];

      parse_type = fn ()
        if (match_tok("colon"))
          [
            | t_set |
            t_set = 0;
            loop
              [
                if (string_cmp(cur_tok()[0], "identifier") == 0)
                  [
                    | t_tok |
                    t_tok = consume_tok();
                    t_set = t_set | ts_type_to_typeset(t_tok[1]);
                    if (string_cmp(cur_tok()[0], "lbracket") == 0)
                      [
                        consume_tok();
                        match_tok("rbracket");
                        t_set = t_set | TSET_VEC;
                      ];
                    if (string_cmp(cur_tok()[0], "op_lt") == 0)
                      [
                        consume_tok();
                        while (string_cmp(cur_tok()[0], "op_gt") != 0 && string_cmp(cur_tok()[0], "eof") != 0)
                          consume_tok();
                        match_tok("op_gt");
                      ];
                  ]
                else if (string_cmp(cur_tok()[0], "lbrace") == 0)
                  [
                    consume_tok();
                    while (string_cmp(cur_tok()[0], "rbrace") != 0 && string_cmp(cur_tok()[0], "eof") != 0)
                      consume_tok();
                    match_tok("rbrace");
                    t_set = t_set | TSET_TAB;
                  ]
                else
                  consume_tok();

                if (string_cmp(cur_tok()[0], "op_bitor") == 0 || string_cmp(cur_tok()[0], "op_bitand") == 0)
                  consume_tok()
                else
                  exit (if (t_set == 0) TYPESET_ANY else t_set);
              ]
          ]
        else
          TYPESET_ANY;

      // Recursive descent parsing
      parse_primary = fn ()
        [
          | tok, loc |
          tok = cur_tok();
          loc = tok[2];

          if (match_tok("op_sub"))
            [
              | sub_expr |
              sub_expr = parse_binary(8);
              make_builtin(loc, mc:b_negate, list(sub_expr))
            ]
          else if (match_tok("op_add"))
            parse_binary(8)
          else if (match_tok("op_not"))
            [
              | not_expr |
              not_expr = parse_binary(8);
              make_builtin(loc, mc:b_eq, list(not_expr, make_const(loc, false)))
            ]
          else if (match_tok("number")) make_const(loc, tok[1])
          else if (match_tok("string") || match_tok("template_literal")) make_const(loc, tok[1])
          else if (match_tok("keyword_true")) make_const(loc, true)
          else if (match_tok("keyword_false")) make_const(loc, false)
          else if (match_tok("keyword_null") || match_tok("keyword_undefined")) make_const(loc, null)
          else if (string_cmp(tok[0], "identifier") == 0)
            [
              consume_tok();
              make_recall(loc, tok[1])
            ]
          else if (match_tok("keyword_typeof"))
            [
              | operand, type_loc, seq, v_tv |
              type_loc = loc;
              v_tv = gen_tmp_var("tv");
              operand = parse_binary(8);
              seq = list(
                make_assign(type_loc, v_tv, operand),
                make_builtin(type_loc, mc:b_ifelse, list(
                  make_call(type_loc, make_recall(type_loc, "string?"), list(make_recall(type_loc, v_tv))),
                  make_const(type_loc, "string"),
                  make_builtin(type_loc, mc:b_ifelse, list(
                    make_builtin(type_loc, mc:b_logical_or, list(
                      make_call(type_loc, make_recall(type_loc, "integer?"), list(make_recall(type_loc, v_tv))),
                      make_call(type_loc, make_recall(type_loc, "float?"), list(make_recall(type_loc, v_tv)))
                    )),
                    make_const(type_loc, "number"),
                    make_builtin(type_loc, mc:b_ifelse, list(
                      make_call(type_loc, make_recall(type_loc, "function?"), list(make_recall(type_loc, v_tv))),
                      make_const(type_loc, "function"),
                      make_builtin(type_loc, mc:b_ifelse, list(
                        make_builtin(type_loc, mc:b_logical_or, list(
                          make_call(type_loc, make_recall(type_loc, "vector?"), list(make_recall(type_loc, v_tv))),
                          make_call(type_loc, make_recall(type_loc, "table?"), list(make_recall(type_loc, v_tv)))
                        )),
                        make_const(type_loc, "object"),
                        make_const(type_loc, "undefined")
                      ))
                    ))
                  ))
                ))
              );
              make_block(
                type_loc,
                list(vector(v_tv, TYPESET_ANY, type_loc)),
                seq
              )
            ]
          // Parenthesized expression or Arrow function
          else if (match_tok("lparen"))
            [
              | params, saved_pos, ret_type |
              saved_pos = tok_pos - 1;
              params = null;

              if (string_cmp(cur_tok()[0], "rparen") != 0)
                [
                  loop
                    [
                      | p_tok, p_loc, p_type |
                      p_tok = cur_tok();
                      p_loc = p_tok[2];
                      if (string_cmp(p_tok[0], "identifier") == 0)
                        [
                          consume_tok();
                          p_type = parse_type();
                          params = vector(vector(format("%s", p_tok[1]), p_type, p_loc), null, null, null, null) . params;
                        ];
                      if (!match_tok("comma")) exit null;
                    ]
                ];
              match_tok("rparen");
              ret_type = parse_type();

              if (string_cmp(cur_tok()[0], "op_arrow") == 0)
                [
                  consume_tok(); // =>
                  | body |
                  if (string_cmp(cur_tok()[0], "lbrace") == 0)
                    body = parse_stmt_list("rbrace")
                  else
                    body = parse_expr();
                  make_closure(loc, ret_type, null, lreverse!(params), body, "arrow")
                ]
              else
                [
                  // Not an arrow function: rewind and parse parenthesized expr
                  tok_pos = saved_pos;
                  match_tok("lparen");
                  | expr |
                  expr = parse_expr();
                  match_tok("rparen");
                  expr
                ]
            ]
          // Array literal [a, b, c]
          else if (match_tok("lbracket"))
            [
              | elements |
              elements = null;
              if (string_cmp(cur_tok()[0], "rbracket") != 0)
                [
                  loop
                    [
                      elements = parse_expr() . elements;
                      if (!match_tok("comma")) exit null;
                    ]
                ];
              match_tok("rbracket");
              make_builtin(loc, mc:b_vector, lreverse!(elements))
            ]
          // Object literal { key: val, ... }
          else if (match_tok("lbrace"))
            [
              | pairs, obj_loc |
              pairs = null;
              obj_loc = loc;
              if (string_cmp(cur_tok()[0], "rbrace") != 0)
                [
                  loop
                    [
                      | k_tok, key_str, val_expr |
                      k_tok = cur_tok();
                      if (string_cmp(k_tok[0], "identifier") == 0 || string_cmp(k_tok[0], "string") == 0)
                        [
                          consume_tok();
                          key_str = k_tok[1];
                          match_tok("colon");
                          val_expr = parse_expr();
                          pairs = (key_str . val_expr) . pairs;
                        ];
                      if (!match_tok("comma")) exit null;
                    ]
                ];
              match_tok("rbrace");

              // Build object as table creation block:
              // let _obj = make_table(); _obj["k1"] = v1; _obj
              | seq, table_recall, v_obj |
              v_obj = gen_tmp_var("obj");
              table_recall = make_call(obj_loc, make_recall(obj_loc, "make_table"), null);
              seq = list(make_assign(obj_loc, v_obj, table_recall));
              lforeach(fn (@(k . v)) [
                seq = make_builtin(obj_loc, mc:b_set, list(make_recall(obj_loc, v_obj), make_const(obj_loc, k), v)) . seq;
              ], lreverse!(pairs));
              seq = make_recall(obj_loc, v_obj) . seq;
              make_block(obj_loc, list(vector(v_obj, TYPESET_ANY, obj_loc)), lreverse!(seq))
            ]
          else
            [
              | tok_val |
              tok_val = cur_tok()[1];
              if (!string?(tok_val)) tok_val = cur_tok()[0];
              mc:error("syntax error near '%s' at %s:%d:%d", tok_val, fname, mc:loc_line(loc), mc:loc_column(loc));
              make_const(loc, null)
            ]
        ];

      // Binary expressions parser (Pratt / Operator Precedence)
      parse_binary = fn (int min_prec)
        [
          | left, loc |
          left = parse_primary();

          loop
            [
              | tok, op_type, prec, bfn, right |
              tok = cur_tok();
              op_type = tok[0];
              loc = tok[2];

              // Member access: obj.prop or obj[idx] or obj?.prop
              if (string_cmp(op_type, "dot") == 0 || string_cmp(op_type, "op_optchain") == 0)
                [
                  consume_tok();
                  | prop_tok |
                  prop_tok = consume_tok();
                  left = make_builtin(loc, mc:b_ref, list(left, make_const(loc, prop_tok[1])));
                ]
              else if (string_cmp(op_type, "lbracket") == 0)
                [
                  consume_tok();
                  | idx_expr |
                  idx_expr = parse_expr();
                  match_tok("rbracket");
                  left = make_builtin(loc, mc:b_ref, list(left, idx_expr));
                ]
              else if (string_cmp(op_type, "lparen") == 0)
                [
                  consume_tok();
                  | args |
                  args = null;
                  if (string_cmp(cur_tok()[0], "rparen") != 0)
                    [
                      loop
                        [
                          args = parse_expr() . args;
                          if (!match_tok("comma")) exit null;
                        ]
                    ];
                  match_tok("rparen");
                  left = make_call(loc, left, lreverse!(args));
                ]
              else
                [
                  prec = if (string_cmp(op_type, "op_mul") == 0 || string_cmp(op_type, "op_div") == 0 || string_cmp(op_type, "op_rem") == 0) 7
                    else if (string_cmp(op_type, "op_add") == 0 || string_cmp(op_type, "op_sub") == 0) 6
                    else if (string_cmp(op_type, "op_shl") == 0 || string_cmp(op_type, "op_shr") == 0) 5
                    else if (string_cmp(op_type, "op_lt") == 0 || string_cmp(op_type, "op_le") == 0 || string_cmp(op_type, "op_gt") == 0 || string_cmp(op_type, "op_ge") == 0 || string_cmp(op_type, "op_spaceship") == 0) 4
                    else if (string_cmp(op_type, "op_eq") == 0 || string_cmp(op_type, "op_ne") == 0) 3
                    else if (string_cmp(op_type, "op_bitand") == 0 || string_cmp(op_type, "op_bitxor") == 0 || string_cmp(op_type, "op_bitor") == 0) 2
                    else if (string_cmp(op_type, "op_and") == 0 || string_cmp(op_type, "op_or") == 0 || string_cmp(op_type, "op_nullish") == 0) 1
                    else 0;

                  if (prec < min_prec) exit left;

                  consume_tok();

                  bfn = if (string_cmp(op_type, "op_add") == 0) mc:b_add
                    else if (string_cmp(op_type, "op_sub") == 0) mc:b_subtract
                    else if (string_cmp(op_type, "op_mul") == 0) mc:b_multiply
                    else if (string_cmp(op_type, "op_div") == 0) mc:b_divide
                    else if (string_cmp(op_type, "op_rem") == 0) mc:b_remainder
                    else if (string_cmp(op_type, "op_eq") == 0) mc:b_eq
                    else if (string_cmp(op_type, "op_ne") == 0) mc:b_ne
                    else if (string_cmp(op_type, "op_lt") == 0) mc:b_lt
                    else if (string_cmp(op_type, "op_le") == 0) mc:b_le
                    else if (string_cmp(op_type, "op_gt") == 0) mc:b_gt
                    else if (string_cmp(op_type, "op_ge") == 0) mc:b_ge
                    else if (string_cmp(op_type, "op_and") == 0) mc:b_logical_and
                    else if (string_cmp(op_type, "op_or") == 0) mc:b_logical_or
                    else if (string_cmp(op_type, "op_bitand") == 0) mc:b_bitand
                    else if (string_cmp(op_type, "op_bitor") == 0) mc:b_bitor
                    else if (string_cmp(op_type, "op_bitxor") == 0) mc:b_bitxor
                    else if (string_cmp(op_type, "op_shl") == 0) mc:b_shift_left
                    else if (string_cmp(op_type, "op_shr") == 0) mc:b_shift_right
                    else null;

                  right = parse_binary(prec + 1);

                  // Spaceship Operator <=>
                  if (string_cmp(op_type, "op_spaceship") == 0)
                    [
                      | sp_loc, seq, cmp_lt, cmp_eq, v_spa, v_spb |
                      sp_loc = loc;
                      v_spa = gen_tmp_var("spa");
                      v_spb = gen_tmp_var("spb");
                      cmp_lt = make_builtin(sp_loc, mc:b_lt, list(make_recall(sp_loc, v_spa), make_recall(sp_loc, v_spb)));
                      cmp_eq = make_builtin(sp_loc, mc:b_eq, list(make_recall(sp_loc, v_spa), make_recall(sp_loc, v_spb)));

                      seq = list(
                        make_assign(sp_loc, v_spa, left),
                        make_assign(sp_loc, v_spb, right),
                        make_builtin(sp_loc, mc:b_ifelse, list(
                          cmp_lt,
                          make_const(sp_loc, -1),
                          make_builtin(sp_loc, mc:b_ifelse, list(
                            cmp_eq,
                            make_const(sp_loc, 0),
                            make_const(sp_loc, 1)
                          ))
                        ))
                      );

                      left = make_block(
                        sp_loc,
                        list(vector(v_spa, TYPESET_ANY, sp_loc), vector(v_spb, TYPESET_ANY, sp_loc)),
                        seq
                      );
                    ]
                  // Polymorphic arithmetic & comparisons (+, -, *, /, <, <=, >, >=)
                  else if (string_cmp(op_type, "op_add") == 0
                           || string_cmp(op_type, "op_sub") == 0
                           || string_cmp(op_type, "op_mul") == 0
                           || string_cmp(op_type, "op_div") == 0
                           || string_cmp(op_type, "op_lt") == 0
                           || string_cmp(op_type, "op_le") == 0
                           || string_cmp(op_type, "op_gt") == 0
                           || string_cmp(op_type, "op_ge") == 0)
                    [
                      | num_loc, seq, is_flt, float_fn, float_branch, int_branch, v_na, v_nb |
                      num_loc = loc;
                      v_na = gen_tmp_var("na");
                      v_nb = gen_tmp_var("nb");
                      float_fn = if (string_cmp(op_type, "op_add") == 0) "fadd"
                        else if (string_cmp(op_type, "op_sub") == 0) "fsub"
                        else if (string_cmp(op_type, "op_mul") == 0) "fmul"
                        else if (string_cmp(op_type, "op_div") == 0) "fdiv"
                        else "fcmp";

                      is_flt = make_builtin(num_loc, mc:b_logical_or, list(
                        make_call(num_loc, make_recall(num_loc, "float?"), list(make_recall(num_loc, v_na))),
                        make_call(num_loc, make_recall(num_loc, "float?"), list(make_recall(num_loc, v_nb)))
                      ));

                      if (string_cmp(float_fn, "fcmp") == 0)
                        [
                          | fcmp_call, rel_bfn |
                          fcmp_call = make_call(num_loc, make_recall(num_loc, "fcmp"), list(make_recall(num_loc, v_na), make_recall(num_loc, v_nb)));
                          rel_bfn = if (string_cmp(op_type, "op_lt") == 0) mc:b_lt
                            else if (string_cmp(op_type, "op_le") == 0) mc:b_le
                            else if (string_cmp(op_type, "op_gt") == 0) mc:b_gt
                            else mc:b_ge;

                          float_branch = make_builtin(num_loc, rel_bfn, list(fcmp_call, make_const(num_loc, 0)));
                          int_branch = make_builtin(num_loc, rel_bfn, list(make_recall(num_loc, v_na), make_recall(num_loc, v_nb)));
                        ]
                      else
                        [
                          float_branch = make_call(num_loc, make_recall(num_loc, float_fn), list(make_recall(num_loc, v_na), make_recall(num_loc, v_nb)));
                          int_branch = make_builtin(num_loc, bfn, list(make_recall(num_loc, v_na), make_recall(num_loc, v_nb)));
                        ];

                      seq = list(
                        make_assign(num_loc, v_na, left),
                        make_assign(num_loc, v_nb, right),
                        make_builtin(num_loc, mc:b_ifelse, list(
                          is_flt,
                          float_branch,
                          int_branch
                        ))
                      );

                      left = make_block(
                        num_loc,
                        list(vector(v_na, TYPESET_ANY, num_loc), vector(v_nb, TYPESET_ANY, num_loc)),
                        seq
                      );
                    ]
                  else if (string_cmp(op_type, "op_nullish") == 0)
                    [
                      // Nullish coalescing: let _na = left; if (_na != null) _na else right
                      | null_loc, seq, cmp_ne, v_na |
                      null_loc = loc;
                      v_na = gen_tmp_var("na");
                      cmp_ne = make_builtin(null_loc, mc:b_ne, list(make_recall(null_loc, v_na), make_const(null_loc, null)));
                      seq = list(
                        make_assign(null_loc, v_na, left),
                        make_builtin(null_loc, mc:b_ifelse, list(
                          cmp_ne,
                          make_recall(null_loc, v_na),
                          right
                        ))
                      );
                      left = make_block(
                        null_loc,
                        list(vector(v_na, TYPESET_ANY, null_loc)),
                        seq
                      );
                    ]
                  else if (bfn != null)
                    left = make_builtin(loc, bfn, list(left, right))
                  else
                    left = make_builtin(loc, mc:b_add, list(left, right));
                ]
            ]
        ];

      // Assignment & Expression
      parse_assign = fn ()
        [
          | left, loc |
          loc = tok_loc();
          left = parse_binary(1);

          if (match_tok("op_assign"))
            [
              | right |
              right = parse_assign();
              if (left[mc:c_class] == mc:c_recall)
                make_assign(loc, left[mc:c_rsymbol], right)
              else if (left[mc:c_class] == mc:c_builtin && left[mc:c_bfn] == mc:b_ref)
                [
                  // Index set: arr[idx] = val
                  | arr_comp, idx_comp |
                  arr_comp = car(left[mc:c_bargs]);
                  idx_comp = cadr(left[mc:c_bargs]);
                  make_builtin(loc, mc:b_set, list(arr_comp, idx_comp, right))
                ]
              else
                left
            ]
          else
            left
        ];

      parse_expr = fn () parse_assign();

      | top_defines, has_exports |
      top_defines = null;
      has_exports = false;

      // Statement list parser collecting block-scoped local variables and statement components
      parse_stmt_list = fn (string end_token)
        [
          | block_loc, block_locals, block_seq, top_level |
          block_loc = tok_loc();
          block_locals = null;
          block_seq = null;
          top_level = string_cmp(end_token, "eof") == 0;

          if (string_cmp(end_token, "rbrace") == 0)
            match_tok("lbrace");

          while (string_cmp(cur_tok()[0], end_token) != 0 && string_cmp(cur_tok()[0], "eof") != 0)
            [
              | tok, loc |
              tok = cur_tok();
              loc = tok[2];

              // Export Statement: export function ... | export let/const/var ... | export { ... }
              if (match_tok("keyword_export"))
                [
                  has_exports = true;
                  | exp_tok |
                  exp_tok = cur_tok();
                  if (string_cmp(exp_tok[0], "keyword_function") == 0)
                    [
                      consume_tok(); // function
                      | fn_name, params, ret_type, body_s, closure_comp |
                      fn_name = cur_tok()[1];
                      consume_tok(); // fn name
                      if (string_cmp(cur_tok()[0], "op_lt") == 0)
                        [
                          consume_tok();
                          while (string_cmp(cur_tok()[0], "op_gt") != 0 && string_cmp(cur_tok()[0], "eof") != 0)
                            consume_tok();
                          match_tok("op_gt");
                        ];
                      match_tok("lparen");
                      params = null;
                      if (string_cmp(cur_tok()[0], "rparen") != 0)
                        [
                          loop
                            [
                              | p_tok, p_loc, p_type |
                              p_tok = cur_tok();
                              p_loc = p_tok[2];
                              if (string_cmp(p_tok[0], "identifier") == 0)
                                [
                                  consume_tok();
                                  p_type = parse_type();
                                  params = vector(vector(format("%s", p_tok[1]), p_type, p_loc), null, null, null, null) . params;
                                ];
                              if (!match_tok("comma")) exit null;
                            ]
                        ];
                      match_tok("rparen");
                      ret_type = parse_type();
                      body_s = parse_stmt_list("rbrace");

                      top_defines = format("%s", fn_name) . top_defines;
                      closure_comp = make_closure(loc, ret_type, null, lreverse!(params), body_s, fn_name);
                      block_seq = make_assign(loc, fn_name, closure_comp) . block_seq;
                    ]
                  else if (string_cmp(exp_tok[0], "keyword_let") == 0 || string_cmp(exp_tok[0], "keyword_const") == 0 || string_cmp(exp_tok[0], "keyword_var") == 0)
                    [
                      consume_tok();
                      loop
                        [
                          | v_tok, v_name, v_loc, v_type, val_expr |
                          v_tok = cur_tok();
                          v_loc = v_tok[2];
                          if (string_cmp(v_tok[0], "identifier") == 0)
                            [
                              consume_tok();
                              v_name = v_tok[1];
                              v_type = parse_type();
                              top_defines = format("%s", v_name) . top_defines;

                              if (match_tok("op_assign"))
                                [
                                  val_expr = parse_expr();
                                  block_seq = make_assign(v_loc, v_name, val_expr) . block_seq;
                                ];
                            ];
                          if (!match_tok("comma")) exit null;
                        ];
                      match_tok("semicolon");
                    ]
                  else if (match_tok("lbrace"))
                    [
                      loop
                        [
                          | e_id |
                          if (string_cmp(cur_tok()[0], "identifier") == 0)
                            [
                              e_id = consume_tok()[1];
                              top_defines = format("%s", e_id) . top_defines;
                            ];
                          if (!match_tok("comma")) exit null;
                        ];
                      match_tok("rbrace");
                      if (match_tok("semicolon")) null;
                    ]
                ]
              // Variable Declaration: let / const / var x = expr
              else if (string_cmp(tok[0], "keyword_let") == 0 || string_cmp(tok[0], "keyword_const") == 0 || string_cmp(tok[0], "keyword_var") == 0)
                [
                  consume_tok();
                  loop
                    [
                      | v_tok, v_name, v_loc, v_type, val_expr |
                      v_tok = cur_tok();
                      v_loc = v_tok[2];
                      if (string_cmp(v_tok[0], "identifier") == 0)
                        [
                          consume_tok();
                          v_name = v_tok[1];
                          v_type = parse_type();
                          if (!top_level || has_exports)
                            block_locals = vector(format("%s", v_name), v_type, v_loc) . block_locals
                          else
                            top_defines = format("%s", v_name) . top_defines;

                          if (match_tok("op_assign"))
                            [
                              val_expr = parse_expr();
                              block_seq = make_assign(v_loc, v_name, val_expr) . block_seq;
                            ];
                        ];
                      if (!match_tok("comma")) exit null;
                    ];
                  match_tok("semicolon");
                ]
              // If Statement: if (cond) stmt1 else stmt2
              else if (match_tok("keyword_if"))
                [
                  match_tok("lparen");
                  | cond, then_s, else_s |
                  cond = parse_expr();
                  match_tok("rparen");
                  then_s = if (string_cmp(cur_tok()[0], "lbrace") == 0) parse_stmt_list("rbrace") else parse_expr();
                  if (string_cmp(cur_tok()[0], "semicolon") == 0) match_tok("semicolon");
                  if (match_tok("keyword_else"))
                    [
                      else_s = if (string_cmp(cur_tok()[0], "lbrace") == 0) parse_stmt_list("rbrace") else parse_expr();
                      if (string_cmp(cur_tok()[0], "semicolon") == 0) match_tok("semicolon");
                      block_seq = make_builtin(loc, mc:b_ifelse, list(cond, then_s, else_s)) . block_seq;
                    ]
                  else
                    block_seq = make_builtin(loc, mc:b_if, list(cond, then_s)) . block_seq;
                ]
              // While Statement: while (cond) stmt
              else if (match_tok("keyword_while"))
                [
                  match_tok("lparen");
                  | cond, body |
                  cond = parse_expr();
                  match_tok("rparen");
                  body = if (string_cmp(cur_tok()[0], "lbrace") == 0) parse_stmt_list("rbrace") else parse_expr();
                  if (string_cmp(cur_tok()[0], "semicolon") == 0) match_tok("semicolon");
                  block_seq = make_builtin(loc, mc:b_while, list(cond, body)) . block_seq;
                ]
              // For Statement: for (init; cond; post) stmt
              else if (match_tok("keyword_for"))
                [
                  match_tok("lparen");
                  | init_s, cond_e, post_e, body_s, loop_comp, f_tok |
                  f_tok = cur_tok();
                  if (string_cmp(f_tok[0], "keyword_let") == 0 || string_cmp(f_tok[0], "keyword_const") == 0 || string_cmp(f_tok[0], "keyword_var") == 0)
                    [
                      consume_tok();
                      | v_tok, v_name, v_loc, v_type, val_expr |
                      v_tok = cur_tok();
                      v_loc = v_tok[2];
                      if (string_cmp(v_tok[0], "identifier") == 0)
                        [
                          consume_tok();
                          v_name = v_tok[1];
                          v_type = parse_type();
                          block_locals = vector(format("%s", v_name), v_type, v_loc) . block_locals;
                          if (match_tok("op_assign"))
                            [
                              val_expr = parse_expr();
                              init_s = make_assign(v_loc, v_name, val_expr);
                            ]
                          else
                            init_s = make_const(v_loc, null);
                        ]
                      else
                        init_s = make_const(v_loc, null);
                      match_tok("semicolon");
                    ]
                  else
                    [
                      init_s = parse_expr();
                      match_tok("semicolon");
                    ];

                  cond_e = parse_expr();
                  match_tok("semicolon");
                  post_e = parse_expr();
                  match_tok("rparen");
                  body_s = if (string_cmp(cur_tok()[0], "lbrace") == 0) parse_stmt_list("rbrace") else parse_expr();

                  // desugar to: init; while (cond) { body; post; }
                  loop_comp = make_builtin(loc, mc:b_while, list(cond_e, make_block(loc, null, list(body_s, post_e))));
                  block_seq = loop_comp . (init_s . block_seq);
                ]
              // Return Statement: return expr;
              else if (match_tok("keyword_return"))
                [
                  | ret_expr |
                  if (string_cmp(cur_tok()[0], "semicolon") != 0 && string_cmp(cur_tok()[0], "rbrace") != 0 && string_cmp(cur_tok()[0], "eof") != 0)
                    ret_expr = parse_expr()
                  else
                    ret_expr = make_const(loc, null);
                  match_tok("semicolon");
                  block_seq = indexed_vector(
                    mc:c_class       . mc:c_exit,
                    mc:c_loc         . loc,
                    mc:c_ename       . "function",
                    mc:c_eexpression . ret_expr) . block_seq;
                ]
              // Try/Catch Statement: try { ... } catch (err) { ... }
              else if (match_tok("keyword_try"))
                [
                  | try_body, err_tok, err_name, err_loc, catch_body, try_fn, catch_fn |
                  try_body = parse_stmt_list("rbrace");
                  match_tok("keyword_catch");
                  match_tok("lparen");
                  err_tok = cur_tok();
                  err_name = err_tok[1];
                  err_loc = err_tok[2];
                  consume_tok(); // err_name
                  match_tok("rparen");
                  catch_body = parse_stmt_list("rbrace");

                  try_fn = make_closure(loc, TYPESET_ANY, null, null, try_body, "try_body");
                  catch_fn = make_closure(loc, TYPESET_ANY, null, list(vector(vector(format("%s", err_name), TYPESET_ANY, err_loc), null, null, null, null)), catch_body, "catch_body");

                  block_seq = make_call(loc, make_recall(loc, "trap_error"), list(try_fn, catch_fn, make_recall(loc, "call_trace_off"), make_const(loc, null))) . block_seq;
                ]
              // Throw Statement: throw expr;
              else if (match_tok("keyword_throw"))
                [
                  | throw_expr |
                  throw_expr = parse_expr();
                  if (string_cmp(cur_tok()[0], "semicolon") == 0) match_tok("semicolon");
                  block_seq = make_call(loc, make_recall(loc, "error"), list(throw_expr)) . block_seq;
                ]
              // Type Alias Statement: type Name = ...;
              else if (match_tok("keyword_type"))
                [
                  | brace_depth |
                  brace_depth = 0;
                  while ((brace_depth > 0 || string_cmp(cur_tok()[0], "semicolon") != 0) && string_cmp(cur_tok()[0], "eof") != 0)
                    [
                      if (string_cmp(cur_tok()[0], "lbrace") == 0) ++brace_depth
                      else if (string_cmp(cur_tok()[0], "rbrace") == 0) --brace_depth;
                      consume_tok();
                    ];
                  if (match_tok("semicolon")) null;
                ]
              // Interface Statement: interface Name { ... }
              else if (match_tok("keyword_interface"))
                [
                  consume_tok(); // name
                  if (string_cmp(cur_tok()[0], "lbrace") == 0)
                    [
                      consume_tok();
                      | depth |
                      depth = 1;
                      while (depth > 0 && string_cmp(cur_tok()[0], "eof") != 0)
                        [
                          if (string_cmp(cur_tok()[0], "lbrace") == 0) ++depth
                          else if (string_cmp(cur_tok()[0], "rbrace") == 0) --depth;
                          consume_tok();
                        ];
                    ]
                ]
              // Function Declaration: function foo<T>(a: number): string { ... }
              else if (match_tok("keyword_function"))
                [
                  | fn_name, params, ret_type, body_s, closure_comp |
                  fn_name = cur_tok()[1];
                  consume_tok(); // fn name
                  if (string_cmp(cur_tok()[0], "op_lt") == 0)
                    [
                      consume_tok();
                      while (string_cmp(cur_tok()[0], "op_gt") != 0 && string_cmp(cur_tok()[0], "eof") != 0)
                        consume_tok();
                      match_tok("op_gt");
                    ];
                  match_tok("lparen");
                  params = null;
                  if (string_cmp(cur_tok()[0], "rparen") != 0)
                    [
                      loop
                        [
                          | p_tok, p_loc, p_type |
                          p_tok = cur_tok();
                          p_loc = p_tok[2];
                          if (string_cmp(p_tok[0], "identifier") == 0)
                            [
                              consume_tok();
                              p_type = parse_type();
                              params = vector(vector(format("%s", p_tok[1]), p_type, p_loc), null, null, null, null) . params;
                            ];
                          if (!match_tok("comma")) exit null;
                        ]
                    ];
                  match_tok("rparen");
                  ret_type = parse_type();
                  body_s = parse_stmt_list("rbrace");

                  if (!top_level || has_exports)
                    block_locals = vector(format("%s", fn_name), TYPESET_ANY, loc) . block_locals
                  else
                    top_defines = format("%s", fn_name) . top_defines;

                  closure_comp = make_closure(loc, ret_type, null, lreverse!(params), body_s, fn_name);
                  block_seq = make_assign(loc, fn_name, closure_comp) . block_seq;
                ]
              // Nested Block Statement: { ... }
              else if (string_cmp(cur_tok()[0], "lbrace") == 0)
                [
                  block_seq = parse_stmt_list("rbrace") . block_seq;
                ]
              // Empty statement
              else if (match_tok("semicolon"))
                null
              // Expression statement
              else
                [
                  | expr |
                  expr = parse_expr();
                  match_tok("semicolon");
                  block_seq = expr . block_seq;
                ]
            ];

          if (string_cmp(end_token, "rbrace") == 0)
            match_tok("rbrace");

          make_block(block_loc, lreverse!(block_locals), lreverse!(block_seq))
        ];

      // Top-level statements parsing
      | top_body |
      top_body = parse_stmt_list("eof");
      vector(top_body, has_exports)
    ];

];
