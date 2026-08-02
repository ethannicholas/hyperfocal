#!/bin/bash
#
# Build the app from the command line and (re)launch it — the everyday
# "run the app" loop. Default is the macOS SwiftUI app, built without
# opening Xcode.app; staying out of Xcode.app also sidesteps its
# Localizable.xcstrings rewrite (see CLAUDE.md): a plain command-line
# build leaves the catalog untouched. --qt builds and launches the Qt
# shell instead (the Windows/Linux UI, built here as a dev/validation
# target).
#
#   Scripts/run.sh                 Debug build, then launch
#   Scripts/run.sh Release         Release build, then launch
#   Scripts/run.sh --no-run        build only
#   Scripts/run.sh --qt            build + launch the Qt shell
#
# A running macOS-app instance is asked to quit first (politely, via
# AppleEvent, so the unsaved-work confirmation still protects a real
# session — cancel it and the script leaves that instance alone and does
# not relaunch). The Qt shell has no AppleEvent quit channel, so a
# running instance is reported and left alone instead — quit it yourself
# (stray duplicate instances confuse hover/tooltip behavior).

set -euo pipefail
cd "$(dirname "$0")/.."

# Checked-in derived artifacts (per-platform notices, translation catalogs)
# regenerate on every build so a NOTICE.md or Localizable.xcstrings edit
# always takes — the same reason xcodegen runs every time below. Both
# generators rewrite only files whose content changed, so incremental
# builds see no churn.
"$(Scripts/python-interpreter.sh)" Scripts/gen-notices.py
"$(Scripts/python-interpreter.sh)" Scripts/gen-translations.py >/dev/null

CONFIG=Debug
RUN=1
QT=0
for arg in "$@"; do
    case "$arg" in
        Debug|Release) CONFIG="$arg" ;;
        --no-run) RUN=0 ;;
        --qt) QT=1 ;;
        *) echo "usage: Scripts/run.sh [--qt] [Debug|Release] [--no-run]" >&2; exit 2 ;;
    esac
done

if [ "$QT" = 1 ]; then
    # The Qt shell has a single build configuration (QtShell/build.sh);
    # an explicit Debug/Release would be silently ignored — refuse it.
    if [ "$CONFIG" != Debug ]; then
        echo "run: --qt has no $CONFIG configuration (QtShell/build.sh builds one)" >&2
        exit 2
    fi
    QtShell/build.sh
    [ "$RUN" = 1 ] || exit 0
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

command -v xcodegen >/dev/null 2>&1 || {
    echo "run: xcodegen not found (brew install xcodegen)" >&2
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
