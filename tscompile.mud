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

library tscompile
requires compiler, link, misc, sequences, tsparser, vars

defines ts_parse, ts_compile, ts_eval, load_ts

reads mc:compile, mc:linkrun

[
  ts_parse = fn (string code, {string,null} filename = "ts_eval.ts")
    [
      if (filename == null) filename = "ts_eval.ts";

      | cbody |
      cbody = ts_parse_string(code, filename);

      indexed_vector(
        mc:m_class    . 0,
        mc:m_name     . filename,
        mc:m_requires . null,
        mc:m_defines  . null,
        mc:m_reads    . null,
        mc:m_writes   . null,
        mc:m_statics  . null,
        mc:m_body     . cbody,
        mc:m_filename . filename,
        mc:m_nicename . filename,
        mc:m_loc      . mc:no_loc,
        mc:m_endloc   . mc:no_loc,
        mc:m_comments . null)
    ];

  ts_compile = fn (string code, {string,null} filename = "ts_eval.ts")
    [
      if (filename == null) filename = "ts_eval.ts";

      | mod, get_src, compiled |
      mod = ts_parse(code, filename);
      get_src = mc:source_code(code);

      compiled = mc:compile(mod, false, seclevel(), get_src);

      if (!compiled)
        exit<function> false;

      compiled
    ];

  ts_eval = fn (string code, {string,null} filename = "ts_eval.ts")
    [
      | compiled, res |
      compiled = ts_compile(code, filename);
      if (!compiled)
        exit<function> false;

      res = mc:linkrun(compiled, seclevel(), true);
      if (pair?(res)) last_element(res) else res
    ];

  load_ts = fn (string filename)
    [
      | port, code |
      port = make_string_port();
      print_file(port, filename);
      code = port_string(port);
      if (!string?(code))
        exit<function> false;

      ts_eval(code, filename)
    ];

];
