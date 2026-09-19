#ifndef DWARF_H
#define DWARF_H

#include "array.h"

struct code;

ARRAY_STRUCT(mcode_array, struct mcode *);

void set_dwarf_source_dir(const char *dir);

/* register array of mcode objects as belonging to GC generation gen */
void register_dwarf_mcodes(unsigned gen, struct mcode_array *ary);
/* clear registrations of mcode objects in GC generation gen */
void reset_dwarf_mcodes(unsigned gen);

struct lni_state {
  uint32_t addr, line;
};

struct string *dwarf_line_number_info(const struct lni_state *states,
                                      size_t nstates);

uint32_t dwarf_lookup_line_number(struct code *code, uint32_t addr);
struct vector *mudlle_line_number_info(struct string *lni);

struct lni_state *line_number_info(struct string *lni, size_t *nentries);

#endif  /* DWARF_H */
