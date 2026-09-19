#include "mudlle-config.h"

#include "jitdump.h"

#if !defined NOCOMPILER && defined __linux__

#define _GNU_SOURCE             /* for gettid() */

#include <stdio.h>
#include <time.h>
#include <unistd.h>

#include <sys/mman.h>

#include "dwarf.h"
#include "elf.h"
#include "mvalues.h"
#include "strbuf.h"
#include "utils.h"

/* https://github.com/torvalds/linux/blob/master/tools/perf/Documentation/
   jitdump-specification.txt */

#define JITDUMP_HEADER_MAGIC   0x4a695444 /* "JiTD" */
#define JITDUMP_HEADER_VERSION 1

struct jitdump_header {
  uint32_t magic;
  uint32_t version;
  uint32_t total_size;
  uint32_t elf_mach;
  uint32_t pad1;
  uint32_t pid;
  uint64_t timestamp;
  uint64_t flags;
};

enum jit_record_type {
  JIT_CODE_LOAD,
  JIT_CODE_MOVE,
  JIT_CODE_DEBUG_INFO,
  JIT_CODE_CLOSE,
};

struct jitdump_record_header {
  enum jit_record_type id : 32;
  uint32_t total_size;
  uint64_t timestamp;
};

struct jitdump_load_record {
  struct jitdump_record_header h;
  uint32_t pid;
  uint32_t tid;
  uint64_t vma;
  uint64_t code_addr;
  uint64_t code_size;
  uint64_t code_index;
  /* followed by NUL-terminated name */
};

struct jitdump_move_record {
  struct jitdump_record_header h;
  uint32_t pid;
  uint32_t tid;
  uint64_t vma;
  uint64_t old_code_addr;
  uint64_t new_code_addr;
  uint64_t code_size;
  uint64_t code_index;
};

struct jitdump_debug_entry {
  uint64_t addr;
  int lineno;        /* source line number starting at 1 */
  int discrim;       /* column discriminator, 0 is default */
  /* followed by NUL-terminated filename; \xff\0 if same as previous entry */
};

struct jitdump_debug_info_record {
  struct jitdump_record_header h;
  uint64_t code_addr;
  uint64_t nr_entry;
  /* followed by struct jitdump_debug_entry */
};

static FILE *jitdump_file;
static void *jitdump_mmap;

static struct strbuf jitdump_path;

static uint64_t jitdump_timestamp(void)
{
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts))
    {
      perror("clock_gettime()");
      abort();
    }
  return (uint64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

void start_jitdump(const char *dstdir, const char *srcpath)
{
  if (dstdir == NULL)
    dstdir = "";

  struct strbuf sb = sb_initf("%s%sjit-%ld.dump", dstdir,
                              *dstdir ? "/" : "", (long)getpid());
  jitdump_file = fopen(sb_str(&sb), "w+");

  if (jitdump_file == NULL)
    {
      struct strbuf sberr = sb_initf("fopen(\"%s\")", sb_str(&sb));
      perror(sb_str(&sberr));
      sb_free(&sberr);
      sb_free(&sb);
      return;
    }

  sb_free(&sb);

  sb_empty(&jitdump_path);
  sb_addstr(&jitdump_path, srcpath);

  jitdump_mmap = mmap(NULL, pagesize, PROT_READ | PROT_EXEC,
                      MAP_PRIVATE, fileno(jitdump_file), 0);
  if (jitdump_mmap == MAP_FAILED)
    {
      perror("mmap()");
      stop_jitdump();
      return;
    }

  struct jitdump_header header = {
    .magic      = JITDUMP_HEADER_MAGIC,
    .version    = JITDUMP_HEADER_VERSION,
    .total_size = sizeof header,
    .elf_mach   = EM_MACHINE,
    .pid        = getpid(),
    .timestamp  = jitdump_timestamp(),
  };
  fwrite(&header, sizeof header, 1, jitdump_file);
  fflush(jitdump_file);
}

void stop_jitdump(void)
{
  sb_free(&jitdump_path);
  if (jitdump_mmap != NULL && jitdump_mmap != MAP_FAILED)
    {
      munmap(jitdump_mmap, pagesize);
      jitdump_mmap = NULL;
    }
  if (jitdump_file == NULL)
    return;
  fclose(jitdump_file);
  jitdump_file = NULL;
}

static void jitdump_debug_info(struct mcode *mcode)
{
  size_t nstates;
  struct lni_state *states = line_number_info(mcode->code.linenos, &nstates);
  if (states == NULL)
    return;

  size_t namesize = string_len(code_filename(&mcode->code)) + 1;

  struct jitdump_debug_info_record r = {
    .h = {
      .id         = JIT_CODE_DEBUG_INFO,
      .total_size = (sizeof r
                     + nstates * sizeof (struct jitdump_debug_entry)
                     + nstates * sb_len(&jitdump_path)
                     + nstates * namesize),
      .timestamp  = jitdump_timestamp()
    },
    .code_addr  = (ulong)&mcode->mcode,
    .nr_entry   = nstates
  };
  fwrite(&r, sizeof r, 1, jitdump_file);
  for (size_t i = 0; i < nstates; ++i)
    {
      /* it looks like a bug in linux/tools/perf/util/genelf.c that one has to
         add sizeof (struct elf_file_hdr) below */
      struct jitdump_debug_entry e = {
        .addr   = ((ulong)&mcode->mcode
                   + sizeof (struct elf_file_hdr)
                   + states[i].addr),
        .lineno = states[i].line,
      };
      fwrite(&e, sizeof e, 1, jitdump_file);
      fwrite(sb_str(&jitdump_path), sb_len(&jitdump_path), 1, jitdump_file);
      fwrite(code_filename(&mcode->code)->str, namesize, 1, jitdump_file);
    }

  free(states);
  fflush(jitdump_file);
}

void jitdump_load(struct mcode *mcode)
{
  if (jitdump_file == NULL)
    return;

  jitdump_debug_info(mcode);

  static const char fn_str[] = "fn";
  const char *name = (mcode->code.varname
                      ? mcode->code.varname->str
                      : fn_str);
  size_t namesize = (mcode->code.varname
                     ? string_len(mcode->code.varname) + 1
                     : sizeof fn_str);


  struct jitdump_load_record r = {
    .h = {
      .id         = JIT_CODE_LOAD,
      .total_size = sizeof r + namesize + mcode->code_length,
      .timestamp  = jitdump_timestamp()
    },
    .pid        = getpid(),
    .tid        = gettid(),
    .vma        = (ulong)&mcode->mcode,
    .code_addr  = (ulong)&mcode->mcode,
    .code_size  = mcode->code_length,
    .code_index = mcode->sequence
  };
  fwrite(&r, sizeof r, 1, jitdump_file);
  fwrite(name, namesize, 1, jitdump_file);
  fwrite(mcode->mcode, mcode->code_length, 1, jitdump_file);
  fflush(jitdump_file);
}

/* note that 'new_mcode' might not have the moved object yet */
void jitdump_move(struct mcode *old_mcode, struct mcode *new_mcode)
{
  if (jitdump_file == NULL)
    return;

  struct jitdump_move_record r = {
    .h = {
      .id         = JIT_CODE_MOVE,
      .total_size = sizeof r,
      .timestamp  = jitdump_timestamp()
    },
    .pid           = getpid(),
    .tid           = gettid(),
    .vma           = (ulong)&new_mcode->mcode,
    .old_code_addr = (ulong)old_mcode->mcode,
    .new_code_addr = (ulong)&new_mcode->mcode,
    .code_size     = old_mcode->code_length,
    .code_index    = old_mcode->sequence
  };
  fwrite(&r, sizeof r, 1, jitdump_file);
  fflush(jitdump_file);
}

#else  /* NOCOMPILER || !__linux__ */

void start_jitdump(const char *dstdir, const char *srcpath) { }
void stop_jitdump(void) { }

void jitdump_load(struct mcode *mcode) { }
void jitdump_move(struct mcode *old_mcode, struct mcode *new_mcode) { }

#endif /* NOCOMPILER || !__linux__ */
