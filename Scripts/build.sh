#!/bin/bash
#
# Build Hyperfocal from the command line — the one build entry point.
# Default is the macOS SwiftUI app, built without opening Xcode.app;
# staying out of Xcode.app also sidesteps its Localizable.xcstrings
# rewrite (see CLAUDE.md): a plain command-line build leaves the catalog
# untouched. --qt builds the Qt shell instead (the Windows/Linux UI,
# also built on macOS as a dev/validation target) — this is the Linux
# build entry point; Windows builds with Scripts/build.ps1.
#
#   Scripts/build.sh                 Debug build of the macOS app
#   Scripts/build.sh Release         Release build of the macOS app
#   Scripts/build.sh --qt            build the Qt shell (bridge + CMake)
#
# Build-and-launch is Scripts/run.sh, which delegates the build here.

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=Debug
QT=0
for arg in "$@"; do
    case "$arg" in
        Debug|Release) CONFIG="$arg" ;;
        --qt) QT=1 ;;
        *) echo "usage: Scripts/build.sh [--qt] [Debug|Release]" >&2; exit 2 ;;
    esac
done

# Regenerate the checked-in derived artifacts the builds compile in
# (per-platform notices, translation catalogs) so a NOTICE.md or
# Localizable.xcstrings edit always takes — the same reason xcodegen runs
# every time below. Both generators rewrite only files whose content
# changed, so incremental builds see no churn. Skipped when Python is
# absent — the checked-in copies then apply, and the commit gate keeps
# those fresh.
if PY=$(Scripts/python-interpreter.sh 2>/dev/null); then
    "$PY" Scripts/gen-notices.py
    "$PY" Scripts/gen-translations.py >/dev/null
else
    echo "== no working Python 3; building with checked-in generated artifacts"
fi

if [ "$QT" = 1 ]; then
    # The Qt shell has a single build configuration; an explicit
    # Debug/Release would be silently ignored — refuse it.
    if [ "$CONFIG" != Debug ]; then
        echo "build: --qt has no $CONFIG configuration (the Qt shell builds one)" >&2
        exit 2
    fi

    # The bridge is a SwiftPM dynamic-library product (over the AppCore
    # module) — the same build carries to Linux, where there is no Xcode.
    BRIDGE_DIR="$PWD/.build/debug"

    echo "== building libHyperfocalBridge (SwiftPM)"
    swift build --product HyperfocalBridge

    echo "== configuring + building Qt shell"
    # One always-non-empty args array: macOS's /bin/bash is 3.2, where
    # set -u + expanding an EMPTY array ("${A[@]}") dies "unbound
    # variable" (fixed in bash 4.4, so Linux never sees it).
    CMAKE_ARGS=(-DHYPERFOCAL_BRIDGE_DIR="$BRIDGE_DIR")
    # Homebrew Qt needs the prefix hint on macOS; Linux distro Qt is found
    # without one.
    [ "$(uname)" = Darwin ] && CMAKE_ARGS+=(-DCMAKE_PREFIX_PATH=/opt/homebrew)
    # On Linux the bridge links libwgpu_native.so (GPU fusion is compiled in,
    # not opted into — see Package.swift), so the shell's link needs the
    # library findable to resolve the bridge's transitive symbols. rpath-link
    # is link-time only, on purpose: no rpath is baked (the same policy as CI
    # and packaging), and Scripts/run.sh supplies LD_LIBRARY_PATH at launch.
    # macOS links Metal instead; Windows builds via build.ps1, where
    # Scripts/windows-env.ps1 does this job for wgpu_native.dll.
    if [ "$(uname)" != Darwin ]; then
        WGPU_LIB="${WGPU_ROOT:-$PWD/../wgpu-native}/lib"
        if [ -d "$WGPU_LIB" ]; then
            CMAKE_ARGS+=(-DCMAKE_EXE_LINKER_FLAGS="-Wl,-rpath-link,$WGPU_LIB")
        else
            echo "== warning: $WGPU_LIB not found (Scripts/fetch-wgpu.sh," \
                 "or set WGPU_ROOT) — the Qt link will fail on wgpu symbols"
        fi
    fi
    cmake -S QtShell -B QtShell/build "${CMAKE_ARGS[@]}" >/dev/null
    cmake --build QtShell/build --parallel

    echo "== built QtShell/build/hyperfocal-qt"
    exit 0
fi

command -v xcodegen >/dev/null 2>&1 || {
    echo "build: xcodegen not found (brew install xcodegen)" >&2
    exit 1
}

# The .xcodeproj and App/Info.plist are generated from App/project.yml (and
# gitignored) — regenerate every time so project.yml edits always take.
(cd App && xcodegen generate >/dev/null)

xcodebuild -project App/Hyperfocal.xcodeproj -scheme Hyperfocal \
    -configuration "$CONFIG" -destination 'platform=macOS' \
    -quiet build
