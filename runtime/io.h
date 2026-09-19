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

#ifndef RUNTIME_IO_H
#define RUNTIME_IO_H

#include "../mudlle-config.h"

#include <time.h>

#include "../ports.h"

enum {
  tm_sec,
  tm_min,
  tm_hour,
  tm_mday,
  tm_mon,
  tm_year,
  tm_wday,
  tm_yday,
  time_fields
};

void io_init(void);

/* end mudlle const */
#define TYPESET_OPORT (TSET(oport) | TSET(file))
#define OPORT_TYPES "a file or output port"

struct oport_info {
  bool use_ascii;
};

enum runtime_error ct_oport(struct oport **oport, const char **errmsg,
                            struct oport_info *info, bool force);
#define __CT_OPORT_E(v, msg, info) ct_oport(&v, msg, info, true)
#define __CT_OPT_OPORT_E(v, msg, info) ct_oport(&v, msg, info, false)

/* CT_OPORT checks that var is a file, oport or character. If it is a
   character, sets var to its standard output port. May cause GC! */
#define CT_OPORT(info) F2(TYPESET_OPORT, __CT_OPORT_E, (info))
/* CT_OPT_OPORT does what CT_OPORT does, but just sets var to NULL for
   null or false. May cause GC! */
#define CT_OPT_OPORT(info)                              \
  F2(TYPESET_OPORT | TYPESET_FALSE | TSET(null),        \
     __CT_OPT_OPORT_E, (info))

#define __CT_STR_OPORT_E(edst, v, msg, typeset) \
  if (!is_string_port(v))                       \
    {                                           \
      *msg = "exepected a string port";         \
      edst = error_bad_value;                   \
    }

/* CT_STR_OPORT checks that var is an oport; then it checks that it is
   a string oport. */
#define CT_STR_OPORT F(TSET(oport), __CT_STR_OPORT_E, TSET(oport))

enum runtime_error ct_time_p(long l, const char **errmsg, time_t *dst);

#define __CT_TIME_E(v, msg, dst) ct_time_p(v, msg, &dst)
#define CT_TIME(dst) CT_INT_P(dst, __CT_TIME_E)

#endif /* RUNTIME_IO_H */
