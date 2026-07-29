#!/usr/bin/env python3
"""Translation coverage gate for both UIs.

A string that reaches either shell untranslated is a bug of the same severity
as a feature that shipped in only one shell (CLAUDE.md). This fails on:

  1. a user-facing literal in the Qt shell not wrapped in qsTr()/tr()
  2. a qsTr()/tr() or localizedString() key with no catalog entry
  3. a catalog entry missing a translation in any shipping language
  4. a generated catalog that has drifted from Localizable.xcstrings

Run from Scripts/ci-gate.sh and .githooks/pre-commit; also runnable alone.
"""

import json
import os
import re
import subprocess
import sys

# Windows consoles default to a legacy code page (cp1252 here), which cannot
# encode the ✓/✗/× below — the gate would then fail on its own success message,
# taking ci-gate.sh down with it. Force UTF-8 on both streams.
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, 'reconfigure'):
        _stream.reconfigure(encoding='utf-8', errors='replace')

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, 'App/Resources/Localizable.xcstrings')
LANGUAGES = ['de', 'es', 'fr', 'it', 'ja', 'ko', 'nl', 'pt-BR', 'ru',
             'zh-Hans']

QT_QML = ['QtShell/Main.qml', 'QtShell/CropOverlay.qml',
          'QtShell/RetouchOverlay.qml', 'QtShell/BrushCircle.qml']
# main.cpp is bootstrap + the selftest harness: its literals are env-var
# names, QML module names and stderr diagnostics, none of which a user reads.
# Shell.cpp is where the C++ side builds dialogs, so it is scanned.
QT_CPP = ['QtShell/Shell.cpp', 'QtShell/PaneItem.cpp']
SWIFT_DIRS = ['AppCore', 'Sources/HyperfocalKit']

# Literals that are not user-facing text. Anything matching stays bare.
NOT_UI = re.compile(
    r'''^(?:
          [a-z0-9_.\-/]*                      # ids, settings keys, suffixes
        | [A-Za-z][A-Za-z0-9_]*\.[a-z]{1,5}   # file names (Shell.h, a.png)
        | [A-Z][A-Z0-9_]{2,}                  # env vars, macro names
        | [a-z][A-Za-z0-9]*                   # camelCase identifiers
        | \#[0-9a-fA-F]{3,8}                  # colors
        | [\d\s.,:%\-+×°/]+                   # numbers, ratios, units
        | (?:Ctrl|Alt|Shift|Meta)\+.*         # accelerators
        | Up|Down|Left|Right|Space|Return|Esc|Tab|Backspace   # key names
        | [A-Z]                               # single-key shortcuts
        | \d+:\d+                             # aspect ratios
        | Menlo|Consolas|monospace            # font families
        | Hyperfocal|Shell|Main               # app / QML component names
        | DMap|PMax                           # algorithm names, never localized
        | \\u[0-9a-fA-F]{4}                   # escaped glyphs
        | .*://.*                             # urls
        | qrc:.*|image://.*
        )$''', re.X)

# Symbols and punctuation carry no language — chevrons, warning triangles,
# ellipses used as bare glyphs.
HAS_LETTER = re.compile(r'[^\W\d_]', re.UNICODE)

# QML properties whose value is never displayed text. A literal assigned to
# one of these is data (an id, a raw enum value, a key sequence), not a
# string the user reads.
NON_TEXT_PROPS = {
    'objectName', 'property', 'source', 'icon.source', 'font.family',
    'sequence', 'sequences', 'shortcut', 'section', 'sliderId', 'key',
    'value', 'suffix', 'defaultSuffix', 'textRole', 'valueRole', 'color',
    'uri', 'prefix', 'id', 'name',
}
# The identifier immediately before a literal: `title: "…"`, `value: "…"`.
ASSIGNED_PROP = re.compile(r'([A-Za-z_][\w.]*)\s*:\s*$')

# C++ lines that never carry UI text.
CPP_SKIP = re.compile(r'#\s*include|qgetenv|qputenv|qEnvironmentVariable'
                      r'|setObjectName|qWarning|qCritical|qDebug')

# Lines opted out with an explicit marker (raw enum values kept verbatim).
OPT_OUT = re.compile(r'//\s*i18n-exempt')

STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')
WRAPPED = re.compile(r'\b(?:qsTr|tr|QStringLiteral|QLatin1String)\(\s*"'
                     r'((?:[^"\\]|\\.)*)"')
KEY_CALL = re.compile(r'\b(?:qsTr|tr)\(\s*"((?:[^"\\]|\\.)*)"')
SWIFT_KEY = re.compile(r'\blocalizedString\(\s*"((?:[^"\\]|\\.)*)"')


def unescape(s):
    # Source-level escapes only; never unicode_escape, which mangles the
    # literal UTF-8 (en dashes, curly quotes, σ) these files contain.
    return s.replace('\\"', '"').replace('\\\\', '\\').replace('\\n', '\n')


def read(path):
    with open(os.path.join(ROOT, path), encoding='utf-8') as f:
        return f.read().split('\n')


def bare_literals(paths, cpp):
    """User-facing literals not inside a translation call."""
    out = []
    for path in paths:
        if not os.path.exists(os.path.join(ROOT, path)):
            continue
        for i, line in enumerate(read(path), 1):
            stripped = line.strip()
            if stripped.startswith('//') or stripped.startswith('*'):
                continue
            if OPT_OUT.search(line):
                continue
            if cpp and CPP_SKIP.search(line):
                continue
            # Blank out every already-wrapped literal, then whatever quoted
            # text is left on the line is unwrapped.
            rest = WRAPPED.sub('', line) if cpp else \
                re.sub(r'\bqsTr\(\s*"((?:[^"\\]|\\.)*)"', '', line)
            for m in STRING.finditer(rest):
                text = unescape(m.group(1))
                if not text or NOT_UI.match(text):
                    continue
                if not HAS_LETTER.search(text):
                    continue
                if not cpp:
                    prop = ASSIGNED_PROP.search(rest[:m.start()])
                    if prop and prop.group(1) in NON_TEXT_PROPS:
                        continue
                out.append((path, i, text))
    return out


def scan_keys(used, path, pattern):
    """Collect translation keys from one file, matching across line breaks.

    Whole-file rather than line-by-line, and that is the whole point: these
    calls wrap as soon as the `comment:` argument is added, putting the literal
    on the line *after* `localizedString(` / `qsTr(`. Tested one line at a time
    the pattern then matched nothing, so every wrapped call was invisible to
    this gate — it could only ever have caught the strings that happened to fit
    on one line. Line numbers still come from the match offset so the report
    points at the literal.
    """
    text = '\n'.join(read(path))
    for m in pattern.finditer(text):
        line = text.count('\n', 0, m.start()) + 1
        used.setdefault(unescape(m.group(1)), []).append('%s:%d' % (path, line))


def keys_used():
    used = {}
    for path in QT_QML + QT_CPP:
        if not os.path.exists(os.path.join(ROOT, path)):
            continue
        scan_keys(used, path, KEY_CALL)
    for d in SWIFT_DIRS:
        for name in sorted(os.listdir(os.path.join(ROOT, d))):
            if not name.endswith('.swift'):
                continue
            scan_keys(used, os.path.join(d, name), SWIFT_KEY)
    return used


def main():
    with open(CATALOG, encoding='utf-8') as f:
        strings = json.load(f)['strings']

    problems = []

    # 1. unwrapped user-facing literals
    for path, line, text in (bare_literals(QT_QML, cpp=False)
                             + bare_literals(QT_CPP, cpp=True)):
        problems.append(
            '%s:%d: literal not wrapped for translation: %r\n'
            '    Wrap it in qsTr()/tr(), or if it is not user-facing text '
            'mark the line // i18n-exempt' % (path, line, text))

    # 2. keys with no catalog entry
    for key, sites in sorted(keys_used().items()):
        if key not in strings:
            problems.append(
                '%s: no catalog entry for %r\n'
                '    Add it to App/Resources/Localizable.xcstrings with all '
                '%d translations' % (sites[0], key, len(LANGUAGES)))

    # 3. catalog entries missing translations
    for key in sorted(strings):
        locs = strings[key].get('localizations', {})
        missing = []
        for lang in LANGUAGES:
            entry = locs.get(lang)
            if entry is None:
                missing.append(lang)
                continue
            unit = entry.get('stringUnit')
            if unit is None:      # plural/device variation: resolved per-form
                continue
            if unit.get('state') != 'translated' or not unit.get('value'):
                missing.append(lang)
        if missing:
            problems.append(
                'Localizable.xcstrings: %r is missing %s\n'
                '    You write the translations — there is no external '
                'translation process (CLAUDE.md)'
                % (key, ', '.join(missing)))

    # 4. generated catalogs in sync
    gen = subprocess.run(
        [sys.executable, os.path.join(ROOT, 'Scripts/gen-translations.py'),
         '--check'], capture_output=True, text=True)
    if gen.returncode != 0:
        problems.append(
            'Generated translations are stale:\n%s'
            '    Run Scripts/gen-translations.py and commit the result'
            % ''.join('    %s\n' % l
                      for l in gen.stderr.strip().split('\n') if l))

    if problems:
        print('✗ translation coverage', file=sys.stderr)
        for p in problems:
            print('  ' + p, file=sys.stderr)
        print('\n  %d problem(s).' % len(problems), file=sys.stderr)
        return 1

    print('✓ translations: %d strings × %d languages, both shells covered'
          % (len(strings), len(LANGUAGES)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
