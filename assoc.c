#include "mudlle-config.h"

#include <assert.h>
#include <limits.h>

#include "assoc.h"
#include "charset.h"
#include "hash.h"

struct assoc_array_node {
  struct assoc_array_node *next;
  assoc_hash_t hash;
  const void *key;
  void *data;
};

/* returns pointer to node, or NULL if not found */
static struct assoc_array_node *assoc_array_lookup_node(
  const struct assoc_array *assoc, const void *key)
{
  if (assoc->used == 0) return NULL;

  assoc_hash_t hash = assoc->type->hash(key);
  size_t bucket = fold_hash(hash, assoc->size_bits);
  for (struct assoc_array_node *node = assoc->nodes[bucket];
       node;
       node = node->next)
    if (node->hash == hash && assoc->type->is_equal(key, node->key))
      return node;
  return NULL;
}

static inline size_t bits_size(unsigned bits)
{
  if (bits == 0)                /* bits = 0 is special-case */
    return 0;
  return (size_t)1 << bits;
}

void *assoc_array_lookup_key(const struct assoc_array *assoc, const void *key,
                             const void **dstkey)
{
  struct assoc_array_node *node = assoc_array_lookup_node(assoc, key);
  if (dstkey)
    *dstkey = node ? node->key : NULL;
  return node ? node->data : NULL;
}

void *assoc_array_lookup(const struct assoc_array *assoc, const void *key)
{
  return assoc_array_lookup_key(assoc, key, NULL);
}

void **assoc_array_lookup_ref(const struct assoc_array *assoc, const void *key)
{
  struct assoc_array_node *node = assoc_array_lookup_node(assoc, key);
  return node ? &node->data : NULL;
}

static void rehash_assoc_array(struct assoc_array *assoc, unsigned size_bits)
{
  size_t size = bits_size(size_bits);
  assert(size > 0);
  struct assoc_array_node **nodes = calloc(size, sizeof *nodes);

  size_t old_size = bits_size(assoc->size_bits);
  for (size_t i = 0; i < old_size; ++i)
    for (struct assoc_array_node *node = assoc->nodes[i], *next;
         node;
         node = next)
      {
        next = node->next;
        assoc_hash_t hash = node->hash;
        size_t bucket = fold_hash(hash, size_bits);
        node->next = nodes[bucket];
        nodes[bucket] = node;
      }

  free(assoc->nodes);
  assoc->nodes = nodes;
  assoc->size_bits = size_bits;
}

/* must know that "key" isn't in the table */
static struct assoc_array_node *assoc_array_add(
  struct assoc_array *assoc, const void *key, void *data)
{
  if (assoc->used * 3 >= bits_size(assoc->size_bits) * 2)
    rehash_assoc_array(assoc, assoc->size_bits ? assoc->size_bits + 1 : 4);

  assoc_hash_t hash = assoc->type->hash(key);
  size_t bucket = fold_hash(hash, assoc->size_bits);

  struct assoc_array_node *node = malloc(sizeof *node);
  *node = (struct assoc_array_node){
    .next = assoc->nodes[bucket],
    .hash = hash,
    .key  = key,
    .data = data
  };
  assoc->nodes[bucket] = node;

  ++assoc->used;
  return node;
}

void **assoc_array_force_ref(struct assoc_array *assoc, const void *key)
{
  void **data = assoc_array_lookup_ref(assoc, key);
  if (data != NULL)
    return data;
  return &assoc_array_add(assoc, key, NULL)->data;
}

void assoc_array_set(struct assoc_array *assoc,
                     const void *key, void *data)
{
  struct assoc_array_node *node = assoc_array_lookup_node(assoc, key);
  if (node)
    {
      if (assoc->type->free_data)
        assoc->type->free_data(node->data);
      node->data = data;
      return;
    }

  assoc_array_add(assoc, key, data);
}

void assoc_array_set_adopt_key(struct assoc_array *assoc,
                               void *key, void *data)
{
  assert(assoc->type->free_key != NULL);
  return assoc_array_set(assoc, key, data);
}

/* Returns true if the key was found */
bool assoc_array_remove(struct assoc_array *assoc, const void *key)
{
  if (assoc->used == 0) return false;

  assoc_hash_t hash = assoc->type->hash(key);
  size_t bucket = fold_hash(hash, assoc->size_bits);

  for (struct assoc_array_node **nodep = &assoc->nodes[bucket];
       *nodep;
       nodep = &(*nodep)->next)
    {
      struct assoc_array_node *node = *nodep;
      if (node->hash != hash || !assoc->type->is_equal(key, node->key))
        continue;
      *nodep = node->next;

      if (assoc->type->free_key)
        assoc->type->free_key((void *)node->key);
      if (assoc->type->free_data)
        assoc->type->free_data(node->data);
      free(node);
      --assoc->used;
      return true;
    }
  return false;
}

void assoc_array_foreach(struct assoc_array *assoc,
                         void (*f)(const void *key, void *data, void *idata),
                         void *idata)
{
  size_t size = bits_size(assoc->size_bits);
  for (size_t i = 0; i < size; ++i)
    for (struct assoc_array_node *node = assoc->nodes[i], *next;
         node ? (next = node->next, true) : false;
         node = next)
      f(node->key, node->data, idata);
}

bool assoc_array_exists(struct assoc_array *assoc,
                        bool (*f)(const void *key, void *data, void *idata),
                        void *idata)
{
  size_t size = bits_size(assoc->size_bits);
  for (size_t i = 0; i < size; ++i)
    for (struct assoc_array_node *node = assoc->nodes[i], *next;
         node ? (next = node->next, true) : false;
         node = next)
      if (f(node->key, node->data, idata))
        return true;

  return false;
}

void assoc_array_free(struct assoc_array *assoc)
{
  size_t size = bits_size(assoc->size_bits);
  for (size_t i = 0; i < size; ++i)
    for (struct assoc_array_node *node = assoc->nodes[i], *next;
         node ? (next = node->next, true) : false;
         node = next)
      {
        if (assoc->type->free_key)
          assoc->type->free_key((void *)node->key);
        if (assoc->type->free_data)
          assoc->type->free_data(node->data);
        free(node);
      }
  free(assoc->nodes);
  assoc->used = 0;
  assoc->size_bits = 0;
  assoc->nodes = NULL;
}

static bool assoc_array_string_equal(const void *a, const void *b)
{
  return strcmp(a, b) == 0;
}

static assoc_hash_t assoc_array_hash_string(const void *k)
{
  const char *s = k;
  return string_hash(s);
}

const struct assoc_array_type const_charp_to_voidp_assoc_array_type = {
  .hash     = assoc_array_hash_string,
  .is_equal = assoc_array_string_equal
};

const struct assoc_array_type malloc_charp_to_voidp_assoc_array_type = {
  .hash     = assoc_array_hash_string,
  .is_equal = assoc_array_string_equal,
  .free_key = free
};

static void assoc_array_freep(void *p)
{
  free(p);
}

static bool assoc_array_long_equal(const void *_a, const void *_b)
{
  long a = (long)_a, b = (long)_b;
  return a == b;
}

static assoc_hash_t assoc_array_hash_long(const void *_k)
{
  long l = (long)_k;
  return string_nhash((const char *)&l, sizeof l);
}

const struct assoc_array_type long_to_mallocp_assoc_array_type = {
  .hash      = assoc_array_hash_long,
  .is_equal  = assoc_array_long_equal,
  .free_data = assoc_array_freep
};

const struct assoc_array_type long_to_voidp_assoc_array_type = {
  .hash     = assoc_array_hash_long,
  .is_equal = assoc_array_long_equal
};

static assoc_hash_t assoc_array_hash_istring(const void *k)
{
  const char *s = k;
  return symbol_7inhash(s, strlen(s), CHAR_BIT * sizeof (assoc_hash_t));
}

static bool assoc_array_istring_equal(const void *a, const void *b)
{
  return str7icmp(a, b) == 0;
}

const struct assoc_array_type const_icharp_to_voidp_assoc_array_type = {
  .hash     = assoc_array_hash_istring,
  .is_equal = assoc_array_istring_equal
};
