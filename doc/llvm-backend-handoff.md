# LLVM backend parity handoff

Goal: LLVM at or ahead of upstream x64 on every README workload. Remove this
file when that goal is reached. Current measurements and reproduction commands
are in `README.md`; raw samples are in `doc/benchmarks/2026-10-12-final.json`.

## Remaining gap

The 31-pair O2 comparison against upstream master
`99a6a18b0145f45c326555ae23145eeab16b08cc` leaves one measurable slowdown:
`list-vector-library-32`, paired LLVM/x64 ratio 1.025, bootstrap 95% interval
[1.007, 1.031]. The other ten workloads are faster or have intervals spanning
1. Library conversion calls interpreted `misc.mud`/`sequences.mud` closures
from a compiled loop. Inspect `llvm_call_value` and `llvm_call_fallback` in
`runtime/llvm.c`: the fallback allocates an argument vector before `callv`.
x64's `builtin_call_interpreter` passes protected arguments directly to the
interpreter stack. Measure a bridge change independently before adopting it.

## Current implementation and invariants

Read `doc/llvm-backend.md`, `doc/gc.md`, and the x64 generator before changing
GC or call behavior. Mudlle is single threaded; `make -j4` or `make -j8`
parallelizes separate processes while retaining O2.

- Keep the moving-GC shadow roots and complete `call_llvm` frames. The frame's
  `fn` field owns the closure; generated code reloads it after allocation.
- Scalar root elision requires emitted dominating integer checks or the
  conservative all-definition proof. Recursive scalar results require every
  normal return to be scalar. Heap arguments and results remain rooted.
- Plain fixed-arity primitive constants pass scalar arguments directly, with
  type/arity guards and the existing generic fallback. Primitive wrappers
  enforce security as on x64; preserve secure-call and global-relocation paths.
- Closure-cache initialization roots the parent and argument metadata before
  allocating. Vararg entry reloads the closure before reading float constants.
- Keep hardcoded layout assertions, trace arguments, error unwinding, loop
  accounting, and cache ABI fingerprints intact. Readonly does not imply
  immutable: immutable objects must contain only immutable values.

## Validation and measurement

The current generator/runtime passed clean O2 and `none` bootstraps, source
suites, and per-pass-verified compiled-loader cold/warm suites. Each cold loader
recorded 4,457 misses, followed by 4,457 warm hits and no misses. Cache ABI and
integration tests, all three known-call stress scripts, baseline error traces,
and exact vector loop accounting passed. Branch x64 and upstream x64 passed
source and compiled suites; the current branch regression suite also passed
on upstream master, with LLVM-only tests skipped by its architecture guard.

Run future build/regression checks separately from measurements. Use upstream
master x64 for performance and branch x64 for regression checks. Run O2
benchmarks in alternating fresh serial processes with native caching disabled;
record exact revisions and source/binary hashes. Require result checks and
completion markers rather than exit status alone. See the README for the
31-round, 100-call command and statistical limitations.
