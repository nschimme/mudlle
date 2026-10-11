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

"""Measure serial bootstrap stages, closure churn, startup, or full validation.

Use a separately built tree. Bootstrap mode refuses existing stage markers;
each invocation writes raw logs beside its JSON report. Peak RSS is wait4's
per-command maximum (the largest child for make), not a sum across processes.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import time


TIMING = re.compile(r"^LLVM timing bytes=(\d+) prepare_parse=([\d.]+) "
                    r"optimize=([\d.]+) codegen_link=([\d.]+)$", re.M)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--mode", choices=("bootstrap", "closures", "startup", "validation"),
                        required=True)
    parser.add_argument("--optimization", default="none")
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--iterations", type=int, default=20000)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    directory = args.directory.resolve()
    output = args.output.resolve()
    if args.runs < 1 or args.iterations < 1:
        parser.error("runs and iterations must be positive")
    if args.mode == "bootstrap":
        if args.runs != 1:
            parser.error("bootstrap requires a fresh tree for each run")
        if any((directory / f"build{s}").exists() for s in range(3)):
            parser.error("bootstrap requires absent build0/build1/build2 directories")
    output.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["MUDLLE_LLVM_OPT"] = args.optimization
    env["MUDLLE_LLVM_CACHE"] = ""
    env["MUDLLE_LLVM_VERIFY_EACH"] = "0"
    env["MUDLLE_LLVM_TIMING"] = "1"
    env.pop("MAKEFLAGS", None)
    env.pop("MUDLLE_LLVM_CACHE_TRACE", None)
    report = {
        "host": {"platform": platform.platform(), "machine": platform.machine()},
        "binary_sha256": hashlib.sha256((directory / "mudlle").read_bytes()).hexdigest(),
        "llvm_cache_abi_header": (directory / "runtime/llvm-cache-abi.h").read_text().strip(),
        "llvm_version": subprocess.check_output(["llvm-config", "--version"], text=True).strip(),
        "cc_version": subprocess.check_output(["gcc", "--version"], text=True).splitlines()[0],
        "directory": str(directory), "mode": args.mode,
        "environment": {k: env[k] for k in ("MUDLLE_LLVM_OPT", "MUDLLE_LLVM_CACHE",
                                             "MUDLLE_LLVM_VERIFY_EACH", "MUDLLE_LLVM_TIMING")},
        "rss_definition": "wait4 ru_maxrss; bytes on Darwin, KiB converted to bytes elsewhere; make reports largest child, serial -j1",
        "samples": [],
    }
    if args.mode == "bootstrap":
        commands = [(f"stage{s}", ["make", "-j1", f"build{s}/.compiler", "USE_LLVM=yes"], None)
                    for s in range(3)]
    elif args.mode == "closures":
        commands = [("closures", ["./mudlle", "-c", "silent=true", "-c",
                     f"closure_iterations={args.iterations}", "-e",
                     "regression/benchmark-llvm-closures.mud"], "LLVM_CLOSURES_OK")]
    elif args.mode == "startup":
        commands = [("startup", ["./mudlle", "-c", "silent=true", "-e", "icxc.mud", "-c",
                     'assert(car(eval("iadd(20,22)")) == 42); display("compiler-load-ok\\n")'],
                     "compiler-load-ok")]
    else:
        caches = {loader: output.with_suffix(f".{loader}.cache") for loader in ("xc", "icxc")}
        if any(cache.exists() for cache in caches.values()):
            parser.error("validation requires fresh cache paths beside the report")
        env["MUDLLE_LLVM_CACHE_TRACE"] = "1"
        report["environment"].update(MUDLLE_LLVM_CACHE={k: str(v) for k, v in caches.items()},
                                     MUDLLE_LLVM_CACHE_TRACE="1")
        commands = [(f"{loader}-{state}", ["./mudlle", "-c", "silent=true", "-e",
                     f"{loader}.mud", "-e", "regression/all.mud"], "SUCCESS")
                    for loader in ("xc", "icxc") for state in ("cold", "warm")]
    for run in range(args.runs):
        for label, command, sentinel in commands:
            if args.mode == "validation":
                env["MUDLLE_LLVM_CACHE"] = str(caches[label.split("-")[0]])
            stem = output.with_suffix(f".{label}-{run + 1}")
            stdout_path = Path(str(stem) + ".stdout")
            stderr_path = Path(str(stem) + ".stderr")
            started = time.perf_counter()
            with stdout_path.open("w") as out, stderr_path.open("w") as err:
                process = subprocess.Popen(command, cwd=directory, env=env, stdout=out, stderr=err)
                _, status, usage = os.wait4(process.pid, 0)
                process.returncode = os.waitstatus_to_exitcode(status)
            wall = time.perf_counter() - started
            stdout = stdout_path.read_text(errors="replace")
            stderr = stderr_path.read_text(errors="replace")
            records = [tuple(map(float, m)) for m in TIMING.findall(stderr)]
            totals = {key: round(sum(r[i] for r in records), 6)
                      for i, key in enumerate(("ir_bytes", "prepare_parse_s", "optimize_s", "codegen_link_s"))}
            sample = {
                "label": label, "run": run + 1, "command": command,
                "returncode": process.returncode,
                "sentinel": sentinel, "sentinel_found": sentinel is None or sentinel in stdout.splitlines(),
                "wall_s": round(wall, 6), "user_s": usage.ru_utime, "system_s": usage.ru_stime,
                "peak_rss_bytes": usage.ru_maxrss * (1 if platform.system() == "Darwin" else 1024),
                "llvm_modules": len(records), "llvm_totals": totals,
                "remaining_wall_s": round(wall - sum(totals[k] for k in
                    ("prepare_parse_s", "optimize_s", "codegen_link_s")), 6),
                "cache_hits": stderr.count("LLVM object cache hit\n"),
                "cache_misses": stderr.count("LLVM object cache miss\n"),
                "stdout_sha256": hashlib.sha256(stdout_path.read_bytes()).hexdigest(),
                "stderr_sha256": hashlib.sha256(stderr_path.read_bytes()).hexdigest(),
            }
            if args.mode == "closures":
                sample["iterations"] = args.iterations
            if args.mode == "bootstrap":
                sample["stage_marker_exists"] = (directory / f"build{label[-1]}/.compiler").exists()
                objects = directory if label == "stage2" else directory / f"build{label[-1]}"
                sample["objects_sha256"] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                             for p in sorted(objects.glob("*.obj"))}
            report["samples"].append(sample)
            output.write_text(json.dumps(report, indent=2) + "\n")
            print(f"{label}: {wall:.3f}s, peak RSS {sample['peak_rss_bytes'] / 2**20:.1f} MiB", flush=True)
            if process.returncode != 0 or not sample["sentinel_found"] or not sample.get("stage_marker_exists", True):
                raise SystemExit(f"failed; see {stdout_path} and {stderr_path}")


if __name__ == "__main__":
    main()
