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

#ifndef RUNTIME_RUNTIME_H
#define RUNTIME_RUNTIME_H

#include "../error.h"

enum {
  forbid_create   = P(0),
  forbid_exec     = P(1),
  forbid_follow   = P(2),
  forbid_move     = P(3),
  forbid_position = P(4),
  forbid_purge    = P(5),
  forbid_all      = P(6) - 1
};

/* end mudlle const */

void runtime_init(void);

void flag_check_failed(const struct prim_op *op, const char *name);

#  define LVL_IMPLEMENTOR 1
#  define LVL_VALA 1
#  define CASSERT_SECLEVEL(seclevel) CASSERT(seclevel == 0 || seclevel == 1)

void system_string_define(struct string *name, value val);
void system_write(struct string *name, value val);
/* Modifies: environment
   Requires: name not already exist in environment.
   Effects: Adds name to environment, with value val for the variable,
     as a 'define' of the system module or as a system-write variable.
*/

/* call with 'name', 'vec' (const char * or struct string * array), 'count',
   optionally followed by
     '.null_allowed = true' and '.empty_is_null = true' */
#define define_string_vector(name, vec, ...) do {               \
  STATIC_STRING(define_name, name);                             \
  define_strvec(GET_STATIC_STRING(define_name),                 \
                _Generic((vec), const char *const *: (vec),     \
                         struct string *const *: NULL),         \
                _Generic((vec), const char *const *: NULL,      \
                         struct string *const *: (vec)),        \
                &(const struct strvec_config){ __VA_ARGS__ });  \
} while (0)

struct strvec_config {
  int count;
  bool null_allowed, empty_is_null;
  ulong *gvaridx;               /* store the gvar index here */
  size_t *len;                  /* store the number of entries here */
};
/* exactly one of 'cvec' and 'mvec' must be non-NULL */
struct vector *define_strvec(struct string *name,
                             const char *const *cvec,
                             struct string *const *mvec,
                             const struct strvec_config *config);

void define_int_vector(struct string *name, const int *vec, int count);

struct primitive *runtime_define(const struct prim_op *op);

#define TYPEIS(v, want) do {                    \
  if (EXPECT_FALSE(!TYPE((v), want)))           \
    bad_type_error((v), type_ ## want, -1);     \
} while (0)

#define TYPESETIS(v, want) do {                 \
  if (EXPECT_FALSE(!is_typeset((v), (want))))   \
    bad_typeset_error((v), (want), -1);         \
} while (0)

#define VALUE_IS_VECTOR_LEN(v, len) do {                \
  struct vector *__v = (v);                             \
  size_t __l = (len);                                   \
  if (!TYPE(__v, vector) || vector_len(__v) != __l)     \
    bad_vector_len_error(__v, __l);                     \
} while (0)

/* get mudlle integer */
#define GETINT(v) (EXPECT_FALSE(!integerp(v))                   \
                   ? (bad_type_error(v, type_integer, -1), 0L)  \
                   : intval(v))

/* get mudlle integer; treat negative numbers as positive overflow */
#define GETUINT(v) (EXPECT_FALSE(!integerp(v))                  \
                    ? (bad_type_error(v, type_integer, -1), 0L) \
                    : uintval(v))

/* get mudlle integer; throw error if v is not in [min, max] */
#define GETRANGE(v, min, max)                                   \
  (EXPECT_FALSE(!integerp(v))                                   \
   ? (bad_type_error(v, type_integer, -1), 0L)                  \
   : (EXPECT_FALSE(intval(v) < (min) || intval(v) > (max))      \
      ? (out_of_range_error(intval(v), (min), (max)), 0L)       \
      : intval(v)))

#ifdef MUDLLE_INTERRUPT
/* Effects: Causes a user_interrupt runtime error if user caused
   SIGINT or SIGQUIT */
void check_interrupt(void);
#else
static inline void check_interrupt(void) { }
#endif

void mudlle_consts_init(void);

const struct prim_op *lookup_primitive(ulong adr);

const char *primop_argname(size_t *namelen, const char **suffix,
                           const char *from);

#define FORBID_MSG_create   "create characters or objects"
#define FORBID_MSG_exec     "run character commands"
#define FORBID_MSG_follow   "follow or unfollow characters"
#define FORBID_MSG_move     "move characters or objects"
#define FORBID_MSG_position "change position of characters"
#define FORBID_MSG_purge    "damage or destroy charaters or objects"

extern unsigned mudlle_forbid;

#define __MFORBID(what) (void)(mudlle_forbid |= forbid_ ## what)

/* use as PUSH_FORBID(create, exec, ...) to disallow such primitives */
#define PUSH_FORBID(...)                                        \
  const unsigned old_forbid = mudlle_forbid;                    \
  do {                                                          \
    FOR_ARGS(__MFORBID, SEP_SEMI, __VA_ARGS__);                 \
  } while (0)

/* must be called after PUSH_FORBID() to restore the previous state */
#define POP_FORBID() (void)(mudlle_forbid = old_forbid)

/* if 'what' is currently forbidden, throw an error */
#define CHECK_FORBID(what) do {                                         \
  if (mudlle_forbid & forbid_ ## what)                                  \
    RUNTIME_ERROR(error_abort,                                          \
                  "cannot " FORBID_MSG_ ## what " at this time");       \
} while (0)

long get_range(value v, long minval, long maxval, const char *what,
               enum runtime_error *error, const char **errmsg);

#endif /* RUNTIME_RUNTIME_H */
