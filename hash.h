#ifndef HASH_H
#define HASH_H

#include <stdlib.h>

unsigned long fold_hash(unsigned long code, int bits);

/* not stable across host bit size */
unsigned long symbol_nhash(const char *s, size_t len, int bits);
unsigned long symbol_7inhash(const char *s, size_t len, int bits);

unsigned long string_nhash(const char *s, size_t len);
unsigned long string_hash(const char *s);

/* stable across host bit size */
struct string;
unsigned long mudlle_string_hash(struct string *s);
unsigned long mudlle_string_7ihash(struct string *s);
unsigned long mudlle_string_8ihash(struct string *s);

#endif  /* HASH_H */
