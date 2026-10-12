# LLVM backend

This document describes the current LLVM backend architecture and the points
that matter when changing it. The README gives the x64 comparison and benchmark
results. The implementation history
and active measurement handoff remain in
[`llvm-backend-handoff.md`](llvm-backend-handoff.md).

## Build and selection

On x86-64, `xc.mud` continues to select the x64 compiler and `llvmc.mud`
selects LLVM. On ARM64 and RISC-V, `xc.mud` selects LLVM. The interpreter is
available without LLVM. LLVM development headers, its C API library and
`llvm-config` must come from one installation. A clean tree is required when
switching backends because compiler object files are backend-specific.

`make USE_LLVM=yes` builds the LLVM runtime and compiler. `make -jN compiler
USE_LLVM=yes` performs the three-stage compiler bootstrap with independent
single-threaded Mudlle processes; the stages remain ordered. The default LLVM
optimization pipeline is O2.

## Compilation and loading

The LLVM generator in `genllvm.mud` lowers Mudlle's shared Phase 2/Phase 3
`ins3` instructions to target-independent LLVM IR. The compiler API remains
the same: `mc:compile` creates a serializable prelinked module, and
`mc:linkrun` loads and runs it. LLVM modules use an LLVM-specific descriptor
containing IR, entry points, constants and relocation metadata. At load time,
`runtime/llvm.c` creates or reuses native code through ORC LLJIT and wraps
entries as ordinary Mudlle closures. `mc:compile_llvm` and
`mc:gen_llvm_ir` are available for IR inspection.

The IR leaves the target triple and data layout to LLVM's host target
selection. This enables targets supported by the installed LLVM and runtime,
but code generation alone does not establish runtime compatibility. LLVM
prelinked modules and x64 `mcode` objects are different formats; neither
backend can load the other's serialized native module.

Mudlle values are represented in generated code as tagged 64-bit words
(`i64`). Locals and temporaries use liveness-colored stack slots; proven
private scalar slots can be promoted to SSA values, while values that may
contain heap pointers stay visible to the collector at safepoints. The
generator emits direct LLVM operations for guarded common cases and retains
runtime helpers as fallback paths for other types and errors. Current fast
paths include tagged integer operations, floating-point chains, vector
access and mutation, vector construction and list construction. These paths must preserve the language's checks and observable errors.

## Calls and moving garbage collection

Generated LLVM closures use a native argument-vector calling convention and
`call_llvm` frames. The frames expose the active closure, code metadata and
arguments to garbage collection, tracing and `compiled?()`. Calls to
interpreted closures and primitives enter the existing runtime. Known
fixed-arity calls can bypass redundant callable and arity checks while keeping
the normal frame and security semantics. Calls to interpreted closures copy
protected arguments onto the interpreter stack using its standard entry
convention.

The backend uses Mudlle's moving collector and explicit shadow-root frames.
Generated code registers live heap-capable slots around collecting calls and
reloads forwarded values after collection. The active call frame keeps the
closure itself reachable, so generated code reloads it from the frame after a
safepoint. C helpers root argument copies before any allocation that can
collect. The collector remains synchronous and Mudlle remains single
threaded; LLVM statepoints and native stack scanning are not used.

Vector construction first attempts a guarded nursery allocation that cannot
collect, then initializes every field before another allocation can occur.
When that fast path cannot allocate, a separate helper roots the arguments,
allows collection and builds the vector from forwarded values. Readonly does
not imply immutable: an object is immutable only when its contents are
immutable too. Keep the root and reload rules, initialization order and
immutability checks intact when changing allocation paths. See
[`gc.md`](gc.md) for the runtime collector contract.

Generated IR relies on C structure offsets and runtime helper behavior.
`runtime/llvm.c` has compile-time layout assertions; update those alongside
the generator if a layout changes. Runtime source and build fingerprints are
part of the object cache identity.

## Runtime integration

- **Module format.** `mc:prelink_llvm` (`link.mud`) builds the usual `pmodule`
  envelope, but the top-level function's code slot holds a five-element
  vector: IR text, entry symbol, arity, constants and global relocations.
  The module's architecture word is `llvm`, so x64 and LLVM modules are
  rejected by each other's loaders. Native modules loaded in a build without
  a compiler are rejected unless they are interpreter code.
- **Stable closures.** Cross-module dependencies on a global normally require
  an immutable value. LLVM closures are also accepted
  (`compiler_stable_closure?`, `llvm_stable_closure`), so known-call fast
  paths can rely on them without the closure being formally immutable.
- **Call frames.** `call_llvm` frames share `struct call_stack_mudlle` with
  bytecode frames and add `native_args`. Frames pushed inline by generated
  direct calls (`offset == -2`) own their argument array and the collector
  forwards it; for other frames the caller roots the arguments.
  `compiled?()` and tracing treat `call_llvm` like `call_compiled`.
- **Allocation helpers.** `try_alloc_vector` and `try_alloc_list`
  (`alloc.c`) allocate only if the nursery has room and never collect, so
  generated code may pass unrooted values to them; they return NULL otherwise
  and the caller falls back to the rooting helper.
- **C callbacks.** LLVM closures are interpreter-visible primitives created with `make_mcallback_varargs_captured_sec*`; they run
  as interpreter closures that pass all arguments as one vector
  (`op_c_callback`), optionally with captured cells, a security level and a
  cached `icode`. `mcallback_varargs_matches` lets the runtime recognize a
  specific callback, so generated code can call it directly.
- **Security levels.** `maxseclevel_for(seclev)` gives the maximum security
  level a function runs with; known-call fast paths use it to preserve the
  normal security semantics.
- **Build.** `MUDARCH=llvm` is chosen by `USE_LLVM=yes`, or automatically when
  `llvm-config` exists and no x64 compiler applies (ARM64, RISC-V). The
  build stamp is `ARCH-MUDARCH`, which is why switching backends needs a
  clean tree. `runtime/llvm-cache-abi.pl` regenerates
  `runtime/llvm-cache-abi.h` on every build from sources and flags; it is
  part of the cache key. `genllvm.mud` and `asmwriter.mud` are always
  compiled; `llvmcompile.mud` replaces `compile.mud` as the compiler API.
- **Value comparison.** `mudlle_values_equal` is exported from
  `runtime/pattern.c` so runtime helpers can reuse `equal?` semantics.

## Optimization, verification and diagnostics

`MUDLLE_LLVM_OPT` selects `none`, `O0`, `O1`, `O2` (the default), `O3`, or the
experimental `fast` pipeline. Invalid values are errors. The selected
pipeline participates in the native object cache key.

IR is verified at optimization boundaries. Set
`MUDLLE_LLVM_VERIFY_EACH=1` to verify after every optimization pass while
debugging. Set `MUDLLE_LLVM_TIMING=1` to print IR size and timings for
compilation stages on cache misses. These diagnostic settings do not change
generated code or cache identity.

The O2 pipeline enables loop vectorization, loop interleaving and SLP. This
does not mean arbitrary Mudlle loops become SIMD: dynamic types, helper calls,
indexing and per-iteration loop-budget accounting can prevent vectorization.
Do not remove checks, alias constraints or loop accounting without proving
the language semantics remain unchanged.

## Persistent native object cache

Mudlle's serialized LLVM module contains IR and relocation data. The runtime
cache stores the relocatable native object emitted by ORC, not linked
addresses. A hit adds that object to the current LLJIT and still resolves
runtime symbols and relocations in the current process. It skips IR parsing,
optimization and native code generation.

The default cache directory is `.mudlle-llvm-cache` in the working directory.
Set `MUDLLE_LLVM_CACHE=/absolute/path` to choose another directory, or set it
to the empty string to disable persistence. The parent directory must exist;
cache failures fall back to compilation. `MUDLLE_LLVM_CACHE_TRACE=1` reports
hits and misses. Cache files are private executable artifacts, written by
temporary file and atomic rename. There is no automatic eviction.

Keys include relocated IR, entry symbol, runtime source and ABI fingerprints,
build flags, LLVM version, target and CPU features, optimization pipeline,
and cache format. Cache entries validate their complete key, length and
checksum before reuse. Changed globals, layouts, code or optimization settings
therefore miss safely. LLVM 19 and newer use a JITDylib per object; older LLVM
versions use the compatibility lookup path and include its sequence marker in
the key. The cache adds no threads; ORC work is synchronous on the calling
thread.

Focused cache checks:

```sh
perl regression/test-llvm-cache-abi.pl
perl regression/test-llvm-cache.pl
```

## Diagnostics and environment

To get IR text for a function:

    load("xc.mud")
    source = "fn (a, b) a + b";
    tree = mudlle_parse(source, null, false);
    ir = mc:compile_llvm(tree, 1, mc:source_code(source));
    w = writer:new_file("module.ll"); writer:write(w, ir); writer:close(w);

Environment variables:

| Variable | Effect |
|----------|--------|
| `MUDLLE_LLVM_OPT` | `none`, `O0`, `O1`, `O2` (default), `O3`, or experimental `fast` |
| `MUDLLE_LLVM_VERIFY_EACH=1` | verify after every pass (default: module boundaries only) |
| `MUDLLE_LLVM_TIMING=1` | report IR size and time per compilation stage on a cache miss |
| `MUDLLE_LLVM_CACHE=<dir>` | native object cache directory (default `.mudlle-llvm-cache`; empty disables) |
| `MUDLLE_LLVM_CACHE_TRACE=1` | print cache hits and misses |

## Validation

Serial runs for any LLVM backend change; the bootstrap and compiled-loader
runs catch relocation and GC-rooting bugs the single-session suite misses:

```sh
MUDLLE_LLVM_CACHE= ./mudlle -c 'silent=true' -e xc.mud -e regression/all.mud
MUDLLE_LLVM_OPT=none MUDLLE_LLVM_CACHE= make compiler USE_LLVM=yes
perl regression/test-llvm-cache-abi.pl
perl regression/test-llvm-cache.pl
MUDLLE_LLVM_VERIFY_EACH=1 MUDLLE_LLVM_CACHE_TRACE=1 ./mudlle \
  -c 'silent=true' -e icxc.mud -e regression/all.mud    # cold, then warm
```

## Assembly and IR writer

`asmwriter.mud` provides output writers for strings, files and ports:

- `writer:new(port = null)` creates a port writer (stdout by default).
- `writer:new_file(filename)` creates a file writer.
- `writer:new_string()` and `writer:get_string(writer)` capture output in a
  string.
- `writer:write`, `writer:write_line` and `writer:format` emit text.
- `writer:close(writer)` closes the writer's underlying resource.

## LLVM references

- [LLVM Language Reference](https://llvm.org/docs/LangRef.html) describes the
  IR instructions and semantics emitted by `genllvm.mud`.
- [LLVM Passes](https://llvm.org/docs/Passes.html) and the [New Pass
  Manager](https://llvm.org/docs/NewPassManager.html) describe optimization
  passes and pipelines selected through `MUDLLE_LLVM_OPT`.
- [ORC v2 documentation](https://llvm.org/docs/ORCv2.html) introduces LLVM's
  JIT architecture; the [LLVM C ORC LLJIT
  API](https://llvm.org/doxygen/group__LLVMCExecutionEngineLLJIT.html) is the
  interface used by the runtime.
- [ORC object caching](https://llvm.org/docs/ORCv2.html#object-caching) gives
  background on caching compiled objects. Mudlle's persistent cache is
  implemented in its runtime around ORC's object transform and object-loading
  APIs.
- [LLVM target configuration](https://llvm.org/docs/CodeGenerator.html)
  describes target-specific code generation and host target setup.
- [LLVM garbage collection](https://llvm.org/docs/GarbageCollection.html)
  and [statepoints](https://llvm.org/docs/Statepoints.html) explain LLVM's GC
  mechanisms. Mudlle currently uses its own explicit shadow-root frames, as
  described above.
- [LLVM vectorizers](https://llvm.org/docs/Vectorizers.html) documents loop,
  interleaving and SLP vectorization used by the O2 pipeline.

For the current x64 comparison see the
[README](../README.md), for benchmark method [benchmark.md](benchmark.md), for history
the [LLVM handoff](llvm-backend-handoff.md).
