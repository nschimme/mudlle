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

#ifndef RUNTIME_FILES_H
#define RUNTIME_FILES_H

#include <stdio.h>

#include "../alloc.h"

#define MAX_ASYNC_PROCESSES 16
#define MAX_MUDLLE_OPEN_FILES 128

enum {
  FS_DEV     =  0,
  FS_INO     =  1,
  FS_MODE    =  2,
  FS_NLINK   =  3,
  FS_UID     =  4,
  FS_GID     =  5,
  FS_RDEV    =  6,
  FS_SIZE    =  7,
  FS_ATIME   =  8,
  FS_MTIME   =  9,
  FS_CTIME   = 10,
  FS_BLKSIZE = 11,
  FS_BLOCKS  = 12,
  FS_AFTIME  = 13,
  FS_MFTIME  = 14,
  FS_CFTIME  = 15,
  FILE_STAT_FIELDS
};

enum {
  FSYS_BSIZE,
  FSYS_FRSIZE,
  FSYS_BLOCKS,
  FSYS_BFREE,
  FSYS_BAVAIL,
  FSYS_FILES,
  FSYS_FFREE,
  FSYS_FAVAIL,
  FSYS_FSID,
  FSYS_FLAG,
  FSYS_NAMEMAX,
  FILE_SYSTEM_STAT_FIELDS
};

enum {
  PW_NAME    = 0,
  PW_UID     = 1,
  PW_GID     = 2,
  PW_GECOS   = 3,
  PW_DIR     = 4,
  PW_SHELL   = 5,
  PASSWD_ENTRY_FIELDS
};

enum {
  GR_NAME    = 0,
  GR_GID     = 1,
  GR_MEM     = 2,
  GROUP_ENTRY_FIELDS
};

enum {
  MNT_FSNAME,
  MNT_DIR,
  MNT_TYPE,
  MNT_OPTS,
  MNT_FREQ,
  MNT_PASSNO,
  MOUNT_ENTRY_FIELDS
};

/* end mudlle const */

void files_init(void);
void poll_async_processes(void);

struct mudlle_file_data {
  FILE *f;                         /* NULL if the file is closed */
  union dynpro_port oport;         /* optional file_oport */
  char *filename;                  /* malloc'ed */
  bool readable : 1, writable : 1; /* permissions */
};

bool is_mudlle_file(value v, struct mudlle_file_data **data);

struct oport *mudlle_file_oport(value mfile);

enum runtime_error ct_mfile(
  value mfile, const char **errmsg, FILE **dstfile,
  struct mudlle_file_data **dstfdata);

#define _CT_FILE(mfile, errmsg, dst)                                    \
  ct_mfile(mfile, errmsg,                                               \
           _Generic((dst),                                              \
                    FILE *: &(dst),                                     \
                    struct mudlle_file_data *: NULL),                   \
           _Generic((dst),                                              \
                    FILE *: NULL,                                       \
                    struct mudlle_file_data *: &(dst)))

/* 'dst' can be 'FILE *' or 'struct mudlle_file_data *' */
#define CT_FILE(dst) F2(TSET(file), _CT_FILE, (dst))

enum runtime_error ct_pathname(struct string *mstr, const char **errmsg);
#define _CT_PATHNAME(var, msg, arg) ct_pathname((var), (msg))
#define CT_PATHNAME F2(TSET(string), _CT_PATHNAME, )

#endif /* RUNTIME_FILES_H */
