# Mudlle LLVM Backend & Assembly Writer Documentation

This document describes the LLVM backend (`genllvm.mud`, `llvm.mud`, `allvm.mud`, `mllvm.mud`) and Assembly Writer abstraction (`asmwriter.mud`) used by the Mudlle compiler.

---

## 1. Overview

The LLVM backend emits LLVM IR for Mudlle functions. ORC LLJIT compiles and loads that IR in process. Optional LLVM command-line tools can validate or inspect emitted IR, but normal execution does not invoke them.

The IR leaves the target triple and data layout unspecified. This lets LLVM select its host target, including 64-bit ARM and RISC-V targets when LLVM provides them. This is code generation coverage, not proof of runtime compatibility or production readiness.

### Restart performance follow-up

Currently `.obj` files contain textual LLVM IR, which the loader parses,
optimizes, and compiles again in each process. A native object cache can skip
these steps on a cache hit, while ORC links and relocates the object at load time.
The installed LLVM 19 C headers expose the necessary APIs:

- `LLVMOrcLLJITGetObjTransformLayer` and
  `LLVMOrcObjectTransformLayerSetTransform` can capture emitted object bytes.
- `LLVMOrcLLJITAddObjectFile` can load the saved relocatable object.

See the [LLVM LLJIT C API](https://llvm.org/docs/doxygen/group__LLVMCExecutionEngineLLJIT.html)
and [object transform API](https://llvm.org/doxygen/Orc_8h_source.html).
Saving optimized bitcode alone still requires machine-code generation.

Before implementing persistent caching, handle load-time global offsets and
`mudlle_module_<sequence>_` symbol names: both currently depend on process state.
Either include the resolved mapping in the cache key (limiting reuse), or change
global access to use a per-module mapping and give cached objects stable symbol
identities with isolated namespaces. Constants already use the rooted closure
environment rather than embedding GC addresses. Cache validity must include
module content/constants layout, Mudlle runtime ABI, LLVM version, target
triple, CPU/features, and optimization settings. Compare cold and warm compiler
loads separately from compilation work. Keep execution single threaded. This
cache is proposed follow-up work and is not implemented yet.

### Native parity contract

LLVM is a native compiler backend only when it can replace the x64 backend in
the normal `mc:compile` → `mc:prelink` → `mc:linkrun` path. Returning IR text or
calling a function through the experimental C ABI bridge does not satisfy this
contract.

The backend must preserve the x64 backend's observable language and runtime
behavior, including:

- Every `ins3` instruction class and every builtin operation, with the same
  tagged values, type checks, errors, security-level checks, and side effects.
- Function calls, closures and captured variables, optional and variadic
  arguments, globals, imported constants, and nested function references.
- Mudlle's compiled-code calling convention, code and closure metadata,
  constants, relocations, function entry points, source locations, and
  serialization rules.
- Garbage-collector correctness while generated code runs, including live
  values in registers and stack slots across allocating calls, stack traces,
  and code movement or unloading.
- The public compiler API and the behavior of interactive evaluation,
  compilation to `.obj`, and loading precompiled modules.

The current x64 runtime makes these requirements explicit: `struct mcode` and
its GC scanner encode x64 machine-code layout (`mvalues.h`, `alloc.c`). The
LLVM path therefore stores IR and constants in an LLVM-specific prelink
descriptor, compiles a shared module at load time, and wraps generated entries
as normal Mudlle closures. This exercises `mc:compile` and `mc:linkrun`, but it
does not make LLVM output compatible with serialized x64 `mcode` objects.

The existing linker in `runtime/support.c` resolves x64 constants, nested code
entries, builtins, globals, primitives, security-level patches, and source
metadata before creating an `mcode`. LLVM uses its own loader and runtime
helpers for those generated modules. Behavioral parity with the x64 linker and
runtime remains an ongoing requirement.

Remaining differences include synthetic callback names and source locations in
LLVM code metadata, ORC modules retained for the lifetime of the process, and
the unsupported `global_syms` argument to LLVM compilation. Compiler loading
and bootstrap are also substantially slower than x64 on the measured Linux
host; README records stage timings and validation commands.
Bootstrap and language regression success do not establish parity for these
behaviors. Primitive signatures must describe integer booleans as `n`, since
`b` denotes bigint and allows inference to discard false branches.

The Assembly Writer (`asmwriter.mud`) provides a writer abstraction that can emit IR and assembly to strings and files.

---

## 2. Assembly & IR Text Writer (`asmwriter.mud`)

The `asmwriter` library provides a uniform interface for outputting formatted text (such as disassemblies, assembly instructions, or LLVM IR).

### Functions

- `writer:new({oport,null} p = null)`
  Creates a writer wrapping output port `p` (defaults to `stdout()` if null).

- `writer:new_file(string filename)`
  Creates a writer that outputs directly to a file `filename`.

- `writer:new_string()`
  Creates a writer capturing output into an in-memory string buffer.

- `writer:get_string(vector w)`
  Returns the captured string from a string writer.

- `writer:write(vector w, string s)`
  Writes string `s` to writer `w`.

- `writer:write_line(vector w, string s)`
  Writes string `s` followed by a newline to writer `w`.

- `writer:format(vector w, string fmt, args...)`
  Formats and writes text to `w` using `pformat`.

- `writer:close(vector w)`
  Closes the underlying file or port if applicable.

---

## 3. LLVM Backend (`genllvm.mud`, `llvm.mud`)

`genllvm.mud` translates Mudlle's Phase 2 / Phase 3 `ins3` 3-address intermediate representation into target-independent LLVM IR (`.ll`).

### Architecture Backend Interface (`mp:`)

`llvm.mud` supplies LLVM instruction generation for the backend interface.
The LLVM loader uses a custom compilation pipeline. `mc:compile_llvm` returns
IR text for inspection; `mc:compile` returns a prelinked LLVM module accepted
by `mc:linkrun`.

### Data Mapping Scheme

- **Tagged Values**: Mudlle uses 64-bit tagged integer pointers (`i64` in LLVM IR).
  - Tagged Integer: `mudlle_int = (c_int << 1) | 1`
  - Untagging: `ashr i64 %val, 1`
  - Boolean `false`: `1` (tagged 0)
  - Boolean `true`: `3` (tagged 1)
- **Local/Temporary Variables**: Stored in 64-bit stack slots (`alloca i64`) in the function entry block. The generator uses the compiler's liveness analysis to share slots between locals whose lifetimes do not overlap. Indirect variables keep exclusive slots because their storage cells are initialized at entry and can escape into closures. Slot zero is reserved for discarded values. Reads and writes use `load i64` and `store i64`. In functions that cannot allocate, LLVM can promote these slots into SSA values and `phi` nodes. Allocating functions publish the slots and closure environment as GC roots.

### Native calls and garbage collection

Generated calls to LLVM closures use their native argument-vector ABI directly.
Calls to interpreted closures and primitives use the normal Mudlle runtime.
The generator roots argument slots before materializing values, and keeps those
roots until the call returns. A `call_llvm` frame exposes the active closure,
code metadata, and actual arguments to GC and call-trace handling. Native entry
preserves stack, interrupt, arity, minimum security level, and maximum security
level checks. `compiled?()` recognizes these frames.

Readonly vectors become immutable only when all their elements are immutable.
A compiler hint alone cannot establish this: readonly constants can still
contain movable objects. Prematurely promoting a parent vector to generation 1
would leave references to generation 0 unvisited during minor collections.

### Helper Functions

- `mc:gen_llvm_ir(vector mod, {writer,null} w = null)`
  Generates LLVM IR for an entire Mudlle module `mod`. If `w` is omitted or null, returns the generated LLVM IR as a string.


---

## 4. Compiler Integration (`compile.mud`)

The x86-64 compiler's `mc:compile` produces a prelinked x64 code object. The
LLVM loader's `mc:compile` produces an LLVM-specific prelink descriptor, which
`mc:linkrun` compiles and loads at runtime. Both follow the public compile and
run API, but the two prelink formats are not interchangeable and full
behavioral parity is still in progress.

---

## 5. Usage Examples

### Example 1: Unified Compilation (`mc:compile`)

```mudlle
load("xc.mud");

| tree, pmod |
tree = mudlle_parse("fn (a, b) [ if (a < b) a * b else a - b ]", "test.mud", false);
pmod = mc:compile(tree, false, 15, mc:source_code("fn (a, b) [ if (a < b) a * b else a - b ]"));
```

### Example 2: Generate LLVM IR text

```mudlle
load("xc.mud");

| tree, ir |
tree = mudlle_parse("fn (a, b) a + b", "test.mud", false);
ir = mc:gen_llvm_ir(tree);
display(ir);
```
