#ifndef MUDLLE_LPSOLVE_H
#define MUDLLE_LPSOLVE_H

#include "mudlle.h"

#ifdef BUILD
#error Fix me; lp_solve may redefine BUILD
#endif

#ifdef USE_LPSOLVE

#if defined HAVE_LP_LIB_H
#  include <lp_lib.h>
#elif defined HAVE_LPSOLVE_LP_LIB_H
#  include <lpsolve/lp_lib.h>
#else
#endif

#if MAJORVERSION == 5 && MINORVERSION == 5 && RELEASE == 0 && BUILD < 15
/* fix warning due to broken header file */
INLINE MYBOOL is_bb_rule(lprec *lp, int bb_rule) UNUSED;
INLINE MYBOOL is_bb_rule(lprec *lp, int bb_rule) { return 0; }
#endif

enum {
  LP_MAJORVERSION = MAJORVERSION,
  LP_MINORVERSION = MINORVERSION,
  LP_RELEASE      = RELEASE,
  LP_BUILD        = BUILD
};
#undef MAJORVERSION
#undef MINORVERSION
#undef RELEASE
#undef BUILD

enum {
  LP_OPTIMAL    = OPTIMAL,
  LP_SUBOPTIMAL = SUBOPTIMAL,
  LP_INFEASIBLE = INFEASIBLE,
  LP_UNBOUNDED  = UNBOUNDED,
  LP_DEGENERATE = DEGENERATE,
  LP_NUMFAILURE = NUMFAILURE,
  LP_USERABORT  = USERABORT,
  LP_TIMEOUT    = TIMEOUT,
  LP_RUNNING    = RUNNING,
  LP_PRESOLVED  = PRESOLVED,
};
#undef OPTIMAL
#undef SUBOPTIMAL
#undef INFEASIBLE
#undef UNBOUNDED
#undef DEGENERATE
#undef NUMFAILURE
#undef USERABORT
#undef TIMEOUT
#undef RUNNING
#undef PRESOLVED

#endif  /* USE_LPSOLVE */

#endif  /* MUDLLE_LPSOLVE_H */
