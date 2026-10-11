#!/usr/bin/env python3
"""Compare LLVM optimization and IR verification pipelines sequentially."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import resource
import statistics
import subprocess
import sys
import time


BASE_BENCHMARK = Path(__file__).with_name("benchmark-backends.py")
TIMING_RE = re.compile(
    r"^LLVM timing bytes=(\d+) prepare_parse=([0-9.]+) "
    r"optimize=([0-9.]+) codegen_link=([0-9.]+)$", re.MULTILINE)
CONFIGURATIONS = (
    ("O2_verify1", "O2", "1"),
    ("O2_verify0", "O2", "0"),
    ("O1_verify0", "O1", "0"),
    ("fast_verify0", "fast", "0"),
    ("none_verify0", "none", "0"),
)


def load_base_benchmark():
    spec = importlib.util.spec_from_file_location("benchmark_backends", BASE_BENCHMARK)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load benchmark helpers from {BASE_BENCHMARK}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def compiler_load_command():
    return [
        "./mudlle", "-c", "silent=true", "-e", "icxc.mud", "-c",
        'assert(car(eval("iadd(20,22)")) == 42); '
        'display("compiler-load-ok\\n")',
    ]


def run_timing_diagnostic(directory, optimization, verify):
    env = os.environ.copy()
    env["MUDLLE_LLVM_OPT"] = optimization
    env["MUDLLE_LLVM_VERIFY_EACH"] = verify
    env["MUDLLE_LLVM_CACHE"] = ""
    env.pop("MUDLLE_LLVM_CACHE_TRACE", None)
    env["MUDLLE_LLVM_TIMING"] = "1"
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    started = time.perf_counter()
    result = subprocess.run(compiler_load_command(), cwd=directory, env=env,
                            text=True, capture_output=True)
    wall_s = time.perf_counter() - started
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    if result.returncode != 0 or "compiler-load-ok\n" not in result.stdout:
        raise RuntimeError(result.stdout + result.stderr)

    records = [
        {
            "ir_bytes": int(match[1]),
            "prepare_parse_s": float(match[2]),
            "optimize_s": float(match[3]),
            "codegen_link_s": float(match[4]),
        }
        for match in TIMING_RE.finditer(result.stderr)
    ]
    if not records:
        raise RuntimeError("no LLVM timing records found in stderr:\n" + result.stderr)
    prepare_parse_s = sum(record["prepare_parse_s"] for record in records)
    optimize_s = sum(record["optimize_s"] for record in records)
    codegen_link_s = sum(record["codegen_link_s"] for record in records)
    stage_total_s = prepare_parse_s + optimize_s + codegen_link_s
    return {
        "module_count": len(records),
        "process": {
            "wall_s": round(wall_s, 6),
            "user_s": round(after.ru_utime - before.ru_utime, 6),
            "system_s": round(after.ru_stime - before.ru_stime, 6),
            "remaining_process_s": round(wall_s - stage_total_s, 6),
        },
        "totals": {
            "ir_bytes": sum(record["ir_bytes"] for record in records),
            "prepare_parse_s": round(prepare_parse_s, 6),
            "optimize_s": round(optimize_s, 6),
            "codegen_link_s": round(codegen_link_s, 6),
        },
        "modules": records,
    }


def median_summary(samples):
    keys = [key for key, value in samples[0].items()
            if isinstance(value, (int, float))]
    return {key: statistics.median(sample[key] for sample in samples)
            for key in keys}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--llvm", type=Path, default=Path("."),
                        help="LLVM build directory (default: current directory)")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--output", type=Path, required=True,
                        help="write the JSON report to this path")
    parser.add_argument("--timing", action="store_true",
                        help="run separate compiler-load timing diagnostics")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")

    directory = args.llvm.resolve()
    benchmark_helpers = load_base_benchmark()
    provenance = benchmark_helpers.build_provenance(directory)
    if not (directory / "mudlle").is_file():
        parser.error(f"Mudlle executable not found in {directory}")
    if not provenance["mudlle_arch"] or not provenance["mudlle_arch"].endswith("-llvm"):
        parser.error(f"{directory} is not marked as an LLVM build")

    report = {
        "runs": args.runs,
        "workloads": {
            "compiler_load": "icxc.mud plus checked eval(iadd(20,22))",
            "kernel": "regression/benchmark.mud; 100 million loop-sum iterations",
        },
        "cache_state": "fresh processes; LLVM object cache disabled; OS filesystem cache not flushed",
        "host": {"platform": platform.platform(), "machine": platform.machine()},
        "build": provenance,
        "results": {},
    }

    measure = benchmark_helpers.measure
    for label, optimization, verify in CONFIGURATIONS:
        samples_by_workload = {}
        for workload in ("compiler_load", "kernel"):
            samples = []
            for run in range(args.runs):
                old_opt = os.environ.get("MUDLLE_LLVM_OPT")
                old_verify = os.environ.get("MUDLLE_LLVM_VERIFY_EACH")
                old_timing = os.environ.get("MUDLLE_LLVM_TIMING")
                os.environ["MUDLLE_LLVM_OPT"] = optimization
                os.environ["MUDLLE_LLVM_VERIFY_EACH"] = verify
                os.environ.pop("MUDLLE_LLVM_TIMING", None)
                try:
                    sample = measure(directory, optimization, workload)
                finally:
                    if old_opt is None:
                        os.environ.pop("MUDLLE_LLVM_OPT", None)
                    else:
                        os.environ["MUDLLE_LLVM_OPT"] = old_opt
                    if old_verify is None:
                        os.environ.pop("MUDLLE_LLVM_VERIFY_EACH", None)
                    else:
                        os.environ["MUDLLE_LLVM_VERIFY_EACH"] = old_verify
                    if old_timing is None:
                        os.environ.pop("MUDLLE_LLVM_TIMING", None)
                    else:
                        os.environ["MUDLLE_LLVM_TIMING"] = old_timing
                if workload == "kernel" and sample.get("backend") != "llvm":
                    raise RuntimeError(f"{directory} did not run the LLVM backend")
                samples.append(sample)
                print(f"{label} {workload} {run + 1}/{args.runs}: {sample}",
                      file=sys.stderr, flush=True)
            samples_by_workload[workload] = {
                "samples": samples,
                "medians": median_summary(samples),
            }
        report["results"][label] = {
            "optimization": optimization,
            "verify_each": verify == "1",
            "workloads": samples_by_workload,
        }

    if args.timing:
        diagnostics = {
            "runs_per_configuration": args.runs,
            "remaining_process_s_definition": (
                "wall_s minus summed LLVM stages; includes source handling, runtime "
                "startup and other process work, so it is not pure IR generation"
            ),
            "configurations": {},
        }
        for label, optimization, verify in CONFIGURATIONS:
            samples = []
            for run in range(args.runs):
                sample = run_timing_diagnostic(directory, optimization, verify)
                samples.append(sample)
                print(f"{label} timing {run + 1}/{args.runs}: "
                      f"process={sample['process']} totals={sample['totals']}",
                      file=sys.stderr, flush=True)
            diagnostics["configurations"][label] = {
                "optimization": optimization,
                "verify_each": verify == "1",
                "compiler_load_samples": samples,
                "medians": median_summary([
                    {
                        "module_count": sample["module_count"],
                        **sample["process"],
                        **sample["totals"],
                    }
                    for sample in samples
                ]),
            }
        report["timing_diagnostics"] = diagnostics

    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {output}", file=sys.stderr)


if __name__ == "__main__":
    main()
