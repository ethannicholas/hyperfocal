#!/bin/bash
# Print the name of a working Python 3 interpreter, for callers that would
# otherwise rely on a `#!/usr/bin/env python3` shebang.
#
# That shebang is not portable to Windows. A standard python.org/winget install
# ships `python.exe` and `py.exe` but NO `python3.exe` — only the Microsoft
# Store build provides that name. Worse, Windows 11 ships an "app execution
# alias" stub at WindowsApps\python3.exe that exists on PATH, so `command -v
# python3` succeeds, and then the stub prints "Python was not found…" and exits
# non-zero. Testing that a candidate actually *runs* is the only reliable check.
#
# Exits non-zero with a message on stderr if nothing usable is found.
set -euo pipefail

for candidate in python3 python py; do
    if command -v "$candidate" >/dev/null 2>&1 \
       && "$candidate" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' \
            >/dev/null 2>&1; then
        echo "$candidate"
        exit 0
    fi
done

echo "no working Python 3 found (tried python3, python, py)" >&2
exit 1
