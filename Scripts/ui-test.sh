#!/bin/bash
#
# UI smoke suite: generates synthetic fixture stacks into the app's sandbox
# container (the one place the sandboxed app can read without a panel
# grant), then runs the XCUITest bundle.
#
#   Scripts/ui-test.sh                 full suite
#   Scripts/ui-test.sh --only NAME     one class or test
#                                      (e.g. ToneJourneyTests or
#                                       ToneJourneyTests/testToneJourney)
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

# Fixtures live in the app's sandbox container: the sandboxed app reads
# its own container without a panel grant, and the test runner can READ
# it via absolute paths (it just can't write there — which is why the app
# writes command results/exports into out/ for the runner to inspect).
FIXTURES="$CONTAINER/tmp/hyperfocal-uitest/fixtures"
echo "== generating fixtures in $FIXTURES"
rm -rf "$FIXTURES"
mkdir -p "$FIXTURES/out"
"$CLI" synth -o "$FIXTURES/stack-a" --frames 6 --width 500 --height 400 --ext jpg >/dev/null
"$CLI" synth -o "$FIXTURES/stack-b" --frames 6 --width 500 --height 400 --ext jpg >/dev/null
# Distinct frame names per stack: same-named frames in two stacks give two
# UI elements the same accessibility identifier, which breaks test queries.
for f in "$FIXTURES/stack-b"/frame_*; do
    mv "$f" "$FIXTURES/stack-b/b_$(basename "$f" | sed s/^frame_//)"
done
# Big enough that Cancel lands mid-registration.
"$CLI" synth -o "$FIXTURES/cancel-stack" --frames 20 --width 3200 --height 2400 --ext jpg >/dev/null
# A flash-misfire frame (index 2; must not be the reference frame) for the
# auto-exclusion test.
"$CLI" synth -o "$FIXTURES/misfire-stack" --frames 8 --width 500 --height 400 --ext jpg --misfire-frame 2 >/dev/null
# Ground truth would ingest as an extra frame.
rm -f "$FIXTURES"/*/ground_truth.*

echo "== regenerating Xcode project"
(cd App && xcodegen generate >/dev/null)

LOG="${TMPDIR:-/tmp}/hyperfocal-ui-test.log"
echo "== running UI tests (full log: $LOG)"
set +e  # xcodebuild's status must be captured, not fatal; grep may exit 1
xcodebuild test \
    -project App/Hyperfocal.xcodeproj \
    -scheme Hyperfocal \
    -destination 'platform=macOS' \
    ${ONLY:+-only-testing:"HyperfocalUITests/$ONLY"} 2>&1 \
    | tee "$LOG" \
    | grep -E "Test [Cc]ase|Test [Ss]uite|error:|\*\* TEST"
RESULT=${PIPESTATUS[0]}
set -e
if [ "$KEEP" -eq 0 ] && [ "$RESULT" -eq 0 ]; then
    rm -rf "$FIXTURES"
fi
if [ "$RESULT" -eq 0 ]; then
    echo "== UI TESTS PASSED"
else
    echo "== UI TESTS FAILED (xcodebuild exit $RESULT)" >&2
fi
exit "$RESULT"
