#!/bin/bash
#
# Build the app and (re)launch it — the everyday "run the app" loop.
# The build itself is Scripts/build.sh (invoked here with the same
# arguments); this script only adds the launch. Default is the macOS
# SwiftUI app; --qt builds and launches the Qt shell instead (the
# Windows/Linux UI, built here as a dev/validation target).
#
#   Scripts/run.sh                 Debug build, then launch
#   Scripts/run.sh Release         Release build, then launch
#   Scripts/run.sh --qt            build + launch the Qt shell
#
# Build without launching: Scripts/build.sh.
#
# A running macOS-app instance is asked to quit first (politely, via
# AppleEvent, so the unsaved-work confirmation still protects a real
# session — cancel it and the script leaves that instance alone and does
# not relaunch). The Qt shell has no AppleEvent quit channel, so a
# running instance is reported and left alone instead — quit it yourself
# (stray duplicate instances confuse hover/tooltip behavior).

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=Debug
QT=0
for arg in "$@"; do
    case "$arg" in
        Debug|Release) CONFIG="$arg" ;;
        --qt) QT=1 ;;
        *) echo "usage: Scripts/run.sh [--qt] [Debug|Release]  (build only: Scripts/build.sh)" >&2; exit 2 ;;
    esac
done

Scripts/build.sh "$@"

if [ "$QT" = 1 ]; then
    if pgrep -xq hyperfocal-qt; then
        echo "run: a hyperfocal-qt instance is already running — quit it first" \
             "(no polite quit channel exists for the bare executable)." >&2
        exit 1
    fi
    echo "run: launching QtShell/build/hyperfocal-qt"
    nohup QtShell/build/hyperfocal-qt >/dev/null 2>&1 &
    disown
    exit 0
fi

# Resolve the product the build actually produced rather than globbing
# DerivedData (stale sibling build dirs make the glob ambiguous).
PRODUCTS=$(xcodebuild -project App/Hyperfocal.xcodeproj -scheme Hyperfocal \
    -configuration "$CONFIG" -destination 'platform=macOS' \
    -showBuildSettings build 2>/dev/null \
    | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p' | head -1)
APP="$PRODUCTS/Hyperfocal.app"
[ -d "$APP" ] || { echo "run: no app at $APP" >&2; exit 1; }

if pgrep -xq Hyperfocal; then
    echo "run: asking the running Hyperfocal to quit…"
    osascript -e 'tell application "Hyperfocal" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do
        pgrep -xq Hyperfocal || break
        sleep 0.2
    done
    if pgrep -xq Hyperfocal; then
        echo "run: still running (unsaved-work prompt?) — not relaunching." >&2
        exit 1
    fi
fi

echo "run: launching $APP"
open "$APP"
