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
`doc/llvm-backend.md` documents the LLVM backend, and
`doc/llvm-backend-handoff.md` lists its open work and validation steps.


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
    make -j8 compiler USE_LLVM=yes                 # three-stage LLVM bootstrap, default O2

Parallel builds run independent single-threaded Mudlle processes. Use `-j4`
or `-j8` to compile the compiler faster while retaining O2.

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
Comparison: this branch's LLVM backend against upstream x64 master
[`99a6a18`](https://github.com/nschimme/mudlle/commit/99a6a18b0145f45c326555ae23145eeab16b08cc).
The AMD Ryzen 9 7940HS host ran Linux 7.0.14, GCC 14.2.0 and LLVM 19.1.7.
Mudlle is single threaded; LLVM kernels use `default<O2>`. The native object
cache was disabled, but filesystem caches were not flushed.

Each row reports the per-backend median CPU milliseconds per sample, followed
by the median of the 31 paired LLVM/x64 ratios and its deterministic bootstrap
95% interval. Lower ratios favor LLVM. There were 31 fresh-process pairs and
100 timed calls per workload, except the integer loop, which used 2,000 calls.
Ratios and intervals are rounded to three decimals.

| Workload | LLVM ms | x64 ms | Paired ratio | 95% interval |
|----------|--------:|-------:|-------------:|-------------:|
| Floating point primitives (100,000 steps) | 525 | 2,610 | 0.201 | 0.199–0.204 |
| Integer loop (50,000 steps; 2,000 calls) | 40 | 88 | 0.453 | 0.448–0.460 |
| Native list/vector conversion, width 32 | 346 | 444 | 0.774 | 0.759–0.788 |
| Native list/vector conversion, width 257 | 611 | 697 | 0.862 | 0.855–0.877 |
| Mixed bigint/float (20,000 steps) | 718 | 794 | 0.914 | 0.893–0.928 |
| Tables, 32 keys | 164 | 177 | 0.936 | 0.918–0.958 |
| Recursive local closure, `fib(27)` | 221 | 235 | 0.936 | 0.919–0.956 |
| Tables, 257 keys | 183 | 192 | 0.948 | 0.920–0.984 |
| Bigint primitives (20,000 steps) | 1,185 | 1,166 | 1.009 | 0.995–1.026 |
| Library list/vector round trip, width 32 | 3,354 | 3,276 | 1.025 | 1.007–1.031 |
| Local closure loop (2,000,000 iterations) | 584 | 587 | 1.002 | 0.985–1.022 |

The library conversion remains 2.5% slower on LLVM in this sample, with an
interval of 0.7% to 3.1% slower. The bigint and closure-loop intervals include
1. These intervals describe these builds and workloads on this shared host;
the bootstrap resamples paired-round log-ratios 5,000 times with seed
20261012 and assumes round pairs are independent and identically distributed.
They do not establish general platform parity. No ARM64, RISC-V or LLVM 14
measurements or validation are included.

Timers sum `ctime()` only across kernel calls. Compilation, warmup, numeric
reference calculations, explicit collection stress, and post-call checks are
outside the timers; table and sequence identity/content guards remain inside
their timed loops. Timed loops keep ordinary loop accounting. The library
conversion calls interpreted library closures; native conversions compile
the equivalent loops locally. The report includes every sample and checksum,
statistical summaries, and build fingerprints in
[`doc/benchmarks/2026-10-12-final.json`](doc/benchmarks/2026-10-12-final.json).

To reproduce the full comparison, build this branch's LLVM tree with
`make USE_LLVM=yes` and `make -j8 compiler USE_LLVM=yes`. Build upstream master
`99a6a18` with `make` and `make -j8 compiler`, and copy this branch's regression
files into that tree; its compiler, runtime and libraries remain upstream.
The report identifies the measured LLVM source snapshot by its base revision
and source hashes. Then run:

    perl regression/benchmark-rich-backends.pl --llvm <llvm-tree> \
      --x64 <upstream-master-x64-tree> --suite all --runs 31 \
      --timed-calls 100 \
      --llvm-revision "$(git -C <llvm-tree> rev-parse HEAD)" \
      --x64-revision 99a6a18b0145f45c326555ae23145eeab16b08cc \
      --output doc/benchmarks/2026-10-12-final.json

The runner checks each workload against its reference and requires its success
marker before recording a sample.

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
