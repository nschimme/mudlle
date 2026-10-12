# LLVM backend parity handoff

Goal: LLVM at or ahead of upstream x64 on every README workload. Remove this
file when that goal is reached. Current measurements and reproduction commands
are in `README.md`; the compact upstream x64 sample fixture is
`doc/benchmarks/x64-baseline.json`, and the raw reused-baseline report remains
outside Git under `/tmp`.

## Remaining gap

The latest O2 comparison used 31 fresh LLVM samples from branch base
`e073c62f3f1c0b629852fbba6632ffc5e331938d` against the 31 unchanged x64
samples recorded from upstream master `99a6a18b0145f45c326555ae23145eeab16b08cc`.
The x64 run was 2026-10-12 15:00–15:10 UTC; LLVM ran 15:40–15:44 UTC. The
unpaired bootstrap leaves two slowdowns: library list/vector conversion is
1.6% slower on LLVM (95% interval +0.5% to +2.8%), and bigint primitives are
2.2% slower (+0.8% to +3.0%). The other nine workloads have lower LLVM
medians; the closure-loop interval spans zero. This comparison uses independent
backend medians and does not capture temporal drift between the two run
windows, so parity is not established.

Library conversion calls interpreted `misc.mud`/`sequences.mud` closures from
a compiled loop. `llvm_call_fallback` now detects interpreted closures and
copies protected arguments directly to the interpreter stack after reserving
space, avoiding the temporary argument vector. The closure and copied values
remain rooted in the fallback, while the generated caller frame also roots
its live values; removing that duplicate root chain is one remaining cost to
measure. Keep the reference report and run timestamps attached to future
comparisons, and do not pair these reused x64 rounds with later LLVM rounds.

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

The current generator/runtime passed source suites at O2 and `none`, a clean
O2 `make -j8 compiler USE_LLVM=yes` bootstrap, and compiled-loader cold/warm O2
suites with `MUDLLE_LLVM_VERIFY_EACH=1`: 4,464 misses followed by 4,464 warm
hits and no misses. Cache ABI/integration checks, known-call stress and
diagnostic tests passed. The refreshed branch x64 runtime build and both source
and compiled `regression/all.mud` suites passed.

Run future build/regression checks separately from measurements. Use upstream
master x64 for performance and branch x64 for regression checks. Reuse the
recorded upstream baseline while its build and workloads remain unchanged;
collect fresh serial LLVM samples with O2 and native caching disabled. Compare
the samples independently, retaining the temporal-drift limitation. Record
exact revisions and source/binary hashes. Require result checks and
completion markers rather than exit status alone. See the README for the
31-round, 100-call command and statistical limitations.
