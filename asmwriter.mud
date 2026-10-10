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

/*
 * Assembly & IR Text Writer Abstraction for Mudlle
 */

library asmwriter

defines
  writer:new, writer:new_file, writer:new_string, writer:get_string,
  writer:write, writer:write_line, writer:format, writer:newline,
  writer:flush, writer:close, writer:port

[
  | w_port, w_file |

  w_port = 0;
  w_file = 1; // underlying file handle if any, or null

  writer:new = fn "port -> writer. Creates a writer wrapping an output port" ({oport,null} p = null)
    [
      if (p == null) p = stdout();
      vector(p, null)
    ];

  writer:new_file = fn "filename -> writer. Creates a writer outputting to a file" (string filename)
    [
      | f |
      f = file_open(filename, "w");
      vector(file_oport(f), f)
    ];

  writer:new_string = fn "-> writer. Creates a writer capturing output into a string" ()
    [
      vector(make_string_port(), null)
    ];

  writer:get_string = fn "writer -> string. Returns captured string from string writer" (vector w)
    [
      port_string(w[w_port])
    ];

  writer:port = fn "writer -> oport. Returns underlying output port" (vector w)
    [
      w[w_port]
    ];

  writer:write = fn "writer, string -> . Writes string to writer" (vector w, string s)
    [
      pprint(w[w_port], s)
    ];

  writer:write_line = fn "writer, string -> . Writes string followed by newline" (vector w, string s)
    [
      pprint(w[w_port], s);
      pprint(w[w_port], "\n")
    ];

  writer:format = fn "writer, fmt, args... -> . Formats and writes to writer" (vector w, string fmt, args...)
    [
      apply(pformat, w[w_port], fmt, args)
    ];

  writer:newline = fn "writer -> . Writes a newline to writer" (vector w)
    [
      pprint(w[w_port], "\n")
    ];

  writer:flush = fn "writer -> . Flushes writer port" (vector w)
    [
      if (w[w_file] != null)
        file_flush(w[w_file])
    ];

  writer:close = fn "writer -> . Closes writer port or file" (vector w)
    [
      if (w[w_file] != null)
        file_close(w[w_file])
    ];

];
