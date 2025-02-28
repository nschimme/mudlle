/*
 * Copyright (c) 1993-2012 David Gay and Gustav H�llberg
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

#ifndef LEXER_H
#define LEXER_H

#include <stdbool.h>
#include <stdio.h>

extern const char *lexer_filename;
extern const char *lexer_nicename;

struct reader_state {
  const char *filename;
  const char *nicename;
  bool force_constant;
};

int yylex(void);

void read_from_strings(const char *const *strs, const char *afilename,
                       const char *anicename, bool force_constant);
void read_from_file(FILE *f, const char *afilename, const char *anicename);
void save_reader_state(struct reader_state *state);
void restore_reader_state(const struct reader_state *state);

bool allow_comma_expression(void);

const struct loc *lexer_location(void);

#endif
