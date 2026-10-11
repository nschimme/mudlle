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

  sudo apt install build-essential flex bison python3 libgmp-dev libreadline-dev llvm llvm-dev

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
    python3 regression/benchmark-llvm-pipelines.py --llvm . --runs 3 \
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

Reproduce kernel/cache measurements on Apple Silicon after building with
Homebrew Bison, Flex, and LLVM:

    make clean && make USE_LLVM=yes
    python3 regression/benchmark-backends.py --arm64 . --runs 3 --kernel-only
Run the focused checks after an LLVM build:

    python3 regression/test-llvm-cache-abi.py
    python3 regression/test-llvm-cache.py

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

Contact Information
-------------------

You can contact me at dgay@acm.org.
