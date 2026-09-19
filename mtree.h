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

#ifndef MTREE_H
#define MTREE_H

#include "types.h"

struct component;
struct constant;
struct mfile;

/* field indices for mudlle compounds ("dynamic constants") */
enum {
  /* mudlle subst s/^m/mc:/ */
  mcompound_class,
  mcompound_loc,
  mcompound_base,
  mcompound_rwmode,
  mcompound_value,
  /* mudlle subst s/^mudlle_/mc:/ */
  mudlle_compound_fields
};

/* fields for mudlle vlists */
enum {
  /* mudlle subst s/^/mc:/ */
  vl_var,
  vl_typeset,
  vl_loc,
  /* mudlle subst s/^mudlle_/mc:/ */
  mudlle_vlist_entries
};

value mudlle_parse(struct mfile *f, bool expand_inline);
value mudlle_parse_expr(struct component *e, bool expand_inline);

/* if 'tab' is NULL, create a new (ephemeral) cache table */
void init_string_cache(struct table *tab);
void free_string_cache(void);

value constant_to_mudlle(const struct constant *c);

struct string *scache_alloc_str_len(const char *str, size_t len);
struct string *scache_alloc_str(const char *str);
value make_shared_string_constant(const struct constant *c,
                                  struct table *cache);
struct list *scache_alloc_pair(const char *car, const char *cdr);

void mtree_init(void);

#endif  /* MTREE_H */
