#!/usr/bin/env bash
set -Eeuo pipefail

ROOTDIR="${ROOTDIR:-$(pwd)}"
WORK_DIR="${WORK_DIR:-$ROOTDIR/.aosp-clang-linux-arm64-work}"
OUT_DIR="${OUT_DIR:-$ROOTDIR/out}"
JOBS="${JOBS:-1}"
SRC_DIR="$WORK_DIR/src"
BUILD_DIR="$WORK_DIR/build"
STAGE_DIR="$WORK_DIR/stage/clang-r416183b-linux-aarch64"
LLVM_PROJECT_REF=c935d99d7cf2016289302412d708641d52d2f7ee
LLVM_ANDROID_REF=07e984be2f6074fb044e0ae06b9027f350fe8844
TOOLCHAIN_UTILS_REF=f5cc9231be5ecd6d0159b352dfb014926bfa77e6
PREBUILT_REF=4bb6424cb1615af408ae80871131f4da8c4ddadf
MANIFEST_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+/$PREBUILT_REF/clang-r416183b/manifest_7284624.xml?format=TEXT"
export LLVM_PROJECT_REF LLVM_ANDROID_REF TOOLCHAIN_UTILS_REF MANIFEST_URL

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
case "$(uname -m)" in aarch64|arm64) ;; *) die 'a native Linux ARM64 host is required';; esac
getconf GNU_LIBC_VERSION
case "$JOBS" in 1|2|3|4) ;; *) die 'JOBS must be 1, 2, 3, or 4';; esac
test "$JOBS" -le "$(nproc)" || die 'JOBS exceeds available CPUs'
test ! -e "$SRC_DIR" || die "use a fresh WORK_DIR; $SRC_DIR already exists"
mkdir -p "$WORK_DIR" "$SRC_DIR" "$OUT_DIR" "$STAGE_DIR/bin"
df -h "$WORK_DIR"
free -h
test "$(df --output=avail -B1 "$WORK_DIR" | tail -n 1)" -ge 10000000000 \
  || die 'at least 10 GB free space is required'
if [ "$JOBS" -gt 1 ]; then
  available_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  test "$available_kib" -ge "$((JOBS * 1800000))" || die 'insufficient memory for requested JOBS'
fi

curl --fail --location --retry 3 "$MANIFEST_URL" \
  | base64 --decode > "$WORK_DIR/manifest_7284624.xml"
python3 - "$WORK_DIR/manifest_7284624.xml" <<'PY'
import os
import sys
import xml.etree.ElementTree as ET
projects = {p.attrib['path']: p.attrib['revision'] for p in ET.parse(sys.argv[1]).iter('project')}
for path, env in [('toolchain/llvm-project', 'LLVM_PROJECT_REF'),
                  ('toolchain/llvm_android', 'LLVM_ANDROID_REF'),
                  ('external/toolchain-utils', 'TOOLCHAIN_UTILS_REF')]:
    if projects.get(path) != os.environ[env]:
        raise SystemExit('official build 7284624 manifest mismatch: ' + path)
print('Verified all three source pins against official build 7284624 manifest')
PY

fetch_repo() {
  local url="$1" ref="$2" dest="$3"
  git init -q "$dest"
  git -C "$dest" remote add origin "$url"
  git -C "$dest" -c http.version=HTTP/1.1 fetch --depth 1 origin "$ref"
  git -C "$dest" checkout -q --detach FETCH_HEAD
  test "$(git -C "$dest" rev-parse HEAD)" = "$ref" || die "source pin mismatch: $url"
}
fetch_repo https://android.googlesource.com/toolchain/llvm-project "$LLVM_PROJECT_REF" "$SRC_DIR/llvm-project"
fetch_repo https://android.googlesource.com/toolchain/llvm_android "$LLVM_ANDROID_REF" "$SRC_DIR/llvm_android"
fetch_repo https://android.googlesource.com/platform/external/toolchain-utils "$TOOLCHAIN_UTILS_REF" "$SRC_DIR/toolchain-utils"

# Use the same pinned patch manager and failure mode as the official source setup.
python3 "$SRC_DIR/toolchain-utils/llvm_tools/patch_manager.py" \
  --svn_version 416183 \
  --patch_metadata_file "$SRC_DIR/llvm_android/patches/PATCHES.json" \
  --filesdir_path "$SRC_DIR/llvm_android/patches" \
  --src_path "$SRC_DIR/llvm-project" \
  --use_src_head --failure_mode fail \
  | tee "$WORK_DIR/patch-manager.log"
git -C "$SRC_DIR/llvm-project" diff --binary > "$WORK_DIR/applied-aosp-patches.diff"

cmake -S "$SRC_DIR/llvm-project/llvm" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="${CC:-gcc}" -DCMAKE_CXX_COMPILER="${CXX:-g++}" \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_INSTALL_PREFIX="$STAGE_DIR" \
  -DCMAKE_EXE_LINKER_FLAGS='-static-libstdc++ -static-libgcc -Wl,--gc-sections' \
  -DLLVM_ENABLE_PROJECTS='clang;lld' \
  -DLLVM_TARGETS_TO_BUILD='AArch64;ARM;BPF;X86' \
  -DLLVM_HOST_TRIPLE=aarch64-unknown-linux-gnu \
  -DLLVM_DEFAULT_TARGET_TRIPLE=aarch64-unknown-linux-gnu \
  -DLLVM_VERSION_PATCH=5 -DLLVM_VERSION_SUFFIX='' \
  -DCLANG_VERSION_PATCHLEVEL=5 -DCLANG_VERSION_SUFFIX='' \
  '-DCLANG_VENDOR=Android (7284624 source, Linux arm64 rebuild, based on r416183b)' \
  -DCLANG_REPOSITORY_STRING=https://android.googlesource.com/toolchain/llvm-project \
  -DCLANG_DEFAULT_LINKER=lld \
  -DLLVM_USE_NEWPM=OFF \
  -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_ENABLE_LTO=OFF \
  -DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_LINK_LLVM_DYLIB=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_ZLIB=ON -DLLVM_ENABLE_BINDINGS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF -DCLANG_INCLUDE_TESTS=OFF \
  -DCLANG_ENABLE_ARCMT=OFF -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
  -DLLVM_PARALLEL_LINK_JOBS=1

programs=(clang lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readobj
          llvm-size llvm-strings llvm-symbolizer llvm-profdata llvm-cov
          llvm-dis llvm-link llc opt)
ninja -C "$BUILD_DIR" -j"$JOBS" "${programs[@]}" clang-resource-headers
for tool in "${programs[@]}"; do
  cp -L "$BUILD_DIR/bin/$tool" "$STAGE_DIR/bin/$tool"
  strip --strip-unneeded "$STAGE_DIR/bin/$tool"
done
for link in clang++ clang-cpp clang-12; do ln -s clang "$STAGE_DIR/bin/$link"; done
ln -s lld "$STAGE_DIR/bin/ld.lld"
ln -s llvm-ar "$STAGE_DIR/bin/llvm-ranlib"
ln -s llvm-objcopy "$STAGE_DIR/bin/llvm-strip"
ln -s llvm-readobj "$STAGE_DIR/bin/llvm-readelf"
ln -s llvm-symbolizer "$STAGE_DIR/bin/llvm-addr2line"
mkdir -p "$STAGE_DIR/lib/clang" "$STAGE_DIR/share/licenses"
cp -a "$BUILD_DIR/lib/clang/12.0.5" "$STAGE_DIR/lib/clang/"
# Clang 12's CFI driver requires this default ignorelist even when
# compiler-rt runtimes are intentionally not part of the minimal SDK.
# Copy the original file from the SAME pinned llvm-project checkout.
cfi_blacklist="$SRC_DIR/llvm-project/compiler-rt/lib/cfi/cfi_blacklist.txt"
test -s "$cfi_blacklist" || die "missing pinned compiler-rt CFI blacklist: $cfi_blacklist"
install -D -m 0644 "$cfi_blacklist" "$STAGE_DIR/lib/clang/12.0.5/share/cfi_blacklist.txt"
for project in llvm clang lld; do
  cp "$SRC_DIR/llvm-project/$project/LICENSE.TXT" "$STAGE_DIR/share/licenses/$project-LICENSE.TXT"
done
cp "$WORK_DIR/manifest_7284624.xml" "$WORK_DIR/applied-aosp-patches.diff" "$WORK_DIR/patch-manager.log" "$STAGE_DIR/"
cp "$BUILD_DIR/CMakeCache.txt" "$STAGE_DIR/"
cp "$ROOTDIR/AOSP_CLANG_LINUX_ARM64.md" "$STAGE_DIR/README.md"
printf '12.0.5\nbased on r416183b\nLinux ARM64 rebuild from Android build 7284624 sources\n' > "$STAGE_DIR/AndroidVersion.txt"
python3 - "$STAGE_DIR" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
stage = Path(sys.argv[1])
data = {
    'aosp_revision': 'r416183b', 'clang_version': '12.0.5',
    'source_android_build': '7284624', 'rebuilt_for_host': 'aarch64-linux-gnu',
    'source_manifest_url': os.environ['MANIFEST_URL'],
    'sources': {key: os.environ[key] for key in
                ['LLVM_PROJECT_REF', 'LLVM_ANDROID_REF', 'TOOLCHAIN_UTILS_REF']},
    'llvm_targets': ['AArch64', 'ARM', 'BPF', 'X86'],
    'host': platform.platform(), 'libc': platform.libc_ver(),
    'workflow_commit': os.environ.get('GITHUB_SHA'),
    'workflow_run_id': os.environ.get('GITHUB_RUN_ID'),
    'host_compiler': subprocess.check_output([os.environ.get('CC', 'gcc'), '--version'], text=True),
    'aosp_patch_diff_sha256': hashlib.sha256((stage / 'applied-aosp-patches.diff').read_bytes()).hexdigest(),
}
(stage / 'BUILD_INFO.json').write_text(json.dumps(data, indent=2) + '\n')
PY
python3 "$ROOTDIR/scripts/smoke-clang-linux-arm64.py" "$STAGE_DIR"
ccache --show-stats

archive=aosp-clang-r416183b-7284624-linux-aarch64.tar.xz
tar -C "$(dirname "$STAGE_DIR")" -c "$(basename "$STAGE_DIR")" \
  | xz -T1 -3 > "$OUT_DIR/$archive"
(cd "$OUT_DIR" && sha256sum "$archive" > "$archive.sha256")
stat -c '%s' "$OUT_DIR/$archive" > "$OUT_DIR/$archive.size"
# Artifact archives have a 512 MB connector limit. 95 MiB raw chunks keep
# each independently downloadable zip around 100 MB and easier to recover.
split -b 95m -d -a 2 "$OUT_DIR/$archive" "$OUT_DIR/$archive.part."
(cd "$OUT_DIR" && sha256sum "$archive".part.* > "$archive.parts.sha256")
part_count=$(find "$OUT_DIR" -maxdepth 1 -type f -name "$archive.part.*" | wc -l)
test "$part_count" -ge 1 && test "$part_count" -le 16 \
  || die "archive needs $part_count parts; increase upload steps before publishing"
printf 'Archive: %s | Bytes: %s | Parts: %s\n' \
  "$archive" "$(cat "$OUT_DIR/$archive.size")" "$part_count"
# Do not upload one large archive: the parts and manifests are the deliverable.
rm "$OUT_DIR/$archive"
ls -lh "$OUT_DIR/$archive.sha256" "$OUT_DIR/$archive.size" \
  "$OUT_DIR/$archive.parts.sha256" "$OUT_DIR/$archive".part.*
