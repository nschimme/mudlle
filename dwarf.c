#include "mudlle-config.h"

#include <ctype.h>

#include "alloc.h"
#include "assoc.h"
#include "dwarf.h"
#include "elf.h"
#include "mvalues.h"
#include "strbuf.h"
#include "utils.h"

#include "runtime/runtime.h"

/* enable to also emit .symtab (and required .strtab) sections */
#undef EMIT_SYMTAB

enum
{
  JIT_NOACTION = 0,
  JIT_REGISTER_FN,
  JIT_UNREGISTER_FN
};

struct jit_code_entry
{
  struct jit_code_entry *next_entry;
  struct jit_code_entry *prev_entry;
  const char *symfile_addr;
  uint64_t symfile_size;
};

struct jit_descriptor
{
  uint32_t version;
  uint32_t action_flag;
  struct jit_code_entry *relevant_entry;
  struct jit_code_entry *first_entry;
};

/* set to true to speed up running with GDB attached */
extern volatile bool inhibit_jit_debug;
volatile bool inhibit_jit_debug = false;

/* GDB puts a breakpoint in this function.  */
__attribute__((noinline)) void __jit_debug_register_code(void);
__attribute__((noinline)) void __jit_debug_register_code(void)
{
  asm("");
}

/* GDB reads this structure to find debug information */
extern struct jit_descriptor __jit_debug_descriptor;
struct jit_descriptor __jit_debug_descriptor = { .version = 1 };

static inline UNUSED void sb_addstrnul(struct strbuf *sb, const char *str)
{
  sb_addmem(sb, str, strlen(str) + 1);
}

UNUSED static void emit_u16(struct strbuf *sb, uint16_t u)
{
  sb_addmem(sb, &u, sizeof u);
}

UNUSED static void emit_u32(struct strbuf *sb, uint32_t u)
{
  sb_addmem(sb, &u, sizeof u);
}

UNUSED static void emit_uintptr(struct strbuf *sb, uintptr_t u)
{
  sb_addmem(sb, &u, sizeof u);
}

#ifdef __x86_64__
enum {
  DWARF_REG_RBP = 6,
  DWARF_REG_RSP = 7,
  DWARF_REG_RETURN_ADDRESS = 16,
  DWARF_REG_SP = DWARF_REG_RSP,
  DWARF_REG_FP = DWARF_REG_RBP,
};
#endif

enum {
  DW_EH_PE_pcrel  = 0x10,
  DW_EH_PE_sdata4 = 0x08 | 0x3,

  DW_CFA_def_cfa          = 0x0c,
  DW_CFA_def_cfa_register = 0x0d,
  DW_CFA_def_cfa_offset   = 0x0e,

  DW_CFA_offset = 2 << 6,

  DW_CFA_nop = 0,

  DW_advance_loc = 1 << 6,
  DW_advance_loc1 = 2,
  DW_advance_loc2 = 3,
  DW_advance_loc4 = 4
};

#ifndef NOCOMPILER
static void emit_cfi_advance(struct strbuf *sb, uint64_t u)
{
  if (u < (1 << 6))
    sb_add_u8(sb, DW_advance_loc | u);
  else if (u <= UINT8_MAX)
    {
      sb_add_u8(sb, DW_advance_loc1);
      sb_add_u8(sb, u);
    }
  else if (u <= UINT16_MAX)
    {
      sb_add_u8(sb, DW_advance_loc2);
      emit_u16(sb, u);
    }
  else
    {
      assert(u <= UINT32_MAX);
      sb_add_u8(sb, DW_advance_loc4);
      emit_u32(sb, u);
    }
}

static void emit_dwarf_cfi_fde(struct strbuf *sb, struct mcode *mcode,
                               size_t cie_start, bool first)
{
  size_t start = sb_len(sb);

  /* length */
  emit_u32(sb, 0);

  /* id (cie offset) */
  emit_u32(sb, sb_len(sb) - cie_start);

  /* initial_location */
  emit_uintptr(sb, (uintptr_t)mcode->mcode);

  /* address_range */
  emit_uintptr(sb, mcode->code_length);

  /* no FDE augmentation data size */

  /* push %ebp or %rbp */
  static const uint8_t push_fp[] = { 0x55 };
  assert(memcmp(mcode->mcode, &push_fp, sizeof push_fp) == 0);
  emit_cfi_advance(sb, sizeof push_fp);

  sb_add_u8(sb, DW_CFA_def_cfa_offset);
  sb_add_leb_u(sb, 2 * sizeof (long));

  sb_add_u8(sb, DW_CFA_offset | DWARF_REG_FP);
  sb_add_leb_u(sb, 2);

#ifdef __x86_64__
  static const uint8_t mov_sp_fp[] = { 0x48, 0x89, 0xe5 }; /* mov %rsp,%rbp */
#else
#error Unsupported architecture
#endif

  assert(mcode->mcode + 1 != NULL); /* silence clang-tidy warning */
  assert(memcmp(mcode->mcode + 1, &mov_sp_fp, sizeof mov_sp_fp) == 0);
  emit_cfi_advance(sb, sizeof mov_sp_fp);
  sb_add_u8(sb, DW_CFA_def_cfa_register);
  sb_add_leb_u(sb, DWARF_REG_FP);

  /* pad and update size */
  sb_addnc(sb, DW_CFA_nop, PADDING(sb_len(sb), sizeof (uint32_t)));
  uint32_t size = sb_len(sb) - start - sizeof size;
  memcpy(sb_mutable_str(sb) + start, &size, sizeof size);
}

static void emit_dwarf_cfi_cie(struct strbuf *sb)
{
  size_t start = sb_len(sb);

  /* length */
  emit_u32(sb, 0);

  const uint32_t CIE_id = 0;
  emit_u32(sb, CIE_id);

  const uint8_t CIE_version = 1;
  sb_add_u8(sb, CIE_version);

  /* augmentation */
  sb_addc(sb, 0);

  /* code alignment */
  sb_add_leb_u(sb, 1);
  /* data alignment */
  sb_add_leb_s(sb, -(int64_t)sizeof (long));
  /* return address register */
  sb_add_leb_u(sb, DWARF_REG_RETURN_ADDRESS);

  sb_add_u8(sb, DW_CFA_def_cfa);
  sb_add_leb_u(sb, DWARF_REG_SP);
  sb_add_leb_u(sb, sizeof (long));

  sb_add_u8(sb, DW_CFA_offset | DWARF_REG_RETURN_ADDRESS);
  sb_add_leb_u(sb, 1);

  /* pad and update size */
  sb_addnc(sb, DW_CFA_nop, PADDING(sb_len(sb), sizeof (uint32_t)));
  uint32_t size = sb_len(sb) - start - sizeof size;
  memcpy(sb_mutable_str(sb) + start, &size, sizeof size);
}

static void emit_dwarf_cfi(struct strbuf *sb, struct mcode_array *ary)
{
  size_t cie_start = sb_len(sb);
  emit_dwarf_cfi_cie(sb);
  bool first = true;
  ARRAY_FOR (*ary, , struct mcode *, mcode)
    {
      emit_dwarf_cfi_fde(sb, mcode, cie_start, first);
      first = false;
    }
}

struct strtab_data {
  struct assoc_array hash;
  struct strbuf strs;
};

static uint32_t strtab_entry(struct strtab_data *data, const char *name)
{
  if (name == NULL || *name == 0)
    return 0;

  uint32_t idx = ptr_int(assoc_array_lookup(&data->hash, name));
  if (idx == 0)
    {
      idx = sb_len(&data->strs);
      sb_addmem(&data->strs, name, strlen(name) + 1);
      assoc_array_set_adopt_key(&data->hash, strdup(name), int_ptr(idx));
    }
  return idx;
}

static void emit_mcode_name(struct strbuf *sb, struct mcode *mcode, bool nul)
{
  const char *name = (mcode->code.varname
                      ? mcode->code.varname->str
                      : "fn");
  size_t vlen = strlen(name);
  sb_makeroom(sb, vlen);
  for (const char *n = name; *n; ++n)
    {
      unsigned char c = *n;
      if (c == '?')
        c = 'p';
      else if (c == '!')
        c = 'b';
      else if (!isalnum(c))
        c = '_';
      sb_addc(sb, c);
    }
  if (nul)
    sb_addc(sb, 0);
}

/* GDB behaves very poorly with many registered ELF objects */
#define MAX_GENERATION_ENTRIES 50

struct dwarf_node {
  struct dwarf_node *next;
  struct mcode_array mcodes;
  struct jit_code_entry jce;
};

static struct {
  struct dwarf_node *nodes;
  int count;
} dwarf_entries[2]; /* one per generation */

#ifdef EMIT_SYMTAB
static void emit_symtab(struct strbuf *sbsymtab, struct strtab_data *strtab,
                        struct mcode_array *ary, unsigned sect_text,
                        uintptr_t minaddr)
{
  /* empty first entry */
  sb_addnc(sbsymtab, 0, sizeof (struct elf_sym_entry));
  struct elf_sym_entry file = {
    .st_name  = strtab_entry(strtab, "mcode"),
    .st_info  = (STB_LOCAL << 4) | STT_FILE,
    .st_shndx = SHN_ABS
  };
  sb_addmem(sbsymtab, &file, sizeof file);

  struct strbuf sbname = SBNULL;
  ARRAY_FOR (*ary, , struct mcode *, mcode)
    {
      sb_empty(&sbname);
      emit_mcode_name(&sbname, mcode, false);

      struct elf_sym_entry sym = {
        .st_name  = strtab_entry(strtab, sb_str(&sbname)),
        .st_value = (uintptr_t)mcode->mcode - minaddr,
        .st_size  = mcode->code_length,
        .st_info  = (STB_LOCAL << 4) | STT_FUNC,
        .st_shndx = sect_text,
      };
      sb_addmem(sbsymtab, &sym, sizeof sym);
    }
  sb_free(&sbname);
}
#endif  /* EMIT_SYMTAB */

#endif  /* ! NOCOMPILER */

enum {
  DW_LNS_copy               = 0x01,
  DW_LNS_advance_pc         = 0x02,
  DW_LNS_advance_line       = 0x03,
  DW_LNS_set_file           = 0x04,

  /* last standard opcode + 1 */
  LNI_OPCODE_BASE,

#if 0                           /* unused */
  DW_LNS_set_column         = 0x05,
  DW_LNS_negate_stmt        = 0x06,
  DW_LNS_set_basic_block    = 0x07,
#endif
  DW_LNS_const_add_pc       = 0x08, /* never emitted */
#if 0
  DW_LNS_fixed_advance_pc   = 0x09,
  DW_LNS_set_prologue_end   = 0x0a,
  DW_LNS_set_epilogue_begin = 0x0b,
  DW_LNS_set_isa            = 0x0c,
#endif

  DW_LNE_end_sequence = 0x01,
  DW_LNE_set_address  = 0x02,
#if 0                           /* unused */
  DW_LNE_define_file  = 0x03,
  DW_LNE_lo_user      = 0x80,
  DW_LNE_hi_user      = 0xff,
#endif
};

struct lni_header {
  uint32_t length;
  uint16_t version;
  uint32_t header_length;
  uint8_t min_instr_len;
  uint8_t default_is_stmt;
  int8_t line_base;
  uint8_t line_range;
  uint8_t opcode_base;
  uint8_t std_opcode_lens[LNI_OPCODE_BASE - 1];
} __attribute__((__packed__));
CASSERT_SIZEOF(struct lni_header, 14 + LNI_OPCODE_BASE);

/* if any of the values in 'lni_header' change, update MCODE_VERSION */
CASSERT(LNI_OPCODE_BASE == 5);
static const struct lni_header lni_header = {
  .version         = 3,         /* corresponding to DWARF3 */
  .min_instr_len   = 1,
  .default_is_stmt = 1,
  /* good numbers for the mudlle compiler (x86-64) */
  .line_base       = -1,
  .line_range      = 5,
  .opcode_base     = LNI_OPCODE_BASE,
  .std_opcode_lens = {
    [DW_LNS_advance_pc - 1]   = 1,
    [DW_LNS_advance_line - 1] = 1,
    [DW_LNS_set_file - 1]     = 1,
  }
};

static char *dwarf_source_dir;

void set_dwarf_source_dir(const char *dir)
{
  free(dwarf_source_dir);
  if (*dir != 0)
    assert(dir[strlen(dir) - 1] == '/');
  dwarf_source_dir = strdup(dir);
}

#ifndef NOCOMPILER
static struct strbuf build_lni(struct mcode_array *ary)
{
  struct strbuf sblni = sb_initmem(&lni_header, sizeof lni_header);

  assert(!ARRAY_IS_EMPTY(*ary));
  struct {
    uint32_t dir, file;
  } *fnames = malloc(sizeof *fnames * ARRAY_ENTRIES(*ary));

  struct assoc_array dir_hash = {
    .type = &malloc_charp_to_voidp_assoc_array_type,
  };

  unsigned dirname_used = 0;

  /* include_directories */
  struct strbuf sb_dir = SBNULL;
  ARRAY_FOR (*ary, mcode_idx, struct mcode *, mcode)
    {
      struct string *fstr = code_filename(&mcode->code);
      assert(TYPE(fstr, string));
      const char *fname = fstr->str;
      const char *rslash = strrchr(fname, '/');
      if (rslash == NULL)
        {
          fnames[mcode_idx].dir = 0;
          continue;
        }
      sb_empty(&sb_dir);
      sb_addmem(&sb_dir, fname, rslash - fname);
      uint32_t idx = ptr_int(assoc_array_lookup(&dir_hash, sb_str(&sb_dir)));
      if (idx == 0)
        {
          sb_addstrnul(&sblni, sb_str(&sb_dir));
          idx = ++dirname_used;
          assoc_array_set_adopt_key(
            &dir_hash, sb_detach(&sb_dir), int_ptr(idx));
        }
      fnames[mcode_idx].dir = idx;
    }
  sb_addc(&sblni, 0);           /* last entry */

  assoc_array_free(&dir_hash);

  /* file_names */
  struct assoc_array file_hash = {
    .type = &const_charp_to_voidp_assoc_array_type,
  };

  unsigned fnames_used = 0;
  ARRAY_FOR (*ary, mcode_idx, struct mcode *, mcode)
    {
      struct string *fstr = code_filename(&mcode->code);
      assert(TYPE(fstr, string));
      const char *fname = fstr->str;
      uint32_t idx = ptr_int(assoc_array_lookup(&file_hash, fname));
      if (idx == 0)
        {
          idx = ++fnames_used;
          assoc_array_set(&file_hash, fname, int_ptr(idx));

          const char *rslash = strrchr(fname, '/');
          sb_addstrnul(&sblni, rslash ? rslash + 1 : fname);
          sb_add_leb_u(&sblni, fnames[mcode_idx].dir); /* directory index */
          sb_add_leb_u(&sblni, 0);        /* time of last modification */
          sb_add_leb_u(&sblni, 0);        /* file size */
        }
      fnames[mcode_idx].file = idx;
    }
  sb_add_u8(&sblni, 0);           /* last entry */

  assoc_array_free(&file_hash);

  uint32_t header_length = (sb_len(&sblni)
                            - offsetof(struct lni_header, min_instr_len));
  memcpy(sb_mutable_str(&sblni) + offsetof(struct lni_header, header_length),
         &header_length, sizeof header_length);

  size_t progsize = 0;
  ARRAY_FOR (*ary, mcode_idx, struct mcode *, mcode)
    {
      progsize += 1 + leb_u_len(fnames[mcode_idx].file); /* file number */
      progsize += 3 + sizeof (uintptr_t);  /* set address */

      progsize += string_len(mcode->code.linenos);
      progsize += 3;            /* end sequence */
    }

  sb_makeroom(&sblni, progsize);
  ARRAY_FOR (*ary, mcode_idx, struct mcode *, mcode)
    {
      sb_add_u8(&sblni, DW_LNS_set_file);
      sb_add_leb_u(&sblni, fnames[mcode_idx].file);

      /* start extended */
      sb_add_u8(&sblni, 0);
      /* bytes of extended opcode */
      sb_add_leb_u(&sblni, 1 + sizeof (uintptr_t));
      sb_add_u8(&sblni, DW_LNE_set_address);
      emit_uintptr(&sblni, (uintptr_t)&mcode->mcode);

      sb_addmem(&sblni, mcode->code.linenos->str,
                string_len(mcode->code.linenos));

      /* start extended */
      sb_add_u8(&sblni, 0);
      /* bytes of extended opcode */
      sb_add_leb_u(&sblni, 1);
      sb_add_u8(&sblni, DW_LNE_end_sequence);
    }

  uint32_t length = sb_len(&sblni) - offsetof(struct lni_header, version);
  memcpy(sb_mutable_str(&sblni) + offsetof(struct lni_header, length),
         &length, sizeof length);

  free(fnames);

  return sblni;
}

enum {
  di_abbrev_compile_unit     = 1,
  di_abbrev_subprogram       = 2,
  di_abbrev_formal_parameter = 3,
  di_abbrev_typedef          = 4,
  di_abbrev_pointer_type     = 5,
};

enum {
  DEBUG_INFO_VERSION      = 3,

  DW_AT_location          = 0x02,
  DW_AT_name              = 0x03,
  DW_AT_byte_size         = 0x0b,
  DW_AT_stmt_list         = 0x10,
  DW_AT_low_pc            = 0x11,
  DW_AT_high_pc           = 0x12,
  DW_AT_language          = 0x13,
  DW_AT_comp_dir          = 0x1b,
  DW_AT_artificial        = 0x34,
  DW_AT_frame_base        = 0x40,
  DW_AT_type              = 0x49,

  DW_CHILDREN_no          = 0x00,
  DW_CHILDREN_yes         = 0x01,

  DW_FORM_addr            = 0x01,
  DW_FORM_data2           = 0x05,
  DW_FORM_data4           = 0x06,
  DW_FORM_string          = 0x08,
  DW_FORM_data1           = 0x0b,
  DW_FORM_flag            = 0x0c,
  DW_FORM_udata           = 0x0f,
  DW_FORM_ref1            = 0x11,
  DW_FORM_exprloc         = 0x18,

  DW_OP_fbreg             = 0x91,
  DW_OP_call_frame_cfa    = 0x9c,

  DW_TAG_formal_parameter = 0x05,
  DW_TAG_pointer_type     = 0x0f,
  DW_TAG_compile_unit     = 0x11,
  DW_TAG_typedef          = 0x16,
  DW_TAG_subprogram       = 0x2e,
};

static void emit_exprloc_fbreg(struct strbuf *sb, int64_t ofs)
{
  size_t len = 1 + leb_s_len(ofs);
  sb_add_leb_u(sb, len);
  size_t start = sb_len(sb);
  sb_add_u8(sb, DW_OP_fbreg);
  sb_add_leb_s(sb, ofs);
  assert(start + len == sb_len(sb));
}

static const struct strbuf *get_abbrev_codes(void)
{
  static struct strbuf sb = SBNULL;
  if (sb_len(&sb) > 0)
    return &sb;

  /* create abbreviation codes */
  sb_add_leb_u(&sb, di_abbrev_compile_unit);
  sb_add_leb_u(&sb, DW_TAG_compile_unit);
  sb_add_u8(&sb, DW_CHILDREN_yes);
  sb_add_leb_u(&sb, DW_AT_comp_dir);
  sb_add_leb_u(&sb, DW_FORM_string);
  sb_add_leb_u(&sb, DW_AT_low_pc);
  sb_add_leb_u(&sb, DW_FORM_addr);
  sb_add_leb_u(&sb, DW_AT_high_pc);
  sb_add_leb_u(&sb, DW_FORM_udata);
  sb_add_leb_u(&sb, DW_AT_stmt_list);
  sb_add_leb_u(&sb, DW_FORM_data4);
  sb_add_leb_u(&sb, 0);
  sb_add_leb_u(&sb, 0);

  sb_add_leb_u(&sb, di_abbrev_subprogram);
  sb_add_leb_u(&sb, DW_TAG_subprogram);
  sb_add_u8(&sb, DW_CHILDREN_yes);
  sb_add_leb_u(&sb, DW_AT_name);
  sb_add_leb_u(&sb, DW_FORM_string);
  sb_add_leb_u(&sb, DW_AT_type);
  sb_add_leb_u(&sb, DW_FORM_ref1);
  sb_add_leb_u(&sb, DW_AT_low_pc);
  sb_add_leb_u(&sb, DW_FORM_addr);
  sb_add_leb_u(&sb, DW_AT_high_pc);
  sb_add_leb_u(&sb, DW_FORM_addr);
  sb_add_leb_u(&sb, DW_AT_frame_base);
  sb_add_leb_u(&sb, DW_FORM_exprloc);
  sb_add_leb_u(&sb, 0);
  sb_add_leb_u(&sb, 0);

  sb_add_leb_u(&sb, di_abbrev_formal_parameter);
  sb_add_leb_u(&sb, DW_TAG_formal_parameter);
  sb_add_u8(&sb, DW_CHILDREN_no);
  sb_add_leb_u(&sb, DW_AT_name);
  sb_add_leb_u(&sb, DW_FORM_string);
  sb_add_leb_u(&sb, DW_AT_location);
  sb_add_leb_u(&sb, DW_FORM_exprloc);
  sb_add_leb_u(&sb, DW_AT_type);
  sb_add_leb_u(&sb, DW_FORM_ref1);
  sb_add_leb_u(&sb, DW_AT_artificial);
  sb_add_leb_u(&sb, DW_FORM_flag);
  sb_add_leb_u(&sb, 0);
  sb_add_leb_u(&sb, 0);

  sb_add_leb_u(&sb, di_abbrev_typedef);
  sb_add_leb_u(&sb, DW_TAG_typedef);
  sb_add_u8(&sb, DW_CHILDREN_no);
  sb_add_leb_u(&sb, DW_AT_name);
  sb_add_leb_u(&sb, DW_FORM_string);
  sb_add_leb_u(&sb, DW_AT_type);
  sb_add_leb_u(&sb, DW_FORM_ref1);
  sb_add_leb_u(&sb, 0);
  sb_add_leb_u(&sb, 0);

  sb_add_leb_u(&sb, di_abbrev_pointer_type);
  sb_add_leb_u(&sb, DW_TAG_pointer_type);
  sb_add_u8(&sb, DW_CHILDREN_no);
  sb_add_leb_u(&sb, DW_AT_byte_size);
  sb_add_leb_u(&sb, DW_FORM_data1);
  sb_add_leb_u(&sb, 0);
  sb_add_leb_u(&sb, 0);

  /* end of abbreviations */
  sb_add_leb_u(&sb, 0);

  sb_trim(&sb);
  return &sb;
}

static void build_debug_info(struct strbuf *sbinfo, uintptr_t minaddr,
                             uintptr_t unitsize, struct mcode_array *ary)
{
  /* unit_length */
  emit_u32(sbinfo, 0);

  /* version */
  emit_u16(sbinfo, DEBUG_INFO_VERSION);

  /* debug_abbrev_offset */
  emit_u32(sbinfo, 0);

  /* address size */
  sb_add_u8(sbinfo, sizeof (uintptr_t));

  sb_add_leb_u(sbinfo, di_abbrev_compile_unit);
  sb_addstrnul(sbinfo, dwarf_source_dir ? dwarf_source_dir : ".");
  emit_uintptr(sbinfo, minaddr);
  sb_add_leb_u(sbinfo, unitsize);
  emit_u32(sbinfo, 0);          /* statement list offset */

  /* define void * type */
  const uint32_t ref_void_p_type = sb_len(sbinfo);
  sb_add_leb_u(sbinfo, di_abbrev_pointer_type);
  sb_add_u8(sbinfo, sizeof (value));

  /* define typedef void *value; */
  const uint32_t ref_value_typedef = sb_len(sbinfo);
  sb_add_leb_u(sbinfo, di_abbrev_typedef);
  sb_addstrnul(sbinfo, "value");
  sb_add_u8(sbinfo, ref_void_p_type);

  ARRAY_FOR (*ary, , struct mcode *, mcode)
    {
      sb_add_leb_u(sbinfo, di_abbrev_subprogram);
      emit_mcode_name(sbinfo, mcode, true);
      sb_add_u8(sbinfo, ref_value_typedef);
      emit_uintptr(sbinfo, (uintptr_t)mcode->mcode);
      emit_uintptr(sbinfo, (uintptr_t)mcode->mcode + mcode->code_length);
      sb_add_leb_u(sbinfo, 1);    /* 1 byte of exprloc */
      sb_add_u8(sbinfo, DW_OP_call_frame_cfa);

      struct vector *argv = mcode->code.arguments;
      int nargs = vector_len(argv), noptional = 0;
      bool has_nargs = false;

      for (int i = 0; i < nargs; ++i)
        {
          struct list *e = argv->data[i];
          assert(TYPE(e, pair));
          value mtypeset = e->cdr;
          if (mtypeset != NULL)
            {
              assert(integerp(mtypeset));
              typeset_t typeset = intval(mtypeset);
              if (typeset & TYPESET_FLAG_OPTIONAL)
                ++noptional;
            }
          else if (mcode->code.vararg_alloc)
            ++noptional;
          else
            {
              has_nargs = true;
              --nargs;
            }
        }

      if (noptional > 0)
        has_nargs = true;

      int nfixed = nargs - noptional;
      for (int i = 0; i < nfixed; ++i)
        {
          struct list *e = argv->data[i];
          sb_add_leb_u(sbinfo, di_abbrev_formal_parameter);
          if (isfalse(e->car))
            sb_add_u8(sbinfo, 0);
          else
            {
              struct string *name = e->car;
              assert(TYPE(name, string));
              sb_addstrnul(sbinfo, name->str);
            }
          emit_exprloc_fbreg(sbinfo, sizeof (value) * i);
          sb_add_u8(sbinfo, ref_value_typedef);
          sb_add_u8(sbinfo, 0);   /* artificial flag */
        }

      if (has_nargs)
        {
          sb_add_leb_u(sbinfo, di_abbrev_formal_parameter);
          sb_addstrnul(sbinfo, "%nargs");
          emit_exprloc_fbreg(sbinfo, -3 * sizeof (value));
          sb_add_u8(sbinfo, ref_value_typedef);
          sb_add_u8(sbinfo, 1);   /* artificial flag */
        }

      sb_add_leb_u(sbinfo, 0);    /* end of di_abbrev_subprogram */
    }

  sb_add_leb_u(sbinfo, 0);    /* end of di_abbrev_compile_unit */

  uint32_t unit_length = sb_len(sbinfo) - sizeof (uint32_t);
  memcpy(sb_mutable_str(sbinfo), &unit_length, sizeof unit_length);
}

static void init_strtab(struct strtab_data *strtab)
{
  *strtab = (struct strtab_data){
    .hash = { .type = &malloc_charp_to_voidp_assoc_array_type },
    .strs = SBNULL,
  };
  /* always start with the empty string */
  assoc_array_set_adopt_key(&strtab->hash, strdup(""), 0);
}

static struct strbuf fini_strtab(struct strtab_data *strtab)
{
  assoc_array_free(&strtab->hash);
  struct strbuf res = strtab->strs;
  sb_init(&strtab->strs);
  return res;
}

/* build an in-memory ELF file for mcodes in ary and register with GDB;
   may empty *ary */
void register_dwarf_mcodes(unsigned gen, struct mcode_array *ary)
{
  if (inhibit_jit_debug || ARRAY_IS_EMPTY(*ary))
    return;

  if (dwarf_entries[gen].count == MAX_GENERATION_ENTRIES)
    {
      size_t nmcodes = ARRAY_ENTRIES(*ary);
      for (struct dwarf_node *n = dwarf_entries[gen].nodes; n; n = n->next)
        nmcodes += ARRAY_ENTRIES(n->mcodes);
      size_t pos = ARRAY_ENTRIES(*ary);
      ARRAY_SET_SIZE(*ary, nmcodes);
      for (struct dwarf_node *n = dwarf_entries[gen].nodes; n; n = n->next)
        {
          size_t cnt = ARRAY_ENTRIES(n->mcodes);
          memcpy(ary->data + pos, n->mcodes.data, cnt * sizeof ary->data[0]);
          pos += cnt;
        }
      assert(pos == nmcodes);

      reset_dwarf_mcodes(gen);
    }

  uintptr_t minaddr = UINTPTR_MAX, maxaddr = 0;
  ARRAY_FOR (*ary, , struct mcode *, mcode)
    {
      mcode->dwarf_seen = true;
      uintptr_t s = (uintptr_t)mcode->mcode;
      uintptr_t e = s + mcode->code_length;
      if (s < minaddr)
        minaddr = s;
      if (e > maxaddr)
        maxaddr = e;
    }

  struct strtab_data shstrtab_data;
  init_strtab(&shstrtab_data);

  struct elf_file elf;
  elf_init(&elf);

  struct elf_sect_data *sect_text = elf_alloc_sect(
    &elf, strtab_entry(&shstrtab_data, ".text"),
    SHT_NOBITS, SHF_ALLOC | SHF_EXECINSTR, 8);
  sect_text->hdr.sh_addr = minaddr;
  elf_set_sect_data(sect_text, NULL, maxaddr - minaddr);

  struct elf_sect_data *sect_debug_info = elf_alloc_sect(
    &elf, strtab_entry(&shstrtab_data, ".debug_info"),
    SHT_PROGBITS, 0, 8);

  struct elf_sect_data *sect_debug_abbrev = elf_alloc_sect(
    &elf, strtab_entry(&shstrtab_data, ".debug_abbrev"),
    SHT_PROGBITS, 0, 8);

  struct elf_sect_data *sect_debug_line = elf_alloc_sect(
    &elf, strtab_entry(&shstrtab_data, ".debug_line"),
    SHT_PROGBITS, 0, 8);

  struct elf_sect_data *sect_eh_frames = elf_alloc_sect(
    &elf, strtab_entry(&shstrtab_data, ".eh_frame"), SHT_UNWIND,
    SHF_ALLOC, 8);

  struct elf_sect_data *sect_shstrtab = elf_alloc_sect(
    &elf, strtab_entry(&shstrtab_data, ".shstrtab"), SHT_STRTAB,
    SHF_STRINGS | SHF_ALLOC, 1);
  elf.file_hdr.e_shstrndx = sect_shstrtab->sect;

  struct strbuf sbcfi = SBNULL;
  emit_dwarf_cfi(&sbcfi, ary);

#ifdef EMIT_SYMTAB
  struct strtab_data strtab_data;
  init_strtab(&strtab_data);

  struct elf_sect_data *sect_strtab = elf_alloc_sect(
    &elf, strtab_entry(&shstrtab_data, ".strtab"), SHT_STRTAB,
    SHF_STRINGS | SHF_ALLOC, 1);

  struct elf_sect_data *sect_symtab = elf_alloc_sect(
    &elf, strtab_entry(&shstrtab_data, ".symtab"),
    SHT_SYMTAB, 0, 8);
  sect_symtab->hdr.sh_link = sect_strtab->sect;
  sect_symtab->hdr.sh_entsize = sizeof (struct elf_sym_entry);

  struct strbuf sbsymtab = SBNULL;
  emit_symtab(&sbsymtab, &strtab_data, ary, sect_text->sect, minaddr);

  elf_set_sect_data(sect_symtab, sb_str(&sbsymtab), sb_len(&sbsymtab));

  struct strbuf strtab_buf = fini_strtab(&strtab_data);
  elf_set_sect_data(sect_strtab, sb_str(&strtab_buf), sb_len(&strtab_buf));
#endif  /* EMIT_SYMTAB */

  struct strbuf shstrtab_buf = fini_strtab(&shstrtab_data);

  struct strbuf sblni = build_lni(ary);

  struct strbuf sbinfo = SBNULL;
  build_debug_info(&sbinfo, minaddr, maxaddr - minaddr, ary);

  elf_set_sect_data(sect_shstrtab, sb_str(&shstrtab_buf),
                    sb_len(&shstrtab_buf));
  elf_set_sect_data(sect_eh_frames, sb_str(&sbcfi), sb_len(&sbcfi));
  elf_set_sect_data(sect_debug_line, sb_str(&sblni), sb_len(&sblni));
  elf_set_sect_data(sect_debug_info, sb_str(&sbinfo), sb_len(&sbinfo));
  const struct strbuf *sbabbrev = get_abbrev_codes();
  elf_set_sect_data(sect_debug_abbrev, sb_str(sbabbrev), sb_len(sbabbrev));

  size_t esize;
  void *elfobj = elf_alloc(&elf, &esize);
  elf_free(&elf);

  sb_free(&shstrtab_buf);
  sb_free(&sbcfi);
  sb_free(&sblni);
  sb_free(&sbinfo);
#ifdef EMIT_SYMTAB
  sb_free(&strtab_buf);
  sb_free(&sbsymtab);
#endif

  struct dwarf_node *n = malloc(sizeof *n);
  *n = (struct dwarf_node){
    .next = dwarf_entries[gen].nodes,
    .mcodes = *ary,
    .jce = {
      .next_entry   = __jit_debug_descriptor.first_entry,
      .prev_entry   = NULL,
      .symfile_addr = elfobj,
      .symfile_size = esize,
    },
  };
  ++dwarf_entries[gen].count;
  dwarf_entries[gen].nodes = n;

  *ary = (struct mcode_array)ARRAY_NULL;

  if (n->jce.next_entry)
    n->jce.next_entry->prev_entry = &n->jce;
  __jit_debug_descriptor.relevant_entry =
    __jit_debug_descriptor.first_entry = &n->jce;
  __jit_debug_descriptor.action_flag = JIT_REGISTER_FN;
  __jit_debug_register_code();
}

void reset_dwarf_mcodes(unsigned gen)
{
  for (struct dwarf_node *n = dwarf_entries[gen].nodes, *next; n; n = next)
    {
      next = n->next;

      if (n->jce.prev_entry)
        n->jce.prev_entry->next_entry = n->jce.next_entry;
      else
        __jit_debug_descriptor.first_entry = n->jce.next_entry;

      if (n->jce.next_entry)
        n->jce.next_entry->prev_entry = n->jce.prev_entry;

      __jit_debug_descriptor.relevant_entry = &n->jce;
      __jit_debug_descriptor.action_flag = JIT_UNREGISTER_FN;
      __jit_debug_register_code();

      ARRAY_FREE(n->mcodes);
      free((void *)n->jce.symfile_addr);
      free(n);
    }
  dwarf_entries[gen].count = 0;
  dwarf_entries[gen].nodes = NULL;
}

#else  /* NOCOMPILER */

void reset_dwarf_mcodes(unsigned gen)
{
}

void register_dwarf_mcodes(unsigned gen, struct mcode_array *a)
{
}

#endif  /* NOCOMPILER */

uint32_t dwarf_lookup_line_number(struct code *code, uint32_t addr)
{
  struct string *lni = code->linenos;

  struct lni_state state = {
    .line = 1,
  };

  uint32_t last_line = 1;
  for (const uint8_t *pos = (uint8_t *)lni->str,
         *const end = pos + string_len(lni);
       pos < end; )
    {
      uint8_t c = *pos++;
      switch (c)
        {
        case DW_LNS_advance_pc:
          state.addr += read_leb_u(&pos);
          continue;
        case DW_LNS_advance_line:
          state.line += read_leb_s(&pos);
          continue;
        case DW_LNS_copy:
          break;
        default:
          if (c < lni_header.opcode_base)
            abort();

          c -= lni_header.opcode_base;
          state.addr += c / lni_header.line_range;
          state.line += lni_header.line_base + (c % lni_header.line_range);
        }

      if (addr < state.addr)
        return last_line;
      if (addr == state.addr)
        return state.line;
      last_line = state.line;
    }
  return last_line;
}

static size_t for_line_number_info(
  struct string *lni,
  void (*emit)(const struct lni_state *, size_t n, void *edata),
  void *edata)
{
  size_t entries = 0;

  struct lni_state state = { .line = 1 };

  for (const uint8_t *pos = (uint8_t *)lni->str,
         *const end = pos + string_len(lni);
       ; )
    {
      if (pos == end)
        break;
      if (pos > end)        /* indicates unterminated LEB */
        return (size_t)-1;

      uint8_t c = *pos++;
      switch (c)
        {
        case DW_LNS_advance_pc:
          state.addr += read_leb_u(&pos);
          continue;
        case DW_LNS_advance_line:
          state.line += read_leb_s(&pos);
          continue;
        case DW_LNS_copy:
          break;
        default:
          if (c < lni_header.opcode_base)
            return (size_t)-1;

          c -= lni_header.opcode_base;
          state.addr += c / lni_header.line_range;
          state.line += lni_header.line_base + (c % lni_header.line_range);
        }

      if (emit != NULL)
        emit(&state, entries, edata);
      ++entries;
    }
  return entries;
}

static void mudlle_lni_entry(const struct lni_state *lni, size_t n, void *data)
{
  struct vector *v = data;
  struct list *l = v->data[n];
  assert(TYPE(l, pair));
  l->car = makeint(lni->addr);
  l->cdr = makeint(lni->line);
}

struct vector *mudlle_line_number_info(struct string *lni)
{
  size_t entries = for_line_number_info(lni, NULL, NULL);
  if (entries == (size_t)-1)
    runtime_error(error_bad_value);

  struct vector *v = NULL;
  {
    GCPRO(v, lni);
    v = alloc_vector(entries);
    for (size_t i = 0; i < entries; ++i)
      SET_VECTOR(v, i, alloc_list(NULL, NULL));
    UNGCPRO();
  }
  for_line_number_info(lni, mudlle_lni_entry, v);
  return v;
}

static void c_lni_entry(const struct lni_state *lni, size_t n, void *data)
{
  struct lni_state *states = data;
  states[n] = *lni;
}

struct lni_state *line_number_info(struct string *lni, size_t *nentries)
{
  size_t entries = for_line_number_info(lni, NULL, NULL);
  if (entries == (size_t)-1 || entries == 0)
    {
      *nentries = 0;
      return NULL;
    }

  struct lni_state *states = malloc(entries * sizeof *states);
  for_line_number_info(lni, c_lni_entry, states);
  *nentries = entries;
  return states;
}

/* creates DWARF line number information from states */
struct string *dwarf_line_number_info(const struct lni_state *states,
                                      size_t nstates)
{
  static const struct lni_state init_state = { .line = 1 };
  const struct lni_state *curstate = &init_state;

  struct strbuf sblni = SBNULL;

  for (; nstates-- > 0; ++states)
    {
      int32_t dline = states->line - curstate->line;

      assert(states->addr >= curstate->addr);
      uint32_t daddr = states->addr - curstate->addr;

    again:
      if (dline == 0 && daddr == 0)
        {
          sb_add_u8(&sblni, DW_LNS_copy);
          curstate = states;
          continue;
        }

      if (dline >= lni_header.line_base
          && dline < lni_header.line_base + lni_header.line_range)
        {
          uint32_t opcode = ((dline - lni_header.line_base)
                             + lni_header.line_range * daddr
                             + lni_header.opcode_base);

          /* LLVM 11 and later has a bug where opcode 8 is unconditionally
             treated as DW_LNS_const_add_pc, so don't emit it */
          if (opcode <= 255 && opcode != DW_LNS_const_add_pc)
            {
              sb_add_u8(&sblni, opcode);
              curstate = states;
              continue;
            }
        }

      if (ABS(dline) > daddr)
        {
          sb_add_u8(&sblni, DW_LNS_advance_line);
          sb_add_leb_s(&sblni, dline);
          dline = 0;
          goto again;
        }
      else
        {
          sb_add_u8(&sblni, DW_LNS_advance_pc);
          sb_add_leb_u(&sblni, daddr);
          daddr = 0;
          goto again;
        }
    }

  struct string *result = strbuf_to_mudlle(&sblni);
  sb_free(&sblni);
  return make_readonly(result);
}
