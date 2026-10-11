#!/usr/bin/env python3
"""Measure compiled kernel execution and fresh compiler loads sequentially."""

import argparse
import json
import os
from pathlib import Path
import re
import resource
import statistics
import subprocess
import sys
import time


def measure(directory, optimization, workload):
    env = os.environ.copy()
    env.pop("MUDLLE_LLVM_OPT", None)
    if optimization is not None:
        env["MUDLLE_LLVM_OPT"] = optimization
    command = ["./mudlle", "-c", "silent=true"]
    if workload == "kernel":
        command += ["-e", "xc.mud", "-e", "regression/benchmark.mud"]
    else:
        command += [
            "-e", "icxc.mud", "-c",
            'assert(car(eval("iadd(20,22)")) == 42); display("compiler-load-ok\\n")',
        ]
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.perf_counter()
    result = subprocess.run(command, cwd=directory, env=env, text=True,
                            capture_output=True)
    wall = time.perf_counter() - start
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    sample = {
        "wall_s": round(wall, 6),
        "user_s": round(after.ru_utime - before.ru_utime, 6),
        "system_s": round(after.ru_stime - before.ru_stime, 6),
    }
    # Mudlle can return zero after a load error; require workload completion.
    if result.returncode != 0:
        raise RuntimeError(result.stdout + result.stderr)
    if workload == "kernel":
        match = re.search(r"backend=(\w+) workload=loop-sum work=50000 "
                          r"runs=2000 cpu_ms=(\d+)", result.stdout)
        if match is None:
            raise RuntimeError(result.stdout + result.stderr)
        sample.update(backend=match[1], kernel_cpu_ms=int(match[2]))
    elif "compiler-load-ok\n" not in result.stdout:
        raise RuntimeError(result.stdout + result.stderr)
    return sample


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--x64", type=Path, required=True)
    parser.add_argument("--llvm", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=3)
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    report = {"runs": args.runs, "kernel_iterations": 100_000_000,
              "compiler_load": "icxc.mud followed by checked eval(iadd(20,22))",
              "cache_state": "fresh processes; OS filesystem cache not flushed",
              "results": {}}
    for label, directory, optimization in [
        ("x64", args.x64.resolve(), None),
        ("llvm_O2", args.llvm.resolve(), "O2"),
        ("llvm_none", args.llvm.resolve(), "none"),
    ]:
        workloads = {}
        for workload in ("kernel", "compiler_load"):
            samples = []
            for run in range(args.runs):
                sample = measure(directory, optimization, workload)
                if workload == "kernel":
                    expected = "x64" if label == "x64" else "llvm"
                    if sample["backend"] != expected:
                        raise RuntimeError(f"{directory} is not a {expected} build")
                samples.append(sample)
                print(f"{label} {workload} {run + 1}/{args.runs}: {sample}",
                      file=sys.stderr, flush=True)
            metrics = [key for key, value in samples[0].items()
                       if isinstance(value, (int, float))]
            workloads[workload] = {
                "samples": samples,
                "medians": {key: statistics.median(s[key] for s in samples)
                            for key in metrics},
            }
        report["results"][label] = workloads
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
