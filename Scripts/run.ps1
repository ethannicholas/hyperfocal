# Build the app and (re)launch it — the everyday "run the app" loop on
# Windows, and the analogue of Scripts/run.sh (whose default is the macOS
# SwiftUI app; here the Qt shell *is* the UI, so there is no --qt to pass).
#
#   Scripts\run.ps1                    build, then launch
#   Scripts\run.ps1 -Lang de           launch in German (localization check)
#   Scripts\run.ps1 -Wait --selftest   pass args through, attached to the console
#
# Build without launching: Scripts\build.ps1.
#
# The build itself is Scripts\build.ps1, invoked here; this script only adds
# the launch policy — an already-running guard and a detached launch that
# doesn't hold the terminal.

param(
    [switch]$Wait,
    [string]$Lang,
    # Position 0 belongs to the pass-through args, not to -Lang. Without it
    # PowerShell hands -Lang the first positional token, so the documented
    # `run.ps1 -Wait --selftest <dir> <out>` above set HFQT_LANG=--selftest and
    # launched an ordinary window instead — the app printed nothing and the run
    # read as a hung test, which is the exact trap main.cpp's usage check exists
    # to close, sprung one layer up.
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$AppArgs
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$exe  = Join-Path $root 'QtShell\build\Hyperfocal.exe'

# Checked before the build, not after: Windows holds a running image open, so
# ninja's relink of Hyperfocal.exe (or of the bridge DLL) fails with a
# sharing violation rather than a useful message. The instance is reported
# rather than killed — the bare executable has no polite quit channel to run
# the unsaved-work confirmation through, which is the same call Scripts/run.sh
# makes for the Qt shell, and a second instance also confuses hover/tooltip
# behavior.
$running = Get-Process -Name Hyperfocal -ErrorAction SilentlyContinue
if ($running) {
    throw ("a Hyperfocal instance is already running (PID " +
           ($running.Id -join ', ') + ") - quit it first; Windows locks the " +
           "running executable against relink, and there is no polite quit " +
           "channel for the bare executable")
}

# build.ps1 throws on any failure, so a failed build terminates here without an
# exit-code check. It also dot-sources windows-env.ps1, which is what puts Qt,
# the Swift runtime, vcpkg and wgpu on PATH — $env: edits are process-wide, so
# they are in place for the launch below.
& (Join-Path $root 'Scripts\build.ps1')

if (-not (Test-Path $exe)) { throw "no executable at $exe" }

# The one runtime path windows-env.ps1 can't supply: the bridge DLL lives in
# the build output, and only the shell needs it (the CLI links the engine
# statically). No rpath on Windows, so it has to be on PATH.
$env:Path = (Join-Path $root '.build\debug') + ";" + $env:Path

$savedLang = $env:HFQT_LANG
try {
    # HFQT_LANG is the Qt shell's catalog tag (de, pt-BR, zh-Hans; see
    # CLAUDE.md). Restored afterwards so a -Lang run doesn't silently colour
    # every later launch from this shell.
    if ($Lang) { $env:HFQT_LANG = $Lang }

    if ($Wait) {
        # Attached: --selftest and friends print to this console, and their
        # exit status becomes ours.
        Write-Host "run: launching $exe (attached)"
        & $exe @AppArgs
        exit $LASTEXITCODE
    }

    Write-Host "run: launching $exe"
    $start = @{ FilePath = $exe; WorkingDirectory = $root }
    if ($AppArgs) { $start.ArgumentList = $AppArgs }
    Start-Process @start
} finally {
    $env:HFQT_LANG = $savedLang
}
