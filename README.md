mudlle: MUD Language for Little Extensions
------------------------------------------

This software is Copyright (C) 1993-2012 David Gay and Gustav Hållberg.
Read the COPYRIGHT file for terms of use.


Installation
------------
To compile on Linux or macOS:

  make
  make compiler

Linux Setup and Backend Validation
----------------------------------
On Debian or Ubuntu, install the build tools and LLVM development files:

  sudo apt install build-essential flex bison perl libgmp-dev libreadline-dev llvm llvm-dev

Python 3 is needed only for the optional benchmark and test scripts under
`regression/`; the build itself uses Perl.

The build detects LLVM through `llvm-config`; normal JIT execution does not
need the LLVM command-line tools. Keep the LLVM headers, C API library, and
`llvm-config` from the same installation:

  llvm-config --version

Build each x86-64 backend from a clean tree. The clean step matters because
the generated compiler objects are backend-specific:

  make clean
  make
  make compiler

  make clean
  make USE_LLVM=yes

Run the same regression suite in each build:

  ./mudlle -e xc.mud -e regression/all.mud

The suite should print `SUCCESS`. It includes the LLVM-specific checks when
the LLVM backend is selected. Run `make compiler USE_LLVM=yes` to check the
multi-stage compiler bootstrap as well. The validation evidence below records
the bootstrap status separately from the language regression suite.

To compare execution after compilation, run the compiled-kernel benchmark:

  ./mudlle -e xc.mud -e regression/benchmark.mud

The benchmark compiles and links one function before starting its timer, checks
the result, then runs a compiled integer reduction loop 2,000 times at 50,000
iterations per call. Its `cpu_ms` value measures Mudlle process CPU time, not
compiler/JIT startup. LLVM runs the `default<O2>` optimization pipeline by
default. Set `MUDLLE_LLVM_OPT=none`, `O0`, `O1`, `O2`, or `O3` to compare
optimization levels. Run each backend from a clean build, repeat the command
several times, and compare the median. `regression/all.mud` is a correctness
suite; timing that whole command also includes loading the compiler, compiling
test snippets, and JIT setup.

macOS Setup
-----------
On macOS (Homebrew), install the required toolchain dependencies including LLVM:

  brew install llvm flex bison

Ensure `llvm-config` for Homebrew LLVM is available to the build:

  export PATH="$(brew --prefix llvm)/bin:$PATH"


Quick Introduction
------------------

mudlle is a small language designed for writing extensions to MUME, an
online multi-user game. It is heavily inspired by Scheme. This
distribution contains a stand-alone interpreter and compiler that can
be used to experiment with the language. It is up to you to integrate
it with your favourite application if you wish to use it as an
extension language.

Once compiled, run mudlle and check that basic stuff works:

  ./mudlle
  mudlle> 2+3
  Result: 5
  mudlle>

EOF (Ctrl-D), or evaluating quit() will exit the interpreter.

doc/mudlle-intro.doc and doc/mudlle-ref.doc contain a language introduction
and reference. doc/llvm-backend.md documents the LLVM backend.

LLVM Compiler Demo (Apple Silicon)
----------------------------------
Install the Homebrew build tools and put all three tool directories first on
`PATH`. In particular, macOS may otherwise select Apple's older `/usr/bin/bison`,
which cannot parse this project's grammar:

  brew install llvm flex bison
  export PATH="$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$(brew --prefix llvm)/bin:$PATH"
  bison --version
  llvm-config --version
  make clean
  make USE_LLVM=yes

On Apple Silicon, Mudlle uses the LLVM backend; there is no native x64 backend
to compare on this host. Run the ARM64 regression suite and compiled-kernel
benchmark with:

  ./mudlle -e xc.mud -e regression/all.mud
  ./mudlle -e xc.mud -e regression/benchmark.mud

On ARM64 and RISC-V, `load("xc.mud")` selects the LLVM backend. At the prompt,
compile a function to LLVM IR text:

  load("xc.mud")
  source = "fn (a, b) a + b";
  tree = mudlle_parse(source, null, false);
  ir = mc:compile_llvm(tree, 1, mc:source_code(source));
  w = writer:new_file("module.ll");
  writer:write(w, ir);
  writer:close(w);

The IR can be inspected or validated with optional LLVM command-line tools.
ORC LLJIT sets the target triple and data layout from the host at runtime. On
x86-64, `load("xc.mud")` keeps the legacy compiler; load `llvmc.mud` to select
LLVM explicitly. Start a fresh Mudlle process with each loader when comparing
the backends.

Without LLVM installed, the interpreter remains available. Native x86-64
compilation continues to use the existing backend.

Validation and Performance
--------------------------
Validated on Linux x86-64 with GCC 14.2.0, LLVM 19.1.7 and an AMD Ryzen 9 7940HS.
Mudlle remains single threaded; LLVM compiles on the calling thread with O2 by
default. x64 and LLVM runtime/three-stage compiler builds pass. LLVM bootstrap
uses `MUDLLE_LLVM_OPT=none`; its final compiler runs under default O2.

The full `regression/all.mud` suite passes with both source and compiled
compilers on both backends. LLVM O2 passes on cache misses and hits; warm source
and compiled suites record 4,405 and 4,426 hits, respectively, with zero misses.
The LLVM source compiler also passes with optimization disabled. LLVM 14.0.6
builds and passes `regression/llvm.mud` and the focused cache tests; its full
suite/bootstrap still needs direct validation.

LLVM Compilation Diagnostics
----------------------------
LLVM verifies each module before optimization and again after optimization.
Per-pass verification is disabled by default; set `MUDLLE_LLVM_VERIFY_EACH=1`
to restore that expensive debugging check. O2 remains the default optimization
pipeline. `MUDLLE_LLVM_OPT` also accepts `none`, `O0`, `O1`, `O2`, `O3`, and
experimental `fast` (SROA, early CSE, instruction combining and CFG cleanup).
The small `fast` pipeline can sacrifice substantial generated-code speed.

Set `MUDLLE_LLVM_TIMING=1` to report each cache miss's IR bytes and wall time
for preparation/parsing/input verification, optimization/output verification,
and native code generation/linking. These timings exclude frontend source
compilation and IR generation; the native stage combines code generation and
linking because ORC performs both during symbol lookup. Cache hits bypass
these stages. All compilation remains on the calling thread.

Reproduce the serial pipeline comparison (fresh processes, cache disabled):

    make USE_LLVM=yes
    perl regression/benchmark-llvm-pipelines.pl --llvm . --runs 3 \
      --timing --output /tmp/mudlle-llvm-pipelines.json

The runner checks compiler-load evaluation and the 100-million-iteration
kernel result. Timing diagnostics run separately from benchmark samples.

Three serial samples on the same LLVM build, with native caching disabled:

| Pipeline | Compiler startup median (s) | Kernel CPU median (ms) |
|----------|-----------------------------|------------------------|
| O2, verify every pass | 57.188005 | 42 |
| O2, verify boundaries (new default) | 8.386301 | 42 |
| O1, verify boundaries | 7.421044 | 39 |
| fast, verify boundaries | 6.332871 | 372 |
| none, verify input | 5.934399 | 392 |

Removing per-pass verification improves this startup workload by about 6.8x
while retaining O2 and boundary verification. The unchanged kernel median is
one-workload evidence, not proof of general execution performance. These new
measurements are not directly comparable to the earlier x64/cache report's
absolute times. Samples and build fingerprints are recorded in
`doc/benchmarks/2026-10-11-llvm-pipelines.json`.

Separate stage diagnostics cover 22 modules and 20,055,462 bytes of IR.
Median O2 optimization time falls from 50.932117 s with per-pass verification
to 2.513848 s with boundary verification; native code generation/linking stays
at about 4.85 s. Preparation/parsing/input verification takes about 0.31 s.
These measurements do not isolate frontend IR generation.

After verifier-error resource cleanup, three samples on the final executable
confirm default O2 startup at 8.341119 s and kernel execution at 38 ms median.
That final build's fingerprints and samples are saved separately in the same
report, alongside one diagnostic run measuring the remaining process time.

Final LLVM 19 validation passes `regression/all.mud` with both `xc.mud` and
`icxc.mud`, on cold and warm caches. Source runs record 4,405 misses then 4,405
hits; compiled runs record 4,426 misses then 4,426 hits, with zero misses on
both warm runs. The cache ABI tests and native cache integration tests pass,
including malformed IR rejection with per-pass verification disabled and
separate `fast` cache entries. This change does not revalidate LLVM 14 or
ARM64/RISC-V execution.

Persistent LLVM Object Cache
----------------------------
LLVM saves ORC's relocatable native objects in `.mudlle-llvm-cache` and reuses
them across restarts. A miss uses the normal O2 pipeline; a hit skips IR parsing,
optimization and machine-code generation while preserving O2 execution.
Serialized `.obj` files still contain IR and GC-rooted constants.

Set `MUDLLE_LLVM_CACHE=/absolute/path` to choose a private cache directory (its
parent must exist), `MUDLLE_LLVM_CACHE=` to disable persistence, or
`MUDLLE_LLVM_CACHE_TRACE=1` to print hits/misses. Unavailable, mismatched or
damaged entries fall back to compilation. Writes use private files and atomic
rename; there is no automatic eviction.

Keys include relocated IR/entry names, the runtime ABI fingerprint, LLVM
version, target/data layout, CPU/features and optimization settings. Changed
global offsets safely miss. LLVM 19+ isolates stable object symbols in separate
ORC namespaces; older LLVM includes sequence-prefixed symbols in the key.
`doc/llvm-backend.md` describes the implementation and compatibility rules.

Three sequential samples per configuration, fresh processes, warm filesystem
cache, no CPU pinning. The kernel performs 100 million integer-reduction
iterations; its CPU timer starts after compilation and linking. Startup loads
`icxc.mud` and checks `iadd(20,22)`. ARM64 startup uses a compiler bootstrapped
with `MUDLLE_LLVM_OPT=none` (about 127 s on this host); the cache miss/hit rows
were timed with `/usr/bin/time` (3 samples each) rather than the JSON runner.

| Platform / backend | Configuration | Kernel CPU median (ms) | Startup wall median (s) |
|--------------------|---------------|------------------------|-------------------------|
| x86_64, LLVM 19.1.7 | x64 | 83 | 0.029431 |
| x86_64, LLVM 19.1.7 | LLVM O2, cache disabled | 37 | 39.255493 |
| x86_64, LLVM 19.1.7 | LLVM none, cache disabled | 368 | 4.766852 |
| x86_64, LLVM 19.1.7 | LLVM O2, cache miss | 38 | 40.533222 |
| x86_64, LLVM 19.1.7 | LLVM O2, cache hit | 37 | 0.697817 |
| Apple Silicon, LLVM 23.1.3 | LLVM O2, cache disabled | 72 | 6.732600 |
| Apple Silicon, LLVM 23.1.3 | LLVM none, cache disabled | 319 | 5.961800 |
| Apple Silicon, LLVM 23.1.3 | LLVM O2, cache miss | 70 | 6.80 |
| Apple Silicon, LLVM 23.1.3 | LLVM O2, cache hit | 69 | 2.79 |

The x86_64 results predate per-pass verification changes; ARM64 uses source
`229cf29`. Different hosts and LLVM versions prevent a direct regression or ABI
comparison.
Full samples and provenance: `doc/benchmarks/2026-10-11-native-cache.json` and
`doc/benchmarks/2026-10-11-arm64.json`.

Interpreter comparison, same loop as `regression/benchmark.mud` (50,000
iterations x 2,000 runs), three runs each, cache disabled.
`regression/benchmark-interpreter.mud` runs the loop without the compiler.
The x86_64 x64 and interpreter rows come from clean builds; the x86_64 LLVM
rows used an existing LLVM 19.1.7 build that was not rebuilt for this run.

| Platform | Backend | CPU median (ms) | Speedup vs interpreter |
|----------|---------|-----------------|------------------------|
| Apple Silicon, LLVM 23.1.3 | Interpreter | 3024 | 1x |
| Apple Silicon, LLVM 23.1.3 | LLVM none | 283 | ~11x |
| Apple Silicon, LLVM 23.1.3 | LLVM O2 | 63 | ~48x |
| x86_64 (Ryzen 9 7940HS), LLVM 19.1.7 | Interpreter | 2486 | 1x |
| x86_64 (Ryzen 9 7940HS), LLVM 19.1.7 | LLVM none | 407 | ~6x |
| x86_64 (Ryzen 9 7940HS), LLVM 19.1.7 | x64 | 87 | ~29x |
| x86_64 (Ryzen 9 7940HS), LLVM 19.1.7 | LLVM O2 | 40 | ~62x |

Speedups are relative to the interpreter on the same host; absolute times are
not comparable across hosts. On x86_64, LLVM O2 is about 2x faster than the
native x64 backend, while unoptimized LLVM is about 4.7x slower. This is one
tight integer loop, a best case for compiled code rather than a general speed
estimate.

LLVM GC, vector traversal, and guarded fast paths
-------------------------------------------------

Five serial, cache-disabled runs on the same x86_64 host (Linux
7.0.14-22-pve) compared baseline commit
`b0b1b2beb5aa66d2d02acfae08db1af8c0e2f5d8`, the updated LLVM build, and x64.
The source-loader kernels compile and link before their `cpu_ms` timers start.
Medians are milliseconds:

| Workload | Baseline LLVM | Updated LLVM O2 | x64 |
|----------|---------------|-----------------|-----|
| Scalar arithmetic with allocations | 239 | 26 | 12 |
| Vector element traversal | 198 | 5 | 5 |
| Membership, absent | 106 | 42 | 213 |
| Membership, late hit | 110 | 40 | 218 |
| Membership, early hit | 10 | 9 | 4 |

Whole-process wall medians were 0.763 s, 0.214 s, and 0.507 s respectively.
These include runtime and module startup, compilation and linking, and timed
kernel calls; they are not startup-only measurements. LLVM O2 still trails x64
on allocation-heavy work and early membership hits, while it reduces full
membership scans substantially. The stage-one report isolated root-liveness
and SIMD membership changes: they improved scans but did not improve the
allocation workload. The final path adds guarded arithmetic, vector-reference,
and vector-length fast paths, and avoids rooting copied argument slots. These
results are workload-specific and do not establish general backend parity.

The five-run samples and provenance are in
`doc/benchmarks/2026-10-11-llvm-gc-simd.json`. Reproduce with separate baseline,
new LLVM, and x64 build directories from the repository root. Build the
baseline with `make USE_LLVM=yes`, the current checkout with the same command,
and a baseline x64 checkout with `make`. Copy the current
`regression/benchmark-llvm-gc.mud` into both baseline directories first:

    perl regression/benchmark-llvm-gc.pl \
      --baseline /tmp/mudlle-gc-baseline \
      --llvm . \
      --x64 /tmp/mudlle-gc-x64 \
      --runs 5 \
      --output doc/benchmarks/2026-10-11-llvm-gc-simd.json

Inspect generated IR, vectorizer remarks, and the actual cached native object:

    regression/inspect-llvm-simd.sh /tmp/mudlle-simd-inspect

On this host the native membership chunk uses AVX-512 integer comparisons.
Other CPUs use LLVM's host-selected instructions; no fixed ISA is required.

Validation for this change: the three-stage compiler bootstrap completed with
`MUDLLE_LLVM_OPT=none`; `regression/all.mud` reached `SUCCESS` through both
`xc.mud` and `icxc.mud` under O2 with `MUDLLE_LLVM_VERIFY_EACH=1`. The focused
LLVM and fast-path tests also passed with optimization disabled, both cache
test scripts passed, and a clean x64 build passed the full regression suite.

Reproduce kernel/cache measurements on Apple Silicon after building with
Homebrew Bison, Flex, and LLVM:

    make clean && make USE_LLVM=yes
    perl regression/benchmark-backends.pl --arm64 . --runs 3 --kernel-only
Run the focused checks after an LLVM build:

    perl regression/test-llvm-cache-abi.pl
    perl regression/test-llvm-cache.pl

For full LLVM validation, run each loader twice with the same cache directory
and require the final `SUCCESS` sentinel (exit zero alone is insufficient):

    make USE_LLVM=yes
    MUDLLE_LLVM_OPT=none make compiler USE_LLVM=yes
    MUDLLE_LLVM_CACHE=/tmp/mudlle-validation-cache \
      ./mudlle -c 'silent=true' -e xc.mud -e regression/all.mud
    MUDLLE_LLVM_CACHE=/tmp/mudlle-validation-cache \
      ./mudlle -c 'silent=true' -e icxc.mud -e regression/all.mud

Keep LLVM validation and benchmarks serial: ORC modules remain resident until
process exit. Remaining limitations include synthetic callback source metadata,
unsupported `global_syms`, and incompatible x64/LLVM serialized code formats.

LLVM vector allocation continuation (6fd3a18)
--------------------------------------------

The next allocation change keeps the existing shadow roots and single-threaded
runtime. Vector construction now checks available aligned heap space: the
noncollecting path fills a new record directly from caller arguments; the
collecting fallback copies and roots them before allocation. Both fully
initialize uninitialized records and retain actual-child immutability checks.
The shared GC regression now checks identity and contents of movable children
through 100,000 vector constructions, explicit collections and error unwinding.

Five serial, cache-disabled samples on Linux x86_64, GCC 14.2.0 / LLVM 19.1.7,
compare fresh builds of `6fd3a18090f68e26028752811eda6c6e781faa2b` with the
modified LLVM runtime and x64 from the same commit. CPU medians in ms:

| Workload | 6fd3a18 LLVM O2 | Updated LLVM O2 | x64 |
|----------|----------------|-----------------|-----|
| Scalar arithmetic with allocations | 25 | 18 | 12 |
| Vector element traversal | 5 | 5 | 5 |
| Membership, absent | 40 | 40 | 223 |
| Membership, late hit | 44 | 42 | 197 |
| Membership, early hit | 10 | 10 | 3 |

Allocation CPU time falls 28%, but remains 1.5x x64 on this workload.
Whole-process wall medians are 0.209428 / 0.201943 / 0.501434 s; they include
compilation and are not startup-only timings. No CPU pinning or filesystem
cache flush was used. Initial samples overlapping validation were discarded.
Samples, host information and source/binary hashes are recorded in
`doc/benchmarks/2026-10-11-llvm-vector-allocation.json`.

Reproduce using isolated source directories under `/tmp` (no Git worktree
metadata writes needed). From the repository root:

    mkdir -p /tmp/mudlle-alloc-baseline /tmp/mudlle-alloc-x64
    git archive 6fd3a18 | tar -x -C /tmp/mudlle-alloc-baseline
    git archive 6fd3a18 | tar -x -C /tmp/mudlle-alloc-x64
    make -C /tmp/mudlle-alloc-baseline USE_LLVM=yes
    make -C /tmp/mudlle-alloc-x64
    make USE_LLVM=yes
    perl regression/benchmark-llvm-gc.pl \
      --baseline /tmp/mudlle-alloc-baseline --llvm . \
      --x64 /tmp/mudlle-alloc-x64 --runs 5 \
      --output /tmp/mudlle-vector-allocation.json

LLVM statepoints could reduce escaping root-slot traffic by representing live
heap references and their relocated SSA values at collecting calls. They need
tagged-value representation work, ORC stack-map registration for cache misses
and hits, native/C stack traversal and compatible error unwinding. They do not
remove allocation or mandatory spills. Keep explicit roots for this change;
no statepoint performance improvement is claimed. The implementation assessment
and a proposed validation scope are in `doc/llvm-backend.md`, with references
to LLVM's statepoint documentation.

Validation on LLVM 19: the full source suite reaches `SUCCESS` under O2 and
`none`; the rebuilt compiled compiler reaches `SUCCESS` on cold and warm O2
caches with per-pass verification enabled. The cold compiled run records 4,437
misses and zero hits; the warm run records 4,437 hits and zero misses. The
three-stage bootstrap completes with optimization disabled. Both cache test
scripts pass, and x64's full source suite passes with the new shared GC test.
No new LLVM 14, ARM64 or RISC-V execution validation was performed.

Reproduce the validation serially, requiring the final `SUCCESS` line for each
suite (exit zero alone does not establish success):

    MUDLLE_LLVM_CACHE= ./mudlle -c 'silent=true' -e xc.mud -e regression/all.mud
    MUDLLE_LLVM_OPT=none MUDLLE_LLVM_CACHE= \
      ./mudlle -c 'silent=true' -e xc.mud -e regression/all.mud
    MUDLLE_LLVM_OPT=none make compiler USE_LLVM=yes
    MUDLLE_LLVM_CACHE=/tmp/mudlle-alloc-validation-cache \
      MUDLLE_LLVM_CACHE_TRACE=1 MUDLLE_LLVM_VERIFY_EACH=1 \
      ./mudlle -c 'silent=true' -e icxc.mud -e regression/all.mud

Repeat the last command for a warm-cache run; use a fresh cache directory for
the cold run. Run both cache scripts listed above. Copy the updated
`regression/gc.mud` into the x64 source directory, then run its full suite with
`xc.mud`. Benchmark report validation entries record commands, final sentinels,
exit statuses, cache counts and log hashes.

LLVM allocation and root-slot profiling continuation (31f7662)
-------------------------------------------------------------

Fresh LLVM 19.1.7 and x64 builds from `31f7662` were measured serially on the
same Ryzen 9 7940HS / GCC 14.2.0 Linux host. Each kernel is compiled and linked
before its CPU timer starts. Five fresh, cache-disabled processes per backend
run ten calls of one million iterations per case. Allocating cases construct
the same four-integer vector every iteration and consume its elements; paired
controls compute those integers directly. Both validate accumulated results.
The 1/4/16-reference cases also retain distinct heap vectors across allocation.

CPU medians, in milliseconds for ten million iterations:

| Incoming heap references | LLVM control | LLVM allocation | x64 control | x64 allocation |
|--------------------------|--------------|-----------------|-------------|----------------|
| 0 | 7 | 205 | 13 | 117 |
| 1 | 26 | 240 | 24 | 144 |
| 4 | 91 | 304 | 92 | 211 |
| 16 | 364 | 647 | 368 | 505 |

Controls perform the same reference element reads and accumulation. They do
not allocate on the successful path, but retain conservative shadow roots for
arithmetic/indexing fallbacks. Allocation-minus-control includes allocation,
collection, scratch indexing, type checks, and optimizer effects; it is not an
isolated root-slot cost. Most of the LLVM deficit is already present with zero
incoming heap references. Root-heavy controls are close to x64 in this mode.

A second mode replaces each reference element read with a non-null identity
comparison yielding the same integer. It removes the growing element-read/type
checking work while keeping heap references live across allocation. This is an
overhead probe, not a moving-GC correctness test. Its CPU medians are:

| Incoming heap references | LLVM control | LLVM allocation | x64 control | x64 allocation |
|--------------------------|--------------|-----------------|-------------|----------------|
| 0 | 8 | 242 | 12 | 123 |
| 1 | 9 | 216 | 15 | 124 |
| 4 | 16 | 249 | 32 | 124 |
| 16 | 42 | 245 | 112 | 202 |

The LLVM allocating identity case has no clear increase from zero to sixteen
incoming references. O2 IR confirms that the sixteen-reference case publishes
20 roots and reloads references inside the loop, compared with four published
roots in the zero-reference allocation case. Registration is at function entry,
not on every loop iteration. With element reads instead, the corresponding
frames contain 36 and four roots; loaded element temporaries can also be
potential heap values. Cache-captured native disassembly confirms the 20-root
registration and the out-of-line allocation/type helpers.

Hardware `perf` counters and sampling were denied by the host's
`perf_event_paranoid=4`, including an outside-sandbox retry. Separate `gcc -pg`
builds provide a limited C profile: LLVM type helpers account for 0.95 s of
1.51 s attributed to executable text; root registration has zero sampled self
time at 10 ms resolution. The x64 profile attributes much of its executable
text time to indexing builtins. These whole-process instrumented profiles omit
dynamic JIT code/libLLVM attribution, distort timing, and have incomplete JIT
call counts. They cannot assign a percentage of total CPU to root loads.

Decision: keep explicit roots and defer a statepoint prototype. These probes
do not establish root-slot traffic as the dominant remaining allocation cost.
Investigate the common vector allocation/scratch access/type-helper path next;
repeat profiling on a host allowing JIT-aware sampling before replacing the GC
ABI. No runtime, generator, cache format, error-unwinding, or threading changes
were made. No statepoint speedup or broader backend parity is claimed.

Reports include individual samples, source/binary hashes and toolchain details:
`doc/benchmarks/2026-10-11-llvm-roots.json`,
`doc/benchmarks/2026-10-11-llvm-root-slots.json`, and
`doc/benchmarks/2026-10-11-llvm-roots-profile.json`. No CPU affinity or filesystem
cache flush was used; differences of a few milliseconds are within sample
variation. Measurements were separate from validation.

Reproduce using fresh directories (the archive preserves the exact runtime
baseline, while the current benchmark is copied into each):

    mkdir -p /tmp/mudlle-roots-llvm /tmp/mudlle-roots-x64
    git archive 31f7662 | tar -x -C /tmp/mudlle-roots-llvm
    git archive 31f7662 | tar -x -C /tmp/mudlle-roots-x64
    make -C /tmp/mudlle-roots-llvm USE_LLVM=yes -j4
    make -C /tmp/mudlle-roots-x64 -j4
    cp regression/benchmark-llvm-roots.mud /tmp/mudlle-roots-llvm/regression/
    cp regression/benchmark-llvm-roots.mud /tmp/mudlle-roots-x64/regression/
    perl regression/benchmark-llvm-roots.pl \
      --llvm /tmp/mudlle-roots-llvm --x64 /tmp/mudlle-roots-x64 \
      --runs 5 --output /tmp/mudlle-roots.json
    perl regression/benchmark-llvm-roots.pl --identity-only \
      --llvm /tmp/mudlle-roots-llvm --x64 /tmp/mudlle-roots-x64 \
      --runs 5 --output /tmp/mudlle-root-slots.json
    perl regression/inspect-llvm-roots.pl \
      --llvm /tmp/mudlle-roots-llvm --output /tmp/mudlle-roots-inspect
    perl regression/inspect-llvm-roots.pl --identity-only \
      --llvm /tmp/mudlle-roots-llvm --output /tmp/mudlle-root-slots-inspect

The inspector writes emitted/O2 IR, a fresh private native cache, extracted
relocatable objects, and `objdump -dr` output. It requires `opt-19`, `llvm-config`
and `objdump`; set `LLVM_OPT` to select a matching alternative optimizer. The
standalone O2 IR uses the host triple, while cached objects use ORC's host CPU
settings. Use distinct output directories for different inspection modes.

For C profiling, create another fresh archive, build with
`make USE_LLVM=yes CC='gcc -pg' -j4`, copy the benchmark as above, and run:

    cd /tmp/mudlle-roots-gprof
    MUDLLE_LLVM_CACHE= MUDLLE_LLVM_OPT=O2 \
      ./mudlle -c 'silent=true' -e xc.mud -e regression/benchmark-llvm-roots.mud
    gprof ./mudlle gmon.out > profile.txt

For x64 omit `USE_LLVM=yes` in its separate fresh build. Do not use instrumented
CPU timings as ordinary benchmark samples.

Validation of the baseline used here: both fresh builds' complete source
`regression/all.mud` suites reach `SUCCESS`; LLVM's cache ABI tests pass all ten
checks and its native-cache integration script passes. This includes the shared
moving-child/collection/error-unwinding regression. The runtime remains single
threaded. This profiling-only change does not repeat compiler bootstrap,
compiled-loader suites, LLVM 14, ARM64, or RISC-V validation.

Contact Information
-------------------

You can contact me at dgay@acm.org.
