#include <stddef.h>
#include <stdio.h>

#include "alloc.h"
#include "context.h"
#include "error.h"

#  include "genconstdefs.h"

#define PR(name, value) ((void)printf("#define %-24s %11zu\n", #name, (value)))

int main(int argc, char **argv)
{
  printf("/* automatically generated by %s */\n", argv[0]);

  PR(object_offset,        sizeof (struct obj));
#ifdef GCDEBUG
  PR(object_gen,           offsetof(struct obj, generation));
#endif
  PR(object_type,          offsetof(struct obj, flags) - 1);
  PR(object_size,          offsetof(struct obj, size));
  PR(object_info,          (offsetof(struct obj, size)
                            + sizeoffield(struct obj, size)));
  PR(object_flags,         offsetof(struct obj, flags));

  PR(pair_size,            sizeof (struct list));
  PR(pair_car_offset,      offsetof(struct list, car));
  PR(pair_cdr_offset,      offsetof(struct list, cdr));

  PR(variable_size,        sizeof (struct variable));

  PR(closure_code_offset,  offsetof(struct closure, code));

  PR(mcode_code_offset,    offsetof(struct mcode, mcode));

  PR(primitive_op,         offsetof(struct primitive, op));

  PR(primop_op,            offsetof(struct prim_op, op));
  PR(primop_nargs,         offsetof(struct prim_op, nargs));
  PR(primop_seclevel,      offsetof(struct prim_op, seclevel));

#ifdef USE_CCONTEXT
  PR(cc_frame_start,       offsetof(struct ccontext, frame_start));
  PR(cc_frame_end_sp,      offsetof(struct ccontext, frame_end_sp));
  PR(cc_frame_end_bp,      offsetof(struct ccontext, frame_end_bp));
#define __PR_CALLER(n, reg)                                     \
  PR(cc_caller_ ## reg, offsetof(struct ccontext, caller.reg))
  FOR_CALLER_SAVE(__PR_CALLER, ;);
#undef __PR_CALLER
#define __PR_CALLEE(n, reg)                                     \
  PR(cc_callee_ ## reg, offsetof(struct ccontext, callee.reg))
  FOR_CALLEE_SAVE(__PR_CALLEE, ;);
#undef __PR_CALLEE
  PR(cc_SIZE,              sizeof (struct ccontext));
#endif

  PR(cs_next,              offsetof(struct call_stack, next));
  PR(cs_type,              offsetof(struct call_stack, type));
  PR(cs_SIZE,              sizeof (struct call_stack));

#ifdef GCSTATS
  PR(gcstats_alloc,        offsetof(struct gcstats, a));
  PR(gcstats_alloc_size,   sizeoffield(struct gcstats_alloc, types[0]));
  PR(gcstats_alloc_nb,     offsetof(struct gcstats_alloc, types[0].nb));
  PR(gcstats_alloc_sz,     offsetof(struct gcstats_alloc, types[0].size));
#endif

#define DEF(op) ((void)printf("#define %-24s %11d\n", #op, (int)op));
  FOR_DEFS(DEF)
  FOR_MUDLLE_TYPES(DEF)

  return 0;
}
