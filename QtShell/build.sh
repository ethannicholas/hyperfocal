#!/bin/bash
# Build the Qt shell against a freshly built bridge dylib (macOS dev loop).
#   QtShell/build.sh            build everything
#   QtShell/build.sh --run      …and launch the shell
set -euo pipefail
cd "$(dirname "$0")/.."

BRIDGE_DIR="$PWD/QtShell/build/bridge"

echo "== building HyperfocalBridge.dylib"
(cd App && xcodegen generate >/dev/null)
xcodebuild -project App/Hyperfocal.xcodeproj -scheme HyperfocalBridge \
    -configuration Debug -destination 'platform=macOS' \
    CONFIGURATION_BUILD_DIR="$BRIDGE_DIR" build \
    | grep -E "error:|warning:|BUILD" | grep -v "warning: Run script" || true

echo "== configuring + building Qt shell"
cmake -S QtShell -B QtShell/build -DHYPERFOCAL_BRIDGE_DIR="$BRIDGE_DIR" \
    -DCMAKE_PREFIX_PATH=/opt/homebrew >/dev/null
cmake --build QtShell/build --parallel

echo "== built QtShell/build/hyperfocal-qt"
if [ "${1:-}" = "--run" ]; then
    exec QtShell/build/hyperfocal-qt
fi
