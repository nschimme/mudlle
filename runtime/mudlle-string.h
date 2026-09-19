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

#ifndef RUNTIME_MUDLLE_STRING_H
#define RUNTIME_MUDLLE_STRING_H

#include "check-types.h"

bool string_equalp(struct string *a, struct string *b);
value string_append(struct string *s1, struct string *s2,
                    const struct prim_op *op);
value string_ref(struct string *str, value midx, const struct prim_op *op);
value mudlle_string_set(struct string *str, value midx, value mc,
                        const struct prim_op *op);

int mudlle_string_isearch(struct string *haystack, struct string *needle);

int mudlle_strcmp(struct string *a, struct string *b);
int mudlle_istrcmp(struct string *a, struct string *b);

value concat_strings(long count, struct string **strings);

void string_init(void);

#ifdef USE_PCRE
/* set these when compiling user-supplied patterns to pcre2_compile() */
#define REQUIRED_PCRE_FLAGS (PCRE2_NEVER_BACKSLASH_C | PCRE2_NEVER_UTF)

struct pcre2_real_compile_context_8 *get_iso88591_pcre2_compile_context(void);
struct pcre2_real_match_context_8 *get_pcre2_match_context(void);
#endif

extern struct string *const static_empty_string;

enum runtime_error ct_string_index(long idx, const char **errmsg,
                                   struct string *str, bool beyond,
                                   long *dst);

#define __CT_STR_IDX_E(v, msg, str_beyond_dst)          \
  ct_string_index(v, msg, EXPAND_ARGS str_beyond_dst)
#define CT_STR_IDX(dst, str, beyond)                    \
  CT_INT_P((str, beyond, &dst), __CT_STR_IDX_E)

#endif /* RUNTIME_MUDLLE_STRING_H */
