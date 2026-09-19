#include "mudlle-config.h"

#include <signal.h>
#include <stdio.h>

#include <sys/time.h>

#include "array.h"
#include "call.h"
#include "dlist.h"
#include "global.h"
#include "mtree.h"
#include "mvalgrind.h"
#include "profile.h"

#undef LOCAL_MUDLLE_TYPES
#define LOCAL_MUDLLE_TYPES struct mprofile *: true,

#define PROFILE_PERIOD_USEC 1000
#define VALGRIND_PROFILE_PERIOD_USEC 200000

CASSERT(sizeof (internal_xcount) == sizeof (long));
/* internal_xcount must always be lock free */
#if ATOMIC_LONG_LOCK_FREE != 2
# error This might not work.
#endif

static atomic_long profile_count;

struct profile_node {
  struct c_call_trace_entry entry;
  struct {
    size_t size, used;
    struct profile_node *data;
  } children;
  unsigned self_count, child_count;
};

struct profile {
  /* doubly-linked list, NULL pointers at ends */
  struct dlist active;
  struct profile_node tree;
  struct call_stack_c_header *limit;
  size_t idx;                   /* index into all_profiles */
  bool is_active;               /* if in active_profiles */
  bool referenced;              /* if mudlle object has a reference */
};

#define DL_PROF(dl) DLIST_GET(dl, struct profile, active)

/* unlimted profiles are added first, limited are added last, and must be in
   last-in-first-out (stack) order */
static DEFINE_DLIST(active_profiles);

static ARRAY_T(struct profile *) all_profiles;

static struct c_call_trace profile_trace;

static bool is_profiling;

static void sigprof_handler(int sig)
{
  /* it's unnecessary with atomic ops in signal handler */
  internal_xcount |= XCOUNT_PROFILE_FLAG;
  ++profile_count;
}

static void tick_one_profile(struct profile *profile,
                             struct c_call_trace *trace,
                             long count)
{
  struct profile_node *node = &profile->tree;
  for (size_t i = trace->used; i-- > 0; )
    {
      node->child_count += count;
      for (size_t j = 0; j < node->children.used; ++j)
        if (c_call_trace_entries_equal(&node->children.data[j].entry,
                                       &trace->data[i]))
          {
            node = &node->children.data[j];
            goto found;
          }

      size_t nsize = node->children.size;
      if (node->children.used >= nsize)
        {
          node->children.size = nsize = nsize ? nsize * 2 : 8;
          node->children.data = realloc(node->children.data,
                                        nsize * sizeof *node->children.data);
        }
      struct profile_node *nnode = &node->children.data[node->children.used];
      ++node->children.used;
      *nnode = (struct profile_node){
        .entry = trace->data[i]
      };
      node = nnode;
    found:
      if (i == 0)
        node->self_count += count;
    }
}

static inline void clear_profile_flag(void)
{
  internal_xcount &= ~XCOUNT_PROFILE_FLAG;
}

void profile_tick(void)
{
  ASSERT_NOALLOC_START();
  profile_trace.used = 0;
  get_c_call_trace(&profile_trace,
                   (DL_PROF(active_profiles.next)->limit == NULL
                    ? NULL
                    : DL_PROF(active_profiles.prev)->limit));

  clear_profile_flag();

  long count;
  do
    count = profile_count;
  while (!atomic_compare_exchange_weak(&profile_count, &count, 0));

  for_dlist (active_profiles, prof, struct profile, active)
    tick_one_profile(prof, &profile_trace, count);
  ASSERT_NOALLOC();
}

static struct vector *profile_mudlle_data(const struct profile_node *node)
{
  struct vector *v = alloc_vector(node->children.used);
  GCPRO(v);
  for (size_t i = 0; i < node->children.used; ++i)
    SET_VECTOR(v, i, profile_mudlle_data(&node->children.data[i]));
  {
    struct vector *v2 = alloc_vector(prof_node_entries);
    SET_VECTOR(v2, prof_node_children, v);
    v = v2;
  }
  UNGCPRO();
  value this = NULL;
  switch (node->entry.class)
    {
    case ct_mudlle: this = node->entry.u.mudlle; break;
    case ct_string: this = scache_alloc_str(node->entry.u.string); break;
    case ct_prim:
      this = GVAR(mglobal_lookup(node->entry.u.primop->name));
      break;
    }
  SET_VECTOR(v, prof_node_entry,       this);
  SET_VECTOR(v, prof_node_self_count,  makeint(node->self_count));
  SET_VECTOR(v, prof_node_child_count, makeint(node->child_count));
  return v;
}

struct mprofile {
  struct mprivate p;
  struct profile *profile;
};

struct vector *extract_profile(struct mprofile *mprofile)
{
  assert(is_profile_data(mprofile));
  init_string_cache(NULL);
  struct profile *profile = mprofile->profile;
  struct vector *result = profile_mudlle_data(&profile->tree);
  free_string_cache();
  return result;
}

static void free_profile_node(struct profile_node *node)
{
  for (size_t i = 0; i < node->children.used; ++i)
    free_profile_node(&node->children.data[i]);
  free(node->children.data);
  *node = (struct profile_node){ 0 };
}

static void maybe_free_profile(struct profile *prof)
{
  if (prof->is_active || prof->referenced)
    return;

  size_t aidx = prof->idx;
  ARRAY_DEL(all_profiles, aidx);
  if (aidx < ARRAY_ENTRIES(all_profiles))
    {
      /* another profile pointer took our place; update its index */
      struct profile *p = ARRAY_GET(all_profiles, aidx);
      p->idx = aidx;
    }
  free_profile_node(&prof->tree);
  free(prof);
}

static void profile_mudlle_free(void *data)
{
  struct profile *prof = data;
  prof->referenced = false;
  maybe_free_profile(prof);
}

bool is_profile_data(value v)
{
  if (!TYPE(v, private))
    return false;
  struct mprivate *p = v;
  return p->ptype == makeint(PRIVATE_PROFILE);
}

static void maybe_start_profile_timer(void)
{
  if (is_profiling)
    return;

  struct sigaction sact = {
    .sa_handler = sigprof_handler,
    .sa_flags   = SA_RESTART
  };
  sigemptyset(&sact.sa_mask);
  if (sigaction(SIGPROF, &sact, NULL) < 0)
    {
      perror("sigaction()");
      abort();
    }

  long period_usec = (RUNNING_ON_VALGRIND > 0
                      ? VALGRIND_PROFILE_PERIOD_USEC
                      : PROFILE_PERIOD_USEC);

  const struct itimerval tv = {
    .it_interval.tv_usec = period_usec,
    .it_value.tv_usec    = 1 + random_range32(period_usec - 1),
  };
  if (setitimer(ITIMER_PROF, &tv, NULL) != 0)
    {
      perror("setitimer(ITIMER_PROF, ...)");
      abort();
    }
  is_profiling = true;
}

static void maybe_stop_profile_timer(void)
{
  if (!is_profiling || !dlist_is_empty(&active_profiles))
    return;

  if (setitimer(ITIMER_PROF, &(const struct itimerval){ 0 }, NULL) != 0)
    {
      perror("setitimer(ITIMER_PROF, 0, ...)");
      abort();
    }

  struct sigaction sact = {
    .sa_handler = SIG_IGN
  };
  if (sigaction(SIGPROF, &sact, NULL) < 0)
    {
      perror("sigaction()");
      abort();
    }

  profile_count = 0;
  clear_profile_flag();

  is_profiling = false;
}

/* profiles with non-NULL limits but be activated/deactivated in
   first-in-last-out (stack) order */
static void activate_profile(struct profile *profile,
                             struct call_stack_c_header *limit)
{
  profile->limit     = limit;
  profile->is_active = true;

  if (limit != NULL)
    {
      /* limited profiles are added last */
      dlist_insert_before(&active_profiles, &profile->active);
    }
  else
    {
      /* unlimited profiles are added first */
      dlist_insert_after(&active_profiles, &profile->active);
    }
}

static void deactivate_profile(struct profile *profile)
{
  dlist_remove(&profile->active);
}

static struct profile *alloc_profile(void)
{
  struct profile *profile = malloc(sizeof *profile);
  *profile = (struct profile){
    .tree.entry.class = ct_mudlle,
    .idx = ARRAY_ENTRIES(all_profiles)
  };
  ARRAY_ADD(all_profiles, profile);
  return profile;
}

static struct mprofile *alloc_mprofile(struct profile *profile)
{
  struct mprofile *mprofile = (struct mprofile *)alloc_weak_ref(
    type_private, sizeof *mprofile, profile, profile_mudlle_free);
  mprofile->p.ptype = makeint(PRIVATE_PROFILE);
  mprofile->profile = profile;
  return mprofile;
}

struct mprofile *start_profiling(struct mprofile *mprofile)
{
  struct profile *profile;
  if (mprofile == NULL)
    profile = alloc_profile();
  else
    {
      assert(is_profile_data(mprofile));
      profile = mprofile->profile;
      if (profile->is_active)
        return mprofile;        /* already running; just return */
    }

  maybe_start_profile_timer();

  activate_profile(profile, NULL);

  profile->referenced = true;
  return alloc_mprofile(profile);
}

void stop_profiling(struct mprofile *mprofile)
{
  assert(is_profile_data(mprofile));
  struct profile *profile = mprofile->profile;
  if (!profile->is_active)
    return;
  deactivate_profile(profile);
}

struct list *profile_call0(value f, struct mprofile *mprofile)
{
  bool was_profiling = is_profiling;

  struct profile *profile;
  if (mprofile == NULL)
    profile = alloc_profile();
  else
    {
      assert(is_profile_data(mprofile));
      profile = mprofile->profile;
      if (profile->is_active)
        {
          /* This profile is already collecting profiling data.
             We can just call f(). */
          assert(was_profiling);
          GCPRO(mprofile);
          value result = call0(f);
          UNGCPRO();
          return alloc_list(mprofile, result);
        }
    }

  maybe_start_profile_timer();

  struct call_stack_c_header me = {
    .s = {
      .next = call_stack,
      .type = call_string_args
    },
    .u.name = "profile-call",
    .nargs = 0
  };
  call_stack = &me.s;

  activate_profile(profile, &me);

  value result;
  {
    GCPRO(mprofile);
    result = mcatch_call(NULL, f);
    UNGCPRO();
  }

  call_stack = me.s.next;

  if (mprofile == NULL)
    {
      GCPRO(result);
      mprofile = alloc_mprofile(profile);
      UNGCPRO();
      profile->referenced = true;
    }
  assert(profile->referenced);

  deactivate_profile(profile);

  maybe_stop_profile_timer();

  maybe_mrethrow();
  return alloc_list(mprofile, result);
}

static void forward_profile_node(struct profile_node *node,
                                 gc_forward_fn forward)
{
  if (node->entry.class == ct_mudlle)
    maybe_forward(forward, &node->entry.u.mudlle);
  for (size_t i = 0; i < node->children.used; ++i)
    forward_profile_node(&node->children.data[i], forward);
}

void forward_profile_roots(gc_forward_fn forward)
{
  ARRAY_FOR (all_profiles, , struct profile *, prof)
    forward_profile_node(&prof->tree, forward);
}
