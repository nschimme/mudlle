# RISC-V (riscv64)

On riscv64 the LLVM backend is the only compiler, as on ARM64. The build
selects it automatically when `llvm-config` is present.

## Status

Tested only under qemu user-mode emulation (Debian trixie, LLVM 19.1.7, GCC
from `build-essential`); there is no RISC-V hardware result and no benchmark
data, since emulated timings are meaningless.

- `make` builds and links.
- `./mudlle -e xc.mud -e regression/all.mud` prints `SUCCESS` at the default
  O2 (about 5 minutes under qemu) and with `MUDLLE_LLVM_OPT=none` (about
  7 minutes).
- Not yet run on RISC-V: the three-stage bootstrap (`make compiler
  USE_LLVM=yes`), `test-llvm-cache*.pl`, the compiled-loader cold/warm runs
  and the GC stress scripts.

## Reproducing on a non-RISC-V host

Register qemu user-mode emulation with binfmt_misc once:

    sudo apt install qemu-user-static binfmt-support

Check that a riscv64 container runs (should print `riscv64`):

    podman run --rm --platform linux/riscv64 docker.io/library/debian:trixie uname -m

Build the image and use a clean checkout, since compiled objects are
architecture-specific:

    podman build --platform linux/riscv64 -t mudlle-riscv64 docker/riscv64
    git clone . /tmp/mudlle-riscv64
    podman run --rm --platform linux/riscv64 -v /tmp/mudlle-riscv64:/src \
        mudlle-riscv64 bash -c \
        'make -j4 && ./mudlle -e xc.mud -e regression/all.mud'

`docker` works the same way.

`-march=native` is not passed on riscv64 because GCC rejects it there.

## Reproducing on macOS

Use Docker Desktop. The containers run inside its Linux VM, so the qemu
emulation has to be available in that VM, not on macOS itself. Rosetta covers
only x86-64, not riscv64. The recipe is untested on a Mac.

Install and start Docker Desktop, then check that a riscv64 container runs
(should print `riscv64`):

    docker run --rm --platform linux/riscv64 docker.io/library/debian:trixie uname -m

If it fails with an exec-format error, riscv64 emulation is not registered in
the VM. Register it with:

    docker run --privileged --rm tonistiigi/binfmt --install riscv64

Then build and test with the commands above, replacing `podman` with `docker`.
Use a checkout under your home directory so the VM can mount it.

Rancher Desktop works as an alternative. Select the dockerd (moby) container
engine in its preferences so the `docker` commands above apply unchanged; with
the containerd engine, use `nerdctl` in place of `docker`. The same
`uname -m` check applies, and I have not verified that its VM ships riscv64
emulation, so the `tonistiigi/binfmt` fallback may be needed there too.

Expect it to be slow. On Apple Silicon the VM is arm64, so every riscv64
process is emulated.
