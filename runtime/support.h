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

#ifndef RUNTIME_SUPPORT_H
#define RUNTIME_SUPPORT_H

#include "../error.h"

extern const struct prim_op *const global_read_ext;
extern const struct prim_op *const global_write_ext;

void support_init(void);

noreturn void global_runtime_error(enum runtime_error error, bool is_write,
                                   ulong goffset, value val);

enum {
  mp_mode_file         = 0,
  mp_mode_any_expr     = 1,
  mp_mode_paren_expr   = 2,
  mp_mode_primary_expr = 3,
  /* end mudlle const */
  mp_mode_mask         = P(2) - 1,
  /* start mudlle const */
  mp_pure_ast          = P(2),
  mp_user_symbols      = P(3),
  mp_allow_tail        = P(4),
  /* end mudlle const */
  mp_all_flags         = P(5) - 1
  /* start mudlle const */
};

#endif /* RUNTIME_SUPPORT_H */
