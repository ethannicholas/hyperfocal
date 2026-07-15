#!/bin/bash
#
# UI smoke suite: generates synthetic fixture stacks into the app's sandbox
# container (the one place the sandboxed app can read without a panel
# grant), then runs the XCUITest bundle.
#
#   Scripts/ui-test.sh                 full suite
#   Scripts/ui-test.sh --only NAME     one test (e.g. testFuseEndToEnd)
#   Scripts/ui-test.sh --keep-fixtures leave fixtures for reruns from Xcode
#
# Notes:
#  - Tests take over the mouse/keyboard while running; the screen must be
#    unlocked. The first run on a machine triggers a one-time Automation
#    permission prompt — approve it from the GUI session.
#  - bash (not sh) for pipefail: xcodebuild's exit code must survive the
#    output filter.

set -euo pipefail
cd "$(dirname "$0")/.."

ONLY=""
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --only) ONLY="$2"; shift 2 ;;
        --keep-fixtures) KEEP=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

# Probe copies drifting silently is a recurring hazard — fail loudly here.
for f in AppModel Stack ProjectStore RetouchSession; do
    if ! diff -q "App/Sources/$f.swift" "Probe/$f.swift" >/dev/null 2>&1; then
        echo "error: Probe/$f.swift is out of sync with App/Sources/$f.swift" >&2
        echo "       cp App/Sources/$f.swift Probe/$f.swift  (and re-run retouch-probe)" >&2
        exit 1
    fi
done

CONTAINER="$HOME/Library/Containers/com.ethannicholas.hyperfocal/Data"
if [ ! -d "$CONTAINER" ]; then
    echo "error: app container missing ($CONTAINER)" >&2
    echo "       launch Hyperfocal once so macOS creates it, then re-run" >&2
    exit 1
fi

echo "== building CLI (fixture generator)"
swift build >/dev/null
CLI=.build/debug/hyperfocal-cli

# Two copies of every fixture: the APP reads from its sandbox container
# (no panel grant needed there), but macOS container protection hides that
# path from the TEST RUNNER — so the runner gets an identical mirror in
# /tmp for its own frame-listing and existence checks. This shell can
# write both (Full Disk Access covers the container).
FIXTURES="$CONTAINER/tmp/hyperfocal-uitest/fixtures"
MIRROR="/tmp/hyperfocal-uitest-fixtures"
echo "== generating fixtures in $MIRROR (mirrored to app container)"
rm -rf "$FIXTURES" "$MIRROR"
mkdir -p "$MIRROR"
"$CLI" synth -o "$MIRROR/stack-a" --frames 6 --width 500 --height 400 --ext jpg >/dev/null
"$CLI" synth -o "$MIRROR/stack-b" --frames 6 --width 500 --height 400 --ext jpg >/dev/null
# Big enough that Cancel lands mid-registration.
"$CLI" synth -o "$MIRROR/cancel-stack" --frames 20 --width 3200 --height 2400 --ext jpg >/dev/null
# Ground truth would ingest as an extra frame.
rm -f "$MIRROR"/*/ground_truth.*
mkdir -p "$FIXTURES"
cp -R "$MIRROR"/. "$FIXTURES"/

echo "== regenerating Xcode project"
(cd App && xcodegen generate >/dev/null)

LOG="${TMPDIR:-/tmp}/hyperfocal-ui-test.log"
echo "== running UI tests (full log: $LOG)"
set +e  # xcodebuild's status must be captured, not fatal; grep may exit 1
xcodebuild test \
    -project App/Hyperfocal.xcodeproj \
    -scheme Hyperfocal \
    -destination 'platform=macOS' \
    ${ONLY:+-only-testing:"HyperfocalUITests/HyperfocalUITests/$ONLY"} 2>&1 \
    | tee "$LOG" \
    | grep -E "Test [Cc]ase|Test [Ss]uite|error:|\*\* TEST"
RESULT=${PIPESTATUS[0]}
set -e
if [ "$KEEP" -eq 0 ] && [ "$RESULT" -eq 0 ]; then
    rm -rf "$FIXTURES" "$MIRROR"
fi
if [ "$RESULT" -eq 0 ]; then
    echo "== UI TESTS PASSED"
else
    echo "== UI TESTS FAILED (xcodebuild exit $RESULT)" >&2
fi
exit "$RESULT"
