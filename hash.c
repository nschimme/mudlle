#include "mudlle-config.h"

#include "charset.h"
#include "hash.h"
#include "mvalues.h"

/* FNV-1a hash from http://tools.ietf.org/html/draft-eastlake-fnv-03 */
#define FNV_PRIME32  UINT32_C(0x01000193)
#define FNV_PRIME64  UINT64_C(0x00000100000001b3)
#define FNV_OFFSET32 UINT32_C(0x811c9dc5)
#define FNV_OFFSET64 UINT64_C(0xcbf29ce484222325)

#define DEFHASH(N)                                              \
static uint ## N ## _t fold_hash ## N(                          \
  uint ## N ## _t code, int bits)                               \
{                                                               \
  if (bits == CHAR_BIT * sizeof code)                           \
    return code;                                                \
  assert(bits >= 0 && (unsigned)bits < CHAR_BIT * sizeof code); \
  code ^= code >> bits;                                         \
  uint ## N ## _t mask = ~UINT ## N ## _C(0) << bits;           \
  return code & ~mask;                                          \
}                                                               \
                                                                \
/* case- and accentuation-insensitive */                        \
static uint ## N ## _t symbol_7inhash ## N(                     \
  const char *name, size_t len, int bits)                       \
{                                                               \
  uint ## N ## _t code = FNV_OFFSET ## N;                       \
  while (len--)                                                 \
    {                                                           \
      unsigned char c = *name++;                                \
      code ^= TO_7LOWER(c);                                     \
      code *= FNV_PRIME ## N;                                   \
    }                                                           \
  return fold_hash ## N(code, bits);                            \
}                                                               \
                                                                \
/* case-insensitive, accentuation-sensitive */                  \
UNUSED static uint ## N ## _t symbol_8inhash ## N(              \
  const char *name, size_t len, int bits)                       \
{                                                               \
  uint ## N ## _t code = FNV_OFFSET ## N;                       \
  while (len--)                                                 \
    {                                                           \
      unsigned char c = *name++;                                \
      code ^= TO_8LOWER(c);                                     \
      code *= FNV_PRIME ## N;                                   \
    }                                                           \
  return fold_hash ## N(code, bits);                            \
}                                                               \
                                                                \
/* case- and accentuation-sensitive */                          \
static uint ## N ## _t symbol_nhash ## N(                       \
  const char *name, size_t len, int bits)                       \
{                                                               \
  uint ## N ## _t code = FNV_OFFSET ## N;                       \
  while (len--)                                                 \
    {                                                           \
      unsigned char c = *name++;                                \
      code ^= c;                                                \
      code *= FNV_PRIME ## N;                                   \
    }                                                           \
  return fold_hash ## N(code, bits);                            \
  }                                                             \
                                                                \
static uint ## N ## _t symbol_nhash ## N(                       \
  const char *name, size_t len, int bits)

DEFHASH(32);
DEFHASH(64);

CASSERT(sizeof (long) == 4 || sizeof (long) == 8);

unsigned long fold_hash(unsigned long code, int bits)
{
  if (sizeof (long) == 4)
    return fold_hash32(code, bits);
  return fold_hash64(code, bits);
}

unsigned long symbol_nhash(const char *s, size_t len, int bits)
{
  if (sizeof (long) == 4)
    return symbol_nhash32(s, len, bits);
  return symbol_nhash64(s, len, bits);
}

unsigned long string_nhash(const char *s, size_t len)
{
  return symbol_nhash(s, len, TAGGED_INT_BITS - 1);
}

unsigned long string_hash(const char *s)
{
  return string_nhash(s, strlen(s));
}

unsigned long symbol_7inhash(const char *s, size_t len, int bits)
{
  if (sizeof (long) == 4)
    return symbol_7inhash32(s, len, bits);
  return symbol_7inhash64(s, len, bits);
}

unsigned long mudlle_string_hash(struct string *s)
{
  return symbol_nhash32(s->str, string_len(s), 30);
}

unsigned long mudlle_string_7ihash(struct string *s)
{
  return symbol_7inhash32(s->str, string_len(s), 30);
}

unsigned long mudlle_string_8ihash(struct string *s)
{
  return symbol_8inhash32(s->str, string_len(s), 30);
}
