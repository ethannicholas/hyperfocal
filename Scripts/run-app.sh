#!/bin/bash
#
# Build the macOS app from the command line and (re)launch it — the everyday
# "run the app" loop without opening Xcode.app. Staying out of Xcode.app also
# sidesteps its Localizable.xcstrings rewrite (see CLAUDE.md): a plain
# command-line build leaves the catalog untouched.
#
#   Scripts/run-app.sh             Debug build, then launch
#   Scripts/run-app.sh Release     Release build, then launch
#   Scripts/run-app.sh --no-run    build only
#
# A running instance is asked to quit first (politely, via AppleEvent, so the
# unsaved-work confirmation still protects a real session — cancel it and the
# script leaves that instance alone and does not relaunch).

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=Debug
RUN=1
for arg in "$@"; do
    case "$arg" in
        Debug|Release) CONFIG="$arg" ;;
        --no-run) RUN=0 ;;
        *) echo "usage: Scripts/run-app.sh [Debug|Release] [--no-run]" >&2; exit 2 ;;
    esac
done

command -v xcodegen >/dev/null 2>&1 || {
    echo "run-app: xcodegen not found (brew install xcodegen)" >&2
    exit 1
}

# The .xcodeproj and App/Info.plist are generated from App/project.yml (and
# gitignored) — regenerate every time so project.yml edits always take.
(cd App && xcodegen generate >/dev/null)

xcodebuild -project App/Hyperfocal.xcodeproj -scheme Hyperfocal \
    -configuration "$CONFIG" -destination 'platform=macOS' \
    -quiet build

[ "$RUN" = 1 ] || exit 0

# Resolve the product the build actually produced rather than globbing
# DerivedData (stale sibling build dirs make the glob ambiguous).
PRODUCTS=$(xcodebuild -project App/Hyperfocal.xcodeproj -scheme Hyperfocal \
    -configuration "$CONFIG" -destination 'platform=macOS' \
    -showBuildSettings build 2>/dev/null \
    | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p' | head -1)
APP="$PRODUCTS/Hyperfocal.app"
[ -d "$APP" ] || { echo "run-app: no app at $APP" >&2; exit 1; }

if pgrep -xq Hyperfocal; then
    echo "run-app: asking the running Hyperfocal to quit…"
    osascript -e 'tell application "Hyperfocal" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do
        pgrep -xq Hyperfocal || break
        sleep 0.2
    done
    if pgrep -xq Hyperfocal; then
        echo "run-app: still running (unsaved-work prompt?) — not relaunching." >&2
        exit 1
    fi
fi

echo "run-app: launching $APP"
open "$APP"
