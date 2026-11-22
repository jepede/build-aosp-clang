#!/usr/bin/env bash
# Cache-aware AOSP Clang Linux AArch64/glibc restore using GitHub Actions.
# Usage: bash scripts/restore-aosp-clang-linux-arm64.sh r450784e /opt/aosp-clang
set -Eeuo pipefail
REV="${1:?revision required}"
DEST="${2:-$PWD}"
case "$REV" in
  r450784e) VER=14.0.7; BUILD=8508608; SHA=8a825818fdabf54c6433020b028dd3fb59e7992b4556c030936873a84c9c11ad;;
  r487747c) VER=17.0.2; BUILD=10087095; SHA=bb269c5d477977ace1cccf73d91e81138ee9387c790da6a3e34cea632e509986;;
  r510928) VER=18.0.0; BUILD=11368308; SHA=f0dcd5a6d6fc16fd050cae7f30e112d19eab44fd505ee05f4934bff5815d8f90;;
  r536225) VER=19.0.1; BUILD=12833971; SHA=fd240d1af741e0ee748807a89cd4205b0f0df09630f2cd8ea6681822d583b047;;
  r584948c) VER=22.0.1; BUILD=15323222; SHA=f1bc84005936d0f87b628b937557e7e85365c0573daed7c812c0598b5c6a8869;;
  *) echo "Unsupported revision: $REV" >&2; exit 2;;
esac
case "$(uname -m)" in aarch64|arm64) ;; *) echo "Requires Linux AArch64 host" >&2; exit 2;; esac
command -v sha256sum >/dev/null
command -v tar >/dev/null
command -v readelf >/dev/null
mkdir -p "$DEST"
cd "$DEST"
RUN=44999143557
REPO=jepede/build-aosp-clang
BASE="aosp-clang-$REV-$BUILD-linux-aarch64.tar.xz"
PREFIX="aosp-clang-$REV-linux-aarch64"
TOOL="clang-$REV-linux-aarch64"
check_archive() { printf '%s  %s\n' "$SHA" "$BASE" | sha256sum -c --status; }
if test -f "$BASE" && check_archive; then
  echo "Verified local original archive cache: $BASE (no artifact re-download)"
else
  command -v gh >/dev/null || { echo "Install GitHub CLI gh and authenticate to GitHub first" >&2; exit 2; }
  if ! test -s "$BASE.parts.sha256" || ! test -s "$BASE.sha256" || ! test -s "$BASE.size"; then
    gh run download "$RUN" -R "$REPO" -n "$PREFIX-manifest" -D .
  fi
  grep -Fx -- "$SHA  $BASE" "$BASE.sha256" >/dev/null || {
    echo "Original SHA256 in downloaded manifest differs from pinned SHA256" >&2; exit 1;
  }
  for n in 00 01; do
    PART="$BASE.part.$n"
    if test -f "$PART" && grep -F -- "  $PART" "$BASE.parts.sha256" | sha256sum -c --status; then
      echo "Verified cached part $n: $PART"
    else
      rm -f -- "$PART"
      gh run download "$RUN" -R "$REPO" -n "$PREFIX-part-$n" -D .
    fi
  done
  sha256sum -c "$BASE.parts.sha256"
  cat "$BASE.part.00" "$BASE.part.01" > "$BASE.tmp"
  mv -- "$BASE.tmp" "$BASE"
  test "$(stat -c%s "$BASE")" = "$(cat "$BASE.size")" || { echo "Archive size mismatch" >&2; exit 1; }
  sha256sum -c "$BASE.sha256"
  check_archive || { echo "Pinned original SHA256 mismatch" >&2; exit 1; }
fi
tar -tJf "$BASE" >/dev/null
tar -xJf "$BASE" --no-same-owner
BIN="$PWD/$TOOL/bin"
test -x "$BIN/clang" && test -x "$BIN/ld.lld"
readelf -h "$BIN/clang" | grep -Eq 'Machine:[[:space:]]+AArch64'
readelf -l "$BIN/clang" | grep -F '/lib/ld-linux-aarch64.so.1'
! readelf -l "$BIN/clang" | grep -F '/system/bin/linker'
"$BIN/clang" --version | grep -F "$VER"
"$BIN/ld.lld" --version | grep -F "$VER"
"$BIN/clang" -dumpmachine | grep -Eq 'aarch64.*linux-gnu'
if command -v ldd >/dev/null; then
  ldd "$BIN/clang" | tee "$TOOL.ldd"
  ! grep -F 'not found' "$TOOL.ldd"
fi
echo "PASS: $TOOL Linux AArch64/glibc; SHA256=$SHA"
echo "Use: export PATH=\"$BIN:\$PATH\""
