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
| r450784e | 14.0.7 | 8508608 | **PASS** — [run 44999143557](https://github.com/jepede/build-aosp-clang/actions/runs/44999143557), 84/84 smoke, 2 parts, SHA256 verified |
| r487747c | 17.0.2 | 10087095 | **PASS**, 84/84 smoke, 2 parts, SHA256 verified |
| r510928 | 18.0.0 | 11368308 | **PASS**, 84/84 smoke, 2 parts, SHA256 verified |
| r536225 | 19.0.1 | 12833971 | **PASS**, 84/84 smoke, 2 parts, SHA256 verified |
| r584948c | 22.0.1 | 15323222 | **PASS**, 84/84 smoke, 2 parts, SHA256 verified |

All six requested versions have passed native AArch64/glibc verification.
The original Clang 12 was reused from its successful run without recompilation.
The other five passed their own GitHub Actions jobs, 84/84 smoke tests each,
outer Artifact ZIP SHA256 checks, 95 MiB raw part checks, original TAR/XZ
SHA256+size checks, and 16 AArch64 ELF/glibc interpreter checks per version. Source locks exist in `source-locks/r*.json`;
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

For the five new versions, use the cache-aware verified restore script. It reuses
an existing valid original archive and only downloads missing or invalid parts:

```sh
# Requires GitHub CLI (`gh auth login`) and native Linux AArch64/glibc.
git clone https://github.com/jepede/build-aosp-clang
cd build-aosp-clang
for rev in r450784e r487747c r510928 r536225 r584948c; do
  bash scripts/restore-aosp-clang-linux-arm64.sh "$rev" /root/work/neihe
done
```

Each version's four Artifact IDs, outer/raw SHA256 digests, sizes, actual expiry,
source pins, and all 16 binary checksums are recorded in
[jepede/gpt-exten/ARTIFACT_CACHE.md](https://github.com/jepede/gpt-exten/blob/main/ARTIFACT_CACHE.md).
GitHub API reported `expires_at=2027-02-20T07:38:21Z` for all five new versions;
GitHub lowered the requested 400-day retention to the repository's 90-day limit.

For manual recovery, download and unzip the manifest and both numbered parts
from run `44999143557` for the **same** revision, then run:

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
