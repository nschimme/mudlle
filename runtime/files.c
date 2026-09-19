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

#include "../mudlle-config.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <grp.h>
#include <libgen.h>
#include <pwd.h>
#include <unistd.h>
#include <utime.h>

#ifdef __linux__
 #include <mntent.h>
#elif defined __MACH__
 #include <fstab.h>
#endif

#include <sys/stat.h>
#include <sys/statvfs.h>

#include "../compile.h"

#include "bigint.h"
#include "check-types.h"
#include "files.h"
#include "io.h"
#include "mudlle-float.h"
#include "prims.h"

#define MZERO_OR_ERRNO_DOC "Returns zero or Unix errno on error."

#ifdef ARG_MAX
#endif

TYPEDOP(load, , "`s -> `b. Loads mudlle file `s. Returns true if successful",
        (struct string *name), OP_STR_READONLY | OP_TRACE, "s.n")
{
  CHECK_TYPES(name, CT_PATHNAME);
  char *path;
  ALLOCA_PATH(path, name);
  return makebool(load_file(path, 1, true, true));
}

TYPEDOP(loading_file, ,
        "-> `s|false. Return the filename of the currently loading mudlle"
        " file, or false. Cf. `load().",
        (void), 0, ".[sz]")
{
  const char *path = loading_file();
  return path ? alloc_string(path) : makebool(false);
}


enum runtime_error ct_pathname(struct string *mstr, const char **errmsg)
{
  size_t l = string_len(mstr);
  if (l == 0)
    *errmsg = "empty path name";
  else if (strlen(mstr->str) != l)
    *errmsg = "path name contains NUL";
  else if (l > PATH_MAX)
    *errmsg = "path name too long";
  else
    return error_none;
  return error_bad_value;
}

enum runtime_error ct_mfile(
  value mfile, const char **errmsg, FILE **dstfile,
  struct mudlle_file_data **dstfdata)
{
  struct mudlle_file_data *fdata;
  if (is_mudlle_file(mfile, &fdata))
    {
      if (dstfile != NULL)
        *dstfile = fdata->f;
      if (dstfdata != NULL)
        *dstfdata = fdata;
      return error_none;
    }
  *errmsg = "expected a file";
  return error_bad_type;
}

static inline value mzero_or_errno(int i)
{
  return makeint(i == 0 ? 0 : errno);
}

UNSAFEOP(mkdir, , "`s `n1 -> `n2. Make directory `s with mode `n1."
         " Only the file permission bits 0777 are allowed.\n"
         MZERO_OR_ERRNO_DOC,
         (struct string *mname, value mmode),
         OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY,
         "sn.n")
{
  unsigned mode;
  CHECK_TYPES(mname, CT_PATHNAME,
              mmode, CT_RANGE(mode, 0, 0777));
  return mzero_or_errno(mkdir(mname->str, mode));
}

UNSAFEOP(rmdir, , "`s -> `n. Remove directory `s."
         " " MZERO_OR_ERRNO_DOC,
         (struct string *name),
         OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY,
         "s.n")
{
  CHECK_TYPES(name, CT_PATHNAME);
  return mzero_or_errno(rmdir(name->str));
}

UNSAFEOP(directory_files, , "`s -> `l. List all files of directory `s"
         " (returns false on error)",
         (struct string *dir),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "s.[ln]")
{
  CHECK_TYPES(dir, CT_PATHNAME);

  DIR *d = opendir(dir->str);
  if (d == NULL)
    return makebool(false);

  struct list *files = NULL;
  GCPRO(files);
  for (struct dirent *entry; (entry = readdir(d)); )
    {
      struct string *fname = alloc_string(entry->d_name);
      files = alloc_list(fname, files);
    }
  UNGCPRO();
  closedir(d);

  return files;
}

static const long allowed_glob_flags =
  0
#ifdef GLOB_TILDE
 #define GD_TILDE     "\n  `GLOB_TILDE    \tCarry out tilde expansion for"    \
                      " home directories."
  | GLOB_TILDE
#else
 #define GD_TILDE ""
#endif
#ifdef GLOB_BRACE
 #define GD_BRACE     "\n  `GLOB_BRACE    \tExpand {a,b} style brace"         \
                      " expressions."
  | GLOB_BRACE
#else
 #define GD_BRACE ""
#endif
#ifdef GLOB_MARK
 #define GD_MARK      "\n  `GLOB_MARK     \tAppend a slash to each path"      \
                      " corresponding to a directory."
  | GLOB_MARK
#else
 #define GD_MARK ""
#endif
#ifdef GLOB_NOCHECK
 #define GD_NOCHECK   "\n  `GLOB_NOCHECK  \tIf no pattern matches, return"    \
                      " the original pattern."
  | GLOB_NOCHECK
#else
 #define GD_NOCHECK ""
#endif
#ifdef GLOB_NOESCAPE
 #define GD_NOESCAPE  "\n  `GLOB_NOESCAPE \tDo not allow backslash to be"     \
                      " used as an escape character."
  | GLOB_NOESCAPE
#else
 #define GD_NOESCAPE ""
#endif
#ifdef GLOB_PERIOD
 #define GD_PERIOD    "\n  `GLOB_PERIOD   \tAllow a leading period to be"     \
                      " matched by metacharacters."
  | GLOB_PERIOD
#else
 #define GD_PERIOD ""
#endif
#ifdef GLOB_NOMAGIC
 #define GD_NOMAGIC   "\n  `GLOB_NOMAGIC  \tIf the pattern contains no"       \
                      " metacharacters, return it as the only match, even"    \
                      " if there is no such file."
  | GLOB_NOMAGIC
#else
 #define GD_NOMAGIC ""
#endif
#ifdef GLOB_ONLYDIR
 #define GD_ONLYDIR   "\n  `GLOB_ONLYDIR  \tHint only to return matching"     \
                      " directories. The implementation may ignore this"      \
                      " flag."
  | GLOB_ONLYDIR
#else
 #define GD_ONLYDIR ""
#endif
  | 0;

UNSAFEOP(glob_files, ,
         "`s0 `s1 `n -> `l. Returns a list of all files matched by"
         " the glob pattern `s1, executed in directory `s0. Returns false on"
         " error. `n specifies flags to use:"
         GD_TILDE
         GD_BRACE
         GD_MARK
         GD_NOCHECK
         GD_NOESCAPE
         GD_PERIOD
         GD_NOMAGIC
         GD_ONLYDIR,
         (struct string *dir, struct string *pat, value mflags),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "ssn.[ln]")
{
  long flags;
  CHECK_TYPES(pat,    string,
              dir,    CT_PATHNAME,
              mflags, CT_INT(flags));
  if (strlen(pat->str) != string_len(pat))
    RUNTIME_ERROR_ARG(0, error_bad_value, "pattern contains NUL");
  if (flags & ~allowed_glob_flags)
    RUNTIME_ERROR_ARG(2, error_bad_value, "invalid flags");

  int orig_wd = open(".", 0);
  if (orig_wd < 0)
    RUNTIME_ERROR(error_abort, "cannot find current working directory");

  if (chdir(dir->str) < 0)
    {
      close(orig_wd);
      RUNTIME_ERROR(error_bad_value, "failed to change working directory");
    }

  glob_t files;
  int res = glob(pat->str, flags, NULL, &files);
  if (fchdir(orig_wd) < 0)
    {
      close(orig_wd);
      globfree(&files);
      RUNTIME_ERROR(error_bad_value, "failed to restore working directory");
    }

  close(orig_wd);

  if (res)
    {
      globfree(&files);
      return makebool(false);
    }

  struct list *l = NULL;
  GCPRO(l);
  for (char **s = files.gl_pathv; *s; ++s)
    {
      struct string *f = alloc_string(*s);
      l = alloc_list(f, l);
    }
  UNGCPRO();
  globfree(&files);
  return l;
}

static value make_timespec(const struct timespec *ts)
{
  return alloc_float(ts->tv_sec + ts->tv_nsec * 1e-9);
}

#ifdef __MACH__
#define st_atim st_atimespec
#define st_mtim st_mtimespec
#define st_ctim st_ctimespec
#endif

static value build_file_stat(struct stat *sb)
{
  struct vector *info = alloc_vector(FILE_STAT_FIELDS);
  GCPRO(info);

#define SETVSTAT(FIELD, field) \
  SET_VECTOR(info, FS_ ## FIELD, make_int_or_bigint(sb->st_ ## field))

  SETVSTAT(DEV,   dev);
  SETVSTAT(INO,   ino);
  SETVSTAT(MODE,  mode);
  SETVSTAT(NLINK, nlink);
  SETVSTAT(UID,   uid);
  SETVSTAT(GID,   gid);
  SETVSTAT(RDEV,  rdev);
  SETVSTAT(SIZE,  size);

  /* treat time as the time() primitive does: no bigints */
  info->data[FS_ATIME] = makeint(sb->st_atime);
  info->data[FS_MTIME] = makeint(sb->st_mtime);
  info->data[FS_CTIME] = makeint(sb->st_ctime);

  SETVSTAT(BLKSIZE, blksize);
  SETVSTAT(BLOCKS,  blocks);

#undef SETVSTAT

  SET_VECTOR(info, FS_AFTIME, make_timespec(&sb->st_atim));
  SET_VECTOR(info, FS_MFTIME, make_timespec(&sb->st_mtim));
  SET_VECTOR(info, FS_CFTIME, make_timespec(&sb->st_ctim));

  UNGCPRO();

  return info;
}

UNSAFEOP(file_stat, , "`s|`file -> `v|false. Returns status of file `s or"
         " `file, or false for failure.\n"
         "See the `FS_xxx constants and `file_lstat().",
         (value mfile),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "[so].[vz]")
{
  FILE *f = NULL;
  CHECK_TYPES(mfile, OR(CT_PATHNAME, CT_FILE(f)));

  int r = -1;
  struct stat sb;
  if (TYPE(mfile, string))
    r = stat(((struct string *)mfile)->str, &sb);
  else if (f != NULL)
    r = fstat(fileno(f), &sb);
  if (r == 0)
    return build_file_stat(&sb);
  return makebool(false);
}

TYPEDOP(file_system_stat, , "`s -> `v. Returns file system statistics"
        " for the file system containing file `s, or Unix errno on error."
        "Note that all entries may contain bigints if the result does"
        " not fit in an integer.\n"
        "See the `FSYS_xxx and `FILE_SYSTEM_STAT_FIELDS constants.\n"
        "Cf. `mount_points().",
        (struct string *fname),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "s.[vn]")
{
  CHECK_TYPES(fname, CT_PATHNAME);

  struct statvfs sb;
  if (statvfs(fname->str, &sb) < 0)
    return makeint(errno);

  struct vector *v = alloc_vector(FILE_SYSTEM_STAT_FIELDS);
  GCPRO(v);

#define SETVFS(FIELD, field) \
  SET_VECTOR(v, FSYS_ ## FIELD, make_int_or_bigint(sb.f_ ## field))

  SETVFS(BSIZE,   bsize);
  SETVFS(FRSIZE,  frsize);
  SETVFS(BLOCKS,  blocks);
  SETVFS(BFREE,   bfree);
  SETVFS(BAVAIL,  bavail);
  SETVFS(FILES,   files);
  SETVFS(FFREE,   ffree);
  SETVFS(FAVAIL,  favail);
  SETVFS(FSID,    fsid);
  SETVFS(FLAG,    flag);
  SETVFS(NAMEMAX, namemax);

#undef SETVFS

  UNGCPRO();
  return v;
}

UNSAFEOP(realpath, ,
         "`s0 -> `s1. Resolves any symbolic links, follows references to"
         " /./ and /../, and returns the canonicalized path for `s0.\n"
         "Returns Unix errno on error.",
         (struct string *path),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "s.[sn]")
{
  CHECK_TYPES(path, CT_PATHNAME);
  char buf[PATH_MAX];
  char *res = realpath(path->str, buf);
  return res == NULL ? makeint(errno) : alloc_string(res);
}

TYPEDOP(dirname, ,
        "`s0 -> `s1. Returns the parent directory name of the file pathname"
        " `s0. Returns \".\" if `s0 does not contain a \"/\".",
        (struct string *path),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "s.s")
{
  CHECK_TYPES(path, CT_PATHNAME);
  char *cpath;
  ALLOCA_PATH(cpath, path);
  return alloc_string(dirname(cpath));
}

TYPEDOP(mudlle_basename, "basename",
        "`s0 -> `s1. Returns the last component of the pathname `s0,"
        " ignoring any trailing \"/\" characters.\n"
        "Returns \".\" if `s0 is the empty string.",
        (struct string *path),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "s.s")
{
  CHECK_TYPES(path, CT_PATHNAME);
  char *cpath;
  ALLOCA_PATH(cpath, path);
  return alloc_string(basename(cpath));
}

UNSAFEOP(file_lstat, ,
         "`s -> `v|false. Returns status of file `s (not following links)."
         " Returns false for failure. See the `FS_xxx constants and"
         " `file_stat()",
         (struct string *fname),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "s.[vz]")
{
  CHECK_TYPES(fname, CT_PATHNAME);
  struct stat sb;
  return lstat(fname->str, &sb) == 0 ? build_file_stat(&sb) : makebool(false);
}

UNSAFEOP(file_utime, ,
         "`s `x -> `n. Sets the access and modification times"
         " of file `s. If `x is null, set both to the current time;"
         " if `x is a pair, set them to `car(`x) and `cdr(`x), respectively.\n"
         MZERO_OR_ERRNO_DOC,
         (struct string *fname, struct list *mmtimes),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "sl.n")
{
  CHECK_TYPES(fname,   CT_PATHNAME,
              mmtimes, CT_TYPESET(TYPESET_LIST));

  struct utimbuf buf, *times;
  if (mmtimes == NULL)
    times = NULL;
  else
    {
      assert(TYPE(mmtimes, pair));
      buf.actime  = GETUINT(mmtimes->car);
      buf.modtime = GETUINT(mmtimes->cdr);
      times = &buf;
    }

  return mzero_or_errno(utime(fname->str, times));
}

UNSAFEOP(readlink, ,
         "`s1 -> `s2|false. Returns the contents of symlink `s, or false"
         " for failure", (struct string *lname),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "s.[sz]")
{
  CHECK_TYPES(lname, CT_PATHNAME);

  struct stat sb;
  if (lstat(lname->str, &sb) || !S_ISLNK(sb.st_mode))
    return makebool(false);

  if (sb.st_size > MAX_STRING_SIZE)
    return makebool(false);

  char buf[sb.st_size ? sb.st_size : PATH_MAX];

  ssize_t r = readlink(lname->str, buf, sizeof buf);
  if (r < 0)
    return makebool(false);

  struct string *res = alloc_string_noinit(r);
  memcpy(res->str, buf, r);
  return res;
}

UNSAFEOP(symlink, ,
         "`s1 `s2 -> `n. Creates a symbolic link named `s2 containing the"
         " string `s1.\n"
         "Returns the Unix errno.",
         (struct string *lname, struct string *tname),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "ss.n")
{
  CHECK_TYPES(lname, CT_PATHNAME,
              tname, CT_PATHNAME);
  return mzero_or_errno(symlink(lname->str, tname->str));
}

UNSAFEOP(mkstemp, ,
         "`s0 -> `s1|`n. Create a temporary filename starting with `s0,"
         " create the file, and return its file name.\n"
         "The file name will be `s0 followed by a period and a random suffix"
         " to make it unique.\n"
         "The file will be created with read/write permissions for the"
         " owner only.\n"
         "Returns a Unix errno value on error.",
         (struct string *mtemplate),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "s.[sn]")
{
  CHECK_TYPES(mtemplate, CT_PATHNAME);

  static const char xes[] = ".XXXXXX";

  size_t tlen = strlen(mtemplate->str);
  if (tlen == 0 || tlen >= PATH_MAX - strlen(xes))
    RUNTIME_ERROR(error_bad_value, "invalid template length");

  char *template = malloc(tlen + sizeof xes);
  memcpy(template, mtemplate->str, tlen);
  memcpy(template + tlen, xes, sizeof xes);

  int fd = mkstemp(template);
  if (fd < 0)
    {
      free(template);
      return makeint(errno);
    }

  close(fd);

  struct string *res = alloc_string(template);
  free(template);
  return res;
}

UNSAFEOP(file_regularp, "file_regular?",
         "`s -> `b. Returns true if `s is a regular file or a symlink to one.",
         (struct string *fname),
         OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY,
         "s.n")
{
  CHECK_TYPES(fname, CT_PATHNAME);
  struct stat sb;
  return makebool(stat(fname->str, &sb) == 0 && S_ISREG(sb.st_mode));
}

UNSAFEOP(directoryp, "directory?",
         "`s -> `b. Returns true if `s is a directory or a symlink to one.",
         (struct string *dname),
         OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_STR_READONLY,
         "s.n")
{
  CHECK_TYPES(dname, CT_PATHNAME);
  struct stat sb;
  return makebool(stat(dname->str, &sb) == 0 && S_ISDIR(sb.st_mode));
}

UNSAFEOP(remove, , "`s -> `n. Removes file `s. " MZERO_OR_ERRNO_DOC,
         (struct string *fname),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "s.n")
{
  CHECK_TYPES(fname, CT_PATHNAME);
  return mzero_or_errno(unlink(fname->str));
}

UNSAFEOP(rename, ,
         "`s1 `s2 -> `n. Renames file `s1 to `s2. " MZERO_OR_ERRNO_DOC,
         (struct string *oldname, struct string *newname),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "ss.n")
{
  CHECK_TYPES(oldname, CT_PATHNAME,
              newname, CT_PATHNAME);
  return mzero_or_errno(rename(oldname->str, newname->str));
}

UNSAFEOP(chown, , "`s1 `n0 `n1 -> `n2. Changed owner of file `s1 to uid `n0"
         " and gid `n1. Use -1 not to change that field.\n"
         MZERO_OR_ERRNO_DOC,
         (struct string *fname, value muid, value mgid),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "snn.n")
{
  uid_t uid;
  gid_t gid;
  CHECK_TYPES(fname, CT_PATHNAME,
              muid,  CT_AUTO_RANGE(uid),
              mgid,  CT_AUTO_RANGE(gid));
  return mzero_or_errno(chown(fname->str, uid, gid));
}

UNSAFEOP(chmod, , "`s1 `n0 -> `n1. Changed mode of file `s1 to `n0.\n"
         MZERO_OR_ERRNO_DOC,
         (struct string *fname, value mmode),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "sn.n")
{
  mode_t mode;
  CHECK_TYPES(fname, CT_PATHNAME,
              mmode, CT_AUTO_RANGE(mode));
  return mzero_or_errno(chmod(fname->str, mode));
}

TYPEDOP(strerror, , "`n -> `s|false. Returns an error string corresponding to"
        " errno `n, or false if there is no such errno.",
        (value merrno), OP_LEAF | OP_NOESCAPE, "n.[sz]")
{
  long e;
  CHECK_TYPES(merrno, CT_INT(e));
  if (e != (int)e)
    return makebool(false);
  const char *s = strerror(e);
  return s ? alloc_string(s) : makebool(false);
}

TYPEDOP(getenv, , "`s0 -> `s1|false. Return the value of the environment"
        " variable `s0, or false if no match.",
        (struct string *name),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY,
        "s.[sz]")
{
  CHECK_TYPES(name, CT_PATHNAME);
  char *r = getenv(name->str);
  return r == NULL ? makebool(false) : alloc_string(r);
}

TYPEDOP(getcwd, , "-> `s|`n. Returns the name of the current working"
        " directory, or a Unix errno value on error. Cf. `strerror",
        (void), OP_LEAF | OP_NOESCAPE, ".[sn]")
{
  char buf[PATH_MAX];
  char *wd = getcwd(buf, sizeof buf);
  return wd == NULL ? makeint(errno) : alloc_string(wd);
}

UNSAFEOP(chdir, , "`s -> `n. Change current working directory to `s."
         " " MZERO_OR_ERRNO_DOC,
         (struct string *path),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY,
         "s.n")
{
  CHECK_TYPES(path, CT_PATHNAME);
  return mzero_or_errno(chdir(path->str));
}

#define PROC_GETINT(name, desc, see)                            \
TYPEDOP(name, , "-> `n. Return the " desc " of the process."    \
        " See also " see ".",                                   \
        (void), OP_LEAF | OP_NOALLOC | OP_NOESCAPE, ".n")       \
{                                                               \
  return makeint(name());                                       \
}

PROC_GETINT(getuid,  "real user ID",       "`geteuid() and `getgid()")
PROC_GETINT(geteuid, "effective user ID",  "`getuid() and `getegid()")
PROC_GETINT(getgid,  "real group ID",      "`getuid() and `getegid()")
PROC_GETINT(getegid, "effective group ID", "`geteuid() and `getgid()")

static void close_mudlle_file_oport(struct mudlle_file_data *fdata)
{
  if (fdata->oport.port != NULL)
    {
      port_close(fdata->oport.port);
      undynpro(&fdata->oport);
    }
}

static int mudlle_file_count;

struct mudlle_file {
  struct obj o;
  struct mudlle_file_data *fdata;
};

static void free_mudlle_file(void *data)
{
  struct mudlle_file_data *fdata = data;
  close_mudlle_file_oport(fdata);
  if (fdata->f != NULL)
    {
      assert(mudlle_file_count > 0);
      --mudlle_file_count;
      fclose(fdata->f);
    }
  free(fdata->filename);
  free(fdata);
}

static struct mudlle_file_data *get_mudlle_file_data(value v)
{
  assert(TYPE(v, file));
  struct mudlle_file *mfile = v;
  return mfile->fdata;
}

bool is_mudlle_file(value v, struct mudlle_file_data **dst)
{
  if (!TYPE(v, file))
    return false;
  if (dst != NULL)
    *dst = ((struct mudlle_file *)v)->fdata;
  return true;
}

static struct mudlle_file *make_mudlle_file(
  FILE *f, const char *filename, bool readable, bool writable)
{
  struct mudlle_file_data *fdata = malloc(sizeof *fdata);
  *fdata = (struct mudlle_file_data){
    .f        = f,
    .filename = strdup(filename),
    .readable = readable,
    .writable = writable
  };
  struct mudlle_file *mfile = (struct mudlle_file *)alloc_weak_ref(
    type_file, sizeof *mfile, fdata, free_mudlle_file);
  mfile->fdata = fdata;
  return mfile;
}

struct oport *mudlle_file_oport(value mfile)
{
  struct mudlle_file_data *fdata = get_mudlle_file_data(mfile);
  if (fdata->oport.port != NULL)
    return fdata->oport.port;
  struct oport *oport = make_file_oport(fdata->f, false);
  dynpro(&fdata->oport, oport);
  return oport;
}

TYPEDOP(filep, "file?",
        "`x -> `b. True if `x is a file object.",
        (value x), OP_LEAF | OP_NOESCAPE | OP_NOALLOC | OP_TRIVIAL, "x.n")
{
  return makebool(is_mudlle_file(x, NULL));
}

TYPEDOP(file_openp, "file_open?",
        "`file -> `b. True if `file is open.",
        (value mfile), OP_LEAF | OP_NOESCAPE | OP_NOALLOC | OP_TRIVIAL,
        "o.n")
{
  FILE *f = NULL;
  CHECK_TYPES(mfile, CT_FILE(f));
  return makebool(f != NULL);
}

UNSAFEOP(file_open, ,
         "`s0 `s1 -> `file|`n. Open the file named `s0 in mode `s1, one of:\n"
         "  \"r\"   \topen for reading, starting at the beginning of the"
         " file\n"
         "  \"r+\"  \topen for reading and writing, starting at the beginning"
         " of the file\n"
         "  \"w\"   \topen for writing, creating the file or truncating to"
         " zero length\n"
         "  \"w+\"  \topen for reading and writing, creating the file or"
         " truncating to zero length\n"
         "  \"a\"   \topen for appending, creating the file if needed,"
         " starting at the end of the file\n"
         "  \"a+\"  \topen for reading and appending, creating the file if"
         " needed, starting at the end of the file\n"
         "Returns a Unix errno value on error.",
         (struct string *mname, struct string *mmode),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "ss.[on]")
{
  CHECK_TYPES(mname, CT_PATHNAME,
              mmode, string);

  static const struct {
    const char *name;
    bool readable : 1, writable : 1;
  } modes[] = {
    { "r",  true,  false },
    { "r+", true,  true },
    { "w",  false, true },
    { "w+", true,  true },
    { "a",  false, true },
    { "a+", true,  true }
  };
  for (size_t i = 0; i < VLENGTH(modes); ++i)
    if (strcmp(mmode->str, modes[i].name) == 0
        && string_len(mmode) == strlen(modes[i].name))
      {
        FILE *f = fopen(mname->str, mmode->str);
        if (f == NULL)
          return makeint(errno);

        if (mudlle_file_count >= MAX_MUDLLE_OPEN_FILES)
          {
            /* GC may free orphaned files */
            garbage_collect(0);
            if (mudlle_file_count >= MAX_MUDLLE_OPEN_FILES)
              {
                fclose(f);
                return makeint(EMFILE);
              }
          }

        ++mudlle_file_count;

        return make_mudlle_file(
          f, mname->str, modes[i].readable, modes[i].writable);
      }

  RUNTIME_ERROR(error_bad_value, "invalid mode");
}

UNSAFEOP(file_close, ,
         "`file -> `n. Closes the file `file, as opened by `open_file().\n"
         MZERO_OR_ERRNO_DOC,
         (struct mudlle_file *mfile),
         OP_LEAF | OP_NOESCAPE, "o.n")
{
  struct mudlle_file_data *fdata;
  CHECK_TYPES(mfile, CT_FILE(fdata));

  if (fdata->f == NULL)
    return makeint(EBADF);
  close_mudlle_file_oport(fdata);
  --mudlle_file_count;
  int r = fclose(fdata->f);
  if (r == 0)
    fdata->f = NULL;
  return mzero_or_errno(r);
}

UNSAFEOP(file_oport, ,
         "`file -> `oport. Returns the output port corresponding to `file, as"
         " opened by `open_file().",
         (struct mudlle_file *mfile),
         OP_LEAF | OP_NOESCAPE, "o.o")
{
  struct mudlle_file_data *fdata;
  CHECK_TYPES(mfile, CT_FILE(fdata));

  if (fdata->f == NULL)
    RUNTIME_ERROR(error_bad_value, "expected an open file");
  if (!fdata->writable)
    RUNTIME_ERROR(error_bad_value, "expected a writable file");
  return mudlle_file_oport(mfile);
}

UNSAFEOP(file_seek, ,
         "`file `n0 `n1 -> `n2. Seeks to position `n0, counting from `n1 (one"
         " of `SEEK_SET, `SEEK_CUR, or `SEEK_END).\n"
         MZERO_OR_ERRNO_DOC,
         (struct mudlle_file *mfile, value mofs, value mwhence),
         OP_LEAF | OP_NOESCAPE | OP_NOALLOC, "onn.n")
{
  FILE *f = NULL;
  off_t ofs;
  long whence;
  CHECK_TYPES(mfile,   CT_FILE(f),
              mofs,    CT_AUTO_RANGE(ofs),
              mwhence, CT_INT(whence));

  if (whence != SEEK_SET && whence != SEEK_CUR && whence != SEEK_END)
    RUNTIME_ERROR(error_bad_value, "invalid SEEK_xxx value");

  if (f == NULL)
    return makeint(EBADF);
  return mzero_or_errno(fseeko(f, ofs, whence));
}

UNSAFEOP(file_tell, ,
         "`file -> `n. Returns the current position of `file, or -1 on error.",
         (struct mudlle_file *mfile),
         OP_LEAF | OP_NOESCAPE | OP_NOALLOC, "o.n")
{
  FILE *f = NULL;
  CHECK_TYPES(mfile, CT_FILE(f));
  if (f == NULL)
    return makeint(-1);
  return makeint((long)ftello(f));
}

UNSAFEOP(file_flush, ,
         "`file -> . Flushes buffered data for `file.\n"
         MZERO_OR_ERRNO_DOC,
         (struct mudlle_file *mfile),
         OP_LEAF | OP_NOESCAPE | OP_NOALLOC, "o.n")
{
  FILE *f = NULL;
  CHECK_TYPES(mfile, CT_FILE(f));
  if (f == NULL)
    return makeint(EBADF);
  return mzero_or_errno(fflush(f));
}

UNSAFEOP(file_setbuf, ,
         "`file `n -> . Set buffering mode to `n, one of `FILE_IONBF"
         " (unbuffered), `FILE_IOLBF (line buffered), or `FILE_IOFBF"
         " (fully buffered).",
         (struct mudlle_file *mfile, value mmode),
         OP_LEAF | OP_NOESCAPE | OP_NOALLOC, "on.")
{
  FILE *f = NULL;
  long mode;
  CHECK_TYPES(mfile, CT_FILE(f),
              mmode, CT_INT(mode));
  if (f == NULL)
    RUNTIME_ERROR(error_bad_value, "expected an open file");
  if (mode != _IONBF && mode != _IOLBF && mode != _IOFBF)
    RUNTIME_ERROR(error_bad_value, "invalid file buffering mode");
  setvbuf(f, NULL, mode, 0);
  undefined();
}

UNSAFEOP(file_truncate, ,
         "`file|`s `n0 -> `n1. Truncate file `file or the file named `s to"
         " a size of `n0 bytes. If the file was previously shorter, it is"
         " extended and padded with null bytes.\n"
         "If a file `file was provided and the file position was beyond `n0,"
         " it is repositioned to `n0.\n"
         MZERO_OR_ERRNO_DOC,
         (value mfile, value mlength),
         OP_LEAF | OP_NOESCAPE | OP_NOALLOC, "[so]n.n")
{
  FILE *f = NULL;
  off_t len;
  CHECK_TYPES(mfile,   OR(CT_PATHNAME, CT_FILE(f)),
              mlength, CT_RANGE(len, 0, MAX_VALUE(len)));

  if (TYPE(mfile, string))
    {
      if (truncate(((struct string *)mfile)->str, len) < 0)
        return makeint(errno);
      return makeint(0);
    }

  if (f == NULL)
    return makeint(EBADF);

  int fno = fileno(f);
  off_t pos = ftello(f);
  if (fno == -1
      || pos == -1
      || fflush(f) != 0
      || ftruncate(fno, len) < 0
      || (pos > len && fseeko(f, len, SEEK_SET) < 0))
    return makeint(errno);

  return makeint(0);
}

UNSAFEOP(print_file_part, ,
         "`oport `file|`s `n0 `n1|null -> `n2. Print `n1 bytes from `file or"
         " the file named `s, starting from byte `n0. If `n1 is null, print"
         " the rest of the file.\n"
         "`n0 is relative to the current position in the case of `file.\n"
         "Output it sent to `oport, " OPORT_TYPES ".\n"
         "Returns zero if successful, a Unix errno value"
         " if there was file I/O error, or -1 if `oport became too full.\n"
         "It is not an error to start after the end of the file, nor to"
         " try to read beyond the end of the file.",
         (struct oport *oport, value mfile, value mstart, value mbytes),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "o[so]n[nu].n")
{
  bool must_close = false;

  long start, bytes = -1;
  FILE *f = NULL;
  {
    GCPRO(mfile);               /* CT_OPORT may cause GC */
    CHECK_TYPES(oport,  CT_OPORT(NULL),
                mfile,  OR(string, CT_FILE(f)),
                mstart, CT_RANGE(start, 0, LONG_MAX),
                mbytes, OR(null, CT_RANGE(bytes, 0, LONG_MAX)));
    UNGCPRO();

    if (TYPE(mfile, string))
      {
        f = fopen(((struct string *)mfile)->str, "r");
        if (f == NULL)
          return makeint(errno);
        must_close = true;
      }
    else if (f == NULL)
      RUNTIME_ERROR(error_bad_value, "expected an open file");
  }

  if (start != 0 && fseek(f, start, SEEK_CUR) == -1)
    {
      int r = errno;
      if (must_close)
        fclose(f);
      return makeint(r);
    }

  GCPRO(oport);

  int result = 0;
  const size_t bufsize = 16 * 1024;
  const size_t maxsize = (is_file_port(oport)
                          ? 10 * 1024 * 1024
                          : 128 * 1024);
  char *buf = malloc(bufsize);
  while (bytes != 0)
    {
      size_t toread = (bytes < 0 || (size_t)bytes > bufsize
                       ? bufsize
                       : (size_t)bytes);
      size_t res = fread(buf, 1, toread, f);
      struct oport_stat obuf;
      port_stat(oport, &obuf);
      if (obuf.size + res >= maxsize)
        {
          result = -1;
          break;
        }
      port_write(oport, buf, res);
      if (bytes >= 0)
        bytes -= res;
      if (res < toread)
        {
          result = ferror(f) ? EIO : 0;
          break;
        }
    }
  free(buf);
  UNGCPRO();

  if (must_close && fclose(f) != 0)
    result = errno;

  return makeint(result);
}

UNSAFEOP(print_file, ,
         "`oport `file|`s -> `n. Print the contents of `file or `s to output"
         " port `oport. Returns zero if successful, a Unix errno value"
         " if there was file I/O error, or -1 if `oport became too full."
         " Cf. `print_file_part().",
         (struct oport *p, value mfile),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "o[so].n")
{
  return code_print_file_part(p, mfile, makeint(0), NULL);
}

UNSAFEOP(file_read, ,
         "`file|`s1 -> `s2|`n. Reads and returns at most `MAX_STRING_SIZE"
         " characters from `file or `s1. Returns a Unix errno value on error.",
         (value mfile),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "[so].[sn]")
{
  bool must_close = false;

  FILE *f = NULL;
  CHECK_TYPES(mfile, OR(CT_PATHNAME, CT_FILE(f)));

  if (TYPE(mfile, string))
    {
      f = fopen(((struct string *)mfile)->str, "r");
      if (f == NULL)
        return makeint(errno);
      must_close = true;
    }
  else if (f == NULL)
    return makeint(EBADF);

  size_t size = MAX_STRING_SIZE;
  struct stat fs;
  if (fstat(fileno(f), &fs) < 0)
    goto got_error;

  if ((fs.st_mode & S_IFMT) == S_IFREG)
    {
      off_t opos = ftello(f);
      if (opos < 0)
        goto got_error;

      if (fs.st_size >= opos)
        {
          size = fs.st_size - opos;
          if (size > MAX_STRING_SIZE)
            size = MAX_STRING_SIZE;
        }
    }

  char *buf = NULL;
  size_t n = 0;
  if (size > 0)
    {
      buf = malloc(size);
      if (buf == NULL)
        {
          int oerrno = errno;
          primitive_runtime_warning("failed to allocate memory", THIS_OP,
                                    1, mfile);
          errno = oerrno;
          goto got_error;
        }

      n = fread(buf, 1, size, f);
      if (n == 0 && ferror(f))
        {
          free(buf);
          errno = EIO;              /* a random error code */
          goto got_error;
        }
    }

  if (must_close)
    fclose(f);

  struct string *s = alloc_string_length(buf, n);
  free(buf);
  return s;

 got_error: ;
  int r = errno;
  if (must_close)
    fclose(f);
  return makeint(r);
}

static bool write_block(void *data, struct string *mstr, size_t len)
{
  const char *str = mstr->str;
  FILE *f = data;
  if (fwrite(str, 1, len, f) != len && ferror(f))
    return false;
  return true;
}

static value file_write(value mfile, value data, bool do_append,
                        const struct prim_op *op)
{
  bool must_close = false;

  FILE *f = NULL;
  CHECK_TYPES_OP(op,
                 mfile, OR(CT_PATHNAME, CT_FILE(f)),
                 data,  OR(string, CT_STR_OPORT));

  if (TYPE(mfile, string))
    {
      f = fopen(((struct string *)mfile)->str, do_append ? "a" : "w");
      if (f == NULL)
        return makeint(-1);
      must_close = true;
    }
  else if (f == NULL)
    primitive_runtime_error_msg(
      error_bad_value, "expected an open file", op, -1, 2, mfile, data);

  if (!(TYPE(data, string)
        ? write_block(f, data, string_len((struct string *)data))
        : port_for_blocks(data, write_block, f)))
    goto got_error;

  if (must_close && fclose(f) != 0)
    return makeint(-1);

  return makeint(0);

 got_error: ;
  if (must_close)
    fclose(f);
  return makeint(-1);
}

UNSAFEOP(file_write, ,
         "`file|`s1 `s2|`p -> `n. Writes string `s2 (or contents of string"
         " port `p) to `file or `s1.\n"
         "Creates the file if does not exist.\n"
         "Returns -1 for failure or 0 for success.\n"
         "On failure, partial data may have been written.",
         (value mfile, value data),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "[so][so].n")
{
  return file_write(mfile, data, false, THIS_OP);
}

UNSAFEOP(file_append, ,
         "`file|`s1 `s2|`p -> `n. Appends string `s2 (or contents of string"
         " port `p) to file `file or `s1.\n"
         "Creates the file if does not exist.\n"
         "Returns -1 for failure or 0 for success.\n"
         "On failure, partial data may have been written.",
         (value mfile, value data),
         OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "[so][so].n")
{
  return file_write(mfile, data, true, THIS_OP);
}

SECOP(passwd_file_entries, ,
      "-> `l. Returns a list of [ `pw_name `pw_uid"
      " `pw_gid `pw_gecos `pw_dir `pw_shell ] from the contents of"
      " /etc/passwd. Cf. `getpwent(3)",
      (void), LVL_VALA, OP_LEAF | OP_NOESCAPE, ".l")
{
  CHECK_TYPES();

  struct list *res = NULL;
  struct vector *v = NULL;

  GCPRO(res, v);

  setpwent();
  for (;;)
    {
      errno = 0;
      struct passwd *pw = getpwent();
      if (pw == NULL)
        {
          int eno = errno;
          if (eno == EINTR)
            continue;
          endpwent();
          /* handle https://sourceware.org/bugzilla/show_bug.cgi?id=23410 */
          if (eno != 0 && eno != ENOENT)
            RUNTIME_ERROR(error_bad_value, errno_message(eno, "getpwent()"));
          break;
	}

      v = alloc_vector(PASSWD_ENTRY_FIELDS);
      SET_VECTOR(v, PW_NAME,  alloc_string(pw->pw_name));
      SET_VECTOR(v, PW_UID,   makeint(pw->pw_uid));
      SET_VECTOR(v, PW_GID,   makeint(pw->pw_gid));
      SET_VECTOR(v, PW_GECOS, alloc_string(pw->pw_gecos));
      SET_VECTOR(v, PW_DIR,   alloc_string(pw->pw_dir));
      SET_VECTOR(v, PW_SHELL, alloc_string(pw->pw_shell));

      res = alloc_list(v, res);
    }

  UNGCPRO();

  return res;
}

SECOP(group_file_entries, ,
      "-> `l. Returns a list of [ `gr_name `gr_gid ( `gr_mem ... ) ] from"
      " the contents of /etc/group. Cf. `getgrent(3)",
      (void), LVL_VALA, OP_LEAF | OP_NOESCAPE, ".l")
{
  CHECK_TYPES();

  struct list *res = NULL, *l = NULL;
  struct group *grp;
  struct vector *v = NULL;

  GCPRO(res, v, l);

  setgrent();
  for (;;)
    {
      errno = 0;
      grp = getgrent();
      if (grp == NULL)
        {
          int eno = errno;
          if (eno == EINTR)
            continue;
	  endgrent();
	  if (eno != 0 && eno != ENOENT)
	    RUNTIME_ERROR(error_bad_value, errno_message(eno, "getgrent()"));
	  break;
	}

      v = alloc_vector(3);
      SET_VECTOR(v, GR_NAME, alloc_string(grp->gr_name));
      SET_VECTOR(v, GR_GID, makeint(grp->gr_gid));

      l = NULL;
      for (char **s = grp->gr_mem; *s; ++s)
	{
	  struct string *str = alloc_string(*s);
	  l = alloc_list(str, l);
	}

      SET_VECTOR(v, GR_MEM, l);

      res = alloc_list(v, res);
    }

  UNGCPRO();

  return res;
}

#if defined __linux__ || defined __MACH__
SECOP(mount_points, ,
      "-> `l. Returns a list of mount points, where each mount point"
      " is a vector indexed by `MNT_xxx:\n"
      "  `MNT_FSNAME   \tname fo the filesystem\n"
      "  `MNT_DIR      \tfilesystem path prefix\n"
      "  `MNT_TYPE     \tmount type\n"
      "  `MNT_OPTS     \tmount options\n"
      "  `MNT_FREQ     \tdump frequency in days\n"
      "  `MNT_PASSNO   \tpass number for parallel fsck\n"
      "Cf. `file_system_stat().",
      (void), LVL_VALA, OP_LEAF | OP_NOESCAPE, ".l")
{
#ifdef __linux__
  FILE *fmtab = setmntent("/etc/mtab", "r");
  if (fmtab == NULL)
    runtime_error_message(error_abort, "failed to open /etc/mtab");
 #define FSF(ent, l, m) (ent)->mnt_ ## l
 #define for_fsent(ent)                                                 \
  for (bool __done = false; (__done = !__done); endmntent(fmtab))       \
    for (struct mntent *ent; (ent = getmntent(fmtab));)
#elif defined __MACH__
  if (!setfsent())
    runtime_error_message(error_abort, "setfsent() failed");
 #define FSF(ent, l, m) (ent)->fs_ ## m
 #define for_fsent(ent)                                                 \
  for (bool __done = false; (__done = !__done); endfsent())             \
    for (struct fstab *ent; (ent = getfsent());)
#else
  #error Unsupported platform
#endif
  struct list *res = NULL;
  struct vector *v = NULL;
  GCPRO(res, v);
  for_fsent (ent)
    {
      v = alloc_vector(MOUNT_ENTRY_FIELDS);
      SET_VECTOR(v, MNT_FSNAME, alloc_string(FSF(ent, fsname, spec)));
      SET_VECTOR(v, MNT_DIR,    alloc_string(FSF(ent, dir,    file)));
      SET_VECTOR(v, MNT_TYPE,   alloc_string(FSF(ent, type,   type)));
      SET_VECTOR(v, MNT_OPTS,   alloc_string(FSF(ent, opts,   mntops)));
#ifdef USE_GMP
      SET_VECTOR(v, MNT_FREQ,   make_int_or_bigint(FSF(ent, freq,   freq)));
      SET_VECTOR(v, MNT_PASSNO, make_int_or_bigint(FSF(ent, passno, passno)));
#endif
      res = alloc_list(v, res);
    }
  UNGCPRO();
  return res;
}
#endif	/* __linux__ || defined __MACH__ */

void files_init(void)
{
  DEFINE(load);
  DEFINE(loading_file);
  DEFINE(file_read);
  DEFINE(file_write);
  DEFINE(file_append);
  DEFINE(print_file);
  DEFINE(print_file_part);

  DEFINE(mkdir);
  DEFINE(rmdir);
  DEFINE(directory_files);
  DEFINE(file_stat);
  DEFINE(file_utime);

  DEFINE(filep);
  DEFINE(file_openp);
  DEFINE(file_open);
  DEFINE(file_close);
  DEFINE(file_oport);
  DEFINE(file_seek);
  DEFINE(file_tell);
  DEFINE(file_flush);
  DEFINE(file_setbuf);
  DEFINE(file_truncate);

  DEFINE(chdir);

  DEFINE(realpath);
  DEFINE(dirname);
  DEFINE(mudlle_basename);

  DEFINE(symlink);
  DEFINE(readlink);
  DEFINE(file_lstat);
  DEFINE(passwd_file_entries);
  DEFINE(group_file_entries);

#if defined __linux__ || defined __MACH__
  DEFINE(mount_points);
#endif
  DEFINE(file_system_stat);

  DEFINE_INT(S_IFMT);
  DEFINE_INT(S_IFSOCK);
  DEFINE_INT(S_IFLNK);
  DEFINE_INT(S_IFBLK);
  DEFINE_INT(S_IFREG);
  DEFINE_INT(S_IFDIR);
  DEFINE_INT(S_IFCHR);
  DEFINE_INT(S_IFIFO);
  DEFINE_INT(S_ISUID);
  DEFINE_INT(S_ISGID);
  DEFINE_INT(S_ISVTX);
  DEFINE_INT(S_IRWXU);
  DEFINE_INT(S_IRUSR);
  DEFINE_INT(S_IWUSR);
  DEFINE_INT(S_IXUSR);
  DEFINE_INT(S_IRWXG);
  DEFINE_INT(S_IRGRP);
  DEFINE_INT(S_IWGRP);
  DEFINE_INT(S_IXGRP);
  DEFINE_INT(S_IRWXO);
  DEFINE_INT(S_IROTH);
  DEFINE_INT(S_IWOTH);
  DEFINE_INT(S_IXOTH);

  DEFINE(chown);
  DEFINE(chmod);

  DEFINE(mkstemp);

  DEFINE(file_regularp);
  DEFINE(directoryp);

  DEFINE(remove);
  DEFINE(rename);

  DEFINE(strerror);

  DEFINE(getcwd);
  DEFINE(getenv);

  DEFINE(getuid);
  DEFINE(geteuid);
  DEFINE(getgid);
  DEFINE(getegid);

  DEFINE_INT(SEEK_SET);
  DEFINE_INT(SEEK_CUR);
  DEFINE_INT(SEEK_END);

  system_define("FILE_IONBF", makeint(_IONBF));
  system_define("FILE_IOLBF", makeint(_IOLBF));
  system_define("FILE_IOFBF", makeint(_IOFBF));

  DEFINE(glob_files);
#ifdef GLOB_MARK
  DEFINE_INT(GLOB_MARK);
#endif
#ifdef GLOB_NOCHECK
  DEFINE_INT(GLOB_NOCHECK);
#endif
#ifdef GLOB_NOESCAPE
  DEFINE_INT(GLOB_NOESCAPE);
#endif
#ifdef GLOB_TILDE
  DEFINE_INT(GLOB_TILDE);
#endif
#ifdef GLOB_BRACE
  DEFINE_INT(GLOB_BRACE);
#endif
#ifdef GLOB_PERIOD
  DEFINE_INT(GLOB_PERIOD);
#endif
#ifdef GLOB_NOMAGIC
  DEFINE_INT(GLOB_NOMAGIC);
#endif
#ifdef GLOB_ONLYDIR
  DEFINE_INT(GLOB_ONLYDIR);
#endif
}
