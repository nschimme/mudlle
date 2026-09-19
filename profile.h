#ifndef PROFILE_H
#define PROFILE_H

#include "alloc.h"
#include "context.h"

enum {
  prof_node_entry,
  prof_node_self_count,
  prof_node_child_count,
  prof_node_children,
  /* end mudlle const */
  prof_node_entries
  /* start mudlle const */
};

struct mprofile;
struct list *profile_call0(value f, struct mprofile *mprofile);
void profile_tick(void);

void forward_profile_roots(gc_forward_fn forward);

struct vector *extract_profile(struct mprofile *mprofile);

bool is_profile_data(value v);

static inline void maybe_profile_tick(void)
{
  if (internal_xcount & XCOUNT_PROFILE_FLAG)
    profile_tick();
}

struct mprofile *start_profiling(struct mprofile *mprofile);
void stop_profiling(struct mprofile *mprofile);

#endif  /* PROFILE_H */
