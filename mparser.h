/*
 * Copyright (c) 1993-2012 David Gay and Gustav Hållberg
 * All rights reserved.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose, without fee, and without written agreement is hereby granted,
 * provided that the above copyright notice and the following two paragraphs
 * appear in all copies of this software.
 *
 * IN NO EVENT SHALL DAVID GAY OR GUSTAV HALLBERG BE LIABLE TO ANY PARTY FOR
 * DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT
 * OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF DAVID GAY OR
 * GUSTAV HALLBERG HAVE BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * DAVID GAY AND GUSTAV HALLBERG SPECIFICALLY DISCLAIM ANY WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
 * FITNESS FOR A PARTICULAR PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS ON AN
 * "AS IS" BASIS, AND DAVID GAY AND GUSTAV HALLBERG HAVE NO OBLIGATION TO
 * PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.
 */

#ifndef MPARSER_H
#define MPARSER_H

#include <stdbool.h>
#include <stdio.h>

struct component;
struct constant;
struct mfile;

enum parser_mode {
  parser_mode_undefined,
  parser_mode_file,
  parser_mode_constant,
  parser_mode_storable,         /* "constant" with #ro, #rw, ... markup */
  parser_mode_any_expr,
  parser_mode_paren_expr,
  parser_mode_primary_expr
};

struct filename {
  const char *filename;
  const char *nicename;
};

struct parser_config {
  struct filename filename;
  enum parser_mode pmode;
  bool allow_empty, comments, purse_ast, user_syms, no_messages;
  FILE *f;                      /* NULL if nstrs/strs are used */
  size_t nstrs;
  const struct cstrlen *strs;
};

bool parse(struct mfile **f, const struct parser_config *pconfig);
bool parse_constant(struct constant **c, const struct parser_config *pconfig);
bool parse_expression(struct component **e, int *end_pos, bool allow_tail,
                      const struct parser_config *pconfig);

bool const_rwmode_is_dynamic(void);

struct loc {
  const struct filename *fname;
  int line, col;
  size_t pos;
};

#define YYLTYPE YYLTYPE
typedef struct {
  struct loc first;
  int last_line;
  int last_column;
  size_t last_pos;
} YYLTYPE;

#define INIT_LOC { .line = -1, .col = -1 }
#define NO_LOC &(const struct loc)INIT_LOC

#define LLOC_LOC(lloc) (&(lloc).first)

#define LLOC_LAST_LOC(lloc) &(const struct loc){        \
  .line  = (lloc).last_line,                            \
  .col   = (lloc).last_column,                          \
  .pos   = (lloc).last_pos,                             \
  .fname = (lloc).first.fname                           \
}

#endif /* MPARSER_H */
