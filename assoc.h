#ifndef ASSOC_H
#define ASSOC_H

#include <stdbool.h>
#include <stddef.h>

typedef unsigned long assoc_hash_t;

struct assoc_array_type {
  bool (*is_equal)(const void *, const void *);
  assoc_hash_t (*hash)(const void *);
  void (*free_key)(void *);
  void (*free_data)(void *);
};

struct assoc_array {
  const struct assoc_array_type *type;
  size_t used;
  unsigned size_bits;           /* size_bits == 0 <=> nodes == NULL */
  struct assoc_array_node **nodes;
};

/* set 'key' to 'data' */
void assoc_array_set(struct assoc_array *assoc, const void *key, void *data);
/* set 'key' to 'data'; adopt 'key' ownership; silences clang-tidy warnings */
void assoc_array_set_adopt_key(struct assoc_array *assoc,
                               void *key, void *data);

/* lookup 'key'; return data or NULL */
void *assoc_array_lookup(const struct assoc_array *assoc, const void *key);
/* lookup 'key' and write the actual key to '*dstkey'; return data or NULL */
void *assoc_array_lookup_key(const struct assoc_array *assoc, const void *key,
                             const void **dstkey);
/* lookup 'key'; return pointer to data or NULL */
void **assoc_array_lookup_ref(const struct assoc_array *assoc,
                              const void *key);
/* lookup 'key'; return pointer to data; creates with NULL data if it does not
   exist */
void **assoc_array_force_ref(struct assoc_array *assoc, const void *key);
/* remove 'key' */
bool assoc_array_remove(struct assoc_array *assoc, const void *key);

/* call f() for all entries until f() returns true; return false if f() never
   returned true; the current entry may be removed */
bool assoc_array_exists(struct assoc_array *assoc,
                        bool (*f)(const void *key, void *data, void *idata),
                        void *idata);
/* call f() for all entries; the current entry may be removed */
void assoc_array_foreach(struct assoc_array *assoc,
                         void (*f)(const void *key, void *data, void *idata),
                         void *idata);
void assoc_array_free(struct assoc_array *assoc);

/* data is malloced and will be freed automatically */
extern const struct assoc_array_type long_to_mallocp_assoc_array_type;
/* key is malloced and will be freed automatically */
extern const struct assoc_array_type malloc_charp_to_voidp_assoc_array_type;
/* data will not be freed automatically from these */
extern const struct assoc_array_type long_to_voidp_assoc_array_type;
extern const struct assoc_array_type const_charp_to_voidp_assoc_array_type;
extern const struct assoc_array_type const_icharp_to_voidp_assoc_array_type;

#endif
