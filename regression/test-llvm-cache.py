#!/usr/bin/env python3
"""Exercise the LLVM native-object cache through fresh Mudlle processes."""

import argparse
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
SUCCESS = "LLVM_CACHE_TEST_OK"


def mudlle_script(body):
    return 'load("xc.mud");\n' + body


def run(binary, script, cache, optimization=None, *, trace=True):
    env = os.environ.copy()
    env["MUDLLE_LLVM_CACHE"] = str(cache) if cache is not None else ""
    env.pop("MUDLLE_LLVM_OPT", None)
    if optimization is not None:
        env["MUDLLE_LLVM_OPT"] = optimization
    if trace:
        env["MUDLLE_LLVM_CACHE_TRACE"] = "1"
    else:
        env.pop("MUDLLE_LLVM_CACHE_TRACE", None)

    with tempfile.NamedTemporaryFile("w", suffix=".mud", encoding="utf-8",
                                     delete=False) as source:
        source.write(mudlle_script(script))
        source_path = Path(source.name)
    try:
        result = subprocess.run([str(binary), "-e", str(source_path)],
                                cwd=ROOT, env=env, text=True,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)
    finally:
        source_path.unlink(missing_ok=True)

    if result.returncode != 0 or SUCCESS not in result.stdout:
        raise AssertionError(
            f"Mudlle did not reach its success sentinel (exit {result.returncode})\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}")
    traces = re.findall(r"^LLVM object cache (hit|miss)$", result.stderr,
                        re.MULTILINE)
    return traces, result


def expect_trace(label, run_result, expected):
    traces, result = run_result
    if traces != expected:
        raise AssertionError(
            f"{label}: expected cache trace {expected}, got {traces}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}")


def simple_script(sentinel=SUCCESS):
    return f'''[
  | source, tree, prelinked, linked, function |
  source = "fn (x) x + 40";
  tree = mudlle_parse(source, "cache-test.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  if (!vector?(prelinked)) error(error_bad_value);
  linked = mc:linkrun(prelinked, 1, true);
  if (!pair?(linked)) error(error_bad_value);
  function = car(linked);
  if (function(2) != 42) error(error_bad_value);
  display("{sentinel}");
];
'''


def cache_files(directory):
    return sorted(directory.glob("*.cache")) if directory.is_dir() else []


def validate_cache_file(path):
    data = path.read_bytes()
    if len(data) < 24:
        raise AssertionError(f"cache file is shorter than its header: {path}")
    key_size, object_size, checksum = struct.unpack("=QQQ", data[:24])
    if key_size == 0 or object_size == 0:
        raise AssertionError(f"cache file has an empty key or object: {path}")
    if len(data) != 24 + key_size + object_size:
        raise AssertionError(f"cache file lengths do not match its header: {path}")
    object_bytes = data[24 + key_size:]
    actual = 14695981039346656037
    for byte in object_bytes:
        actual = ((actual ^ byte) * 1099511628211) & 0xffffffffffffffff
    if actual != checksum:
        raise AssertionError(f"cache object checksum does not match: {path}")
    return data[24:24 + key_size]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mudlle", type=Path, default=ROOT / "mudlle",
                        help="LLVM-enabled Mudlle executable (default: ./mudlle)")
    args = parser.parse_args()
    binary = args.mudlle.resolve()
    if not binary.is_file():
        parser.error(f"Mudlle executable not found: {binary}")

    with tempfile.TemporaryDirectory(prefix="mudlle-llvm-cache-test-") as tmp:
        base = Path(tmp)

        # A fresh process populates the cache; another process reuses it.
        cache = base / "cold-warm"
        expect_trace("cold process", run(binary, simple_script(), cache), ["miss"])
        expect_trace("warm process", run(binary, simple_script(), cache), ["hit"])
        files = cache_files(cache)
        if len(files) != 1:
            raise AssertionError(f"expected one cache entry, found {len(files)}")
        validate_cache_file(files[0])

        # Reusing one object twice must not collide in ORC's module namespace.
        duplicate_script = '''[
  | source, tree, prelinked, first, second, f1, f2 |
  source = "fn (x) x + 40";
  tree = mudlle_parse(source, "cache-duplicate.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  if (!vector?(prelinked)) error(error_bad_value);
  first = mc:linkrun(prelinked, 1, true);
  if (!pair?(first)) error(error_bad_value);
  f1 = car(first);
  second = mc:linkrun(prelinked, 1, true);
  if (!pair?(second)) error(error_bad_value);
  f2 = car(second);
  if (f1(2) != 42 || f2(2) != 42 || f1(3) != 43) error(error_bad_value);
  display("LLVM_CACHE_TEST_OK");
];
'''
        cache = base / "duplicate"
        cold_duplicate = run(binary, duplicate_script, cache)
        keys = [validate_cache_file(path) for path in cache_files(cache)]
        if not keys:
            raise AssertionError("duplicate loads did not populate the cache")
        legacy_sequence_key = any(
            marker in key for key in keys
            for marker in (b"LLVM14-module-sequence=",
                           b"legacy-module-sequence="))
        cold_expected = ["miss", "miss"] if legacy_sequence_key else ["miss", "hit"]
        expect_trace("duplicate links cold", cold_duplicate, cold_expected)
        expect_trace("duplicate links warm",
                     run(binary, duplicate_script, cache), ["hit", "hit"])

        # The exact same source refers to globals at different offsets when
        # their registration order changes. Each ordering must miss once and
        # then hit its own correctly relocated object.
        source = "fn () cache_global_a * 100 + cache_global_b"
        descriptor_path = base / "global-relocation.obj"
        producer = f'''[
  | source, tree, prelinked |
  cache_global_a = 11;
  cache_global_b = 22;
  source = "{source}";
  tree = mudlle_parse(source, "cache-global-order.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  if (!vector?(prelinked)) error(error_bad_value);
  save_data("{descriptor_path}", prelinked);
  display("LLVM_CACHE_TEST_OK");
];
'''
        expect_trace("serialize global relocation descriptor",
                     run(binary, producer, None, trace=False), [])
        if not descriptor_path.is_file():
            raise AssertionError("Mudlle did not serialize the LLVM descriptor")

        def ordered_globals(first, expected):
            assignments = ("cache_global_a = 11; cache_global_b = 22;"
                           if first == "a" else
                           "cache_global_b = 22; cache_global_a = 11;")
            return f'''{assignments}
[
  | prelinked, linked, function |
  prelinked = load_data("{descriptor_path}");
  linked = mc:linkrun(prelinked, 1, true);
  if (!pair?(linked)) error(error_bad_value);
  function = car(linked);
  if (function() != {expected}) error(error_bad_value);
  display("LLVM_CACHE_TEST_OK");
];
'''

        cache = base / "global-order"
        expect_trace("globals A/B cold",
                     run(binary, ordered_globals("a", 1122), cache), ["miss"])
        expect_trace("globals A/B warm",
                     run(binary, ordered_globals("a", 1122), cache), ["hit"])
        expect_trace("globals B/A cold",
                     run(binary, ordered_globals("b", 1122), cache), ["miss"])
        expect_trace("globals B/A warm",
                     run(binary, ordered_globals("b", 1122), cache), ["hit"])

        # Optimization settings are part of the cache key.
        cache = base / "optimization"
        expect_trace("O2 cold", run(binary, simple_script(), cache, "O2"), ["miss"])
        expect_trace("none cold", run(binary, simple_script(), cache, "none"), ["miss"])
        expect_trace("none warm", run(binary, simple_script(), cache, "none"), ["hit"])
        expect_trace("O2 warm", run(binary, simple_script(), cache, "O2"), ["hit"])

        # A truncated object and a checksum-corrupted object are both ignored
        # and regenerated while execution still reaches its sentinel.
        for mode in ("truncated", "corrupted"):
            cache = base / mode
            expect_trace(f"{mode} populate",
                         run(binary, simple_script(), cache), ["miss"])
            entry, = cache_files(cache)
            data = entry.read_bytes()
            if mode == "truncated":
                entry.write_bytes(data[:24])
            else:
                damaged = bytearray(data)
                damaged[-1] ^= 0x01
                entry.write_bytes(damaged)
            expect_trace(f"{mode} fallback",
                         run(binary, simple_script(), cache), ["miss"])
            validate_cache_file(entry)
            expect_trace(f"{mode} repaired hit",
                         run(binary, simple_script(), cache), ["hit"])

        # Keep the cached object and checksum intact, but alter the stored key
        # while leaving the filename at the hash of the original key. The
        # complete-key comparison must reject this entry.
        cache = base / "mismatched-key"
        expect_trace("mismatched key populate",
                     run(binary, simple_script(), cache), ["miss"])
        entry, = cache_files(cache)
        data = bytearray(entry.read_bytes())
        key_size, _, _ = struct.unpack("=QQQ", data[:24])
        if key_size == 0:
            raise AssertionError("cache file has an empty key")
        data[24] ^= 0x01
        entry.write_bytes(data)
        expect_trace("mismatched key fallback",
                     run(binary, simple_script(), cache), ["miss"])
        validate_cache_file(entry)
        expect_trace("mismatched key repaired hit",
                     run(binary, simple_script(), cache), ["hit"])

        # A path occupied by a regular file cannot be used as a cache dir.
        unavailable = base / "not-a-directory"
        unavailable.write_text("occupied", encoding="utf-8")
        expect_trace("unavailable cache directory",
                     run(binary, simple_script(), unavailable), ["miss"])
        if unavailable.read_text(encoding="utf-8") != "occupied":
            raise AssertionError("unavailable cache path was modified")

        # Empty MUDLLE_LLVM_CACHE disables persistence and tracing.
        expect_trace("disabled cache",
                     run(binary, simple_script(), None, trace=False), [])

    print("LLVM native object cache integration tests passed")


if __name__ == "__main__":
    main()
