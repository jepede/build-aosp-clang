# AOSP Clang 12.0.5 for Linux ARM64

This toolchain runs natively on a Linux ARM64 host with glibc, including the
ARM64 Linux distribution inside Termux/PRoot. It uses the source revisions and
AOSP patches recorded in the official Android build 7284624 manifest for
r416183b. The compiler identifies itself as a Linux ARM64 rebuild.

The workflow is `.github/workflows/build-aosp-clang-linux-arm64.yml`. It builds
on `ubuntu-22.04-arm`, with GCC 11, and packages `clang`, `clang++`, `ld.lld`,
the kernel's LLVM binutils, Clang resource headers, and build provenance.
Code generation targets are AArch64, ARM, BPF, and X86. The compiler's C++
runtime is linked statically; glibc and zlib come from the Linux host.

## Source pins

The build script downloads and checks these against Google's
`clang-r416183b/manifest_7284624.xml` before fetching sources:

| Repository | Commit |
| --- | --- |
| toolchain/llvm-project | c935d99d7cf2016289302412d708641d52d2f7ee |
| toolchain/llvm_android | 07e984be2f6074fb044e0ae06b9027f350fe8844 |
| platform/external/toolchain-utils | f5cc9231be5ecd6d0159b352dfb014926bfa77e6 |

The pinned AOSP patch manager applies patches with `--failure_mode fail`.
`BUILD_INFO.json`, the original manifest, the applied patch diff,
`CMakeCache.txt`, and `smoke-results.json` accompany the binaries.

## Download and use

Download `aosp-clang-r416183b-7284624-linux-aarch64` from the successful
workflow run, then verify and extract its archive:

```sh
sha256sum -c aosp-clang-r416183b-7284624-linux-aarch64.tar.xz.sha256
tar -xf aosp-clang-r416183b-7284624-linux-aarch64.tar.xz
export PATH="$PWD/clang-r416183b-linux-aarch64/bin:$PATH"
clang --version
```

For a kernel tree supporting the LLVM variables:

```sh
make -j1 O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 your_device_defconfig
make -j1 O=out ARCH=arm64 LLVM=1 LLVM_IAS=1
```

Use the actual device's defconfig and vendor build settings. Older vendor trees
may also require their matching GNU cross binutils or `CROSS_COMPILE` settings.
The package does not include a GNU cross toolchain or an Android NDK sysroot.

## Validation and rebuilding

The workflow checks Linux AArch64 ELF interpreters and dependencies, executes
native C/C++ programs, compiles ARM64/ARM32/X86/BPF freestanding objects,
exercises archive/strip/objcopy/disassembly tools, and links AArch64 full-LTO
and ThinLTO binaries with CFI enabled. These checks do not compile or boot a
complete device kernel.

To rebuild on Linux ARM64 with GCC 11 and the workflow's listed dependencies:

```sh
CC=gcc-11 CXX=g++-11 JOBS=1 bash scripts/build-aosp-clang-linux-arm64.sh
```

To rerun validation against an extracted package:

```sh
python3 scripts/smoke-clang-linux-arm64.py /absolute/path/to/clang-r416183b-linux-aarch64
```
