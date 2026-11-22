#!/usr/bin/env bash
# Rebuild pinned AOSP Clang for native Linux AArch64/glibc.
set -Eeuo pipefail

ROOTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVISION="${1:?Usage: $0 r450784e|r487747c|r510928|r536225|r584948c}"
case "$REVISION" in r450784e|r487747c|r510928|r536225|r584948c) ;; *) echo "Unsupported revision: $REVISION" >&2; exit 2;; esac
JOBS="${JOBS:-3}"
WORK_DIR="${WORK_DIR:-$ROOTDIR/.aosp-clang-$REVISION-work}"
OUT_DIR="${OUT_DIR:-$ROOTDIR/out/$REVISION}"
SRC_DIR="$WORK_DIR/src"
BUILD_DIR="$WORK_DIR/build"
STAGE_DIR="$WORK_DIR/stage/clang-$REVISION-linux-aarch64"
LOCK_FILE="$ROOTDIR/source-locks/$REVISION.json"
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

case "$(uname -m)" in aarch64|arm64) ;; *) die "Only native Linux AArch64 hosts are allowed";; esac
test -f "$LOCK_FILE" || die "Source lock missing: $LOCK_FILE"
getconf GNU_LIBC_VERSION
case "$JOBS" in 1|2|3|4) ;; *) die "JOBS must be 1-4";; esac
test "$JOBS" -le "$(nproc)" || die "JOBS exceeds runner CPU count"
test ! -e "$SRC_DIR" || die "Work dir already contains a source checkout; use a fresh WORK_DIR"
mkdir -p "$SRC_DIR" "$OUT_DIR" "$STAGE_DIR/bin"
df -h "$WORK_DIR"
free -h
test "$(df --output=avail -B1 "$WORK_DIR" | tail -n1)" -ge 12000000000 \
  || die "At least 12 GB free storage is required"
if test "$JOBS" -gt 1; then
  available_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  test "${available_kib:-0}" -ge "$((JOBS * 1900000))" \
    || die "Not enough RAM to build with JOBS=$JOBS"
fi

# Load immutable source locks committed into this repository.
eval "$(python3 - "$LOCK_FILE" "$REVISION" <<'PY'
import json, re, shlex, sys
r=json.load(open(sys.argv[1], encoding="utf8"))
assert r["aosp_revision"] == sys.argv[2]
for n in ["llvm_project", "llvm_android", "toolchain_utils"]:
    assert re.fullmatch("[0-9a-f]{40}", r["sources"][n])
for n in ["prebuilt_commit", "manifest_sha256"]:
    assert re.fullmatch("[0-9a-f]{40}" if n == "prebuilt_commit" else "[0-9a-f]{64}", r[n])
assert re.fullmatch(r"\d+\.\d+\.\d+", r["clang_version"])
for k,v in {
    "CLANG_VERSION":r["clang_version"],
    "AOSP_BUILD":r["build_id"],
    "LLVM_REV":r["llvm_revision"],
    "LLVM_PROJECT_REF":r["sources"]["llvm_project"],
    "LLVM_ANDROID_REF":r["sources"]["llvm_android"],
    "TOOLCHAIN_UTILS_REF":r["sources"]["toolchain_utils"],
    "MANIFEST_URL":r["manifest_url"],
    "MANIFEST_NAME":r["manifest_name"],
    "MANIFEST_SHA256":r["manifest_sha256"],
}.items():
    print("export " + k + "=" + shlex.quote(str(v)))
PY
)"
export CLANG_VERSION AOSP_BUILD LLVM_REV LLVM_PROJECT_REF LLVM_ANDROID_REF TOOLCHAIN_UTILS_REF MANIFEST_URL MANIFEST_NAME MANIFEST_SHA256
printf 'Building AOSP %s (Clang %s, build %s) for Linux AArch64/glibc\n' "$REVISION" "$CLANG_VERSION" "$AOSP_BUILD"

# Read the official manifest by its prebuilt git commit, then verify SHA256
# before it is permitted to determine any source checkout.
curl --fail --location --retry 5 "$MANIFEST_URL" | base64 --decode > "$WORK_DIR/$MANIFEST_NAME"
echo "$MANIFEST_SHA256  $WORK_DIR/$MANIFEST_NAME" | sha256sum --check --status \
  || die "Official manifest SHA256 mismatch"
python3 - "$WORK_DIR/$MANIFEST_NAME" <<'PY'
import os, sys, xml.etree.ElementTree as ET
projects={e.attrib.get("path"):e.attrib.get("revision") for e in ET.parse(sys.argv[1]).iter("project")}
for path, name in [("toolchain/llvm-project","LLVM_PROJECT_REF"),
                   ("toolchain/llvm_android","LLVM_ANDROID_REF"),
                   ("external/toolchain-utils","TOOLCHAIN_UTILS_REF")]:
    if projects.get(path) != os.environ[name]:
        raise SystemExit("Official manifest does not match pinned source: " + path)
print("Verified three source SHAs against immutable AOSP manifest",flush=True)
PY

fetch_repo() {
  local git_url="$1" ref="$2" dest="$3"
  mkdir -p "$dest"
  git init -q "$dest"
  git -C "$dest" remote add origin "$git_url"
  git -C "$dest" -c http.version=HTTP/1.1 fetch --depth 1 origin "$ref"
  git -C "$dest" checkout --quiet --detach FETCH_HEAD
  test "$(git -C "$dest" rev-parse HEAD)" = "$ref" || die "Source SHA mismatch for $git_url"
}
fetch_repo https://android.googlesource.com/toolchain/llvm-project "$LLVM_PROJECT_REF" "$SRC_DIR/llvm-project"
fetch_repo https://android.googlesource.com/toolchain/llvm_android "$LLVM_ANDROID_REF" "$SRC_DIR/llvm_android"
fetch_repo https://android.googlesource.com/platform/external/toolchain-utils "$TOOLCHAIN_UTILS_REF" "$SRC_DIR/toolchain-utils"

manager="$SRC_DIR/toolchain-utils/llvm_tools/patch_manager.py"
patches="$SRC_DIR/llvm_android/patches"
test -f "$manager" || die "Pinned AOSP patch manager missing: $manager"
test -f "$patches/PATCHES.json" || die "Pinned AOSP PATCHES.json missing"
# The official toolchain-utils patch manager has changed its CLI several
# times. Invoke as a Python module (required by newer llvm_tools imports) and
# pass ONLY the options recognized by this exact pinned version.
# Pinned toolchain-utils mixes absolute imports (failure_modes, get_llvm_hash)
# and package imports (llvm_tools.*) across AOSP revisions. Both roots are
# necessary; running the script directly retains the old import behavior.
export PYTHONPATH="$SRC_DIR/toolchain-utils/llvm_tools:$SRC_DIR/toolchain-utils${PYTHONPATH:+:$PYTHONPATH}"
pm_help=$(python3 "$manager" --help)
patch_args=(--patch_metadata_file "$patches/PATCHES.json" --src_path "$SRC_DIR/llvm-project")
if grep -q -- '--svn_version' <<< "$pm_help"; then
  patch_args+=(--svn_version "$LLVM_REV")
fi
if grep -q -- '--failure_mode' <<< "$pm_help"; then
  patch_args+=(--failure_mode fail)
fi
if grep -q -- '--filesdir_path' <<< "$pm_help"; then
  patch_args+=(--filesdir_path "$patches")
fi
if grep -q -- '--use_src_head' <<< "$pm_help"; then
  patch_args+=(--use_src_head)
fi
printf 'Patch manager options: %s\n' "${patch_args[*]}"
python3 "$manager" "${patch_args[@]}" | tee "$WORK_DIR/patch-manager.log"
git -C "$SRC_DIR/llvm-project" diff --binary > "$WORK_DIR/applied-aosp-patches.diff"

# Native Ubuntu AArch64 GCC builds Linux/glibc ELF, not Android/Bionic.
IFS=. read -r major minor patch <<< "$CLANG_VERSION"
cmake -S "$SRC_DIR/llvm-project/llvm" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="${CC:-gcc-12}" -DCMAKE_CXX_COMPILER="${CXX:-g++-12}" \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_INSTALL_PREFIX="$STAGE_DIR" \
  '-DCMAKE_EXE_LINKER_FLAGS=-static-libstdc++ -static-libgcc -Wl,--gc-sections' \
  '-DLLVM_ENABLE_PROJECTS=clang;lld' \
  '-DLLVM_TARGETS_TO_BUILD=AArch64;ARM;BPF;X86' \
  -DLLVM_HOST_TRIPLE=aarch64-unknown-linux-gnu \
  -DLLVM_DEFAULT_TARGET_TRIPLE=aarch64-unknown-linux-gnu \
  -DLLVM_VERSION_MAJOR="$major" -DLLVM_VERSION_MINOR="$minor" \
  -DLLVM_VERSION_PATCH="$patch" -DLLVM_VERSION_SUFFIX='' \
  -DCLANG_VERSION_PATCHLEVEL="$patch" -DCLANG_VERSION_SUFFIX='' \
  -DCLANG_VENDOR=Android \
  -DCLANG_REPOSITORY_STRING=https://android.googlesource.com/toolchain/llvm-project \
  -DCLANG_DEFAULT_LINKER=lld \
  -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_ENABLE_LTO=OFF \
  -DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_LINK_LLVM_DYLIB=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_ZLIB=ON -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_BINDINGS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF -DCLANG_INCLUDE_TESTS=OFF \
  -DCLANG_ENABLE_ARCMT=OFF -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
  -DLLVM_PARALLEL_LINK_JOBS=1

programs=(clang lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readobj
          llvm-size llvm-strings llvm-symbolizer llvm-profdata llvm-cov
          llvm-dis llvm-link llc opt)
ninja -C "$BUILD_DIR" -j"$JOBS" "${programs[@]}" clang-resource-headers

for tool in "${programs[@]}"; do
  test -f "$BUILD_DIR/bin/$tool" || die "Missing compiled tool: $tool"
  cp -L "$BUILD_DIR/bin/$tool" "$STAGE_DIR/bin/$tool"
  strip --strip-unneeded "$STAGE_DIR/bin/$tool"
done
for link in clang++ clang-cpp "clang-$major"; do ln -s clang "$STAGE_DIR/bin/$link"; done
ln -s lld "$STAGE_DIR/bin/ld.lld"
ln -s llvm-ar "$STAGE_DIR/bin/llvm-ranlib"
ln -s llvm-readobj "$STAGE_DIR/bin/llvm-readelf"
ln -s llvm-objcopy "$STAGE_DIR/bin/llvm-strip"
ln -s llvm-symbolizer "$STAGE_DIR/bin/llvm-addr2line"
mkdir -p "$STAGE_DIR/lib/clang" "$STAGE_DIR/share/licenses"
cp -a "$BUILD_DIR/lib/clang/." "$STAGE_DIR/lib/clang/"
# Older Clang drivers require a default CFI ignorelist; copy original only.
if test -s "$SRC_DIR/llvm-project/compiler-rt/lib/cfi/cfi_blacklist.txt"; then
  resource="$("$STAGE_DIR/bin/clang" -print-resource-dir)"
  case "$resource" in "$STAGE_DIR"/lib/clang/*) ;; *) die "Wrong resource path: $resource";; esac
  install -D -m 0644 "$SRC_DIR/llvm-project/compiler-rt/lib/cfi/cfi_blacklist.txt" "$resource/share/cfi_blacklist.txt"
fi
for project in llvm clang lld; do
  if test -f "$SRC_DIR/llvm-project/$project/LICENSE.TXT"; then
    cp "$SRC_DIR/llvm-project/$project/LICENSE.TXT" "$STAGE_DIR/share/licenses/$project-LICENSE.TXT"
  fi
done
cp "$WORK_DIR/$MANIFEST_NAME" "$WORK_DIR/applied-aosp-patches.diff" "$WORK_DIR/patch-manager.log" "$STAGE_DIR/"
cp "$LOCK_FILE" "$STAGE_DIR/SOURCE_LOCK.json"
cp "$BUILD_DIR/CMakeCache.txt" "$STAGE_DIR/"
cat > "$STAGE_DIR/AndroidVersion.txt" <<EOF
$CLANG_VERSION
based on $REVISION
Linux AArch64/glibc rebuild from Android build $AOSP_BUILD sources
EOF

python3 - "$STAGE_DIR" "$LOCK_FILE" <<'PY'
import hashlib, json, os, platform, subprocess, sys
from pathlib import Path
stage=Path(sys.argv[1])
lock=json.loads(Path(sys.argv[2]).read_text())
data=dict(lock)
data.update({
  "rebuilt_for_host":"aarch64-unknown-linux-gnu",
  "host":platform.platform(),
  "libc":platform.libc_ver(),
  "workflow_commit":os.environ.get("GITHUB_SHA"),
  "workflow_run_id":os.environ.get("GITHUB_RUN_ID"),
  "host_compiler":subprocess.check_output([os.environ.get("CC","gcc-12"),"--version"],text=True).splitlines()[0],
  "aosp_patch_diff_sha256":hashlib.sha256((stage/"applied-aosp-patches.diff").read_bytes()).hexdigest(),
  "llvm_targets":["AArch64","ARM","BPF","X86"],
})
(stage/"BUILD_INFO.json").write_text(json.dumps(data,indent=2)+"\n")
PY

HOST_GCC_TOOLCHAIN="${HOST_GCC_TOOLCHAIN:-/usr}" \
  python3 "$ROOTDIR/scripts/smoke-clang-linux-arm64-multi.py" "$STAGE_DIR" "$CLANG_VERSION"
ccache --show-stats || true

archive="aosp-clang-$REVISION-$AOSP_BUILD-linux-aarch64.tar.xz"
tar -C "$(dirname "$STAGE_DIR")" -c "$(basename "$STAGE_DIR")" \
  | xz -T1 -3 > "$OUT_DIR/$archive"
(
  cd "$OUT_DIR"
  sha256sum "$archive" > "$archive.sha256"
  stat -c %s "$archive" > "$archive.size"
  split -b 95m -d -a 2 "$archive" "$archive.part."
  sha256sum "$archive".part.* > "$archive.parts.sha256"
  count=$(find . -maxdepth 1 -name "$archive.part.*" -type f | wc -l)
  test "$count" -ge 1 && test "$count" -le 16 \
    || die "Archive exceeded 16 x 95 MiB part capacity ($count)"
  printf 'Full archive %s: %s bytes, %s parts\n' "$archive" "$(cat "$archive.size")" "$count"
  ls -lh "$archive" "$archive".part.*
  rm "$archive"
)
