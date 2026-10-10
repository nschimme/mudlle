/* Runtime support for the LLVM native backend. */
#include "../mudlle-config.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

static const char *llvm_optimization_pipeline(void)
{
  const char *level = getenv("MUDLLE_LLVM_OPT");
  static char pipeline[32];
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
      fprintf(stderr, "MUDLLE_LLVM_OPT must be none, O0, O1, O2, or O3\n");
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
  LLVMOrcDefinitionGeneratorRef generator;
  llvm_orc_check_error(LLVMOrcCreateDynamicLibrarySearchGeneratorForProcess(
    &generator, LLVMOrcLLJITGetGlobalPrefix(llvm_orc_jit), NULL, NULL));
  LLVMOrcJITDylibAddGenerator(
    LLVMOrcLLJITGetMainJITDylib(llvm_orc_jit), generator);
}

static void *llvm_orc_compile_ir(struct string *ir, struct string *symbol)
{
  char *parse_message = NULL;
  char *unique_symbol;
  LLVMOrcThreadSafeContextRef safe_context;
  LLVMContextRef context;
  LLVMMemoryBufferRef buffer;
  LLVMModuleRef module;
  LLVMOrcThreadSafeModuleRef safe_module;
  LLVMOrcExecutorAddress address;
  size_t sequence;

  llvm_orc_initialize();
  sequence = llvm_orc_module_sequence++;
  safe_context = LLVMOrcCreateNewThreadSafeContext();
  context = LLVMOrcThreadSafeContextGetContext(safe_context);
  buffer = LLVMCreateMemoryBufferWithMemoryRangeCopy(
    ir->str, string_len(ir), "mudlle-module");
  if (LLVMParseIRInContext(context, buffer, &module, &parse_message))
    {
      if (parse_message != NULL)
        fprintf(stderr, "LLVM IR parse error: %s\n", parse_message);
      if (parse_message != NULL)
        LLVMDisposeMessage(parse_message);
      LLVMOrcDisposeThreadSafeContext(safe_context);
      runtime_error(error_bad_value);
    }
  if (parse_message != NULL)
    LLVMDisposeMessage(parse_message);

  const char *pipeline = llvm_optimization_pipeline();
  if (pipeline != NULL)
    {
      LLVMPassBuilderOptionsRef options = LLVMCreatePassBuilderOptions();
      LLVMSetTarget(module, LLVMOrcLLJITGetTripleString(llvm_orc_jit));
      LLVMSetDataLayout(module, LLVMOrcLLJITGetDataLayoutStr(llvm_orc_jit));
      LLVMPassBuilderOptionsSetVerifyEach(options, 1);
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
          llvm_orc_check_error(error);
        }
    }

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

  int symbol_length = snprintf(NULL, 0, "mudlle_module_%zu_%s",
                               sequence, symbol->str);
  if (symbol_length < 0)
    {
      LLVMDisposeModule(module);
      LLVMOrcDisposeThreadSafeContext(safe_context);
      runtime_error(error_bad_value);
    }
  unique_symbol = malloc((size_t)symbol_length + 1);
  if (unique_symbol == NULL)
    {
      LLVMDisposeModule(module);
      LLVMOrcDisposeThreadSafeContext(safe_context);
      runtime_error(error_bad_value);
    }
  snprintf(unique_symbol, (size_t)symbol_length + 1,
           "mudlle_module_%zu_%s", sequence, symbol->str);

  safe_module = LLVMOrcCreateNewThreadSafeModule(module, safe_context);
  LLVMOrcDisposeThreadSafeContext(safe_context);
  llvm_orc_check_error(LLVMOrcLLJITAddLLVMIRModule(
    llvm_orc_jit, LLVMOrcLLJITGetMainJITDylib(llvm_orc_jit), safe_module));
  llvm_orc_check_error(LLVMOrcLLJITLookup(llvm_orc_jit, &address,
                                          unique_symbol));
  free(unique_symbol);
  return (void *)(uintptr_t)address;
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

value llvm_build_vector(value *arguments, int64_t nargs, int64_t readonly,
                       int64_t immutable);

value llvm_build_vector(value *arguments, int64_t nargs, int64_t readonly,
                       int64_t immutable)
{
  if (nargs < 0 || nargs > MAX_FUNCTION_ARGS)
    runtime_error(error_bad_value);

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

  value result = (value)alloc_vector((size_t)nargs);
  struct gcpro result_root;
  GCPROV(result_root, result);
  struct vector *vector = result;
  for (int64_t i = 0; i < nargs; ++i)
    vector->data[i] = rooted[i];
  if (readonly)
    {
      result = make_readonly(result);
      if (immutable)
        ((struct obj *)result)->flags |= OBJ_IMMUTABLE;
    }
  gcpro = old_gcpro;
  return result;
}

value llvm_concat_strings(value *arguments, int64_t nargs);

value llvm_concat_strings(value *arguments, int64_t nargs)
{
  if (nargs < 0)
    runtime_error(error_bad_value);
  return concat_strings((long)nargs, (struct string **)arguments);
}

TYPEDOP(llvm_load_function, "llvm_load_function",
        "`s `s -> `n. Load a native LLVM shared library and return the address"
        " of the named function. For the LLVM runtime bridge.",
        (struct string *library, struct string *symbol),
        OP_LEAF | OP_NOESCAPE | OP_STR_READONLY, "ss.n")
{
  CHECK_TYPES(library, string,
              symbol, string);
  llvm_orc_initialize();
  LLVMOrcDefinitionGeneratorRef generator;
  llvm_orc_check_error(LLVMOrcCreateDynamicLibrarySearchGeneratorForPath(
    &generator, library->str, LLVMOrcLLJITGetGlobalPrefix(llvm_orc_jit),
    NULL, NULL));
  LLVMOrcJITDylibAddGenerator(
    LLVMOrcLLJITGetMainJITDylib(llvm_orc_jit), generator);

  LLVMOrcExecutorAddress function;
  llvm_orc_check_error(LLVMOrcLLJITLookup(
    llvm_orc_jit, &function, symbol->str));
  return makeint((intptr_t)(uintptr_t)function);
}

typedef int64_t (*llvm_native_fn0)(int64_t);
typedef int64_t (*llvm_native_fn1)(int64_t, int64_t);
typedef int64_t (*llvm_native_fn2)(int64_t, int64_t, int64_t);
typedef int64_t (*llvm_native_fn3)(int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*llvm_native_fn4)(int64_t, int64_t, int64_t, int64_t,
                                   int64_t);
typedef int64_t (*llvm_native_fn5)(int64_t, int64_t, int64_t, int64_t,
                                   int64_t, int64_t);
typedef int64_t (*llvm_native_fn6)(int64_t, int64_t, int64_t, int64_t,
                                   int64_t, int64_t, int64_t);

VAROP(llvm_call_function, "llvm_call_function",
      "`n `n `x... -> `x. Call an LLVM C ABI function with an environment"
      " value followed by its Mudlle arguments. Supports up to six arguments.",
      (value mfunction, value menv, struct vector *arguments),
      OP_TRACE, "nnx*.")
{
  long function_address, env_value;
  CHECK_TYPES(mfunction, CT_INT(function_address),
              menv, CT_INT(env_value),
              arguments, CT_ARGV(0, 6));
  if (function_address == 0)
    RUNTIME_ERROR(error_bad_value, "null LLVM function address");

  int64_t fnargs[6];
  size_t nargs = vector_len(arguments);
  for (size_t i = 0; i < nargs; ++i)
    fnargs[i] = (int64_t)(uintptr_t)arguments->data[i];
  int64_t env = env_value;
  int64_t result;
  switch (nargs)
    {
    case 0: result = ((llvm_native_fn0)(uintptr_t)function_address)(env); break;
    case 1: result = ((llvm_native_fn1)(uintptr_t)function_address)(env, fnargs[0]); break;
    case 2: result = ((llvm_native_fn2)(uintptr_t)function_address)(env, fnargs[0], fnargs[1]); break;
    case 3: result = ((llvm_native_fn3)(uintptr_t)function_address)(env, fnargs[0], fnargs[1], fnargs[2]); break;
    case 4: result = ((llvm_native_fn4)(uintptr_t)function_address)(env, fnargs[0], fnargs[1], fnargs[2], fnargs[3]); break;
    case 5: result = ((llvm_native_fn5)(uintptr_t)function_address)(env, fnargs[0], fnargs[1], fnargs[2], fnargs[3], fnargs[4]); break;
    case 6: result = ((llvm_native_fn6)(uintptr_t)function_address)(env, fnargs[0], fnargs[1], fnargs[2], fnargs[3], fnargs[4], fnargs[5]); break;
    default: abort();
    }
  return (value)(uintptr_t)result;
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
  int64_t result = data->entry((int64_t)(uintptr_t)closure, arguments->data,
                               (int64_t)vector_len(arguments));
  UNGCPRO();
  return (value)(uintptr_t)result;
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

/* Entry point used by generated LLVM code for calls through Mudlle values. */
value llvm_call_value(value caller, value function, value *arguments,
                      size_t nargs, int64_t secure_call)
{
  if (nargs > MAX_FUNCTION_ARGS)
    {
      runtime_error(error_wrong_parameters);
      return NULL;
    }

  seclev_t caller_seclevel = llvm_caller_seclevel(caller);
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

  seclev_t old_seclevel = internal_seclevel;
  bool old_seclevel_valid = seclevel_valid;
  set_seclevel(caller_seclevel);
  struct vector *argv = alloc_vector(nargs);
  struct gcpro argv_root;
  GCPROV(argv_root, argv);
  for (size_t i = 0; i < nargs; ++i)
    argv->data[i] = rooted_args[i];
  if (secure_call)
    llvm_check_callable(function, (long)nargs, caller_seclevel);
  else
    callable(function, (long)nargs);
  value result = callv(function, argv);
  set_seclevel(old_seclevel);
  seclevel_valid = old_seclevel_valid;
  gcpro = old_gcpro;
  return result;
}

int64_t llvm_call_global(int64_t raw_caller, int64_t raw_name,
                         value *arguments, int64_t nargs)
{
  seclev_t caller_seclevel = llvm_caller_seclevel(
    (value)(uintptr_t)raw_caller);
  value name = (value)(uintptr_t)raw_name;
  if (!TYPE(name, string) || nargs < 0 || nargs > MAX_FUNCTION_ARGS
      || (nargs != 0 && arguments == NULL))
    { runtime_error(error_bad_value); return (int64_t)(uintptr_t)NULL; }

  struct gcpro *old_gcpro = gcpro;
  struct gcpro name_root;
  GCPROV(name_root, name);
  value rooted_args[nargs ? (size_t)nargs : 1];
  struct gcpro argument_roots[nargs ? (size_t)nargs : 1];
  bool has_float = false, has_bigint = false;
  for (int64_t i = 0; i < nargs; ++i)
    {
      rooted_args[i] = arguments[i];
      argument_roots[i] = (struct gcpro){
        .next = i == 0 ? &name_root : &argument_roots[i - 1],
        .obj = &rooted_args[i]
      };
      GCCHECK(rooted_args[i]);
      has_float |= TYPE(rooted_args[i], float);
      has_bigint |= TYPE(rooted_args[i], bigint);
    }
  if (nargs != 0) gcpro = &argument_roots[nargs - 1];

  seclev_t old_seclevel = internal_seclevel;
  bool old_seclevel_valid = seclevel_valid;
  set_seclevel(caller_seclevel);
  const char *name_text = ((struct string *)(uintptr_t)name)->str;
  const char *resolved_name = name_text;
  bool compare = false;
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
      else if (strcmp(name_text, "<") == 0 || strcmp(name_text, "<=") == 0
               || strcmp(name_text, ">") == 0 || strcmp(name_text, ">=") == 0)
        { resolved_name = "fcmp"; compare = true; }
    }
  else if (has_bigint)
    {
      if (strcmp(name_text, "+") == 0) resolved_name = "biadd";
      else if (strcmp(name_text, "-") == 0) resolved_name = nargs == 1 ? "bineg" : "bisub";
      else if (strcmp(name_text, "negate") == 0) resolved_name = "bineg";
      else if (strcmp(name_text, "*") == 0) resolved_name = "bimul";
      else if (strcmp(name_text, "/") == 0) resolved_name = "bitdiv_q";
      else if (strcmp(name_text, "%") == 0) resolved_name = "bitdiv_r";
      else if (strcmp(name_text, "<") == 0 || strcmp(name_text, "<=") == 0
               || strcmp(name_text, ">") == 0 || strcmp(name_text, ">=") == 0)
        { resolved_name = "bicmp"; compare = true; }
    }

  value function = GVAR(global_lookup(resolved_name));
  struct gcpro function_root;
  GCPROV(function_root, function);
  struct vector *argv = alloc_vector((size_t)nargs);
  struct gcpro argv_root;
  GCPROV(argv_root, argv);
  for (int64_t i = 0; i < nargs; ++i) argv->data[i] = rooted_args[i];
  llvm_check_callable(function, (long)nargs, caller_seclevel);
  value result = callv(function, argv);
  set_seclevel(old_seclevel);
  seclevel_valid = old_seclevel_valid;
  if (compare)
    {
      long relation = intval(result);
      if (strcmp(name_text, "<") == 0) result = makebool(relation < 0);
      else if (strcmp(name_text, "<=") == 0) result = makebool(relation <= 0);
      else if (strcmp(name_text, ">") == 0) result = makebool(relation > 0);
      else result = makebool(relation >= 0);
    }
  gcpro = old_gcpro;
  return (int64_t)(uintptr_t)result;
}

STATIC_STRING(llvm_function_closure_help,
              "Calls an LLVM native function as a Mudlle closure.");

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
  struct closure *closure = make_mcallback_varargs_captured_sec(
    llvm_call_closure, llvm_free_callback, data, env,
    "llvm_function_closure", GET_STATIC_STRING(llvm_function_closure_help),
    __FILE__, __LINE__, parent_seclevel);
  closure->code->arguments = (struct vector *)arguments_metadata;
  closure->code->return_typeset = (typeset_t)return_typeset;
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

TYPEDOP(llvm_load_ir_closure, "llvm_load_ir_closure",
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
        "@llvm_check_global_write(i64 "
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
        "llvm_load_ir_closure", GET_STATIC_STRING(llvm_function_closure_help),
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
    "llvm_load_ir_closure", GET_STATIC_STRING(llvm_function_closure_help),
    __FILE__, __LINE__, (seclev_t)seclev);
  UNGCPRO();
  return closure;
}

TYPEDOP(llvm_function_closure, "llvm_function_closure",
        "`n `n -> `f. Wrap an LLVM entry point and its arity as a Mudlle closure.",
        (value mfunction, value mnargs), OP_TRACE, "nn.f")
{
  long address;
  long nargs;
  CHECK_TYPES(mfunction, CT_INT(address),
              mnargs, CT_RANGE(nargs, 0, MAX_FUNCTION_ARGS));
  if (address == 0)
    RUNTIME_ERROR(error_bad_value, "null LLVM function address");

  struct llvm_callback_data *data = malloc(sizeof *data);
  if (data == NULL)
    RUNTIME_ERROR(error_bad_value, "out of memory");
  struct gcpro *old_gcpro = gcpro;
  data->entry = (llvm_native_entry)(uintptr_t)address;
  data->nargs = (size_t)nargs;
  data->check_arity = true;
  data->stable = false;
  struct vector *constants = alloc_vector(0);
  struct gcpro constants_root;
  GCPROV(constants_root, constants);
  struct vector *captures = alloc_vector(1);
  struct gcpro captures_root;
  GCPROV(captures_root, captures);
  captures->data[0] = constants;
  struct closure *closure = make_mcallback_varargs_captured_sec(
    llvm_call_closure, llvm_free_callback, data, captures,
    "llvm_function_closure", GET_STATIC_STRING(llvm_function_closure_help),
    __FILE__, __LINE__, c_maxseclevel());
  gcpro = old_gcpro;
  return closure;
}

TYPEDOP(system_cmd, "system_cmd",
        "`s -> `n. Executes shell command `s.",
        (struct string *cmd),
        OP_LEAF | OP_NOESCAPE | OP_NOALLOC, "s.n")
{
  CHECK_TYPES(cmd, string);
  return makeint(system(cmd->str));
}

void llvm_init(void)
{
  DEFINE(system_cmd);
  DEFINE(llvm_load_function);
  DEFINE(llvm_load_ir_closure);
  DEFINE(llvm_call_function);
  DEFINE(llvm_function_closure);
}
