# Linux AArch64/glibc AOSP Clang kernel toolchains

These binaries are **native Linux AArch64 ELF** built against **glibc** on
`ubuntu-22.04-arm`, and are **not** Android/Bionic toolchains. They are built
from pinned official Android llvm-project, llvm_android and toolchain-utils
source revisions, with AOSP patches applied. The host may use GCC 12 to
bootstrap LLVM, but all resulting Clang/LLD executables target native AArch64.

## Six requested revisions

| Revision | Clang | Official Android build | Status / source |
| --- | --- | --- | --- |
| r416183b | 12.0.5 | 7284624 | Built and smoke-tested: [run 44970015495](https://github.com/jepede/build-aosp-clang/actions/runs/44970015495) |
| r450784e | 14.0.7 | 8508608 | [multi-version build](https://github.com/jepede/build-aosp-clang/actions/runs/44984024201) |
| r487747c | 17.0.2 | 10087095 | same run |
| r510928 | 18.0.0 | 11368308 | same run |
| r536225 | 19.0.1 | 12833971 | same run |
| r584948c | 22.0.1 | 15323222 | same run |

The first has been verified successfully; **all later versions must pass their
individual GitHub Actions job, smoke tests and SHA256 verification before they
are regarded as finished**. Source locks exist in `source-locks/r*.json`;
the original, immutable official manifest location and SHA256 are embedded in
every file. [Source lock verification run](https://github.com/jepede/build-aosp-clang/actions/runs/44983855258).

The multi-build workflow is `.github/workflows/build-aosp-clang-linux-arm64-multi.yml`.
The build script is `scripts/build-aosp-clang-linux-arm64-multi.sh`.
The smoke script is `scripts/smoke-clang-linux-arm64-multi.py`.
Each matrix job uses a clean isolated source/work directory and cache.

## Output

Each passing job publishes `aosp-clang-rNNNNNN-linux-aarch64-manifest`
and one or more `aosp-clang-rNNNNNN-linux-aarch64-part-XX` artifacts.
A separate `...-evidence` artifact contains smoke results and build logs.
Parts are at most **95 MiB**, below the connector's 512 MB limit.
GitHub caps the actual retention period independently of the requested
`retention-days`. Check `expires_at` on every Artifact before use.

Download and unzip the **manifest artifact** and **all numbered part artifacts
for the SAME revision/run** into `/root/work/neihe`; then run:

```sh
cd /root/work/neihe
rev=r450784e             # change as needed, e.g. r584948c
# Check build ID in source-locks/$rev.json to avoid mixing versions
build=8508608
base="aosp-clang-$rev-$build-linux-aarch64.tar.xz"
sha256sum -c "$base.parts.sha256"
cat "$base".part.* > "$base"
test "$(stat -c%s "$base")" = "$(cat "$base.size")"
sha256sum -c "$base.sha256"
tar -xJf "$base"
export PATH="$PWD/clang-$rev-linux-aarch64/bin:$PATH"
clang --version
ld.lld --version
file "$(command -v clang)"
readelf -l "$(command -v clang)" | grep -A1 INTERP
```

These packages include clang/clang++, lld/ld.lld, LLVM binutils, Clang
resource headers, BUILD_INFO.json, source SHA locks, original AOSP manifest,
and CMakeCache.txt. The build targets include AArch64, ARM, BPF and X86.
They do not bundle a full GNU cross toolchain, Android sysroot, or the original
Google prebuilts. For Linux ARM64 kernel projects, invoke the device-specific
defconfig and correct `LLVM=1`/`LLVM_IAS=1` options supported by that tree.

## Local rebuilding

On a native Linux AArch64 host with GCC 12, Ninja, CMake, ccache, Python 3,
Git, curl, xz, zlib and at least 12 GB free space:

```sh
JOBS=3 CC=gcc-12 CXX=g++-12 bash scripts/build-aosp-clang-linux-arm64-multi.sh r487747c
```

For old Clang 12, use the original
`scripts/build-aosp-clang-linux-arm64.sh` and its dedicated workflow.

**Authenticity rule:** a successful CMake/Ninja build is insufficient;
`smoke-results.json` must report passing executable, native C/C++, LLVM
cross-target, linker, and LTO/CFI tests before publishing.
