#include "array.h"
#include "utils.h"

void array_make_room(struct generic_array *array, size_t elems, size_t dsize)
{
  assert(SIZE_MAX - array->used >= elems);
  size_t nsize = array->used + elems;
  if (nsize > array->size)
    {
      array->size = nsize <= 16 ? 16 : NEXT_POW2(nsize - 1);
      array->data = realloc(array->data, dsize * array->size);
    }
}

void array_set_size(struct generic_array *array, size_t elems, size_t dsize)
{
  array->data = realloc(array->data, dsize * elems);
  array->size = elems;
  if (array->used > array->size)
    array->used = array->size;
}

void array_copy(struct generic_array *dst, struct generic_array *src,
                size_t dsize)
{
  array_free(dst);
  if (src->used == 0)
    return;
  dst->size = dst->used = src->used;
  size_t asize = dst->used * dsize;
  dst->data = malloc(asize);
  memcpy(dst->data, src->data, asize);
}
