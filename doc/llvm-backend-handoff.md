# LLVM backend: working notes for the next contributor

Branch `llvm-backend-parity`. Goal: the LLVM backend at or ahead of x64 on the
README benchmarks. The current numbers are in the README table; the design is
in `doc/llvm-backend.md`. This file is what is not obvious from either.

## Where things stand

Ahead of x64: integer loop, native list/vector conversions, floating point
(nested `fadd`/`fsub`/`fmul`/`fdiv`/`fneg`/`fabs`/`fsqrt` stay raw doubles
within a basic block). Parity: library round trip, bigint, mixed bigint/float.
Behind: tables (1.3x to 1.4x), recursive `fib(27)` and a local closure called in
a loop (both about 1.6x).

## Remaining work, largest first

1. **Skip the `call_llvm` frame for leaf callees.** x64 pushes no per-call
   frame: `error.c` walks the machine stack lazily. Here every known call
   builds a 7-word frame (`mudlle_call_known`). A leaf callee could build it
   only on slow paths, but then the callee needs its own closure (today only
   the caller has it) and the GC and `error.c` must still see a complete frame
   at the moments they run. Highest gain, highest risk.
2. **Pass arguments in registers** through a direct entry beside the
   `(env, argv, nargs)` bridge; point the frame's `native_args` at the callee's
   own rooted slots.
3. **Make the closure argument optional** for capture-free callees (it only
   fills the frame's `fn` field).
4. **Tables:** call primitive function pointers directly; what is left is the
   security-level save/restore and the call.
5. **Float:** keep loop-carried named float locals as doubles with the type
   check hoisted to loop entry; inline the bump allocation in
   `llvm_box_float`. SIMD was investigated and is not worth pursuing: the
   kernel is a serial recurrence over boxed values.

## Rules that are easy to break

- Immutable objects are promoted and never rescanned: never mutate one after
  creation. Any pointer held across an allocation needs a root.
- A `call_llvm` frame with `offset == -2` owns its argument array and
  `alloc.c` forwards `native_args` for it; frames from `llvm_invoke_closure`
  have the array rooted by the caller. `error.c` prints `native_args` in
  backtraces, so they must stay valid.
- Generated IR hardcodes layouts (type byte at +9, flags +10, closure code +16,
  float payload +16, code seclevel +58, `call_stack_mudlle` 56 bytes,
  `call_llvm == 11`). Keep the `_Static_assert`s in `runtime/llvm.c` in sync.
- `mudlle_call_known` does not touch `internal_seclevel`: every call out of
  generated code sets it from the calling closure's own code first
  (`llvm_call_value`, `llvm_call_global`, `llvm_call_global_constant`).
  `regression/llvm-known-call-seclevel.mud` checks it, but only at level 1: the
  loader accepts levels 0 and 1 and a level-0 module cannot link the secure
  `seclevel` primitive.
- The JIT does not resolve libm symbols, so `fmod` and the libm-backed unary
  functions stay on the boxed helpers; `frem` would lower to a libm call.
- `regression/llvm.mud` asserts IR text; update it when emitted names change.

## Validation for any generator or runtime change

Run serially and require a final `SUCCESS` marker from each; the source suite
alone misses relocation and GC-rooting bugs, and the bootstrap has caught real
ones.

1. `./mudlle -e xc.mud -e regression/all.mud`, at default opt and with
   `MUDLLE_LLVM_OPT=none`. Never set `MUDLLE_LLVM_OPT` to an empty string: it
   is rejected.
2. Both bootstraps: delete `build0 build1 build2` and `*.obj`, then
   `MUDLLE_LLVM_OPT=none MUDLLE_LLVM_CACHE= make compiler USE_LLVM=yes`; delete
   again and run `make compiler USE_LLVM=yes`.
3. `perl regression/test-llvm-cache-abi.pl` and
   `perl regression/test-llvm-cache.pl`.
4. Compiled loader, cold then warm, with an emptied cache directory:
   `MUDLLE_LLVM_VERIFY_EACH=1 MUDLLE_LLVM_CACHE_TRACE=1 ./mudlle -e icxc.mud
   -e regression/all.mud`. Expect all misses, then all hits, with equal counts.
5. The stress scripts in `regression/stress/` (each ends in `STRESS_DONE`) and
   `regression/llvm-call-diagnostics.mud`, `regression/llvm-vector-diagnostics.mud`.

## Measuring

- The host is shared and noisy (single batches vary by 10% or more, and a
  12 ms kernel can move 10% on x64 alone). Compare small effects with strictly
  alternating A/B runs, 9 to 15 each, and use medians. Build the x64 tree from
  the same commit for the README table.
- `perf` and `gdb -p` attach are not available. To profile, run
  `gdb -batch -ex 'handle SIGINT stop nopass' -ex run -ex 'bt 4' --args
  ./mudlle ...` as the parent and send `pkill -INT -x mudlle` from a
  background `sleep N` (never `pkill -f`); take 30 to 40 samples of a
  long-running variant of the workload. Guessing at hot spots has been wrong
  more than once.
- Stress scripts must not wrap their body in `reval("""...""")`.

## Tooling notes

- In the author's shell `grep` is a function that honours ignore files; use
  `/usr/bin/grep` when searching generated or ignored files.
- Builds, validation and benchmark runs are mechanical and worked well when
  delegated to a cheaper model with these instructions: run serially, stop at
  the first failure, never edit tracked files, never commit.
