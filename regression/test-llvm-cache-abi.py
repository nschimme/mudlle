#!/usr/bin/env python3
# Copyright (c) 2026 Nils Schimmelmann
# All rights reserved.
#
# Permission to use, copy, modify, and distribute this software for any
# purpose, without fee, and without written agreement is hereby granted,
# provided that the above copyright notice and the following two paragraphs
# appear in all copies of this software.
#
# IN NO EVENT SHALL NILS SCHIMMELMANN BE LIABLE TO ANY PARTY FOR DIRECT, INDIRECT,
# SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OF
# THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF NILS SCHIMMELMANN HAS BEEN ADVISED OF
# THE POSSIBILITY OF SUCH DAMAGE.
#
# NILS SCHIMMELMANN SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS" BASIS, AND NILS
# SCHIMMELMANN HAS NO OBLIGATION TO PROVIDE MAINTENANCE, SUPPORT, UPDATES,
# ENHANCEMENTS, OR MODIFICATIONS.

"""Tests for the LLVM native object cache ABI fingerprint generator."""

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "runtime" / "llvm-cache-abi.py"
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("llvm_cache_abi", GENERATOR)
ABI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ABI)


class CacheABITest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mudlle-cache-abi-test-")
        self.addCleanup(self.temporary.cleanup)
        self.source_dir = Path(self.temporary.name)
        self.runtime_dir = self.source_dir / "runtime"
        self.runtime_dir.mkdir()
        self.makefile = self.source_dir / "Makefile"
        self.makefile.write_text("all: app\n", encoding="utf-8")
        for relative, content in (
            ("module.c", "int root_source;\n"),
            ("module.h", "#define ROOT_HEADER 1\n"),
            ("runtime/llvm.c", "int llvm_source;\n"),
            ("runtime/llvm.h", "#define LLVM_HEADER 1\n"),
        ):
            (self.source_dir / relative).write_text(content, encoding="utf-8")

    def fingerprint(self, cflags="-O2", cppflags="-I."):
        return ABI.digest(self.source_dir, self.makefile, cflags, cppflags)

    def test_sources_makefile_and_flags_change_fingerprint(self):
        baseline = self.fingerprint()
        inputs = [
            (self.source_dir / "module.c", "int root_source_changed;\n"),
            (self.source_dir / "module.h", "#define ROOT_HEADER 2\n"),
            (self.runtime_dir / "llvm.c", "int llvm_source_changed;\n"),
            (self.runtime_dir / "llvm.h", "#define LLVM_HEADER 2\n"),
            (self.makefile, "all: different-target\n"),
        ]
        for path, changed in inputs:
            with self.subTest(path=path.relative_to(self.source_dir)):
                original = path.read_text(encoding="utf-8")
                path.write_text(changed, encoding="utf-8")
                self.assertNotEqual(self.fingerprint(), baseline)
                path.write_text(original, encoding="utf-8")
        self.assertNotEqual(self.fingerprint(cflags="-O3"), baseline)
        self.assertNotEqual(self.fingerprint(cppflags="-Iinclude"), baseline)

    def test_generated_header_is_excluded_from_fingerprint(self):
        baseline = self.fingerprint()
        generated = self.runtime_dir / "llvm-cache-abi.h"
        generated.write_text('#define MUDLLE_LLVM_CACHE_ABI "old-value"\n',
                             encoding="ascii")
        self.assertEqual(self.fingerprint(), baseline)

    def test_regeneration_preserves_mtime_when_content_is_unchanged(self):
        output = self.runtime_dir / "llvm-cache-abi.h"
        command = [
            sys.executable, str(GENERATOR),
            "--source-dir", str(self.source_dir),
            "--makefile", str(self.makefile),
            "--cflags=-O2", "--cppflags=-I.",
            "--output", str(output),
        ]
        subprocess.run(command, check=True)
        self.assertRegex(output.read_text(encoding="ascii"),
                         r'^#define MUDLLE_LLVM_CACHE_ABI "[0-9a-f]{64}"\n$')
        original_mtime = 1_600_000_000_000_000_000
        os.utime(output, ns=(original_mtime, original_mtime))
        subprocess.run(command, check=True)
        self.assertEqual(output.stat().st_mtime_ns, original_mtime)


if __name__ == "__main__":
    unittest.main()
