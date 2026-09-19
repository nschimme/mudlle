#ifndef MUDLLE_H
#define MUDLLE_H

/* Generally useful declarations for the mudlle (pronounced muddle)
   interpreter */

#include "mudlle-config.h"

#ifdef USE_GMP
#  include <gmp.h>
#endif

#  include <assert.h>
#  include <stdbool.h>
#  include <stdint.h>
#  include <stdlib.h>
#  include <stdnoreturn.h>

#  define UNUSED __attribute__((__unused__))
#  define FMT_PRINTF(a, b) __attribute__((format(printf, a, b)))

#  define EXPECT_FALSE(c) __builtin_expect((c), 0)

#  define FALLTHROUGH ((void)0)
#  define NONSTRING
#  if defined __has_attribute
#    if __has_attribute (fallthrough)
#      undef FALLTHROUGH
#      define FALLTHROUGH __attribute__((fallthrough))
#    endif
#    if __has_attribute (nonstring)
#      undef NONSTRING
#      define NONSTRING __attribute__((nonstring))
#    endif
#  endif


enum mudlle_data_version {
  MDATA_VER_LEGACY,
  MDATA_VER_NEW_HASH,       /* new hash algorithm for symbol tables */
  MDATA_VER_RO_SYM_NAMES,   /* symbols forced to have readonly names */

  MDATA_VERSIONS,
  MDATA_VER_CURRENT = MDATA_VERSIONS - 1
};

void mudlle_init(void);

#endif
