#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out_dir=${1:-/tmp/mudlle-simd-inspect}
mkdir -p -- "$out_dir"
out_dir=$(CDPATH= cd -- "$out_dir" && pwd)
cd -- "$out_dir"
cache_dir=$(mktemp -d "$out_dir/cache.XXXXXX")

source='fn (needle, haystack) if (vfind?(needle, haystack)) 1 else 0'
mudlle_output=membership.run.log
if MUDLLE_LLVM_CACHE="$cache_dir" MUDLLE_LLVM_OPT=O2 \
    "$repo_dir/mudlle" -c silent=true -e "$repo_dir/xc.mud" \
    -c "source = \"$source\"; tree = mudlle_parse(source, \"membership.mud\", false); ir = mc:compile_llvm(tree, 1, mc:source_code(source)); w = writer:new_file(\"membership.ll\"); writer:write(w, ir); writer:close(w); tree = mudlle_parse(source, \"membership.mud\", false); prelinked = mc:compile(tree, false, 1, mc:source_code(source)); linked = mc:linkrun(prelinked, 1, true); if (!pair?(linked)) error(error_bad_value); f = car(linked); if (f(1, vector(1)) != 1) error(error_bad_value); display(\"SIMD_PROBE_OK\\n\");" \
    >"$mudlle_output" 2>&1; then
  :
else
  cat "$mudlle_output"
  exit 1
fi
cat "$mudlle_output"
if ! grep -Fq 'SIMD_PROBE_OK' "$mudlle_output"; then
  echo "Mudlle exited without the SIMD probe success marker" >&2
  exit 1
fi
if ! grep -Fq 'mudlle_vector_find_chunk' membership.ll; then
  echo "Generated IR does not contain mudlle_vector_find_chunk" >&2
  exit 1
fi

python3 - "$cache_dir" <<'PY'
import pathlib
import struct
import sys

cache = pathlib.Path(sys.argv[1])
for path in sorted(cache.glob("*.cache")):
    data = path.read_bytes()
    if len(data) < 24:
        continue
    key_size, object_size, _ = struct.unpack_from("=QQQ", data)
    end_key = 24 + key_size
    end_object = end_key + object_size
    if end_object != len(data) or b"mudlle_vector_find_chunk" not in data[24:end_key]:
        continue
    pathlib.Path("membership-native.o").write_bytes(data[end_key:end_object])
    break
else:
    raise SystemExit("no cached native object key contains mudlle_vector_find_chunk")
PY

objdump -d membership-native.o > membership-native.dis
llvm_opt=${LLVM_OPT:-opt-19}
if command -v "$llvm_opt" >/dev/null 2>&1 && command -v llvm-config >/dev/null 2>&1; then
  triple=$(llvm-config --host-target)
  if ! "$llvm_opt" -passes='default<O2>' -mtriple="$triple" \
      -pass-remarks=loop-vectorize -pass-remarks-missed=loop-vectorize \
      -pass-remarks-analysis=loop-vectorize -S membership.ll \
      -o membership.opt.ll 2>membership.vectorize-remarks.txt; then
    cat membership.vectorize-remarks.txt >&2
    exit 1
  fi
  echo "LLVM remarks: $out_dir/membership.vectorize-remarks.txt"
else
  echo "Skipping opt remarks: opt or llvm-config is unavailable"
fi
echo "SIMD artifacts: $out_dir"
