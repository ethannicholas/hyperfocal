#!/bin/bash
# Build the Qt shell against a freshly built bridge dylib (macOS dev loop).
#   QtShell/build.sh            build everything
#   QtShell/build.sh --run      …and launch the shell
set -euo pipefail
cd "$(dirname "$0")/.."

# Regenerate the checked-in derived artifacts this build compiles into the
# executable (the windows-linux notices slice, the i18n catalogs) so master
# edits always take. Skipped when Python is absent — the checked-in copies
# then apply, and the commit gate keeps those fresh.
if command -v python3 >/dev/null 2>&1; then
    python3 Scripts/gen-notices.py
    python3 Scripts/gen-translations.py >/dev/null
else
    echo "== python3 not found; building with checked-in generated artifacts"
fi

# The bridge is a SwiftPM dynamic-library product (over the AppCore
# module) — the same build carries to Linux, where there is no Xcode.
BRIDGE_DIR="$PWD/.build/debug"

echo "== building libHyperfocalBridge (SwiftPM)"
swift build --product HyperfocalBridge

echo "== configuring + building Qt shell"
# Homebrew Qt needs the prefix hint on macOS; Linux distro Qt is found
# without one.
PREFIX_ARGS=()
[ "$(uname)" = Darwin ] && PREFIX_ARGS=(-DCMAKE_PREFIX_PATH=/opt/homebrew)
cmake -S QtShell -B QtShell/build -DHYPERFOCAL_BRIDGE_DIR="$BRIDGE_DIR" \
    "${PREFIX_ARGS[@]}" >/dev/null
cmake --build QtShell/build --parallel

echo "== built QtShell/build/hyperfocal-qt"
if [ "${1:-}" = "--run" ]; then
    exec QtShell/build/hyperfocal-qt
fi
