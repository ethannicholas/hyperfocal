#!/usr/bin/env bash
# Fetch the pinned wgpu-native prebuilt (headers + static/dynamic libs) for
# the wgpu compute backend (HYPERFOCAL_WGPU=1 builds). Same pattern as the
# aqt/vcpkg dependencies: nothing vendored in the repo, the pin and its
# sha256 live here, and the fetch is idempotent — a destination already on
# the pinned tag is left untouched (safe for CI caches and repeated runs).
#
# Usage: Scripts/fetch-wgpu.sh [dest] [platform]
#   dest      where to unpack (default: ../wgpu-native — Package.swift's
#             default WGPU_ROOT)
#   platform  release-asset platform (default: autodetected), one of:
#             macos-aarch64 macos-x86_64 linux-aarch64 linux-x86_64
#             windows-aarch64-msvc windows-x86_64-msvc
#
# Works on macOS, Linux, and Windows Git Bash (ci-gate.sh's environment).
set -euo pipefail

TAG=v29.0.1.1

# sha256 of each release asset, recorded from the GitHub release
# (gh api repos/gfx-rs/wgpu-native/releases/tags/$TAG). Bumping TAG means
# re-recording every hash — that is the point.
sha_for() {
    case "$1" in
        macos-aarch64)        echo a5797a37b1adf720bcd5dcffb291edbbd5b7b14be0a3874c28e6393a655a7a3e ;;
        macos-x86_64)         echo 8e2f7378548ddd0e2cf21e7d864dda46e953f0af724855a33778b85ead206d41 ;;
        linux-aarch64)        echo 015fcdf1dbae82e614a783cc38017e5399ae0927a889fe9b69c9b664bc61b47a ;;
        linux-x86_64)         echo 95a4d90c071005a98d03eab348beaa6b07e16eb00d1dcdb9f8348f75eb97ec5a ;;
        windows-aarch64-msvc) echo 4a876421a8c1e5fe72f849b3722214280fe485cb1c56f77f8b0c82414be5b29f ;;
        windows-x86_64-msvc)  echo 7e67d7445c42aeb85e30f88930fd8d7d83ee769e3390aeb1ada75ebf3cf78132 ;;
        *) echo "fetch-wgpu: no pinned sha256 for platform '$1'" >&2; exit 1 ;;
    esac
}

detect_platform() {
    local os arch
    case "$(uname -s)" in
        Darwin) os=macos ;;
        Linux)  os=linux ;;
        MINGW*|MSYS*|CYGWIN*) os=windows ;;
        *) echo "fetch-wgpu: unsupported OS $(uname -s)" >&2; exit 1 ;;
    esac
    case "$(uname -m)" in
        arm64|aarch64) arch=aarch64 ;;
        x86_64|amd64)  arch=x86_64 ;;
        *) echo "fetch-wgpu: unsupported arch $(uname -m)" >&2; exit 1 ;;
    esac
    if [ "$os" = windows ]; then echo "$os-$arch-msvc"; else echo "$os-$arch"; fi
}

DEST=${1:-"$(cd "$(dirname "$0")/.." && pwd)/../wgpu-native"}
PLATFORM=${2:-"$(detect_platform)"}
EXPECTED_SHA=$(sha_for "$PLATFORM")
ASSET="wgpu-$PLATFORM-release.zip"
URL="https://github.com/gfx-rs/wgpu-native/releases/download/$TAG/$ASSET"

# Already on the pinned tag? Done. (The tag file ships inside the archive.)
if [ "$(cat "$DEST/wgpu-native-meta/wgpu-native-git-tag" 2>/dev/null)" = "$TAG" ]; then
    echo "fetch-wgpu: $DEST already at $TAG"
    exit 0
fi

echo "fetch-wgpu: $ASSET ($TAG) -> $DEST"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/$ASSET" "$URL"

if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL_SHA=$(sha256sum "$TMP/$ASSET" | cut -d' ' -f1)
else
    ACTUAL_SHA=$(shasum -a 256 "$TMP/$ASSET" | cut -d' ' -f1)
fi
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    echo "fetch-wgpu: sha256 MISMATCH for $ASSET" >&2
    echo "  expected $EXPECTED_SHA" >&2
    echo "  actual   $ACTUAL_SHA" >&2
    exit 1
fi

# unzip where available; bsdtar (macOS tar, Windows 10+ tar) reads zip too.
mkdir -p "$TMP/unpack"
if command -v unzip >/dev/null 2>&1; then
    unzip -q "$TMP/$ASSET" -d "$TMP/unpack"
else
    tar -xf "$TMP/$ASSET" -C "$TMP/unpack"
fi
[ -f "$TMP/unpack/wgpu-native-meta/wgpu-native-git-tag" ] || {
    echo "fetch-wgpu: archive layout unexpected (no wgpu-native-meta)" >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
mv "$TMP/unpack" "$DEST"
echo "fetch-wgpu: done — build with HYPERFOCAL_WGPU=1 WGPU_ROOT=$DEST"
