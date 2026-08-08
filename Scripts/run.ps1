# Build the app and (re)launch it — the everyday "run the app" loop on
# Windows, and the analogue of Scripts/run.sh (whose default is the macOS
# SwiftUI app; here the Qt shell *is* the UI).
#
#   Scripts\run.ps1                    build, then launch
#   Scripts\run.ps1 -NoRun             build only
#   Scripts\run.ps1 -Lang de           launch in German (localization check)
#   Scripts\run.ps1 -Wait --selftest   pass args through, attached to the console
#
# The build is QtShell\build.ps1 and is not duplicated here: Qt kit discovery,
# the bridge, and the regenerated catalogs/notices all live there, so this
# script cannot drift from it. What it adds is the launch policy — an
# already-running guard and a detached launch that doesn't hold the terminal.

param(
    [switch]$NoRun,
    [switch]$Wait,
    [string]$Lang,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AppArgs
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$exe  = Join-Path $root 'QtShell\build\hyperfocal-qt.exe'

# Checked before the build, not after, and regardless of -NoRun: Windows holds
# a running image open, so ninja's relink of hyperfocal-qt.exe (or of the
# bridge DLL) fails with a sharing violation rather than a useful message. The
# instance is reported rather than killed — the bare executable has no polite
# quit channel to run the unsaved-work confirmation through, which is the same
# call Scripts/run.sh makes for the Qt shell, and a second instance also
# confuses hover/tooltip behavior.
$running = Get-Process -Name hyperfocal-qt -ErrorAction SilentlyContinue
if ($running) {
    throw ("a hyperfocal-qt instance is already running (PID " +
           ($running.Id -join ', ') + ") - quit it first; Windows locks the " +
           "running executable against relink, and there is no polite quit " +
           "channel for the bare executable")
}

# build.ps1 throws on any failure (and dot-sources windows-env.ps1 itself), so
# a failed build terminates here without an exit-code check.
& (Join-Path $root 'QtShell\build.ps1')

if (-not (Test-Path $exe)) { throw "no executable at $exe" }
if ($NoRun) {
    Write-Host "run: built $exe (not launching)"
    return
}

# No rpath on Windows: Qt, the bridge, the Swift runtime and vcpkg all resolve
# through PATH. build.ps1 has just prepended them — $env: edits are
# process-wide, so they are already in place here and the child inherits them.
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
