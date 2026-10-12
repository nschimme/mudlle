mudlle: MUD Language for Little Extensions
------------------------------------------

This software is Copyright (C) 1993-2012 David Gay and Gustav Hållberg.
Read the COPYRIGHT file for terms of use.


Introduction
------------
mudlle is a small language for writing extensions to MUME, an online
multi-user game. It is heavily inspired by Scheme. This distribution contains
a stand-alone interpreter and compiler with an interpreter, a native x86-64
backend and an LLVM backend.

    ./mudlle
    mudlle> 2+3
    Result: 5

EOF (Ctrl-D) or `quit()` exits. `doc/mudlle-intro.doc` and
`doc/mudlle-ref.doc` are the introduction and reference;
`doc/llvm-backend.md` documents the LLVM backend.


Build
-----
Linux (Debian/Ubuntu):

    sudo apt install build-essential flex bison perl libgmp-dev libreadline-dev llvm llvm-dev

macOS (Homebrew; Apple's bison is too old, so put Homebrew's first):

    brew install llvm flex bison
    export PATH="$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$(brew --prefix llvm)/bin:$PATH"

The build finds LLVM through `llvm-config`; keep its headers, C API library and
`llvm-config` from one installation. Build one backend at a time from a clean
tree, since the compiler objects are backend-specific:

    make clean && make && make compiler            # native x64
    make clean && make USE_LLVM=yes                # LLVM (ORC LLJIT)
    make compiler USE_LLVM=yes                     # three-stage LLVM bootstrap

On ARM64 and RISC-V the LLVM backend is the only compiler. Without LLVM the
interpreter remains available.

Test (each build should print `SUCCESS`):

    ./mudlle -e xc.mud -e regression/all.mud


LLVM backend
------------
`load("xc.mud")` selects the LLVM backend on ARM64 and RISC-V; on x86-64 it
keeps the x64 compiler, and `llvmc.mud` selects LLVM. Use a fresh process per
backend when comparing. To get IR text for a function:

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

The persistent cache stores relocatable native objects. A hit skips IR parsing,
optimization and code generation. Keys cover the IR, runtime ABI, LLVM version,
target, CPU features and optimization settings; unusable entries fall back to
compilation. Writes are atomic; there is no automatic eviction. The cache and
compatibility rules are described in `doc/llvm-backend.md`.


Benchmarks
----------
Host: AMD Ryzen 9 7940HS, Linux 7.0.14, GCC 14.2.0, LLVM 19.1.7, single
threaded. LLVM runs `default<O2>`. The host was shared: load average was 5 to 7
during the runs, so treat differences under about 10% as noise.

Median CPU milliseconds per kernel (see below), lower is better; ratio is
LLVM / x64. Both backends are built from the same commit. Each kernel is
compiled and linked before its timer starts, and every result is checked
against an independent reference. Rich suite: 9 fresh-process rounds of 5
timed runs; the other kernels: 9 processes, alternating backends.

| Workload | LLVM | x64 | LLVM / x64 |
|----------|-----:|----:|-----------:|
| Floating point (100,000 steps per call) | 35 | 136 | 0.26 |
| Integer loop (50,000 x 2,000) | 42 | 90 | 0.47 |
| Native list/vector conversion, width 257 | 28 | 34 | 0.82 |
| Native list/vector conversion, width 32 | 19 | 20 | 0.95 |
| Mixed bigint/float | 43 | 44 | 0.98 |
| Library list/vector round trip, width 32 (interpreted `misc.mud`) | 166 | 163 | 1.02 |
| Bigint (20,000 steps per call) | 69 | 62 | 1.11 |
| Tables, 257 keys | 13 | 10 | 1.30 |
| Tables, 32 keys | 12 | 9 | 1.33 |
| Recursive local closure, `fib(27)` | 21 | 11 | 1.91 |
| Local closure called in a loop (2,000,000 iterations per call) | 62 | 30 | 2.07 |

Notes:

- Conversions copy list/vector containers, mutate scalar slots and shared
  children, and run native loops; the library row calls the library closures,
  which run interpreted in both builds.
- Float and bigint use the explicit `f*` / `bi*` primitives (what
  `#arith(f)` and `#arith(b)` expand to); nested `fadd`/`fsub`/`fmul`/`fdiv`/`fneg`/`fabs`/`fsqrt`
  stay unboxed within a basic block. Bigint and mixed bigint/float are
  interleaved-run medians because the rich suite differed by over 10%.
- LLVM calls statically known functions directly, inlines small ones
  (`alwaysinline`) and caches shared closures in rooted per-function slots;
  each call still builds a call frame and saves and restores the security
  level, which is the main remaining gap on call-heavy code.
- `cpu_ms` is `ctime()` summed over the timed calls: 5 calls per kernel (the
  integer loop is 2,000 calls); compilation and JIT startup are excluded. The
  startup cost of compiling the compiler under LLVM is not measured here.
- No ARM64, RISC-V or LLVM 14 benchmarks or validation are included.

Samples, parameters and build fingerprints are in
`doc/benchmarks/2026-10-12-final.json`.

Reproduce (build both trees from the same commit; `<x64>` is the plain-`make`
tree, with the benchmark files copied into its `regression/` directory):

    make USE_LLVM=yes
    perl regression/benchmark-rich-backends.pl --llvm . --x64 <x64> --runs 9 \
      --output /tmp/mudlle-bench.json
    for f in benchmark benchmark-calls; do
      MUDLLE_LLVM_CACHE= ./mudlle -c 'silent=true' -e xc.mud -e regression/$f.mud
      (cd <x64> && ./mudlle -c 'silent=true' -e xc.mud -e regression/$f.mud)
    done

`benchmark-rich-backends.pl --suite numeric|sequences|tables` runs one suite.
Require the final `SUCCESS` marker, not just a zero exit status.

Validation for a change to the LLVM backend (serial; the bootstrap and the
compiled-loader runs catch relocation and GC-rooting bugs that the single
session source suite does not):

    MUDLLE_LLVM_CACHE= ./mudlle -c 'silent=true' -e xc.mud -e regression/all.mud
    MUDLLE_LLVM_OPT=none MUDLLE_LLVM_CACHE= make compiler USE_LLVM=yes
    perl regression/test-llvm-cache-abi.pl
    perl regression/test-llvm-cache.pl
    MUDLLE_LLVM_VERIFY_EACH=1 MUDLLE_LLVM_CACHE_TRACE=1 ./mudlle \
      -c 'silent=true' -e icxc.mud -e regression/all.mud    # cold, then warm


Contact Information
-------------------

You can contact me at dgay@acm.org.
