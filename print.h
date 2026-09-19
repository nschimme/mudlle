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

#ifndef PRINT_H
#define PRINT_H

#include "ports.h"

enum fmt_flag {
  fmt_display           = 0,
  fmt_write             = 1,
  fmt_examine           = 2,
  fmt_constant          = 3,
  /* end mudlle const */
  fmt_level_mask        = 3,
  /* start mudlle const */

  fmt_base_bin          = 1 << 2,
  fmt_base_oct          = 2 << 2,
  fmt_base_dec          = 0 << 2, /* default */
  fmt_base_hex          = 3 << 2,
  /* end mudlle const */
  fmt_base_mask         = 3 << 2,
  /* start mudlle const */

  fmt_flag_ascii        = P(4),
  fmt_flag_quote        = P(5),
  fmt_flag_truncate     = P(6),
  fmt_flag_nref         = P(7),
  fmt_flag_replace_gone = P(8),
  fmt_flag_storable     = P(11), /* support store/restore with fmt_constant */
  /* end mudlle const */
  fmt_flag_full_code    = P(9), /* allow arbitrary-length code output */
  fmt_mudlle_flags      = (fmt_flag_ascii | fmt_flag_quote | fmt_flag_truncate
                           | fmt_flag_nref | fmt_flag_replace_gone
                           | fmt_flag_storable),
  /* start mudlle const */

  fmt_nest_shift        = 16,
  fmt_nest_max          = P(5) - 1,
  fmt_nest_mask         = fmt_nest_max << fmt_nest_shift
};

/* end mudlle const */


bool output_value_cut(struct oport *f, value v, size_t maxlen, unsigned flags);
void output_value(struct oport *f, enum fmt_flag level, value v,
                  bool use_ascii);

void print_init(void);

void describe_fn(struct strbuf *sb, value v);

/* use 'len' SIZE_MAX for NUL-terminated 'str' */
void sb_write_string(struct strbuf *sb, const char *str, size_t len,
                     bool use_ascii);

void sb_add_seclevel(struct strbuf *sb, int lev);

bool mudout_wants_ascii(void);

#endif
