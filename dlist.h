/* static doubly-linked list */

#ifndef DLIST_H
#define DLIST_H

#include "mudlle-config.h"

#include <stdbool.h>
#include <stddef.h>

struct dlist {
  struct dlist *next;
  struct dlist *prev;
};

#define DEFINE_DLIST(name)                      \
  struct dlist name = {                         \
    .prev = &name,                              \
    .next = &name                               \
  }

static ALWAYS_INLINE void init_dlist(struct dlist *head)
{
  head->prev = head->next = head;
}

static ALWAYS_INLINE bool dlist_is_empty(const struct dlist *head)
{
  return head->next == head;
}

/* allows deleting 'var' and break/continue */
#define for_dlist(head, var, type, field)               \
  for (bool __fdl_done = false; !__fdl_done; )          \
    for (type *var = NULL;                              \
         !__fdl_done;                                   \
         __fdl_done = true)                             \
      for (struct dlist *__fdln = (head).next;          \
           (__fdln == &(head)                           \
            ? false                                     \
            : (var = DLIST_GET(__fdln, type, field),    \
               __fdln = __fdln->next,                   \
               true));                                  \
           )

void dlist_insert_before(struct dlist *where, struct dlist *data);
void dlist_insert_after(struct dlist *where, struct dlist *data);
void dlist_remove(struct dlist *what);

size_t dlist_entries(const struct dlist *head);

/* 'node' is the struct dlist, 'type' is the struct it's embedded
   in, and 'field' is the field in 'type' that contains 'node' */
#define DLIST_GET(node, type, field)                    \
  (CASSERT_TYPE(&((type *)0)->field, struct dlist *),   \
   CASSERT_TYPE((node), struct dlist *),                \
   (type *)((char *)(node) - offsetof(type, field)))

#endif
