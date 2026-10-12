/*
 * Copyright (c) 2026 Nils Schimmelmann
 * All rights reserved.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose, without fee, and without written agreement is hereby granted,
 * provided that the above copyright notice and the following two paragraphs
 * appear in all copies of this software.
 *
 * IN NO EVENT SHALL NILS SCHIMMELMANN BE LIABLE TO ANY PARTY FOR DIRECT,
 * INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE
 * USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF NILS SCHIMMELMANN HAS
 * BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * NILS SCHIMMELMANN SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 * PARTICULAR PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS"
 * BASIS, AND NILS SCHIMMELMANN HAS NO OBLIGATION TO PROVIDE MAINTENANCE,
 * SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.
 */

/* Runtime support for the LLVM native backend. */
#include "../mudlle-config.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include "llvm-cache-abi.h"

#include "../alloc.h"
#include "../compile.h"
#include "../context.h"
#include "../global.h"
#include "../utils.h"
#include "bigint.h"
#include "call.h"
#include "check-types.h"
#include "io.h"
#include "llvm.h"
#include "mudlle-float.h"
#include "mudlle-string.h"
#include "pattern.h"
#include "profile.h"
#include "prims.h"
#include "../strbuf.h"

#include <llvm-c/Core.h>
#include <llvm-c/Analysis.h>
#include <llvm-c/Error.h>
#include <llvm-c/IRReader.h>
#include <llvm-c/LLJIT.h>
#include <llvm-c/Orc.h>
#include <llvm-c/Support.h>
#include <llvm-c/Target.h>
#include <llvm-c/TargetMachine.h>
#include <llvm-c/Transforms/PassBuilder.h>
#include <llvm/Config/llvm-config.h>

static LLVMOrcLLJITRef llvm_orc_jit;
static LLVMTargetMachineRef llvm_orc_target_machine;
static size_t llvm_orc_module_sequence;

/* Optional wall-clock diagnostics; all compilation stays on the caller. */
static double llvm_compile_time(void)
{
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return now.tv_sec + now.tv_nsec * 1e-9;
}

static const char *llvm_optimization_pipeline(void)
{
  const char *level = getenv("MUDLLE_LLVM_OPT");
  static char pipeline[32];
  if (level != NULL && strcmp(level, "fast") == 0)
    return "function(sroa,early-cse,instcombine,simplifycfg)";
  if (level == NULL || strcmp(level, "2") == 0)
    level = "O2";
  else if (strcmp(level, "none") == 0 || strcmp(level, "0") == 0)
    return NULL;
  else if (strcmp(level, "1") == 0)
    level = "O1";
  else if (strcmp(level, "3") == 0)
    level = "O3";
  else if (strcmp(level, "O0") != 0 && strcmp(level, "O1") != 0
           && strcmp(level, "O2") != 0 && strcmp(level, "O3") != 0)
    {
      fprintf(stderr, "MUDLLE_LLVM_OPT must be none, O0, O1, O2, O3, or fast\n");
      runtime_error(error_bad_value);
    }
  snprintf(pipeline, sizeof pipeline, "default<%s>", level);
  return pipeline;
}

static void llvm_orc_create_target_machine(void)
{
  const char *triple = LLVMOrcLLJITGetTripleString(llvm_orc_jit);
  LLVMTargetRef target;
  char *error_message = NULL;
  if (LLVMGetTargetFromTriple(triple, &target, &error_message))
    {
      if (error_message != NULL)
        fprintf(stderr, "LLVM target lookup error: %s\n", error_message);
      if (error_message != NULL)
        LLVMDisposeMessage(error_message);
      runtime_error(error_bad_value);
    }

  char *cpu = LLVMGetHostCPUName();
  char *features = LLVMGetHostCPUFeatures();
  llvm_orc_target_machine = LLVMCreateTargetMachine(
    target, triple, cpu != NULL ? cpu : "", features != NULL ? features : "",
    LLVMCodeGenLevelDefault, LLVMRelocDefault, LLVMCodeModelJITDefault);
  if (cpu != NULL)
    LLVMDisposeMessage(cpu);
  if (features != NULL)
    LLVMDisposeMessage(features);
  if (llvm_orc_target_machine == NULL)
    runtime_error(error_bad_value);
}

static void llvm_orc_check_error(LLVMErrorRef error)
{
  if (error != NULL)
    {
      char *message = LLVMGetErrorMessage(error);
      fprintf(stderr, "LLVM JIT error: %s\n", message);
      LLVMDisposeErrorMessage(message);
      runtime_error(error_bad_value);
    }
}

static void llvm_verify_module(LLVMModuleRef module,
                               LLVMOrcThreadSafeContextRef context,
                               char *cache_path, struct strbuf *key)
{
  char *message = NULL;
  int invalid = LLVMVerifyModule(module, LLVMReturnStatusAction, &message);
  if (invalid)
    fprintf(stderr, "LLVM IR verification error: %s\n", message ? message : "invalid module");
  if (message != NULL) LLVMDisposeMessage(message);
  if (invalid)
    {
      LLVMDisposeModule(module);
      LLVMOrcDisposeThreadSafeContext(context);
      free(cache_path);
      sb_free(key);
      runtime_error(error_bad_value);
    }
}

static void llvm_unresolved_symbol_stub(void)
{
  runtime_error(error_bad_value);
}

#define LLVM_SYMBOL_ENTRY(fn) \
  { LLVMOrcLLJITMangleAndIntern(llvm_orc_jit, #fn), \
    { (LLVMOrcExecutorAddress)(uintptr_t)&(fn), \
      { LLVMJITSymbolGenericFlagsExported | LLVMJITSymbolGenericFlagsCallable, 0 } } }

#define LLVM_SYMBOL_ENTRY_VAL(name, fn) \
  { LLVMOrcLLJITMangleAndIntern(llvm_orc_jit, name), \
    { (LLVMOrcExecutorAddress)(uintptr_t)(fn), \
      { LLVMJITSymbolGenericFlagsExported | LLVMJITSymbolGenericFlagsCallable, 0 } } }

/* Generated code builds call_llvm frames inline and reads object headers and
   closure/code fields at fixed offsets (see mudlle_call_known in genllvm.mud).
   Break the build if any of these layouts change. */
_Static_assert(call_llvm == 11, "generated IR hardcodes call_llvm");
_Static_assert(sizeof (struct call_stack_mudlle) == 56
               && offsetof(struct call_stack_mudlle, s.next) == 0
               && offsetof(struct call_stack_mudlle, s.type) == 8
               && offsetof(struct call_stack_mudlle, fn) == 16
               && offsetof(struct call_stack_mudlle, code) == 24
               && offsetof(struct call_stack_mudlle, locals) == 32
               && offsetof(struct call_stack_mudlle, native_args) == 40
               && offsetof(struct call_stack_mudlle, nargs) == 48
               && offsetof(struct call_stack_mudlle, offset) == 52,
               "generated IR hardcodes struct call_stack_mudlle");
_Static_assert(offsetof(struct closure, code) == 16
               && offsetof(struct closure, variables) == 24
               && offsetof(struct variable, vvalue) == 16
               && offsetof(struct vector, data) == 16
               && offsetof(struct code, seclevel) == 58
               && sizeof (seclev_t) == 1 && sizeof (seclevel_valid) == 1,
               "generated IR hardcodes closure/code layout");

extern struct vector *llvm_call_closure_cache;

static void llvm_orc_register_absolute_symbols(LLVMOrcJITDylibRef dylib)
{
  LLVMOrcCSymbolMapPair symbols[] = {
    { LLVMOrcLLJITMangleAndIntern(llvm_orc_jit, "internal_xcount"),
      { (LLVMOrcExecutorAddress)(uintptr_t)&internal_xcount,
        { LLVMJITSymbolGenericFlagsExported, 0 } } },
    { LLVMOrcLLJITMangleAndIntern(llvm_orc_jit, "llvm_call_closure_cache"),
      { (LLVMOrcExecutorAddress)(uintptr_t)&llvm_call_closure_cache,
        { LLVMJITSymbolGenericFlagsExported, 0 } } },
    { LLVMOrcLLJITMangleAndIntern(llvm_orc_jit, "call_stack"),
      { (LLVMOrcExecutorAddress)(uintptr_t)&call_stack,
        { LLVMJITSymbolGenericFlagsExported, 0 } } },
    { LLVMOrcLLJITMangleAndIntern(llvm_orc_jit, "internal_seclevel"),
      { (LLVMOrcExecutorAddress)(uintptr_t)&internal_seclevel,
        { LLVMJITSymbolGenericFlagsExported, 0 } } },
    { LLVMOrcLLJITMangleAndIntern(llvm_orc_jit, "seclevel_valid"),
      { (LLVMOrcExecutorAddress)(uintptr_t)&seclevel_valid,
        { LLVMJITSymbolGenericFlagsExported, 0 } } },
    { LLVMOrcLLJITMangleAndIntern(llvm_orc_jit, "gcpro"),
      { (LLVMOrcExecutorAddress)(uintptr_t)&gcpro,
        { LLVMJITSymbolGenericFlagsExported, 0 } } },
    { LLVMOrcLLJITMangleAndIntern(llvm_orc_jit, "mudlle_stack_limit"),
      { (LLVMOrcExecutorAddress)(uintptr_t)&mudlle_stack_limit,
        { LLVMJITSymbolGenericFlagsExported, 0 } } },
    LLVM_SYMBOL_ENTRY(llvm_raise_error),
    LLVM_SYMBOL_ENTRY(llvm_loop_check),
    LLVM_SYMBOL_ENTRY(llvm_loop_slow_path),
    LLVM_SYMBOL_ENTRY(llvm_check_type),
    LLVM_SYMBOL_ENTRY(llvm_check_integer_pair),
    LLVM_SYMBOL_ENTRY(llvm_check_typeset),
    LLVM_SYMBOL_ENTRY(llvm_check_mutable),
    LLVM_SYMBOL_ENTRY(llvm_type_matches),
    LLVM_SYMBOL_ENTRY(llvm_object_length),
    LLVM_SYMBOL_ENTRY(llvm_predicate),
    LLVM_SYMBOL_ENTRY(llvm_vector_find),
    LLVM_SYMBOL_ENTRY(llvm_pair_car),
    LLVM_SYMBOL_ENTRY(llvm_pair_cdr),
    LLVM_SYMBOL_ENTRY(llvm_cons),
    LLVM_SYMBOL_ENTRY(llvm_make_function_closure_for_call),
    LLVM_SYMBOL_ENTRY(llvm_float_binop),
    LLVM_SYMBOL_ENTRY(llvm_float_unop),
    LLVM_SYMBOL_ENTRY(llvm_equal),
    LLVM_SYMBOL_ENTRY(llvm_build_vector),
    LLVM_SYMBOL_ENTRY(llvm_concat_strings),
    LLVM_SYMBOL_ENTRY(llvm_check_arity),
    LLVM_SYMBOL_ENTRY(llvm_argument_get),
    LLVM_SYMBOL_ENTRY(llvm_make_varargs),
    LLVM_SYMBOL_ENTRY(llvm_global_read),
    LLVM_SYMBOL_ENTRY(llvm_check_global_read),
    LLVM_SYMBOL_ENTRY(llvm_global_write),
    LLVM_SYMBOL_ENTRY(llvm_check_global_write),
    LLVM_SYMBOL_ENTRY(llvm_gc_roots_enter),
    LLVM_SYMBOL_ENTRY(llvm_gc_roots_leave),
    LLVM_SYMBOL_ENTRY(llvm_call_value),
    LLVM_SYMBOL_ENTRY(llvm_call_global),
    LLVM_SYMBOL_ENTRY(llvm_call_global_constant),
    LLVM_SYMBOL_ENTRY(llvm_variable_new),
    LLVM_SYMBOL_ENTRY(llvm_variable_get),
    LLVM_SYMBOL_ENTRY(llvm_variable_set),
    LLVM_SYMBOL_ENTRY(llvm_make_function_closure),
    LLVM_SYMBOL_ENTRY(llvm_constant_get),
    LLVM_SYMBOL_ENTRY(llvm_closure_capture_get),
    LLVM_SYMBOL_ENTRY(llvm_closure_capture_set),
    LLVM_SYMBOL_ENTRY_VAL("system", llvm_unresolved_symbol_stub),
    LLVM_SYMBOL_ENTRY_VAL("execve", llvm_unresolved_symbol_stub),
    LLVM_SYMBOL_ENTRY_VAL("dlopen", llvm_unresolved_symbol_stub),
    LLVM_SYMBOL_ENTRY_VAL("mmap", llvm_unresolved_symbol_stub),
    LLVM_SYMBOL_ENTRY_VAL("popen", llvm_unresolved_symbol_stub),
    LLVM_SYMBOL_ENTRY_VAL("fork", llvm_unresolved_symbol_stub)
  };
  size_t count = sizeof symbols / sizeof symbols[0];
  LLVMOrcMaterializationUnitRef mu = LLVMOrcAbsoluteSymbols(symbols, count);
  llvm_orc_check_error(LLVMOrcJITDylibDefine(dylib, mu));
}


static void llvm_orc_initialize(void)
{
  if (llvm_orc_jit != NULL)
    return;
#if LLVM_VERSION_MAJOR < 15
  /* LLVM 14 still defaults to typed pointers when parsing textual IR. */
  const char *opaque_pointer_args[] = { "mudlle", "-opaque-pointers" };
  LLVMParseCommandLineOptions(2, opaque_pointer_args, NULL);
#endif
  if (LLVMInitializeNativeTarget() || LLVMInitializeNativeAsmPrinter())
    runtime_error(error_bad_value);


  /* A default LLJIT compiles on the calling thread; no worker pool is used. */
  llvm_orc_check_error(LLVMOrcCreateLLJIT(&llvm_orc_jit, NULL));
  llvm_orc_create_target_machine();
  llvm_orc_register_absolute_symbols(LLVMOrcLLJITGetMainJITDylib(llvm_orc_jit));
}

/* Cache files are private, disposable native-code artifacts. The complete key
   is stored and compared, so filename hash collisions cannot reuse wrong code.
   Writes use rename, allowing independent single-threaded processes to race. */
static uint64_t llvm_cache_hash(const void *bytes, size_t length)
{
  const unsigned char *p = bytes;
  uint64_t hash = UINT64_C(14695981039346656037);
  for (size_t i = 0; i < length; ++i)
    hash = (hash ^ p[i]) * UINT64_C(1099511628211);
  return hash;
}

static void llvm_cache_key(struct strbuf *key, struct string *ir,
                           struct string *symbol)
{
  sb_init(key);
  sb_addstr(key, "mudlle-native-object-v2\n" MUDLLE_LLVM_CACHE_ABI "\n"
            LLVM_VERSION_STRING "\norc-default-codegen\n");
  sb_addstr(key, LLVMOrcLLJITGetTripleString(llvm_orc_jit));
  sb_addstr(key, "\n");
  sb_addstr(key, LLVMOrcLLJITGetDataLayoutStr(llvm_orc_jit));
  char *cpu = LLVMGetTargetMachineCPU(llvm_orc_target_machine);
  char *features = LLVMGetTargetMachineFeatureString(llvm_orc_target_machine);
  sb_addstr(key, "\n"); sb_addstr(key, cpu);
  sb_addstr(key, "\n"); sb_addstr(key, features);
  LLVMDisposeMessage(cpu); LLVMDisposeMessage(features);
  const char *pipeline = llvm_optimization_pipeline();
  sb_addstr(key, "\n"); sb_addstr(key, pipeline ? pipeline : "none");
  sb_addstr(key, "\n"); sb_addstr(key, symbol->str);
  sb_addstr(key, "\n"); sb_addmem(key, ir->str, string_len(ir));
}

static char *llvm_cache_path(struct strbuf *key)
{
  const char *directory = getenv("MUDLLE_LLVM_CACHE");
  if (directory == NULL) directory = ".mudlle-llvm-cache";
  if (*directory == '\0') return NULL;
  if (mkdir(directory, 0700) != 0)
    {
      struct stat st;
      if (stat(directory, &st) != 0 || !S_ISDIR(st.st_mode)) return NULL;
    }
  size_t size = strlen(directory) + 32;
  char *path = malloc(size);
  if (path != NULL)
    snprintf(path, size, "%s/%016llx.cache", directory,
             (unsigned long long)llvm_cache_hash(sb_str(key), sb_len(key)));
  return path;
}

static LLVMMemoryBufferRef llvm_cache_read(const char *path, struct strbuf *key)
{
  if (path == NULL) return NULL;
  FILE *file = fopen(path, "rb");
  if (file == NULL) return NULL;
  uint64_t header[3];
  LLVMMemoryBufferRef result = NULL;
  size_t key_size = sb_len(key);
  if (fread(header, sizeof header, 1, file) == 1 && header[0] == key_size
      && header[1] > 0 && header[1] <= 256 * 1024 * 1024)
    {
      char *stored_key = malloc(key_size);
      char *object = malloc((size_t)header[1]);
      if (stored_key != NULL && object != NULL
          && fread(stored_key, 1, key_size, file) == key_size
          && memcmp(stored_key, sb_str(key), key_size) == 0
          && fread(object, 1, (size_t)header[1], file) == header[1]
          && fgetc(file) == EOF
          && llvm_cache_hash(object, (size_t)header[1]) == header[2])
        result = LLVMCreateMemoryBufferWithMemoryRangeCopy(
          object, (size_t)header[1], "mudlle-cached-object");
      free(stored_key); free(object);
    }
  fclose(file);
  return result;
}

static void llvm_cache_write(char *path, struct strbuf *key,
                             LLVMMemoryBufferRef object)
{
  if (path == NULL) return;
  char *temporary = malloc(strlen(path) + 8);
  if (temporary == NULL) { free(path); return; }
  sprintf(temporary, "%s.XXXXXX", path);
  int fd = mkstemp(temporary);
  if (fd >= 0)
    {
      FILE *file = fdopen(fd, "wb");
      if (file != NULL)
        {
          uint64_t header[] = { sb_len(key), LLVMGetBufferSize(object),
            llvm_cache_hash(LLVMGetBufferStart(object), LLVMGetBufferSize(object)) };
          bool ok = fwrite(header, sizeof header, 1, file) == 1
            && fwrite(sb_str(key), 1, header[0], file) == header[0]
            && fwrite(LLVMGetBufferStart(object), 1, header[1], file) == header[1];
          if (fclose(file) != 0) ok = false;
          if (ok) (void)rename(temporary, path);
        }
      else close(fd);
      unlink(temporary);
    }
  free(temporary); free(path);
}

#if LLVM_VERSION_MAJOR >= 19
struct llvm_lookup_result { LLVMOrcExecutorAddress address; bool done; };
static void llvm_lookup_complete(LLVMErrorRef error,
                                 LLVMOrcCSymbolMapPairs symbols, size_t count,
                                 void *opaque)
{
  llvm_orc_check_error(error);
  struct llvm_lookup_result *result = opaque;
  if (count != 1) runtime_error(error_bad_value);
  result->address = symbols[0].Sym.Address;
  result->done = true;
}
#endif

static LLVMOrcJITDylibRef llvm_orc_module_dylib(size_t sequence)
{
#if LLVM_VERSION_MAJOR < 19
  /* Older LLVM releases have no C API for lookup in a selected dylib. Include the
     sequence in their key and object symbols instead of sharing names. */
  (void)sequence;
  return LLVMOrcLLJITGetMainJITDylib(llvm_orc_jit);
#else
  char name[64];
  snprintf(name, sizeof name, "mudlle_module_%zu", sequence);
  LLVMOrcJITDylibRef dylib;
  LLVMOrcExecutionSessionRef session = LLVMOrcLLJITGetExecutionSession(llvm_orc_jit);
  llvm_orc_check_error(LLVMOrcExecutionSessionCreateJITDylib(session, &dylib, name));
  llvm_orc_register_absolute_symbols(dylib);
  return dylib;
#endif
}

static void *llvm_orc_lookup(LLVMOrcJITDylibRef dylib, const char *symbol,
                             size_t sequence)
{
#if LLVM_VERSION_MAJOR < 19
  (void)dylib;
  struct strbuf name = sb_initf("mudlle_module_%zu_%s", sequence, symbol);
  LLVMOrcExecutorAddress address;
  LLVMErrorRef error = LLVMOrcLLJITLookup(llvm_orc_jit, &address, sb_str(&name));
  sb_free(&name);
  llvm_orc_check_error(error);
  return (void *)(uintptr_t)address;
#else
  (void)sequence;
  LLVMOrcCJITDylibSearchOrderElement order = {
    dylib, LLVMOrcJITDylibLookupFlagsMatchAllSymbols };
  LLVMOrcCLookupSetElement lookup = {
    LLVMOrcLLJITMangleAndIntern(llvm_orc_jit, symbol),
    LLVMOrcSymbolLookupFlagsRequiredSymbol };
  struct llvm_lookup_result result = {0};
  /* Default LLJIT and process generators complete synchronously. No workers. */
  LLVMOrcExecutionSessionLookup(LLVMOrcLLJITGetExecutionSession(llvm_orc_jit),
    LLVMOrcLookupKindStatic, &order, 1, &lookup, 1, llvm_lookup_complete, &result);
  if (!result.done) runtime_error(error_bad_value);
  return (void *)(uintptr_t)result.address;
#endif
}

struct llvm_cache_capture { char *path; struct strbuf *key; };
static LLVMErrorRef llvm_cache_capture_object(void *opaque,
                                              LLVMMemoryBufferRef *object)
{
  struct llvm_cache_capture *capture = opaque;
  if (capture != NULL)
    {
      llvm_cache_write(capture->path, capture->key, *object);
      capture->path = NULL;
    }
  return LLVMErrorSuccess;
}

static void *llvm_orc_compile_ir(struct string *ir, struct string *symbol)
{
  double started = llvm_compile_time(), parsed, optimized;
  char *parse_message = NULL;
  LLVMOrcThreadSafeContextRef safe_context;
  LLVMContextRef context;
  LLVMMemoryBufferRef buffer;
  LLVMModuleRef module;
  size_t sequence;

  llvm_orc_initialize();
  /* A previous Mudlle error may have unwound a lookup. Never leave a
     transform referring to that call's stack-local capture context. */
  LLVMOrcObjectTransformLayerSetTransform(
    LLVMOrcLLJITGetObjTransformLayer(llvm_orc_jit), llvm_cache_capture_object, NULL);
  sequence = llvm_orc_module_sequence++;
  struct strbuf key;
  llvm_cache_key(&key, ir, symbol);
#if LLVM_VERSION_MAJOR < 19
  sb_printf(&key, "\nlegacy-module-sequence=%zu", sequence);
#endif
  LLVMOrcJITDylibRef dylib = llvm_orc_module_dylib(sequence);
  char *cache_path = llvm_cache_path(&key);
  buffer = llvm_cache_read(cache_path, &key);
  if (getenv("MUDLLE_LLVM_CACHE_TRACE") != NULL)
    fprintf(stderr, "LLVM object cache %s\n", buffer ? "hit" : "miss");
  if (buffer != NULL)
    {
      free(cache_path); sb_free(&key);
      llvm_orc_check_error(LLVMOrcLLJITAddObjectFile(llvm_orc_jit, dylib, buffer));
      return llvm_orc_lookup(dylib, symbol->str, sequence);
    }
#if LLVM_VERSION_MAJOR >= 21
  /* LLVM 21 removed the ORC accessor for a context created by ORC. */
  context = LLVMContextCreate();
  safe_context = LLVMOrcCreateNewThreadSafeContextFromLLVMContext(context);
#else
  safe_context = LLVMOrcCreateNewThreadSafeContext();
  context = LLVMOrcThreadSafeContextGetContext(safe_context);
#endif
  buffer = LLVMCreateMemoryBufferWithMemoryRangeCopy(
    ir->str, string_len(ir), "mudlle-module");
  if (LLVMParseIRInContext(context, buffer, &module, &parse_message))
    {
      if (parse_message != NULL)
        fprintf(stderr, "LLVM IR parse error: %s\n", parse_message);
      if (parse_message != NULL)
        LLVMDisposeMessage(parse_message);
      LLVMOrcDisposeThreadSafeContext(safe_context);
      free(cache_path); sb_free(&key);
      runtime_error(error_bad_value);
    }
  if (parse_message != NULL)
    LLVMDisposeMessage(parse_message);

  llvm_verify_module(module, safe_context, cache_path, &key);
  parsed = llvm_compile_time();

  const char *pipeline = llvm_optimization_pipeline();
  if (pipeline != NULL)
    {
      LLVMPassBuilderOptionsRef options = LLVMCreatePassBuilderOptions();
      LLVMSetTarget(module, LLVMOrcLLJITGetTripleString(llvm_orc_jit));
      LLVMSetDataLayout(module, LLVMOrcLLJITGetDataLayoutStr(llvm_orc_jit));
      const char *verify = getenv("MUDLLE_LLVM_VERIFY_EACH");
      LLVMPassBuilderOptionsSetVerifyEach(options,
                                         verify != NULL && strcmp(verify, "1") == 0);
      LLVMPassBuilderOptionsSetLoopInterleaving(options, 1);
      LLVMPassBuilderOptionsSetLoopVectorization(options, 1);
      LLVMPassBuilderOptionsSetSLPVectorization(options, 1);
      LLVMErrorRef error = LLVMRunPasses(module, pipeline,
                                         llvm_orc_target_machine, options);
      LLVMDisposePassBuilderOptions(options);
      if (error != NULL)
        {
          LLVMDisposeModule(module);
          LLVMOrcDisposeThreadSafeContext(safe_context);
          free(cache_path); sb_free(&key);
          llvm_orc_check_error(error);
        }
    }

  if (pipeline != NULL)
    llvm_verify_module(module, safe_context, cache_path, &key);
  optimized = llvm_compile_time();

#if LLVM_VERSION_MAJOR < 19
  for (LLVMValueRef function = LLVMGetFirstFunction(module); function != NULL;
       function = LLVMGetNextFunction(function))
    if (LLVMCountBasicBlocks(function) != 0)
      {
        size_t old_length;
        const char *old_name = LLVMGetValueName2(function, &old_length);
        char prefix[48];
        int prefix_length = snprintf(prefix, sizeof prefix,
                                     "mudlle_module_%zu_", sequence);
        if (prefix_length < 0 || (size_t)prefix_length >= sizeof prefix
            || old_length > SIZE_MAX - (size_t)prefix_length)
          {
            LLVMDisposeModule(module);
            LLVMOrcDisposeThreadSafeContext(safe_context);
            runtime_error(error_bad_value);
          }
        char *new_name = malloc((size_t)prefix_length + old_length + 1);
        if (new_name == NULL)
          {
            LLVMDisposeModule(module);
            LLVMOrcDisposeThreadSafeContext(safe_context);
            runtime_error(error_bad_value);
          }
        memcpy(new_name, prefix, (size_t)prefix_length);
        memcpy(new_name + prefix_length, old_name, old_length);
        new_name[prefix_length + old_length] = 0;
        LLVMSetValueName2(function, new_name,
                          (size_t)prefix_length + old_length);
        free(new_name);
      }

#endif
  LLVMOrcThreadSafeModuleRef safe_module =
    LLVMOrcCreateNewThreadSafeModule(module, safe_context);
  LLVMOrcDisposeThreadSafeContext(safe_context);
  struct llvm_cache_capture capture = { cache_path, &key };
  LLVMOrcObjectTransformLayerRef layer = LLVMOrcLLJITGetObjTransformLayer(llvm_orc_jit);
  LLVMOrcObjectTransformLayerSetTransform(layer, llvm_cache_capture_object, &capture);
  llvm_orc_check_error(LLVMOrcLLJITAddLLVMIRModule(llvm_orc_jit, dylib, safe_module));
  void *address = llvm_orc_lookup(dylib, symbol->str, sequence);
  if (getenv("MUDLLE_LLVM_TIMING") != NULL)
    fprintf(stderr, "LLVM timing bytes=%zu prepare_parse=%.6f optimize=%.6f codegen_link=%.6f\n",
            (size_t)string_len(ir), parsed - started, optimized - parsed,
            llvm_compile_time() - optimized);
  LLVMOrcObjectTransformLayerSetTransform(layer, llvm_cache_capture_object, NULL);
  free(capture.path);
  sb_free(&key);
  return address;
}

void llvm_raise_error(int64_t error_code, int64_t argument);

/* Raise an ordinary Mudlle runtime error from generated LLVM code. */
void llvm_raise_error(int64_t error_code, int64_t argument)
{
  enum runtime_error error = (enum runtime_error)error_code;
  if (error == error_no_match && argument != 0)
    no_match_error((value)(uintptr_t)argument);
  runtime_error(error);
}

void llvm_loop_check(void);
static void llvm_check_stack(void);

/* Account for one generated loop back edge and enforce the active limit. */
void llvm_loop_check(void)
{
  if (internal_xcount & XCOUNT_PROFILE_FLAG)
    profile_tick();
  ulong count = get_xcount();
  set_xcount(count - 1);
  if (count <= 1)
    runtime_error(error_loop);
  llvm_check_stack();
}

/* The generated fast path decrements the shared counter directly.  A
   nonpositive result means either the budget expired or a profiling signal
   set the sign-bit flag.  Match x64 by servicing the flag and continuing. */
void llvm_loop_slow_path(void)
{
  if (internal_xcount & XCOUNT_PROFILE_FLAG)
    {
      profile_tick();
      return;
    }
  runtime_error(error_loop);
}

static void llvm_check_stack(void)
{
  if (get_stack_pointer() < mudlle_stack_limit)
    runtime_error(error_recurse);
}

void llvm_check_type(int64_t raw_value, int64_t raw_type);
void llvm_check_typeset(int64_t raw_value, int64_t raw_typeset,
                        int64_t raw_argnum);
void llvm_check_mutable(int64_t raw_value);
int32_t llvm_type_matches(int64_t raw_value, int64_t raw_type);
int64_t llvm_object_length(int64_t raw_value, int64_t is_string);
int32_t llvm_predicate(int64_t raw_value, int64_t predicate);
int32_t llvm_vector_find(int64_t raw_needle, int64_t raw_haystack);
int32_t llvm_equal(int64_t raw_lhs, int64_t raw_rhs);

int32_t llvm_equal(int64_t raw_lhs, int64_t raw_rhs)
{
  return mudlle_values_equal((value)(uintptr_t)raw_lhs,
                             (value)(uintptr_t)raw_rhs);
}

int32_t llvm_vector_find(int64_t raw_needle, int64_t raw_haystack)
{
  value needle = (value)(uintptr_t)raw_needle;
  value haystack = (value)(uintptr_t)raw_haystack;
  if (!TYPE(haystack, vector))
    bad_type_error(haystack, type_vector, -1);
  struct vector *v = (struct vector *)haystack;
  for (size_t i = 0; i < vector_len(v); ++i)
    if (v->data[i] == needle)
      return 1;
  return 0;
}

int64_t llvm_pair_car(int64_t raw_pair)
{
  struct list *pair = (struct list *)(uintptr_t)raw_pair;
  if (!TYPE(pair, pair))
    bad_type_error((value)pair, type_pair, -1);
  return (int64_t)(uintptr_t)pair->car;
}

int64_t llvm_pair_cdr(int64_t raw_pair)
{
  struct list *pair = (struct list *)(uintptr_t)raw_pair;
  if (!TYPE(pair, pair))
    bad_type_error((value)pair, type_pair, -1);
  return (int64_t)(uintptr_t)pair->cdr;
}

/* Direct cons/pcons: arguments are by value and rooted by alloc_list. */
int64_t llvm_cons(int64_t raw_car, int64_t raw_cdr, int64_t readonly);

int64_t llvm_cons(int64_t raw_car, int64_t raw_cdr, int64_t readonly)
{
  value car = (value)(uintptr_t)raw_car, cdr = (value)(uintptr_t)raw_cdr;
  struct list *p = try_alloc_list(car, cdr, readonly != 0);
  if (p == NULL)
    {
      p = alloc_list(car, cdr);
      if (readonly)
        {
          unsigned imm = immutablep(car) && immutablep(cdr) ? OBJ_IMMUTABLE : 0;
          p->o.flags |= OBJ_READONLY | imm;
        }
    }
  return (int64_t)(uintptr_t)p;
}

/* fadd/fsub/fmul/fdiv on floats and fixnums. Returns 0 for anything else so
   the generic call reports the usual type error. The operands are read
   before the result is allocated, so nothing needs rooting. */
int64_t llvm_float_binop(int64_t op, int64_t raw_a, int64_t raw_b);

int64_t llvm_float_binop(int64_t op, int64_t raw_a, int64_t raw_b)
{
  value a = (value)(uintptr_t)raw_a, b = (value)(uintptr_t)raw_b;
  double x, y;
  if (TYPE(a, float)) x = ((struct mudlle_float *)a)->d;
  else if (integerp(a)) x = intval(a);
  else return 0;
  if (TYPE(b, float)) y = ((struct mudlle_float *)b)->d;
  else if (integerp(b)) y = intval(b);
  else return 0;
  double r;
  switch (op)
    {
    case 0: r = x + y; break;
    case 1: r = x - y; break;
    case 2: r = x * y; break;
    case 3: r = x / y; break;
    case 4: r = fmod(x, y); break;
    case 5:
      /* fcmp: NaN is an error, left to the generic call */
      if (isunordered(x, y)) return 0;
      return (int64_t)(uintptr_t)makeint(isless(x, y) ? -1 : isgreater(x, y));
    default: return 0;
    }
  return (int64_t)(uintptr_t)alloc_float(r);
}

/* Unary float functions on floats and fixnums; 0 means use the generic call. */
int64_t llvm_float_unop(int64_t op, int64_t raw_a);

int64_t llvm_float_unop(int64_t op, int64_t raw_a)
{
  value a = (value)(uintptr_t)raw_a;
  double x, r;
  if (TYPE(a, float)) x = ((struct mudlle_float *)a)->d;
  else if (integerp(a)) x = intval(a);
  else return 0;
  switch (op)
    {
    case 0: r = -x; break;
    case 1: r = fabs(x); break;
    case 2: r = sqrt(x); break;
    case 3: r = exp(x); break;
    case 4: r = log(x); break;
    case 5: r = sin(x); break;
    case 6: r = cos(x); break;
    case 7: r = tan(x); break;
    case 8: r = atan(x); break;
    case 9: r = asin(x); break;
    case 10: r = acos(x); break;
    case 11: r = ceil(x); break;
    case 12: r = floor(x); break;
    case 13: r = round(x); break;
    case 14: r = trunc(x); break;
    default: return 0;
    }
  return (int64_t)(uintptr_t)alloc_float(r);
}

int32_t llvm_predicate(int64_t raw_value, int64_t predicate)
{
  value v = (value)(uintptr_t)raw_value;
  switch (predicate)
    {
    case 0: return immutablep(v);
    case 1: return !immutablep(v);
    case 2: return readonlyp(v);
    case 3: return !readonlyp(v);
    case 4: return is_any_primitive(v);
    case 5: return !is_any_primitive(v);
    default: return 0;
    }
}

int64_t llvm_object_length(int64_t raw_value, int64_t is_string)
{
  value v = (value)(uintptr_t)raw_value;
  if (is_string)
    {
      if (!TYPE(v, string))
        bad_type_error(v, type_string, -1);
      return (int64_t)makeint(string_len((struct string *)v));
    }
  if (!TYPE(v, vector))
    bad_type_error(v, type_vector, -1);
  return (int64_t)makeint(vector_len((struct vector *)v));
}

int32_t llvm_type_matches(int64_t raw_value, int64_t raw_type)
{
  if (raw_type < 0 || raw_type >= mudlle_synthetic_types)
    return 0;
  value v = (value)(uintptr_t)raw_value;
  return is_typeset(v, type_typeset((enum mudlle_type)raw_type));
}

void llvm_check_mutable(int64_t raw_value)
{
  value v = (value)(uintptr_t)raw_value;
  if (!pointerp(v))
    runtime_error(error_bad_type);
  if (obj_readonlyp((struct obj *)v))
    runtime_error(error_value_read_only);
}

void llvm_check_type(int64_t raw_value, int64_t raw_type)
{
  value v = (value)(uintptr_t)raw_value;
  enum mudlle_type type = (enum mudlle_type)raw_type;
  if (!is_typeset(v, type_typeset(type)))
    bad_type_error(v, type, -1);
}

void llvm_check_integer_pair(int64_t raw_first, int64_t raw_second)
{
  value first = (value)(uintptr_t)raw_first;
  value second = (value)(uintptr_t)raw_second;
  if (!integerp(first))
    bad_type_error(first, type_integer, -1);
  if (!integerp(second))
    bad_type_error(second, type_integer, -1);
}

void llvm_check_typeset(int64_t raw_value, int64_t raw_typeset,
                        int64_t raw_argnum)
{
  value v = (value)(uintptr_t)raw_value;
  typeset_t expected = (typeset_t)raw_typeset;
  typeset_t accepted = expected & (TYPESET_ANY | TYPESET_FALSE);
  if (!is_typeset(v, accepted))
    bad_typeset_error(v, expected, (int)raw_argnum);
}

/* This initialization must remain call-free with respect to Mudlle GC. */
static value llvm_finish_vector(struct vector *vector, value *arguments,
                                int64_t nargs, int64_t readonly,
                                int64_t immutable)
{
  for (int64_t i = 0; i < nargs; ++i)
    {
      GCCHECK(arguments[i]);
      vector->data[i] = arguments[i];
      /* Readonly constants can still contain movable mutable children. */
      immutable = immutable && immutablep(arguments[i]);
    }
  if (readonly)
    {
      make_readonly(vector);
      if (immutable)
        vector->o.flags |= OBJ_IMMUTABLE;
    }
  return vector;
}

/* Keep the variable-sized copy and root records off the common path. */
static __attribute__((noinline)) value
llvm_build_vector_collecting(value *arguments, int64_t nargs, int64_t readonly,
                             int64_t immutable)
{
  struct gcpro *old_gcpro = gcpro;
  value rooted[nargs ? nargs : 1];
  struct gcpro roots[nargs ? nargs : 1];
  for (int64_t i = 0; i < nargs; ++i)
    {
      rooted[i] = arguments[i];
      roots[i] = (struct gcpro){
        .next = i == 0 ? old_gcpro : &roots[i - 1],
        .obj = &rooted[i]
      };
      GCCHECK(rooted[i]);
    }
  if (nargs != 0)
    gcpro = &roots[nargs - 1];

  struct vector *vector = ALLOC_RECORD_NOINIT(vector, (size_t)nargs);
  value result = llvm_finish_vector(vector, rooted, nargs, readonly, immutable);
  gcpro = old_gcpro;
  return result;
}

value llvm_build_vector(value *arguments, int64_t nargs, int64_t readonly,
                       int64_t immutable)
{
  if (nargs < 0 || nargs > MAX_FUNCTION_ARGS)
    runtime_error(error_bad_value);

  /* Single-threaded, fully initialized construction; failure does not GC. */
  struct vector *vector = try_alloc_vector(arguments, (size_t)nargs,
                                           readonly != 0, immutable != 0);
  if (vector != NULL)
    return vector;
  return llvm_build_vector_collecting(arguments, nargs, readonly, immutable);
}

value llvm_concat_strings(value *arguments, int64_t nargs);

value llvm_concat_strings(value *arguments, int64_t nargs)
{
  if (nargs < 0)
    runtime_error(error_bad_value);
  return concat_strings((long)nargs, (struct string **)arguments);
}


typedef int64_t (*llvm_native_entry)(int64_t, value *, int64_t);

void llvm_check_arity(int64_t nargs, int64_t minimum, int64_t maximum)
{
  if (nargs < minimum || (maximum >= 0 && nargs > maximum))
    runtime_error(error_wrong_parameters);
}

int64_t llvm_argument_get(value *arguments, int64_t nargs, int64_t index)
{
  if (nargs < 0 || index < 0 || index >= nargs || arguments == NULL)
    return (int64_t)(uintptr_t)NULL;
  return (int64_t)(uintptr_t)arguments[index];
}

int64_t llvm_make_varargs(value *arguments, int64_t nargs, int64_t start)
{
  if (nargs < 0 || start < 0 || (nargs != 0 && arguments == NULL))
    {
      runtime_error(error_wrong_parameters);
      return (int64_t)(uintptr_t)NULL;
    }
  if (start > nargs) start = nargs;
  size_t count = (size_t)(nargs - start);
  value rooted[count ? count : 1];
  struct gcpro roots[count ? count : 1];
  struct gcpro *old_gcpro = gcpro;
  for (size_t i = 0; i < count; ++i)
    {
      rooted[i] = arguments[(size_t)start + i];
      roots[i] = (struct gcpro){
        .next = i == 0 ? old_gcpro : &roots[i - 1], .obj = &rooted[i]
      };
      GCCHECK(rooted[i]);
    }
  if (count != 0) gcpro = &roots[count - 1];
  struct vector *result = alloc_vector(count);
  struct gcpro result_root;
  GCPROV(result_root, result);
  for (size_t i = 0; i < count; ++i)
    result->data[i] = rooted[i];
  gcpro = old_gcpro;
  return (int64_t)(uintptr_t)result;
}

struct llvm_callback_data
{
  llvm_native_entry entry;
  size_t nargs;
  bool check_arity;
  bool stable;
};

static value llvm_invoke_closure(struct llvm_callback_data *data,
                                 struct closure *closure,
                                 value *arguments, size_t nargs);

static value llvm_call_closure(void *cbdata, struct closure *closure,
                               struct vector *arguments)
{
  struct llvm_callback_data *data = cbdata;
  if (data->check_arity && vector_len(arguments) != data->nargs)
    {
      runtime_error(error_wrong_parameters);
      return NULL;
    }
  GCPRO(closure, arguments);
  size_t nargs = vector_len(arguments);
  value argv[nargs ? nargs : 1];
  value *slots[nargs ? nargs : 1];
  struct gcpro roots[nargs ? nargs : 1];
  for (size_t i = 0; i < nargs; ++i)
    {
      argv[i] = arguments->data[i];
      slots[i] = &argv[i];
    }
  struct gcpro *old_gcpro = llvm_gc_roots_enter(slots, nargs, roots);
  value result = llvm_invoke_closure(data, closure, argv, nargs);
  llvm_gc_roots_leave(old_gcpro);
  UNGCPRO();
  return result;
}

bool llvm_stable_closure(value fn)
{
  if (!TYPE(fn, closure) || !readonlyp(fn))
    return false;
  void *cbdata = NULL;
  if (!mcallback_varargs_matches((struct closure *)fn, llvm_call_closure,
                                 &cbdata))
    return false;
  struct llvm_callback_data *data = cbdata;
  return data->stable;
}

static void llvm_free_callback(void *cbdata)
{
  free(cbdata);
}

/* Generated calls can enter another LLVM closure directly. Keep a language
   frame for GC and error traces without executing its interpreter wrapper. */
static value llvm_invoke_closure(struct llvm_callback_data *data,
                                 struct closure *closure,
                                 value *arguments, size_t nargs)
{
  /* The callee's inline entry sequence checks the stack limit. */
  check_allow_mudlle_call();
  check_interrupt();
  struct call_stack_mudlle frame = {
    .s = { .next = call_stack, .type = call_llvm },
    .fn = closure,
    .code = (struct icode *)closure->code,
    .locals = NULL,
    .native_args = arguments,
    .nargs = (int)nargs,
    .offset = -1
  };
  call_stack = &frame.s;

  seclev_t level = closure->code->seclevel;
  if (level < minlevel)
    runtime_error(error_security_violation);
  seclev_t maximum = maxseclevel_for(level);
  seclev_t old_maximum = c_maxseclevel();
  seclev_t old_trace = trace_seclevel();
  if (maximum < old_maximum)
    set_c_maxseclevel(maximum);
  if (maximum < old_trace)
    set_trace_seclevel(maximum);

  if (data->check_arity && nargs != data->nargs)
    runtime_error(error_wrong_parameters);
  value result = (value)(uintptr_t)data->entry(
    (int64_t)(uintptr_t)frame.fn, arguments, (int64_t)nargs);
  set_c_maxseclevel(old_maximum);
  set_trace_seclevel(old_trace);
  call_stack = frame.s.next;
  return result;
}

/* JIT-generated calls run as Mudlle code even though the caller is C here.
   Keep the language security check, without applying the C-entry restriction
   in function_callable(). */
static seclev_t llvm_caller_seclevel(value caller)
{
  if (!TYPE(caller, closure) || ((struct closure *)caller)->code == NULL)
    {
      runtime_error(error_bad_value);
      return DEFAULT_SECLEVEL;
    }
  return ((struct closure *)caller)->code->seclevel;
}

static void llvm_check_callable(value function, long nargs,
                                seclev_t caller_seclevel)
{
  if (TYPE(function, secure))
    {
      const struct prim_op *op = ((struct primitive *)function)->op;
      if (caller_seclevel < op->seclevel
          || (in_mudlle_session() && c_maxseclevel() < op->seclevel))
        runtime_error_message(error_security_violation, "maxseclevel too low");
      if (!callablep(function, nargs))
        runtime_error(error_wrong_parameters);
      return;
    }

  callable(function, nargs);
}

value llvm_global_read(int64_t offset)
{
  if (offset < 0 || (ulong)offset >= vector_len(global_names))
    {
      runtime_error(error_bad_value);
      return NULL;
    }
  return GVAR((ulong)offset);
}

void llvm_check_global_read(int64_t offset)
{
  if (offset < 0 || (ulong)offset >= vector_len(global_names))
    runtime_error(error_bad_value);
  check_global_read((ulong)offset);
}

void llvm_global_write(int64_t offset, int64_t raw_value)
{
  if (offset < 0 || (ulong)offset >= vector_len(global_names))
    runtime_error(error_bad_value);
  GVAR((ulong)offset) = (value)(uintptr_t)raw_value;
}

void llvm_check_global_write(int64_t offset, int64_t raw_value)
{
  if (offset < 0 || (ulong)offset >= vector_len(global_names))
    runtime_error(error_bad_value);
  check_global_write((ulong)offset, (value)(uintptr_t)raw_value);
}

/* Register values stored in an LLVM frame as ordinary Mudlle GC roots. */
struct gcpro *llvm_gc_roots_enter(value **slots, int64_t nslots,
                                  struct gcpro *roots)
{
  struct gcpro *old_gcpro = gcpro;
  for (int64_t i = 0; i < nslots; ++i)
    {
      GCCHECK(*slots[i]);
      roots[i] = (struct gcpro){
        .next = i == 0 ? old_gcpro : &roots[i - 1],
        .obj = slots[i]
      };
    }
  if (nslots != 0)
    gcpro = &roots[nslots - 1];
  return old_gcpro;
}

void llvm_gc_roots_leave(struct gcpro *old_gcpro)
{
  gcpro = old_gcpro;
}

/* Call a fixed-arity primitive with its arguments passed by value, as callv()
   does after copying them out of an argument vector. The caller has verified
   callability, so nargs matches the primitive and no vector is allocated. */
static value llvm_call_primitive(struct primitive *prim, const value *args,
                                 size_t nargs)
{
  switch (nargs)
    {
    case 0: return ((op0_fn)prim->op->op)();
#define __ARGV(N) args[DEC(N)]
#define __PCALLOP(N)                                                    \
    case N:                                                             \
      return ((PRIMOPTYPE(N))prim->op->op)(CONCATCOMMA(N, __ARGV))
    DOPRIMARGS(__PCALLOP, SEP_SEMI);
#undef __PCALLOP
#undef __ARGV
    }
  abort();
}

/* Keep the allocating fallback out of the native call's C stack frame. */
static value llvm_call_fallback(value function, value *arguments, size_t nargs)
{
  struct gcpro *old_gcpro = gcpro;
  struct gcpro function_root;
  GCPROV(function_root, function);
  value rooted_args[nargs ? nargs : 1];
  struct gcpro argument_roots[nargs ? nargs : 1];
  for (size_t i = 0; i < nargs; ++i)
    {
      rooted_args[i] = arguments[i];
      argument_roots[i] = (struct gcpro){
        .next = i == 0 ? &function_root : &argument_roots[i - 1],
        .obj = &rooted_args[i]
      };
      GCCHECK(rooted_args[i]);
    }
  if (nargs != 0)
    gcpro = &argument_roots[nargs - 1];

  struct vector *argv = alloc_vector(nargs);
  struct gcpro argv_root;
  GCPROV(argv_root, argv);
  for (size_t i = 0; i < nargs; ++i)
    argv->data[i] = rooted_args[i];
  value result = callv(function, argv);
  gcpro = old_gcpro;
  return result;
}

/* Entry point used by generated LLVM code for calls through Mudlle values.
   The generator roots the incoming argument slots for the entire call. */
value llvm_call_value(value caller, value function, value *arguments,
                      size_t nargs, int64_t secure_call)
{
  if (nargs > MAX_FUNCTION_ARGS)
    runtime_error(error_wrong_parameters);
  seclev_t caller_seclevel = llvm_caller_seclevel(caller);
  seclev_t old_seclevel = internal_seclevel;
  bool old_seclevel_valid = seclevel_valid;
  set_seclevel(caller_seclevel);
  /* An exact arity match is the first test closure_callable() makes. */
  if (!(TYPE(function, closure)
        && vector_len(((struct closure *)function)->code->arguments)
             == (size_t)nargs))
    {
      if (secure_call)
        llvm_check_callable(function, (long)nargs, caller_seclevel);
      else
        callable(function, (long)nargs);
    }
  void *cbdata = NULL;
  value result;
  if (TYPE(function, primitive) || TYPE(function, secure))
    /* The generated frame already roots the arguments, and a fixed-arity
       primitive receives them by value: no argument vector is needed. */
    result = llvm_call_primitive((struct primitive *)function, arguments,
                                 nargs);
  else if (TYPE(function, closure)
      && mcallback_varargs_matches(function, llvm_call_closure, &cbdata))
    result = llvm_invoke_closure(cbdata, function, arguments, nargs);
  else
    result = llvm_call_fallback(function, arguments, nargs);
  set_seclevel(old_seclevel);
  seclevel_valid = old_seclevel_valid;
  return result;
}

/* Call through a constant global without a generated root frame. Primitives
   take their arguments by value and protect them themselves; every other
   callee gets the arguments rooted in a C frame before it can collect. */
value llvm_call_global_constant(int64_t offset, value caller, value *arguments,
                                int64_t nargs)
{
  if (offset < 0 || (ulong)offset >= vector_len(global_names)
      || nargs < 0 || nargs > MAX_FUNCTION_ARGS
      || (nargs != 0 && arguments == NULL))
    {
      runtime_error(error_bad_value);
      return NULL;
    }
  seclev_t caller_seclevel = llvm_caller_seclevel(caller);
  value function = GVAR((ulong)offset);
  seclev_t old_seclevel = internal_seclevel;
  bool old_seclevel_valid = seclevel_valid;
  set_seclevel(caller_seclevel);
  value result;
  /* A plain primitive called with its exact arity needs no further check
     (that is all function_callable() tests for one); it type-checks its own
     parameters. */
  if (TYPE(function, primitive)
      && ((struct primitive *)function)->op->nargs == (unsigned)nargs)
    result = llvm_call_primitive((struct primitive *)function, arguments,
                                 (size_t)nargs);
  else if (llvm_check_callable(function, (long)nargs, caller_seclevel),
           TYPE(function, primitive) || TYPE(function, secure))
    {
      for (int64_t i = 0; i < nargs; ++i)
        GCCHECK(arguments[i]);
      result = llvm_call_primitive((struct primitive *)function, arguments,
                                   (size_t)nargs);
    }
  else
    {
      value rooted_args[nargs ? (size_t)nargs : 1];
      value *slots[nargs ? (size_t)nargs : 1];
      struct gcpro roots[nargs ? (size_t)nargs : 1];
      for (int64_t i = 0; i < nargs; ++i)
        {
          rooted_args[i] = arguments[i];
          slots[i] = &rooted_args[i];
        }
      struct gcpro *old_gcpro = llvm_gc_roots_enter(slots, nargs, roots);
      void *cbdata = NULL;
      if (TYPE(function, closure)
          && mcallback_varargs_matches(function, llvm_call_closure, &cbdata))
        result = llvm_invoke_closure(cbdata, function, rooted_args,
                                     (size_t)nargs);
      else
        result = llvm_call_fallback(function, rooted_args, (size_t)nargs);
      llvm_gc_roots_leave(old_gcpro);
    }
  set_seclevel(old_seclevel);
  seclevel_valid = old_seclevel_valid;
  return result;
}

enum llvm_compare_kind { compare_none, compare_lt, compare_le, compare_gt,
                         compare_ge };

int64_t llvm_call_global(int64_t raw_caller, int64_t raw_name,
                         value *arguments, int64_t nargs)
{
  seclev_t caller_seclevel = llvm_caller_seclevel(
    (value)(uintptr_t)raw_caller);
  value name = (value)(uintptr_t)raw_name;
  if (!TYPE(name, string) || nargs < 0 || nargs > MAX_FUNCTION_ARGS
      || (nargs != 0 && arguments == NULL))
    { runtime_error(error_bad_value); return (int64_t)(uintptr_t)NULL; }

  bool has_float = false, has_bigint = false;
  for (int64_t i = 0; i < nargs; ++i)
    {
      GCCHECK(arguments[i]);
      has_float |= TYPE(arguments[i], float);
      has_bigint |= TYPE(arguments[i], bigint);
    }

  seclev_t old_seclevel = internal_seclevel;
  bool old_seclevel_valid = seclevel_valid;
  set_seclevel(caller_seclevel);
  const char *name_text = ((struct string *)(uintptr_t)name)->str;
  enum llvm_compare_kind compare = compare_none;
  const char *resolved_name = name_text;
  if (strcmp(name_text, ".") == 0) resolved_name = "cons";
  else if (strcmp(name_text, "set") == 0) resolved_name = "set!";
  else if (strcmp(name_text, "i+") == 0) resolved_name = "iadd";
  if (has_float)
    {
      if (strcmp(name_text, "+") == 0) resolved_name = "fadd";
      else if (strcmp(name_text, "-") == 0) resolved_name = nargs == 1 ? "fneg" : "fsub";
      else if (strcmp(name_text, "negate") == 0) resolved_name = "fneg";
      else if (strcmp(name_text, "*") == 0) resolved_name = "fmul";
      else if (strcmp(name_text, "/") == 0) resolved_name = "fdiv";
      else if (strcmp(name_text, "%") == 0) resolved_name = "fmod";
      else if (strcmp(name_text, "<") == 0) { resolved_name = "fcmp"; compare = compare_lt; }
      else if (strcmp(name_text, "<=") == 0) { resolved_name = "fcmp"; compare = compare_le; }
      else if (strcmp(name_text, ">") == 0) { resolved_name = "fcmp"; compare = compare_gt; }
      else if (strcmp(name_text, ">=") == 0) { resolved_name = "fcmp"; compare = compare_ge; }
    }
  else if (has_bigint)
    {
      if (strcmp(name_text, "+") == 0) resolved_name = "biadd";
      else if (strcmp(name_text, "-") == 0) resolved_name = nargs == 1 ? "bineg" : "bisub";
      else if (strcmp(name_text, "negate") == 0) resolved_name = "bineg";
      else if (strcmp(name_text, "*") == 0) resolved_name = "bimul";
      else if (strcmp(name_text, "/") == 0) resolved_name = "bitdiv_q";
      else if (strcmp(name_text, "%") == 0) resolved_name = "bitdiv_r";
      else if (strcmp(name_text, "<") == 0) { resolved_name = "bicmp"; compare = compare_lt; }
      else if (strcmp(name_text, "<=") == 0) { resolved_name = "bicmp"; compare = compare_le; }
      else if (strcmp(name_text, ">") == 0) { resolved_name = "bicmp"; compare = compare_gt; }
      else if (strcmp(name_text, ">=") == 0) { resolved_name = "bicmp"; compare = compare_ge; }
    }


  value function = GVAR(global_lookup(resolved_name));
  llvm_check_callable(function, (long)nargs, caller_seclevel);
  value result;
  if (TYPE(function, primitive) || TYPE(function, secure))
    /* Nothing here allocates, so name and arguments need no roots. Primitives
       protect their own parameters. */
    result = llvm_call_primitive((struct primitive *)function, arguments,
                                 (size_t)nargs);
  else
    {
      struct gcpro *old_gcpro = gcpro;
      struct gcpro function_root;
      GCPROV(function_root, function);
      value rooted_args[nargs ? (size_t)nargs : 1];
      struct gcpro argument_roots[nargs ? (size_t)nargs : 1];
      for (int64_t i = 0; i < nargs; ++i)
        {
          rooted_args[i] = arguments[i];
          argument_roots[i] = (struct gcpro){
            .next = i == 0 ? &function_root : &argument_roots[i - 1],
            .obj = &rooted_args[i]
          };
        }
      if (nargs != 0) gcpro = &argument_roots[nargs - 1];
      struct vector *argv = alloc_vector((size_t)nargs);
      struct gcpro argv_root;
      GCPROV(argv_root, argv);
      for (int64_t i = 0; i < nargs; ++i) argv->data[i] = rooted_args[i];
      result = callv(function, argv);
      gcpro = old_gcpro;
    }
  set_seclevel(old_seclevel);
  seclevel_valid = old_seclevel_valid;
  if (compare != compare_none)
    {
      long relation = intval(result);
      switch (compare)
        {
        case compare_lt: result = makebool(relation < 0); break;
        case compare_le: result = makebool(relation <= 0); break;
        case compare_gt: result = makebool(relation > 0); break;
        default: result = makebool(relation >= 0); break;
        }
    }
  return (int64_t)(uintptr_t)result;
}

STATIC_STRING(llvm_ir_closure_help,
              "Calls an LLVM native function as a Mudlle closure.");

#define LLVM_ICODE_CACHE_SIZE 256
static struct vector *llvm_icode_cache;

/* Create a generated function closure with its lexical environment. */
value llvm_make_function_closure(int64_t address, int64_t nargs,
                                 value *captures, int64_t ncaptures,
                                 int64_t self_capture, int64_t parent_env,
                                 int64_t raw_arguments,
                                 int64_t return_typeset)
{
  if (address == 0 || nargs < 0 || nargs > MAX_FUNCTION_ARGS
      || ncaptures < 0 || ncaptures > MAX_FUNCTION_ARGS
      || self_capture < -1 || self_capture >= ncaptures)
    {
      runtime_error(error_bad_value);
      return NULL;
    }

  struct closure *parent = (struct closure *)(uintptr_t)parent_env;
  if (!TYPE(parent, closure))
    {
      runtime_error(error_bad_value);
      return NULL;
    }
  seclev_t parent_seclevel = parent->code->seclevel;
  size_t parent_nvars = (parent->o.size - offsetof(struct closure, variables))
    / sizeof parent->variables[0];
  if (parent_nvars < 2)
    {
      runtime_error(error_bad_value);
      return NULL;
    }
  value constants = parent->variables[1]->vvalue;
  if (!TYPE(constants, vector))
    {
      runtime_error(error_bad_value);
      return NULL;
    }
  value arguments_metadata = (value)(uintptr_t)raw_arguments;
  if (!TYPE(arguments_metadata, vector))
    {
      runtime_error(error_bad_type);
      return NULL;
    }

  struct gcpro *old_gcpro = gcpro;
  value rooted_captures[ncaptures ? ncaptures : 1];
  struct gcpro roots[ncaptures ? ncaptures : 1];
  for (int64_t i = 0; i < ncaptures; ++i)
    {
      rooted_captures[i] = captures[i];
      roots[i] = (struct gcpro){
        .next = i == 0 ? old_gcpro : &roots[i - 1],
        .obj = &rooted_captures[i]
      };
      GCCHECK(rooted_captures[i]);
    }
  if (ncaptures != 0)
    gcpro = &roots[ncaptures - 1];
  struct gcpro constants_root;
  GCPROV(constants_root, constants);
  struct gcpro arguments_root;
  GCPROV(arguments_root, arguments_metadata);

  struct vector *env = alloc_vector((size_t)ncaptures + 1);
  struct gcpro env_root;
  GCPROV(env_root, env);
  env->data[0] = constants;
  for (int64_t i = 0; i < ncaptures; ++i)
    env->data[i + 1] = rooted_captures[i];
  struct llvm_callback_data *data = malloc(sizeof *data);
  if (data == NULL)
    {
      gcpro = old_gcpro;
      runtime_error(error_bad_value);
      return NULL;
    }
  data->entry = (llvm_native_entry)(uintptr_t)address;
  data->nargs = (size_t)nargs;
  data->check_arity = false;
  data->stable = ncaptures == 0;
  /* The wrapper code depends only on the argument metadata, return typeset
     and security level; reuse it instead of regenerating it per closure. */
  if (llvm_icode_cache == NULL)
    {
      llvm_icode_cache = alloc_vector(LLVM_ICODE_CACHE_SIZE);
      staticpro(&llvm_icode_cache);
    }
  size_t slot = ((uintptr_t)arguments_metadata >> 4) % LLVM_ICODE_CACHE_SIZE;
  struct icode *icode = (struct icode *)llvm_icode_cache->data[slot];
  if (icode != NULL
      && (icode->code.arguments != (struct vector *)arguments_metadata
          || icode->code.return_typeset != (typeset_t)return_typeset
          || icode->code.seclevel != parent_seclevel))
    icode = NULL;
  struct closure *closure = make_mcallback_varargs_captured_sec_cached(
    llvm_call_closure, llvm_free_callback, data, env,
    "llvm_function_closure", GET_STATIC_STRING(llvm_ir_closure_help),
    __FILE__, __LINE__, parent_seclevel, &icode,
    (struct vector *)arguments_metadata, (typeset_t)return_typeset);
  slot = ((uintptr_t)arguments_metadata >> 4) % LLVM_ICODE_CACHE_SIZE;
  llvm_icode_cache->data[slot] = (value)icode;
  struct gcpro closure_root;
  GCPROV(closure_root, closure);
  if (self_capture >= 0)
    closure->variables[self_capture + 2]->vvalue = (value)closure;
  /* A closure with no native captures has no user-mutable lexical state. */
  if (ncaptures == 0)
    closure->o.flags |= OBJ_READONLY;
  gcpro = old_gcpro;
  return closure;
}

/* A capture-free closure that is only called at once has no observable
   identity, so one per (code address, enclosing constants) is shared. */
#define LLVM_CALL_CLOSURE_CACHE_SIZE 64
_Static_assert(LLVM_CALL_CLOSURE_CACHE_SIZE == 64,
               "mudlle_closure_for_call in genllvm.mud masks with 63");
struct vector *llvm_call_closure_cache;

value llvm_make_function_closure_for_call(
  int64_t address, int64_t nargs, value *captures, int64_t ncaptures,
  int64_t self_capture, int64_t parent_env, int64_t raw_arguments,
  int64_t return_typeset)
{
  if (llvm_call_closure_cache == NULL)
    {
      /* may collect: do it before reading any heap pointer */
      llvm_call_closure_cache
        = alloc_vector(3 * LLVM_CALL_CLOSURE_CACHE_SIZE);
      staticpro(&llvm_call_closure_cache);
    }
  struct closure *parent = (struct closure *)(uintptr_t)parent_env;
  value constants = NULL;
  if (ncaptures == 0 && TYPE(parent, closure)
      && (parent->o.size - offsetof(struct closure, variables))
           / sizeof parent->variables[0] >= 2
      && TYPE(parent->variables[1], variable))
    constants = parent->variables[1]->vvalue;
  if (constants == NULL || !TYPE(constants, vector))
    return llvm_make_function_closure(address, nargs, captures, ncaptures,
                                      self_capture, parent_env,
                                      raw_arguments, return_typeset);
  size_t slot = (((uintptr_t)address >> 4) ^ ((uintptr_t)constants >> 4))
    & (LLVM_CALL_CLOSURE_CACHE_SIZE - 1);
  value *entry = &llvm_call_closure_cache->data[3 * slot];
  if (entry[0] == makeint(address) && entry[1] == constants && entry[2] != NULL)
    return entry[2];

  struct gcpro constants_root;
  GCPROV(constants_root, constants);
  value closure = llvm_make_function_closure(
    address, nargs, captures, ncaptures, self_capture, parent_env,
    raw_arguments, return_typeset);
  struct gcpro closure_root;
  GCPROV(closure_root, closure);
  slot = (((uintptr_t)address >> 4) ^ ((uintptr_t)constants >> 4))
    & (LLVM_CALL_CLOSURE_CACHE_SIZE - 1);
  entry = &llvm_call_closure_cache->data[3 * slot];
  entry[0] = makeint(address);
  entry[1] = constants;
  entry[2] = closure;
  UNGCPROV(closure_root);
  UNGCPROV(constants_root);
  return closure;
}

value llvm_constant_get(int64_t menv, int64_t index)
{
  struct closure *closure = (struct closure *)(uintptr_t)menv;
  if (!TYPE(closure, closure) || index < 0)
    {
      runtime_error(error_bad_value);
      return NULL;
    }
  size_t nvars = (closure->o.size - offsetof(struct closure, variables))
    / sizeof closure->variables[0];
  if (nvars < 2)
    {
      runtime_error(error_bad_value);
      return NULL;
    }
  value constants = closure->variables[1]->vvalue;
  if (!TYPE(constants, vector) || (size_t)index >= vector_len((struct vector *)constants))
    {
      runtime_error(error_bad_value);
      return NULL;
    }
  return ((struct vector *)constants)->data[index];
}

value llvm_closure_capture_get(int64_t menv, int64_t index)
{
  struct closure *closure = (struct closure *)(uintptr_t)menv;
  assert(TYPE(closure, closure));
  size_t nvars = (closure->o.size - offsetof(struct closure, variables))
    / sizeof closure->variables[0];
  assert(index >= 0 && (size_t)index + 2 < nvars);
  return closure->variables[index + 2]->vvalue;
}

void llvm_closure_capture_set(int64_t menv, int64_t index, int64_t new_value)
{
  struct closure *closure = (struct closure *)(uintptr_t)menv;
  assert(TYPE(closure, closure));
  size_t nvars = (closure->o.size - offsetof(struct closure, variables))
    / sizeof closure->variables[0];
  assert(index >= 0 && (size_t)index + 2 < nvars);
  closure->variables[index + 2]->vvalue = (value)(uintptr_t)new_value;
}

int64_t llvm_variable_new(int64_t raw_value)
{
  struct variable *variable = alloc_variable((value)(uintptr_t)raw_value);
  return (int64_t)(uintptr_t)variable;
}

int64_t llvm_variable_get(int64_t raw_variable)
{
  value v = (value)(uintptr_t)raw_variable;
  if (!TYPE(v, variable))
    runtime_error(error_bad_type);
  return (int64_t)(uintptr_t)((struct variable *)v)->vvalue;
}

void llvm_variable_set(int64_t raw_variable, int64_t raw_value)
{
  value v = (value)(uintptr_t)raw_variable;
  if (!TYPE(v, variable))
    runtime_error(error_bad_type);
  ((struct variable *)v)->vvalue = (value)(uintptr_t)raw_value;
}

UNSAFEOP(llvm_load_ir_closure, "llvm_load_ir_closure",
         "`s `s `n `n `v `v -> `f. Compile LLVM IR, relocate globals, and wrap its entry point.",
         (struct string *ir, struct string *symbol, value mnargs,
          value mseclev, struct vector *runtime_data), OP_TRACE, "ssnnv.f")
{
  long nargs, seclev;
  CHECK_TYPES(ir, string,
              symbol, string,
              mnargs, CT_RANGE(nargs, 0, MAX_FUNCTION_ARGS),
              mseclev, CT_RANGE(seclev, 0, MAX_SECLEVEL),
              runtime_data, vector);
  if (vector_len(runtime_data) != 2
      || !TYPE(runtime_data->data[0], vector)
      || !TYPE(runtime_data->data[1], vector))
    RUNTIME_ERROR(error_bad_value, "invalid LLVM closure data");
  struct vector *mconstants = (struct vector *)runtime_data->data[0];
  struct vector *global_relocations = (struct vector *)runtime_data->data[1];
  GCPRO(ir, symbol, mconstants, global_relocations);

  struct string *relocated_ir;
  if (vector_len(global_relocations) == 0)
    relocated_ir = ir;
  else
    {
      struct llvm_global_relocation {
        long old_offset;
        long new_offset;
      } *relocations;
      size_t nrelocations = vector_len(global_relocations);
      relocations = malloc(nrelocations * sizeof *relocations);
      if (relocations == NULL)
        RUNTIME_ERROR(error_bad_value, "out of memory");
      for (size_t i = 0; i < nrelocations; ++i)
        {
          value entry = global_relocations->data[i];
          if (!TYPE(entry, vector) || vector_len((struct vector *)entry) != 2
              || !integerp(((struct vector *)entry)->data[0])
              || !TYPE(((struct vector *)entry)->data[1], string))
            {
              free(relocations);
              RUNTIME_ERROR(error_bad_value, "invalid LLVM global relocation");
            }
          struct vector *relocation = (struct vector *)entry;
          relocations[i].old_offset = intval(relocation->data[0]);
          value name = relocation->data[1];
          struct gcpro name_root;
          GCPROV(name_root, name);
          relocations[i].new_offset = mglobal_lookup(name);
          UNGCPROV(name_root);
        }

      static const char *patterns[] = {
        "@llvm_global_read(i64 ",
        "@llvm_check_global_read(i64 ",
        "@llvm_global_write(i64 ",
        "@llvm_check_global_write(i64 ",
        "@llvm_call_global_constant(i64 "
      };
      struct strbuf output;
      sb_init(&output);
      const char *cursor = ir->str;
      while (*cursor != '\0')
        {
          const char *match = NULL;
          size_t pattern_length = 0;
          for (size_t i = 0; i < sizeof patterns / sizeof patterns[0]; ++i)
            {
              const char *candidate = strstr(cursor, patterns[i]);
              if (candidate != NULL && (match == NULL || candidate < match))
                {
                  match = candidate;
                  pattern_length = strlen(patterns[i]);
                }
            }
          if (match == NULL)
            {
              sb_addstr(&output, cursor);
              break;
            }
          const char *digits = match + pattern_length;
          char *end;
          long long old_offset = strtoll(digits, &end, 10);
          if (end == digits)
            {
              sb_addmem(&output, cursor, (size_t)(digits - cursor));
              cursor = digits;
              continue;
            }
          sb_addmem(&output, cursor, (size_t)(digits - cursor));
          bool found = false;
          for (size_t i = 0; i < nrelocations; ++i)
            if (relocations[i].old_offset == old_offset)
              {
                sb_addint(&output, relocations[i].new_offset);
                found = true;
                break;
              }
          if (!found)
            sb_addmem(&output, digits, (size_t)(end - digits));
          cursor = end;
        }
      free(relocations);
      relocated_ir = alloc_string(sb_str(&output));
      sb_free(&output);
      struct gcpro relocated_ir_root;
      GCPROV(relocated_ir_root, relocated_ir);
      void *address = llvm_orc_compile_ir(relocated_ir, symbol);
      struct llvm_callback_data *data = malloc(sizeof *data);
      if (data == NULL)
        RUNTIME_ERROR(error_bad_value, "out of memory");
      data->entry = (llvm_native_entry)(uintptr_t)address;
      data->nargs = (size_t)nargs;
      data->check_arity = true;
      data->stable = false;
      struct vector *captures = alloc_vector(1);
      struct gcpro captures_root;
      GCPROV(captures_root, captures);
      captures->data[0] = mconstants;
      struct closure *closure = make_mcallback_varargs_captured_sec(
        llvm_call_closure, llvm_free_callback, data, captures,
        "llvm_load_ir_closure", GET_STATIC_STRING(llvm_ir_closure_help),
        __FILE__, __LINE__, (seclev_t)seclev);
      UNGCPRO();
      return closure;
    }

  void *address = llvm_orc_compile_ir(relocated_ir, symbol);

  struct llvm_callback_data *data = malloc(sizeof *data);
  if (data == NULL)
    RUNTIME_ERROR(error_bad_value, "out of memory");
  data->entry = (llvm_native_entry)(uintptr_t)address;
  data->nargs = (size_t)nargs;
  data->check_arity = true;
  data->stable = false;
  struct vector *captures = alloc_vector(1);
  struct gcpro captures_root;
  GCPROV(captures_root, captures);
  captures->data[0] = mconstants;
  struct closure *closure = make_mcallback_varargs_captured_sec(
    llvm_call_closure, llvm_free_callback, data, captures,
    "llvm_load_ir_closure", GET_STATIC_STRING(llvm_ir_closure_help),
    __FILE__, __LINE__, (seclev_t)seclev);
  UNGCPRO();
  return closure;
}

/* genllvm reads the type byte at offset 9 before vector indexing. Supported
   64-bit little-endian hosts share this layout, including GCDEBUG headers. */
_Static_assert(sizeof(value) == 8 && offsetof(struct obj, flags) == 10,
               "LLVM vector guards require the 64-bit Mudlle object header");

void llvm_init(void)
{
  const struct obj vector_header = { .type = type_vector };
  if (((const unsigned char *)&vector_header)[9] != type_vector)
    {
      fprintf(stderr, "Unsupported LLVM object type-byte layout\n");
      runtime_error(error_bad_value);
    }
  DEFINE(llvm_load_ir_closure);
}
