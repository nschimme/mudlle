#include "dlist.h"
#include "mudlle.h"

void dlist_insert_before(struct dlist *where, struct dlist *data)
{
  assert(data->next == NULL && data->prev == NULL);
  data->prev = where->prev;
  data->next = where;
  where->prev->next = data;
  where->prev = data;
}

void dlist_insert_after(struct dlist *where, struct dlist *data)
{
  assert(data->next == NULL && data->prev == NULL);
  data->prev = where;
  data->next = where->next;
  where->next->prev = data;
  where->next = data;
}

void dlist_remove(struct dlist *what)
{
  what->prev->next = what->next;
  what->next->prev = what->prev;
  what->next = what->prev = NULL;
}

size_t dlist_entries(const struct dlist *head)
{
  size_t n = 0;
  for (const struct dlist *d = head->next; d != head; d = d->next)
    ++n;
  return n;
}
