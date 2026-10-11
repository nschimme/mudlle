# Mudlle LLVM Backend & Assembly Writer Documentation

This document describes the LLVM backend (`genllvm.mud`, `llvm.mud`, `allvm.mud`, `mllvm.mud`) and Assembly Writer abstraction (`asmwriter.mud`) used by the Mudlle compiler.

---

## 1. Overview

The LLVM backend emits LLVM IR for Mudlle functions. ORC LLJIT compiles and loads that IR in process. Optional LLVM command-line tools can validate or inspect emitted IR, but normal execution does not invoke them.

IR verification runs at the input and output of optimization, rather than
after every pass. `MUDLLE_LLVM_VERIFY_EACH=1` enables per-pass verification for
debugging. `MUDLLE_LLVM_TIMING=1` reports compilation stages on object-cache
misses. `MUDLLE_LLVM_OPT=fast` selects an experimental small scalar pipeline;
O2 remains the default. The selected pipeline already participates in native
object cache keys. Verification and timing settings do not change the code
generation pipeline or require separate cache keys.

Mudlle's generated code uses explicit GC root frames. Before flattening the
control-flow graph, the backend computes variables live at potentially
collecting instructions. It conservatively recognizes integer/null-only
locals from all their definitions; incoming arguments and indirect cells
remain potentially heap-valued. A physical slot is published only when its
values need protection. GC-visible and private slots use separate coloring
classes, so nonoverlapping heap/scalar lifetimes cannot accidentally make a
private scalar slot escape. Entry allocation (varargs or boxing) keeps the
conservative full frame; unknown/uncolored temporaries stay rooted.

The safepoint classifier is shared with whole-function root elision. This
remains a manual shadow stack: registered slots must still be reloaded after
collecting calls. No LLVM statepoints, native stack crawler, or new threads
are introduced. Statepoints would additionally require representing tagged
values as managed references, registering ORC stack maps, relocating live
references, and preserving error unwinding across C/native frames.

### Vector allocation and statepoint assessment

`llvm_build_vector` checks the allocator's aligned record size before taking
its common path. With sufficient generation-zero space, the existing allocator
cannot collect; the helper allocates an uninitialized record and fills every
element before any subsequent allocating call. It reads the caller's argument
buffer directly. On exhaustion, a separate non-inlined helper copies the
arguments into registered C roots before allocation and initializes the vector
from the relocated copies. Neither path marks a readonly vector immutable
unless its actual children are immutable. There are no new threads or changes
to the generated-code ABI. Runtime source fingerprints invalidate cached native
objects when the helper implementation changes.

This guard depends on synchronous, single-threaded collection. Keep vector
initialization, immutability checks and debug checks nonallocating. If that
contract changes, both paths need a new root/reload audit. Uninitialized records
must never reach an intervening allocation before all fields have valid values.

LLVM [statepoints](https://llvm.org/docs/Statepoints.html) describe live managed
pointers at collecting calls; `gc.relocate` supplies the post-collection SSA
values, and generated stack maps describe their spill locations. This could
allow SSA optimization between safepoints and avoid whole-function escaping
root slots. It does not eliminate allocation, initialization, or required
safepoint spills.

For Mudlle, adopting them would require a managed-pointer representation for
the current mixed tagged `i64` values, base/derived-pointer tracking, ORC stack
map registration on both object-cache misses and hits, and a stack scanner
across nested native/C/interpreter calls. Error longjmp unwinding must remove
active frames safely. Existing C roots still need protection. A prototype should
first test mixed integers/null/static strings/heap values, nested allocating
calls, moving collections, error recovery, cached objects, and LLVM 14/19 on
each supported host. Merely adding statepoint intrinsics to the current IR
would not provide these runtime guarantees.

Recommendation: retain the explicit roots for this change. Statepoints remain
a possible larger optimization after profiling shows root-slot traffic is the
dominant remaining cost; no statepoint speedup has been measured. The guarded
allocation path addresses repeated C argument-root setup independently.

### Allocation/root-slot profile at 31f7662

The continuation's controlled probes do not justify replacing shadow roots
with statepoints yet. In five serial LLVM 19/x64 samples, the ten-million-vector
workload is slower under LLVM even with zero incoming heap references (205 vs
117 ms). When growing element reads are replaced with non-null identity checks,
LLVM allocation medians are 242/216/249/245 ms for 0/1/4/16 incoming references.
The sixteen-reference identity case retains 20 published roots and loop-body
root reloads; the zero-reference case retains four roots. No clear allocation
scaling with additional root slots is visible in that probe.

The element-read probe has 36 published slots at sixteen references, including
potential heap-valued element temporaries. Its nonallocating successful-path
control still publishes 34 slots for fallback safety and performs close to x64.
Whole-function publication is distinct from per-iteration root-frame setup;
these loops register once per native invocation. Scalar slots remain promotable
where the existing liveness/type analysis proves them private.

A separate instrumented C profile points to type helpers and allocator/debug
checks, but cannot measure generated-code root-load time: `perf` is denied by
the host and gprof does not attribute dynamic JIT code. Absence of sampled root
registration time is not proof that root slots are free. Likewise, control
subtraction is not pure root cost, and the identity probe is not a GC test.

Retain the moving-GC shadow-stack ABI, C roots, synchronous ORC loading/cache
path, and longjmp root restoration. No prototype or runtime changes accompany
this profile. Before a future statepoint experiment, obtain JIT-aware samples
or another controlled measurement demonstrating a material root-slot bottleneck.
The managed-pointer/stack-map/cache-hit/unwinding requirements above still apply;
LLVM statepoints still require spilling live values at collecting calls.

README records full samples, limitations, validation scope and Linux commands.
`regression/benchmark-llvm-roots.pl --identity-only` generates the identity
variant without modifying either source checkout. The inspection driver exports
IR and actual ORC cache objects for both modes. It uses the normal
`mc:compile`/`mc:linkrun` path and requires successful result checks before
accepting artifacts.

### SIMD and automatic vectorization

The runtime already enables loop vectorization, loop interleaving and SLP
with the default O2 pipeline. A scalar tagged `i64` is not by itself an
obstacle to packing independent integer operations. The main obstacles in
ordinary language loops are opaque runtime/builtin calls, type-check failure
paths, dynamic indexing and the volatile atomic loop-budget update on every
back edge. Removing that update or adding `noalias` without proof would change
language semantics. Floating-point reassociation likewise requires an
explicit numerical contract rather than globally enabling fast math.

Vector membership branches use a lazily emitted internal LLVM helper. It
checks the vector type/length with the existing runtime helper, then compares
32 contiguous tagged words in a call-free OR reduction. LLVM can unroll and
pack that reduction through SLP; the emitted IR contains no fixed SIMD ISA or
lane width. Search stops after a matching chunk, and the final 0-31 words use
scalar early exits. This retains pointer-identity comparison for heap objects,
never reads beyond vector length, and does not allocate or poll for GC. It is
a runtime primitive implementation, so it does not change language-loop
budget accounting. The runtime vector-find symbol remains available.

Generic integer arithmetic now has tagged-integer guards and visible LLVM
operations, with the runtime fallback retaining other types and errors.
Vector indexing similarly exposes checked loads, including negative indices;
`vlength` uses the existing checked length helper. Temporary argument buffers
for vector construction and builtin dispatch need no extra root frame when
argument evaluation cannot collect: these runtime helpers copy and root the
arguments before allocating. Concatenation retains its caller roots because
its runtime implementation reads that buffer after allocation.

General loop SIMD still requires proving integer element types and bounds
across iterations, exposing stores, and forming
counted call-free regions while preserving allocation, aliasing, error and
budget semantics. Compiler latency is a separate performance target; root
selection and a faster search primitive do not remove cold ORC compilation.

See LLVM's [GC integration](https://llvm.org/docs/GarbageCollection.html),
[statepoints](https://llvm.org/docs/Statepoints.html), and
[vectorizers](https://llvm.org/docs/Vectorizers.html) documentation.
The timing diagnostics do not separately measure frontend IR generation or
separate ORC machine-code generation from linking.

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
perl regression/test-llvm-cache-abi.pl
perl regression/test-llvm-cache.pl
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
