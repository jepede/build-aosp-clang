#!/usr/bin/env bash
set -Eeuo pipefail

# Build a Linux/ARM64-hosted Android NDK from Google's r28c package and the
# matching AOSP LLVM sources. Every source/ref is fixed below. This script must
# run natively on aarch64 and never installs or invokes QEMU.

ROOTDIR="${ROOTDIR:-$(pwd)}"
NDK_VERSION=r28c
NDK_SHA1=a7b54a5de87fecd125a17d54f73c446199e72a64
NDK_SIZE=722261334
AOSP_REV=r416183b
LLVM_PROJECT_REF=c935d99d7cf2016289302412d708641d52d2f7ee
LLVM_ANDROID_REF=07e984be2f6074fb044e0ae06b9027f350fe8844
ANDROID_PLATFORM="${ANDROID_PLATFORM:-24}"
JOBS="${JOBS:-2}"

WORK="${WORK:-$ROOTDIR/.ndk-arm64-work}"
SRC_DIR="$WORK/src"
BUILD_DIR="$WORK/llvm-build"
LLVM_INSTALL="$WORK/llvm-install"
NDK_ZIP="$WORK/android-ndk-${NDK_VERSION}-linux.zip"
OFFICIAL_DIR="$WORK/official"
STAGE_DIR="$WORK/stage"
NDK_DIR="$STAGE_DIR/android-ndk-${NDK_VERSION}"
OUT_DIR="${OUT_DIR:-$ROOTDIR/out}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

case "$(uname -m)" in
  aarch64|arm64) ;;
  *) die "this build must run natively on aarch64; got $(uname -m)" ;;
esac
case "$ANDROID_PLATFORM" in ''|*[!0-9]*) die "ANDROID_PLATFORM must be numeric";; esac
case "$JOBS" in ''|*[!0-9]*) die "JOBS must be numeric";; esac
test "$JOBS" -ge 1 || die "JOBS must be at least 1"

mkdir -p "$WORK" "$SRC_DIR" "$STAGE_DIR" "$OUT_DIR"

download_official_ndk() {
  if [ ! -s "$NDK_ZIP" ]; then
    log "Downloading official Google NDK ${NDK_VERSION}"
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
      --output "$NDK_ZIP" \
      "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip"
  fi
  [ "$(stat -c '%s' "$NDK_ZIP")" = "$NDK_SIZE" ] || die "official NDK size mismatch"
  printf '%s  %s\n' "$NDK_SHA1" "$NDK_ZIP" | sha1sum -c -
  unzip -Z1 "$NDK_ZIP" | awk '/^\// || /(^|\/)\.\.\// { bad=1 } END { exit bad }'
  if [ ! -d "$OFFICIAL_DIR/android-ndk-${NDK_VERSION}" ]; then
    rm -rf "$OFFICIAL_DIR"
    mkdir -p "$OFFICIAL_DIR"
    unzip -q "$NDK_ZIP" -d "$OFFICIAL_DIR"
  fi
}

fetch_fixed_repo() {
  local repo="$1" ref="$2" dest="$3"
  if [ -d "$dest/.git" ] && [ "$(git -C "$dest" rev-parse HEAD)" = "$ref" ]; then
    return 0
  fi
  rm -rf "$dest"
  mkdir -p "$dest"
  git -C "$dest" init -q
  git -C "$dest" remote add origin "$repo"
  git -C "$dest" fetch --depth 1 origin "$ref"
  git -C "$dest" checkout -q --detach FETCH_HEAD
  test "$(git -C "$dest" rev-parse HEAD)" = "$ref" || die "fixed commit verification failed for $repo"
}

fetch_sources() {
  log "Fetching fixed AOSP LLVM sources"
  fetch_fixed_repo https://android.googlesource.com/toolchain/llvm-project \
    "$LLVM_PROJECT_REF" "$SRC_DIR/llvm-project"
  fetch_fixed_repo https://android.googlesource.com/toolchain/llvm_android \
    "$LLVM_ANDROID_REF" "$SRC_DIR/llvm_android"
}

apply_aosp_patches() {
  local patch_root="$SRC_DIR/llvm_android/patches"
  local patches_json="$patch_root/PATCHES.json"
  [ -f "$patches_json" ] || die "AOSP PATCHES.json is missing"
  git -C "$SRC_DIR/llvm-project" config user.email actions@github.com
  git -C "$SRC_DIR/llvm-project" config user.name 'GitHub Actions'
  mapfile -t patches < <(
    jq -r --argjson R 416183 '
      .[]
      | select((.platforms // ["android"]) | index("android"))
      | (.version_range.from // .start_version // -1) as $from
      | (.version_range.until // .end_version // null) as $until
      | select(($from <= $R) and (($until == null) or ($R < $until)))
      | (.rel_patch_path // .patch // .path // empty)
    ' "$patches_json" | sed '/^$/d'
  )
  log "Applying ${#patches[@]} AOSP patches for ${AOSP_REV}"
  for rel in "${patches[@]}"; do
    local patch_file="$patch_root/$rel"
    [ -f "$patch_file" ] || die "missing AOSP patch: $rel"
    if git -C "$SRC_DIR/llvm-project" am --keep-cr "$patch_file"; then
      continue
    fi
    git -C "$SRC_DIR/llvm-project" am --abort || true
    patch -p1 --forward --input="$patch_file" -d "$SRC_DIR/llvm-project" || die "failed to apply AOSP patch: $rel"
  done
}

build_llvm() {
  log "Building native ARM64 clang/lld"
  cmake -S "$SRC_DIR/llvm-project/llvm" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$LLVM_INSTALL" \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DLLVM_ENABLE_PROJECTS='clang;lld' \
    -DLLVM_TARGETS_TO_BUILD=AArch64 \
    -DLLVM_DEFAULT_TARGET_TRIPLE=aarch64-linux-android \
    -DCLANG_DEFAULT_LINKER=ld.lld \
    -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
    -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF -DCLANG_INCLUDE_TESTS=OFF \
    -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_BINDINGS=OFF -DLLVM_ENABLE_LTO=OFF \
    -DLLVM_BUILD_TOOLS=ON -DLLVM_INSTALL_TOOLCHAIN_ONLY=ON \
    -DLLVM_PARALLEL_LINK_JOBS=1
  ninja -C "$BUILD_DIR" -j"$JOBS" -l"$JOBS" install
}

rename_host_dirs() {
  local base="$NDK_DIR/toolchains/llvm/prebuilt"
  if [ -d "$base/linux-x86_64" ] && [ ! -e "$base/linux-arm64" ]; then
    mv "$base/linux-x86_64" "$base/linux-arm64"
  fi
  [ -d "$base/linux-arm64" ] || die "official LLVM host directory missing"
  rm -f "$base/linux-x86_64"
  ln -s linux-arm64 "$base/linux-x86_64"

  base="$NDK_DIR/prebuilt"
  if [ -d "$base/linux-x86_64" ] && [ ! -e "$base/linux-arm64" ]; then
    mv "$base/linux-x86_64" "$base/linux-arm64"
  fi
  [ -d "$base/linux-arm64" ] || die "official prebuilt host directory missing"
  rm -f "$base/linux-x86_64"
  ln -s linux-arm64 "$base/linux-x86_64"

  base="$NDK_DIR/shader-tools"
  if [ -d "$base/linux-x86_64" ] && [ ! -e "$base/linux-arm64" ]; then
    mv "$base/linux-x86_64" "$base/linux-arm64"
  fi
  if [ -d "$base/linux-arm64" ]; then
    rm -f "$base/linux-x86_64"
    ln -s linux-arm64 "$base/linux-x86_64"
  fi
}

replace_host_binaries() {
  local toolchain="$NDK_DIR/toolchains/llvm/prebuilt/linux-arm64"
  local tc_bin="$toolchain/bin"
  local built_res official_res built_version official_res_dir
  while IFS= read -r -d '' file; do
    file "$file" | grep -q ELF && rm -f "$file" || true
  done < <(find "$tc_bin" -maxdepth 1 -type f -print0)
  while IFS= read -r -d '' file; do
    local name="$(basename "$file")"
    rm -f "$tc_bin/$name"
    cp -a "$file" "$tc_bin/$name"
  done < <(find "$LLVM_INSTALL/bin" -maxdepth 1 -type f -perm -111 -print0)

  built_res="$(find "$LLVM_INSTALL/lib/clang" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [ -n "$built_res" ] || die "built clang resource directory missing"
  built_version="$(basename "$built_res")"
  official_res="$(find "$toolchain/lib/clang" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1 || true)"
  official_res_dir="$toolchain/lib/clang/$built_version"
  mkdir -p "$official_res_dir"
  cp -a "$built_res/include" "$official_res_dir/"
  if [ -n "$official_res" ] && [ -d "$official_res/lib" ] && [ "$official_res" != "$official_res_dir" ]; then
    cp -a "$official_res/lib" "$official_res_dir/"
  fi
}

replace_support_tools() {
  local prebuilt="$NDK_DIR/prebuilt/linux-arm64/bin"
  local shader_tools="$NDK_DIR/shader-tools/linux-arm64"
  local file

  # The official archive's support tools are x86_64. Remove those files and
  # provide native tools from Ubuntu; target libraries remain untouched.
  while IFS= read -r -d '' file; do
    file "$file" | grep -q ELF && rm -f "$file" || true
  done < <(find "$prebuilt" "$shader_tools" -type f -print0 2>/dev/null)

  cp -a "$(command -v make)" "$prebuilt/make"
  cp -a "$(command -v yasm)" "$prebuilt/yasm"
  ln -sfn /usr/bin/python3 "$prebuilt/python3"
  ln -sfn /usr/bin/yasm "$NDK_DIR/toolchains/llvm/prebuilt/linux-arm64/bin/yasm"
}

patch_host_tags() {
  while IFS= read -r -d '' file; do
    if grep -Iq . "$file"; then
      sed -i 's/linux-x86_64/linux-arm64/g' "$file"
    fi
  done < <(find "$NDK_DIR/build" "$NDK_DIR/ndk-build" "$NDK_DIR/ndk-gdb" \
    "$NDK_DIR/ndk-lldb" "$NDK_DIR/prebuilt/linux-arm64/bin" \
    "$NDK_DIR/toolchains/llvm/prebuilt/linux-arm64/bin" -type f -print0 2>/dev/null)
}

assemble_ndk() {
  log "Assembling ARM64-hosted NDK"
  rm -rf "$STAGE_DIR"
  mkdir -p "$STAGE_DIR"
  cp -a "$OFFICIAL_DIR/android-ndk-${NDK_VERSION}" "$NDK_DIR"
  rename_host_dirs
  replace_host_binaries
  replace_support_tools
  patch_host_tags

  local tc="$NDK_DIR/toolchains/llvm/prebuilt/linux-arm64"
  local clang="$tc/bin/clang"
  [ -x "$clang" ] || die "ARM64 clang was not staged"
  file "$clang" | grep -Eq 'ARM aarch64|AArch64' || die "staged clang is not ARM64"
  "$clang" --version | head -n 2
  printf '%s\n' 'int main(void) { return 0; }' \
    | "$tc/bin/aarch64-linux-android${ANDROID_PLATFORM}-clang" \
      --sysroot="$tc/sysroot" -x c -c -o "$WORK/probe.o" -
  file "$WORK/probe.o" | grep -Eq 'ARM aarch64|AArch64' || die "Android ARM64 compile probe failed"

  while IFS= read -r -d '' file; do
    if file "$file" | grep -q 'x86-64'; then
      die "x86_64 host executable remains: $file"
    fi
  done < <(find "$NDK_DIR/prebuilt/linux-arm64/bin" "$NDK_DIR/toolchains/llvm/prebuilt/linux-arm64/bin" "$NDK_DIR/shader-tools/linux-arm64" -type f -print0 2>/dev/null)
}

write_manifest() {
  local artifact="$OUT_DIR/android-ndk-${NDK_VERSION}-linux-arm64.tar.xz"
  log "Writing manifest and archive"
  tar -C "$STAGE_DIR" -cf - "android-ndk-${NDK_VERSION}" | xz -T"$JOBS" -6 > "$artifact"
  cat > "$OUT_DIR/android-ndk-${NDK_VERSION}-linux-arm64.manifest.txt" <<MANIFEST
artifact=$(basename "$artifact")
artifact_sha256=$(sha256sum "$artifact" | awk '{print $1}')
artifact_size=$(stat -c '%s' "$artifact")
host_arch=$(uname -m)
ndk_version=$NDK_VERSION
official_ndk_url=https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip
official_ndk_sha1=$NDK_SHA1
official_ndk_size=$NDK_SIZE
aosp_revision=$AOSP_REV
llvm_project_commit=$LLVM_PROJECT_REF
llvm_android_commit=$LLVM_ANDROID_REF
android_platform=$ANDROID_PLATFORM
qemu=disabled
source_repository=https://android.googlesource.com/toolchain/llvm-project
android_patches_repository=https://android.googlesource.com/toolchain/llvm_android
MANIFEST
  sha256sum "$artifact" "$OUT_DIR/android-ndk-${NDK_VERSION}-linux-arm64.manifest.txt"
}

download_official_ndk
fetch_sources
apply_aosp_patches
build_llvm
assemble_ndk
write_manifest
