# Benchmarks

Comparison of this branch's LLVM backend with upstream x64 master `99a6a18`;
the results table is in the [README](../README.md#benchmarks). Mudlle is single
threaded and LLVM kernels use `default<O2>`. Each sample is a fresh process
running 100 timed calls per workload (2,000 for the integer loop); there are 31
LLVM samples and 31 x64 samples, the latter recorded earlier on the same host.
The bootstrap independently resamples each backend 5,000 times with seed
20261012. It assumes independent, identically distributed samples and does not
capture drift between baseline and LLVM runs.

Timers sum `ctime()` only across kernel calls. Compilation, warmup, numeric
reference calculations, explicit collection stress, and post-call checks are
outside the timers; table and sequence identity/content guards remain inside
their timed loops. Timed loops keep ordinary loop accounting. The library
conversion calls interpreted library closures; native conversions compile
the equivalent loops locally. The compact x64 sample fixture is
[`benchmarks/x64-baseline.json`](benchmarks/x64-baseline.json).
The runner writes raw samples, checksums, source/binary fingerprints and
statistical summaries outside Git through its `--output` option.

To reproduce the LLVM samples on the same host and reuse the checked-in x64
fixture, build this branch with `make USE_LLVM=yes` and
`make -j8 compiler USE_LLVM=yes`, then run:

    perl regression/benchmark-rich-backends.pl --llvm <this-branch-tree> \
      --baseline-report doc/benchmarks/x64-baseline.json \
      --suite all --runs 31 \
      --timed-calls 100 \
      --llvm-revision "$(git -C <this-branch-tree> rev-parse HEAD)" \
      --x64-revision 99a6a18b0145f45c326555ae23145eeab16b08cc \
      --output /tmp/mudlle-benchmark-report.json

The baseline fixture requires the same host platform and cache configuration.
The runner checks each workload against its reference and requires its success
marker before recording a sample.
