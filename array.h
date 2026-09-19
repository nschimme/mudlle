#ifndef ARRAY_H
#define ARRAY_H

#include "mudlle-config.h"

#include <stdlib.h>

#include "mudlle-macro.h"
#include "mudlle.h"
#include "random.h"

#define __ARRAY_STRUCT(name, type)              \
  struct name {                                 \
    size_t size, used;                          \
    type *data;                                 \
  }

__ARRAY_STRUCT(generic_array, void);

/* auto-growing arrays */
#define ARRAY_STRUCT(tag, type) struct tag {    \
  union {                                       \
    __ARRAY_STRUCT(, type);                     \
    struct generic_array generic;               \
  };                                            \
}
#define ARRAY_T(type) ARRAY_STRUCT(, type)

#define ARRAY_NULL { .generic = { .size = 0, .used = 0, .data = 0 } }

static inline void array_free(struct generic_array *array)
{
  free(array->data);
  *array = (struct generic_array){ 0 };
}

#define ARRAY_FREE(array) array_free(&(array).generic)

/* the array adopts the data in 'src' (malloc'ed data) with 'nelem' elements;
   frees any previous data */
#define ARRAY_ADOPT(array, src, nelem) do {     \
  (void)((array).data - (src));                 \
  ARRAY_FREE(array);                            \
  (array).data = (src);                         \
  (array).size = (array).used = (nelem);        \
} while (0)

/* copy contents of array 'src' into 'dst'; frees any previous data */
#define ARRAY_COPY(dst, src)                                            \
  array_copy(&(dst).generic, &(src).generic,                            \
             ((void)(&(dst) - &(src)), sizeof (dst).data[0]))

/* unary plus to avoid assignment */
#define ARRAY_SIZE(array)     (+(array).size)
#define ARRAY_ENTRIES(array)  (+(array).used)
#define ARRAY_IS_EMPTY(array) ((array).used == 0)

#define ARRAY_SET_SIZE(array, size)                             \
  array_set_size(&(array).generic, (size), sizeof (array).data[0])

#define ARRAY_TRIM(array) ARRAY_SET_SIZE((array), ARRAY_ENTRIES(array))

#define ARRAY_SET_ENTRIES(array, nused) do {                            \
  if ((nused) != 0)                                                     \
    assert((nused) > 0 && (size_t)(nused) <= ARRAY_SIZE(array));        \
  (array).used = (nused);                                               \
} while (0)
#define ARRAY_EMPTY(array) ((void)((array).used = 0))

#define ARRAY_MAKE_ROOM(array, elems)                           \
  array_make_room(&(array).generic, (elems), sizeof (array).data[0])

#define ARRAY_ADD(array, value) do {                            \
  if ((array).used >= (array).size)                             \
    ARRAY_MAKE_ROOM(array, 1);                                  \
  (array).data[(array).used++] = (value);                       \
} while (0)

#define ARRAY_POP(array)                                        \
  (assert((array).used > 0), (array).data[--(array).used])

#define ARRAY_GET(array, idx) ((array).data[idx])

#define ARRAY_SET(array, idx, value) do {       \
  size_t __idx = (idx);                         \
  assert(__idx < (array).used);                 \
  (array).data[__idx] = (value);                \
} while (0)

#define ARRAY_DEL(array, idx) do {                      \
  size_t __idx = (idx);                                 \
  assert(__idx < (array).used);                         \
  if (__idx < --(array).used)                           \
    (array).data[__idx] = (array).data[(array).used];   \
} while (0)

/* delete 'elems' elements starting at index 'idx' */
#define ARRAY_DEL_ORDERED(array, idx, elems) do {                       \
  size_t __idx = (idx), __elems = (elems);                              \
  assert(__elems <= (array).used && __idx <= (array).used - __elems);   \
  (array).used -= __elems;                                              \
  if (__idx < (array).used)                                             \
    memmove((array).data + __idx, (array).data + __idx + __elems,       \
            ((array).used - __idx) * sizeof (array).data[0]);           \
} while (0)

#define ARRAY_INS(array, idx, value) do {                       \
  size_t __idx = (idx);                                         \
  assert(__idx <= (array).used);                                \
  if ((array).used >= (array).size)                             \
    ARRAY_MAKE_ROOM((array), 1);                                \
  memmove((array).data + __idx + 1, (array).data + __idx,       \
          ((array).used - __idx) * sizeof (array).data[0]);     \
  ++(array).used;                                               \
  (array).data[__idx] = (value);                                \
} while (0)

#define ARRAY_QSORT(array, compar)                      \
  qsort((array).data, ARRAY_ENTRIES(array),             \
        sizeof (array).data[0], (compar))
#define ARRAY_BSEARCH(key, array, compar)               \
  bsearch((key), (array).data, ARRAY_ENTRIES(array),    \
          sizeof (array).data[0], (compar))
#define ARRAY_RANDOMIZE(array)                          \
  randomize_array((array).data, ARRAY_ENTRIES(array),   \
                  sizeof (array).data[0])

#define _ARRAY_FOR(array, idx, type, var)                               \
  for (bool __afor_done = false; !__afor_done; )                        \
    for (type var; !__afor_done; __afor_done = true)                    \
      for (size_t idx = 0;                                              \
           (idx < (array).used                                          \
            && (var = _Generic(                                         \
                  &ARRAY_GET((array), idx),                             \
                  UNCONST(type):   &ARRAY_GET((array), idx),            \
                  UNCONST(type) *: ARRAY_GET((array), idx)),            \
                true));                                                 \
           ++idx)

/* loop over array; 'idx' is the variable name used for index into the
   array (can be left empty); 'type' can be T, T *, const T *, and
   'var' will be of that type; 'var' will be set to the value of the
   entry, or point to the value */
#define ARRAY_FOR(array, idx, type, var)                        \
  _ARRAY_FOR((array), IF_EMPTY(idx)(__idx, idx), type, var)

void array_make_room(struct generic_array *array, size_t elems, size_t dsize);
void array_set_size(struct generic_array *array, size_t elems, size_t dsize);
void array_copy(struct generic_array *dst, struct generic_array *src,
                size_t dsize);

#endif
