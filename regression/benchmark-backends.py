#!/usr/bin/env python3
# Copyright (c) 2026 Nils Schimmelmann
# All rights reserved.
#
# Permission to use, copy, modify, and distribute this software for any
# purpose, without fee, and without written agreement is hereby granted,
# provided that the above copyright notice and the following two paragraphs
# appear in all copies of this software.
#
# IN NO EVENT SHALL NILS SCHIMMELMANN BE LIABLE TO ANY PARTY FOR DIRECT,
# INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE
# USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF NILS SCHIMMELMANN HAS
# BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# NILS SCHIMMELMANN SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
# PARTICULAR PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS"
# BASIS, AND NILS SCHIMMELMANN HAS NO OBLIGATION TO PROVIDE MAINTENANCE,
# SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.

"""Measure compiled kernel execution and fresh compiler loads sequentially."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import resource
import statistics
import subprocess
import sys
import tempfile
import time


def build_provenance(directory):
    executable = directory / "mudlle"
    arch_file = directory / ".mudlle-arch"
    abi_header = directory / "runtime" / "llvm-cache-abi.h"
    abi_match = None
    if abi_header.is_file():
        match = re.search(
            r'^#define MUDLLE_LLVM_CACHE_ABI "([0-9a-f]+)"$',
            abi_header.read_text(encoding="ascii"), re.MULTILINE)
        if match:
            abi_match = match[1]
    executable_hash = None
    if executable.is_file():
        hasher = hashlib.sha256()
        with executable.open("rb") as binary:
            for block in iter(lambda: binary.read(1024 * 1024), b""):
                hasher.update(block)
        executable_hash = hasher.hexdigest()
    return {
        "path": str(directory),
        "mudlle_arch": arch_file.read_text(encoding="utf-8").strip()
        if arch_file.is_file() else None,
        "mudlle_sha256": executable_hash,
        "llvm_cache_abi": abi_match,
    }


def measure(directory, optimization, workload, cache_directory=None):
    env = os.environ.copy()
    env.pop("MUDLLE_LLVM_OPT", None)
    if optimization is not None:
        env["MUDLLE_LLVM_OPT"] = optimization
    if cache_directory is None:
        env["MUDLLE_LLVM_CACHE"] = ""
        env.pop("MUDLLE_LLVM_CACHE_TRACE", None)
    else:
        env["MUDLLE_LLVM_CACHE"] = str(cache_directory)
        env["MUDLLE_LLVM_CACHE_TRACE"] = "1"
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
    if cache_directory is not None:
        sample["cache_hits"] = len(re.findall(
            r"^LLVM object cache hit$", result.stderr, re.MULTILINE))
        sample["cache_misses"] = len(re.findall(
            r"^LLVM object cache miss$", result.stderr, re.MULTILINE))
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
    targets = parser.add_mutually_exclusive_group(required=True)
    targets.add_argument("--x64", type=Path)
    targets.add_argument("--llvm", type=Path)
    targets.add_argument("--arm64", type=Path,
                         help="measure the ARM64 LLVM backend only")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--kernel-only", action="store_true",
                        help="skip compiler-load timing (for unbootstrapped trees)")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    arm64 = args.arm64 is not None
    x64_directory = args.x64.resolve() if args.x64 else None
    llvm_directory = (args.llvm or args.arm64).resolve()
    workloads_to_run = ("kernel",) if args.kernel_only else (
        "kernel", "compiler_load")
    report = {"runs": args.runs, "kernel_iterations": 100_000_000,
              "workloads": list(workloads_to_run),
              "cache_state": "fresh processes; OS filesystem cache not flushed",
              "host": {"platform": platform.platform(),
                       "machine": platform.machine()},
              "builds": ({"arm64": build_provenance(llvm_directory)} if arm64 else
                         {"x64": build_provenance(x64_directory),
                          "llvm": build_provenance(llvm_directory)}),
              "results": {}}
    configurations = ([
        ("llvm_O2", llvm_directory, "O2"),
        ("llvm_none", llvm_directory, "none"),
    ] if arm64 else [
        ("x64", x64_directory, None),
        ("llvm_O2", llvm_directory, "O2"),
        ("llvm_none", llvm_directory, "none"),
    ])
    for label, directory, optimization in configurations:
        workloads = {}
        for workload in workloads_to_run:
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

    # Pair each cold-cache sample with a warm-cache measurement in its own
    # temporary cache, so runs cannot inherit entries from earlier samples.
    cached_workloads = {}
    for workload in workloads_to_run:
        miss_samples = []
        hit_samples = []
        for run in range(args.runs):
            with tempfile.TemporaryDirectory(prefix="mudlle-llvm-cache-") as cache:
                miss = measure(llvm_directory, "O2", workload, cache)
                if miss["cache_misses"] < 1:
                    raise RuntimeError(f"LLVM cache miss was not observed: {miss}")
                # Explicitly prime immediately before timing the cache hit.
                measure(llvm_directory, "O2", workload, cache)
                hit = measure(llvm_directory, "O2", workload, cache)
                if hit["cache_hits"] < 1 or hit["cache_misses"] != 0:
                    raise RuntimeError(f"LLVM warm cache was not exclusively hit: {hit}")
                if workload == "kernel":
                    if miss["backend"] != "llvm" or hit["backend"] != "llvm":
                        raise RuntimeError(f"{llvm_directory} is not an llvm build")
                miss_samples.append(miss)
                hit_samples.append(hit)
                print(f"llvm_O2_cache_miss {workload} {run + 1}/{args.runs}: {miss}",
                      file=sys.stderr, flush=True)
                print(f"llvm_O2_cache_hit {workload} {run + 1}/{args.runs}: {hit}",
                      file=sys.stderr, flush=True)
        for suffix, samples in (("miss", miss_samples), ("hit", hit_samples)):
            metrics = [key for key, value in samples[0].items()
                       if isinstance(value, (int, float))]
            cached_workloads.setdefault(f"llvm_O2_cache_{suffix}", {})[workload] = {
                "samples": samples,
                "medians": {key: statistics.median(s[key] for s in samples)
                            for key in metrics},
            }
    report["results"].update(cached_workloads)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
