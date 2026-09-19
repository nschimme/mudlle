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

#ifndef COMPILE_H
#define COMPILE_H

#include "types.h"

struct mcallback;
struct mfile;
struct parser_config;

extern struct component *component_undefined;
extern struct component *component_true, *component_false;
#define component_one component_true

extern struct constant *constant_null;

bool interpret(value *result, seclev_t seclev, bool reload,
               const struct parser_config *pconfig);
struct closure *compile_code(struct mfile *f, seclev_t seclev);

/* returns a closure fn() that calls cb->f(cb->cbarg) */
struct closure *make_primitive_closure(
  struct mcallback *cb, const char *funcname, struct string *help,
  const char *filename, int line);

void compile_init(void);

struct compiler_state {
  struct compiler_state *prev;
  struct mfile *prev_mfile;
  struct alloc_block *block;
  const struct parser_config *pconfig;
};

void push_compiler_state(struct compiler_state *cstate,
                         const struct parser_config *pconfig);
void pop_compiler_state(struct compiler_state *cstate);

void get_compiler_line(struct strbuf *dst, size_t pos);

bool should_suppress_compiler_messages(void);

bool load_file(const char *fullname, seclev_t seclev, bool throw_errors,
               bool reload);
const char *loading_file(void);

#endif
