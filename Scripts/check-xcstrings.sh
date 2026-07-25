#!/bin/bash
# Guards App/Resources/Localizable.xcstrings against Xcode's string-catalog
# rewrite. Run by Scripts/ci-gate.sh and by .githooks/pre-commit.
#
# The catalog is hand-maintained (see CLAUDE.md). Opening the project in
# Xcode.app and building rewrites it: Xcode's *lightweight parser* extracts only
# ~101 of the catalog's 264 strings — it misses most SwiftUI literals and cannot
# see HyperfocalKit at all — and `xcstringstool sync` then marks every string it
# did not find as stale, deletes the untranslated stubs, and adds junk keys
# scraped from string interpolation ("%@", "%@%@", "%@ of %@").
#
# Nothing is wrong with the committed file: `xcstringstool sync
# --skip-marking-strings-stale` reproduces it byte-for-byte. The rewrite is pure
# damage, ~22k lines of churn that buries real translation edits, and it is a
# one-command fix — so catch it rather than let it land.
#
# Note the command-line build is innocent (SWIFT_EMIT_LOC_STRINGS is already NO;
# a clean `xcodebuild` leaves the file untouched). Only Xcode.app does this.
set -euo pipefail

FILE="${1:-$(dirname "$0")/../App/Resources/Localizable.xcstrings}"
[ -f "$FILE" ] || { echo "check-xcstrings: no such file: $FILE" >&2; exit 1; }

fail() {
    cat >&2 <<EOF
✗ Localizable.xcstrings looks like Xcode's rewrite, not the hand-maintained
  catalog: $1

  This happens when the project is opened in Xcode.app and built. It marks live
  translated strings "stale", drops untranslated stubs, and adds junk keys — it
  never adds translations. Discard it:

      git checkout App/Resources/Localizable.xcstrings

  (If you were adding a string, add its entry to the committed file by hand
  instead — keys are the English strings. See CLAUDE.md.)
EOF
    exit 1
}

grep -qE '"extractionState"[[:space:]]*:[[:space:]]*"stale"' "$FILE" \
    && fail 'it contains extractionState "stale" markers'

for junk in '%@' '%@%@' '%@ of %@'; do
    grep -qE "^[[:space:]]*\"${junk//%/%}\"[[:space:]]*:[[:space:]]*\{" "$FILE" \
        && fail "it contains the extracted-interpolation key \"$junk\""
done

exit 0
