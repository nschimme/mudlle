# Mudlle LLVM Backend & Assembly Writer Documentation

This document describes the LLVM backend (`genllvm.mud`, `llvm.mud`, `allvm.mud`, `mllvm.mud`) and Assembly Writer abstraction (`asmwriter.mud`) used by the Mudlle compiler.

---

## 1. Overview

The LLVM backend emits LLVM IR for Mudlle functions. ORC LLJIT compiles and loads that IR in process. Optional LLVM command-line tools can validate or inspect emitted IR, but normal execution does not invoke them.

The IR leaves the target triple and data layout unspecified. This lets LLVM select its host target, including 64-bit ARM and RISC-V targets when LLVM provides them. This is code generation coverage, not proof of runtime compatibility or production readiness.

### Persistent native object cache

`.obj` files remain portable textual LLVM IR plus rooted constants and global
relocations. The runtime caches the **relocatable native object**, rather than
optimized bitcode or linked addresses. On a miss it uses the existing O2 IR
pipeline and ORC compilation path; an object-transform callback captures the
emitted bytes before linking. On a hit it calls `LLVMOrcLLJITAddObjectFile`,
skipping IR parsing, optimization, and machine-code generation. ORC still
resolves runtime symbols and object relocations in the new process.

The default cache directory is `.mudlle-llvm-cache` in the working directory.
Set `MUDLLE_LLVM_CACHE=/absolute/path` to share a private cache across restarts,
or set `MUDLLE_LLVM_CACHE=` to disable persistence. The parent directory must
exist; an unavailable cache falls back to compilation. Set
`MUDLLE_LLVM_CACHE_TRACE=1` for one `LLVM object cache hit` or `miss` line per
module. Cache directories are created with mode 0700 and files with mode 0600.
They contain executable artifacts and should remain under the user's control.
There is no automatic eviction; deleting the directory discards the cache.

The key includes the complete **relocated IR** and entry symbol, a generated
SHA256 fingerprint of runtime C/header sources (including generated ABI headers),
Makefile and C/CPP flags, LLVM's full version, target triple and data layout,
host CPU/features, and the selected optimization pipeline. The cache format
version and ORC default code-generation policy are included too. Changes to
constant indices or layouts affect IR; actual constant values are loaded from
the current GC-rooted closure environment, never embedded as process addresses.

Global offsets are resolved before lookup. A changed global registration order
therefore produces a safe miss, and each mapping can subsequently hit its own
object. This deliberately trades some reuse for retaining direct global access
and the existing serialized descriptor format. LLVM 19 and newer load each
object into its own JITDylib, preserving stable object symbol names without
process-sequence prefixes or duplicate-definition collisions. Older releases
use the established main-dylib lookup API with sequence-prefixed function names;
the sequence is also in their cache key, restricting reuse to matching load
order. Entry names and generated function numbers remain part of the content
key; changed descriptors safely miss.

A cache file stores the full key, native object length and checksum, and object
bytes. The filename is only a hash index: a hit requires exact key equality,
correct lengths, and a matching object checksum. Missing, truncated, mismatched,
or damaged entries are recompiled. Writes use a temporary file and atomic
rename; failed writes do not prevent execution. Independent processes may
populate the same directory without partial-file reads. This introduces no
Mudlle threads: default LLJIT compiles on the calling thread, and the transform
capture is scoped to its synchronous lookup. JIT modules remain resident for
the process lifetime, as before.

Run the focused checks after an LLVM build:

```sh
python3 regression/test-llvm-cache-abi.py
python3 regression/test-llvm-cache.py
```

The integration driver covers fresh-process hits, linking the same descriptor
twice, serialized modules loaded with different global orders, optimization
invalidation, damaged entries, and unavailable/disabled caches. README records
full-backend validation and measured cold/warm startup results.

See the [LLVM LLJIT C API](https://llvm.org/docs/doxygen/group__LLVMCExecutionEngineLLJIT.html)
and [object transform API](https://llvm.org/doxygen/Orc_8h_source.html).

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
