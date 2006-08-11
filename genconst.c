#include "mudlle.h"
#include <stdint.h>
#include "mvalues.h"
#include "error.h"

#define PR(name, value) ((void)printf("#define %-24s %11zu\n", #name, (value)))

#define DEF(op) ((void)printf("#define %-24s %11d\n", #op, (int)op))

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

  PR(mcode_seclevel,       offsetinobj(struct mcode, seclevel));
  PR(function_offset,      offsetinobj(struct mcode, mcode));

  PR(primitive_op,         offsetinobj(struct primitive, op));
  PR(primitive_call_count, offsetinobj(struct primitive, call_count));

  PR(primop_op,            offsetof(struct primitive_ext, op));
  PR(primop_nargs,         offsetof(struct primitive_ext, nargs));
  PR(primop_seclevel,      offsetof(struct primitive_ext, seclevel));

#ifdef USE_CCONTEXT
  PR(cc_frame_start,       offsetof(struct ccontext, frame_start));
  PR(cc_frame_end_sp,      offsetof(struct ccontext, frame_end_sp));
  PR(cc_frame_end_bp,      offsetof(struct ccontext, frame_end_bp));
  PR(cc_callee,            offsetof(struct ccontext, callee));
  PR(cc_caller,            offsetof(struct ccontext, caller));
  PR(cc_retadr,            offsetof(struct ccontext, retadr));
  PR(cc_SIZE,              sizeof (struct ccontext));
#endif

  PR(cs_next,              offsetof(struct call_stack, next));
  PR(cs_type,              offsetof(struct call_stack, type));

#  include "genconstdefs.h"

  return 0;
}
