#!/usr/bin/env python3
"""Split NOTICE.md into the per-platform copies the binaries bundle.

NOTICE.md is the master document — the complete, source-distribution view of
every third-party component, and what GitHub renders. Each shipped binary
should only carry the notices for what it actually contains, so this script
filters the master by the `<!-- notices: ... -->` markers into:

  Packaging/notices/macos/NOTICE.md          the macOS app bundle's copy
  Packaging/notices/windows-linux/NOTICE.md  the Qt shell's copy (compiled
                                             into its resources, and staged
                                             beside the executable by
                                             Scripts/package-windows.ps1)

A marker applies until the next one; the file starts as `all`. Tags: `all`
(every output), `macos`, `qt` (the Windows/Linux build), `source` (master
only — the CLI-only and build-time sections, which no app bundle ships).

Both outputs are checked in so builds stay hermetic. The dev build entry
points (Scripts/build.sh, QtShell/build.ps1) regenerate them
on every build; the packaging scripts verify them with --check (a release
ships what is committed, never silent regeneration); Scripts/ci-gate.sh and
the pre-commit hook fail when they drift.

Usage:  Scripts/gen-notices.py [--check]
        --check  exit 1 if the outputs would change (no writes)
"""

import argparse
import os
import re
import sys

# Windows consoles default to a legacy code page (cp1252), which cannot encode
# the ✓ this prints on success — the gate would then fail on its own success
# message, taking ci-gate.sh and the pre-commit hook down with it. Same guard
# as check-translations.py, for the same reason.
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, 'reconfigure'):
        _stream.reconfigure(encoding='utf-8', errors='replace')

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MASTER = os.path.join(ROOT, 'NOTICE.md')
TARGETS = {
    'macos': os.path.join(ROOT, 'Packaging/notices/macos/NOTICE.md'),
    'qt': os.path.join(ROOT, 'Packaging/notices/windows-linux/NOTICE.md'),
}
MARKER = re.compile(r'^<!--\s*notices:\s*([a-z ]+?)\s*-->$')
KNOWN_TAGS = {'all', 'source'} | set(TARGETS)


def split(master_text):
    outputs = {target: [] for target in TARGETS}
    active = {'all'}
    in_preamble_comment = False
    for line in master_text.splitlines():
        # The explanatory comment block at the top of the master is
        # master-only tooling documentation, not notice text.
        if line.startswith('<!-- Platform markers'):
            in_preamble_comment = True
        if in_preamble_comment:
            if line.rstrip().endswith('-->'):
                in_preamble_comment = False
            continue
        m = MARKER.match(line.strip())
        if m:
            active = set(m.group(1).split())
            unknown = active - KNOWN_TAGS
            if unknown:
                sys.exit(f'gen-notices: unknown tag(s) {sorted(unknown)} '
                         f'in marker: {line.strip()}')
            continue
        for target, lines in outputs.items():
            if 'all' in active or target in active:
                lines.append(line)

    rendered = {}
    for target, lines in outputs.items():
        text = '\n'.join(lines)
        text = re.sub(r'\n{3,}', '\n\n', text).strip() + '\n'
        rendered[target] = text
    return rendered


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()

    with open(MASTER, encoding='utf-8') as f:
        rendered = split(f.read())

    stale = []
    for target, text in rendered.items():
        path = TARGETS[target]
        current = None
        if os.path.exists(path):
            with open(path, encoding='utf-8') as f:
                current = f.read()
        if current == text:
            continue
        stale.append(path)
        if not args.check:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'w', encoding='utf-8') as f:
                f.write(text)
            print(f'wrote {os.path.relpath(path, ROOT)}')

    if args.check and stale:
        rel = ', '.join(os.path.relpath(p, ROOT) for p in stale)
        sys.exit(f'✗ per-platform notices out of date: {rel}\n'
                 '  Re-run Scripts/gen-notices.py and commit the result.')
    if args.check:
        print('✓ per-platform notices match NOTICE.md')


if __name__ == '__main__':
    main()
