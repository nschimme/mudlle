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
`doc/mudlle-ref.doc` are the introduction and reference.
The LLVM backend is summarized below and documented in
[`doc/llvm.md`](doc/llvm.md); history lives in
[`doc/llvm-backend-handoff.md`](doc/llvm-backend-handoff.md).


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
Versus the x64 backend on `master`, the front-end and shared `ins3`
instruction pipeline are unchanged. The x64 machine-code emitter and `mcode`
loader are replaced by LLVM IR generation (`genllvm.mud`) and ORC LLJIT
loading (`runtime/llvm.c`), optimized at O2 by default.

- **Mudlle-specific fast paths:** checked tagged-integer ops, unboxed
  floating-point chains, direct known-function and primitive calls, and
  guarded vector access and construction, with runtime fallbacks for type,
  error and security behavior.
- **GC:** explicit shadow roots for the moving collector.
- **Persistent cache:** relocatable native objects are cached across processes.
- **Portability:** LLVM is the only compiler on ARM64 and RISC-V. On x86-64,
  x64 stays the default and `llvmc.mud` selects LLVM.
- **Formats:** LLVM and x64 prelinked objects are not interchangeable.

Design, environment variables, cache rules, IR inspection and validation:
[`doc/llvm.md`](doc/llvm.md).


Benchmarks
----------
LLVM (this branch) against upstream x64 master
[`99a6a18`](https://github.com/nschimme/mudlle/commit/99a6a18b0145f45c326555ae23145eeab16b08cc):
median CPU ms over 31 single-threaded process samples each, AMD Ryzen 9
7940HS, Linux 7.0.14, GCC 14.2.0, LLVM 19.1.7, O2, object cache disabled.
Negative is faster on LLVM; the interval is a bootstrapped 95% CI.

| Workload | LLVM ms | x64 ms | CPU time vs x64 | 95% interval |
|----------|--------:|-------:|----------------:|-------------:|
| Floating point primitives (100,000 steps) | 526 | 2,610 | -79.8% | -80.5% to -79.4% |
| Integer loop (50,000 steps; 2,000 calls) | 40 | 88 | -54.5% | -55.7% to -53.4% |
| Native list/vector conversion, width 32 | 370 | 444 | -16.7% | -18.8% to -14.3% |
| Native list/vector conversion, width 257 | 599 | 697 | -14.1% | -15.5% to -11.7% |
| Mixed bigint/float (20,000 steps) | 729 | 794 | -8.2% | -9.7% to -6.5% |
| Tables, 32 keys | 160 | 177 | -9.6% | -11.7% to -5.7% |
| Recursive local closure, `fib(27)` | 214 | 235 | -8.9% | -9.7% to -4.7% |
| Tables, 257 keys | 182 | 192 | -5.2% | -9.1% to -1.1% |
| Local closure loop (2,000,000 iterations) | 583 | 587 | -0.7% | -1.4% to +2.4% |
| Library list/vector round trip, width 32 | 3,329 | 3,276 | +1.6% | +0.5% to +2.8% |
| Bigint primitives (20,000 steps) | 1,192 | 1,166 | +2.2% | +0.8% to +3.0% |

Nine of eleven workloads have a lower LLVM median (floating point -80%,
integer loops -55%); library list/vector conversion and bigint primitives are
2% slower, and the closure loop is within noise. This is an unpaired same-host
comparison on x86-64 only. ARM64 was measured against the interpreter on
macOS 27.0 ARM64 (Apple Clang 21, LLVM 23.1.3, O2). Values are
median CPU milliseconds over three fresh-process rounds per backend; negative
is faster for LLVM. Workloads, iteration counts, timed calls, and result checks
match the amd64 suite. The interpreter executes the same kernel bodies as
interpreted closures.

| Workload | LLVM ms | Interpreter ms | CPU time vs interpreter | 95% interval |
|----------|--------:|---------------:|------------------------:|-------------:|
| Floating point primitives (100,000 steps) | 485 | 13,158 | -96.3% | -96.3% to -96.3% |
| Integer loop (50,000 steps; 2,000 calls) | 63 | 6,746 | -99.1% | -99.1% to -99.1% |
| Native list/vector conversion, width 32 | 423 | 9,284 | -95.4% | -95.5% to -95.4% |
| Native list/vector conversion, width 257 | 619 | 13,490 | -95.4% | -95.4% to -95.4% |
| Mixed bigint/float (20,000 steps) | 998 | 2,125 | -53.0% | -53.3% to -53.0% |
| Tables, 32 keys | 614 | 2,354 | -73.9% | -74.0% to -73.7% |
| Recursive local closure, `fib(27)` | 188 | 4,894 | -96.2% | -96.2% to -96.2% |
| Tables, 257 keys | 679 | 2,374 | -71.4% | -71.5% to -71.3% |
| Local closure loop (2,000,000 iterations) | 476 | 21,385 | -97.8% | -97.8% to -97.8% |
| Library list/vector round trip, width 32 | 7,919 | 1,054 | +650.6% | +649.9% to +654.0% |
| Bigint primitives (20,000 steps) | 1,707 | 2,423 | -29.6% | -29.7% to -29.5% |

The intervals are paired bootstrap 95% intervals from these three rounds, so
they are coarse. RISC-V and LLVM 14 results are unavailable.
Methodology and reproduction: [`doc/benchmark.md`](doc/benchmark.md).


Contact Information
-------------------

You can contact me at dgay@acm.org.
