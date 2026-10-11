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

"""Generate a stable ABI fingerprint for the native LLVM object cache."""

import argparse
import hashlib
from pathlib import Path
import os
import tempfile


def digest(source_dir, makefile, cflags, cppflags):
    hasher = hashlib.sha256()

    def add(name, content):
        encoded_name = name.encode("utf-8")
        hasher.update(len(encoded_name).to_bytes(8, "big"))
        hasher.update(encoded_name)
        hasher.update(len(content).to_bytes(8, "big"))
        hasher.update(content)

    sources = sorted(source_dir.glob("*.c")) + sorted(source_dir.glob("*.h"))
    runtime_dir = source_dir / "runtime"
    sources += sorted(runtime_dir.glob("*.c")) + sorted(runtime_dir.glob("*.h"))
    for source in sources:
        if source == runtime_dir / "llvm-cache-abi.h":
            continue
        add(source.relative_to(source_dir).as_posix(), source.read_bytes())
    add("Makefile", makefile.read_bytes())
    add("CFLAGS", cflags.encode("utf-8"))
    add("CPPFLAGS", cppflags.encode("utf-8"))
    return hasher.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--makefile", type=Path, required=True)
    parser.add_argument("--cflags", required=True)
    parser.add_argument("--cppflags", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    value = digest(args.source_dir.resolve(), args.makefile.resolve(),
                   args.cflags, args.cppflags)
    content = f'#define MUDLLE_LLVM_CACHE_ABI "{value}"\n'
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists() and args.output.read_text(encoding="ascii") == content:
        return
    fd, temporary = tempfile.mkstemp(prefix=args.output.name + ".",
                                     dir=args.output.parent)
    try:
        with os.fdopen(fd, "w", encoding="ascii") as output:
            output.write(content)
        os.replace(temporary, args.output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    main()
