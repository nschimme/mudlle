#ifndef JITDUMP_H
#define JITDUMP_H

struct mcode;

void start_jitdump(const char *dstdir, const char *srcpath);
void stop_jitdump(void);

void jitdump_load(struct mcode *mcode);
void jitdump_move(struct mcode *old_mcode, struct mcode *new_mcode);

#endif  /* JITDUMP_H */
