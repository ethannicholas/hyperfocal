# Store-listing media capture for the Qt shell - the Windows analogue of
# Scripts/store-media.py, and the same idea: stage the real app and capture
# store-ready screenshots repeatably, in every catalog language, without a
# human at the mouse.
#
#   Scripts\store-media.ps1 -Frames <stack-dir> -Out <dir>
#   Scripts\store-media.ps1 -Frames <dir> -Out <dir> -Lang de        # one language
#   Scripts\store-media.ps1 -Frames <dir> -Out <dir> -Shots retouch  # one framing
#
# Microsoft Store screenshots: PNG, 1366x768 minimum, 3840x2160 maximum, at
# most 10 per listing. The script validates what it actually wrote rather than
# assuming.
#
# -Window is in POINTS and the shot lands at points x devicePixelRatio. The
# default 1600x900 clears the 1366x768 floor even at dpr 1 while still fitting
# a 1920x1080 screen's work area - a window is clamped to that area (the
# taskbar's height comes off), exactly as the macOS driver is clamped by the
# Dock, so 1920x1080 is NOT reachable on a 1920x1080 display. Ask for more only
# on a larger screen; get-geometry reports availW/availH, and set-window's
# failure names them.
#
# Drives the shell through the CommandChannel (QtShell/CommandChannel.h),
# which is inert unless HFQT_COMMAND_DIR is set. Unlike the macOS driver this
# one needs no screen recorder, no cursor helper and no accessibility
# permission: grabs come from the app's own grabWindow(), and the retouch
# brush circle is a QML overlay that a grab captures, so `set-hover` stands in
# for parking a real pointer.
#
# The window is grabbed, not the screen, so the app does NOT need to be
# frontmost and the run does not take over the machine - but it does open a
# window per language, so do not fight it for the desktop.
#
# ASCII ONLY, for the reason spelled out at the top of package-windows.ps1:
# Windows PowerShell 5.1 decodes a BOM-less .ps1 as the ANSI codepage, where
# the last byte of a UTF-8 em dash is CP1252's closing curly quote, which
# terminates a string early and stops the file parsing.
param(
    [Parameter(Mandatory = $true)][string]$Frames,
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$Lang = "all",
    [string]$Shots = "fused,retouch,depth",
    [string]$Window = "1600x900",
    [double]$Exposure = 0,
    [double]$Highlights = 0,
    [double]$Shadows = 0,
    [double]$ShotZoom = 1.0,
    [string]$ShotCenter,
    [string]$Cursor,
    [string]$Exe,
    [int]$FuseTimeout = 1800
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# The localization catalog (CLAUDE.md). Store listings exist for every one of
# these, so a run defaults to all of them; a single tag is for testing.
$LANGS = @('en', 'de', 'es', 'fr', 'it', 'ja', 'ko', 'nl', 'pt-BR', 'ru',
           'zh-Hans')
# Store bounds, in pixels.
$MIN_W = 1366; $MIN_H = 768; $MAX_W = 3840; $MAX_H = 2160

function Log($msg) { Write-Host "== $msg" }

function Parse-Size([string]$s) {
    if ($s -notmatch '^(\d+)[xX](\d+)$') { throw "bad size '$s' (want WxH)" }
    return @([int]$Matches[1], [int]$Matches[2])
}

function Parse-Pair([string]$s) {
    if ($s -notmatch '^(-?[\d.]+),(-?[\d.]+)$') { throw "bad point '$s' (want x,y)" }
    return @([double]$Matches[1], [double]$Matches[2])
}

# ---------------------------------------------------------------- session --
# One launched shell: command posting plus the poll loops the captures need.
class Session {
    [System.Diagnostics.Process]$Proc
    [string]$Dir
    [int]$Counter = 0

    Session([string]$exe, [string]$frames, [string]$dir, [string]$lang,
            [string]$log) {
        $this.Dir = $dir
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
        New-Item -ItemType Directory -Force $dir | Out-Null
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        # The shell ingests a folder handed to it in argv - the same path a
        # dropped folder takes (main.cpp).
        $psi.Arguments = '"' + $frames + '"'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.EnvironmentVariables['HFQT_COMMAND_DIR'] = $dir
        # No capture may wait on a human; every confirm takes its default.
        $psi.EnvironmentVariables['HFQT_AUTOCONFIRM'] = '1'
        # "en" installs no translator, matching the selftest's contract.
        if ($lang -ne 'en') { $psi.EnvironmentVariables['HFQT_LANG'] = $lang }
        $this.Proc = [System.Diagnostics.Process]::Start($psi)
    }

    # Wait for the channel's "ready" marker. Without this a shell that never
    # installed the channel looks exactly like one that is slow to ingest,
    # and the run burns the whole ingest timeout before saying anything
    # useful (the shell is a GUI-subsystem binary, so its logs go nowhere).
    [void] WaitReady([int]$timeoutSec) {
        $marker = Join-Path $this.Dir 'ready'
        $deadline = (Get-Date).AddSeconds($timeoutSec)
        while ((Get-Date) -lt $deadline) {
            if ($this.Proc.HasExited) {
                throw "app exited (code $($this.Proc.ExitCode)) before the command channel started"
            }
            if (Test-Path $marker) { return }
            Start-Sleep -Milliseconds 200
        }
        throw "command channel never started (no 'ready' in $($this.Dir)) - is HFQT_COMMAND_DIR honoured by this build?"
    }

    # Send one command; return its parsed reply. Writes the request through a
    # temp name so the shell's poller never reads a half-written file.
    [object] Post([string]$action, [hashtable]$params, [int]$timeoutSec) {
        $this.Counter++
        $n = $this.Counter
        $payload = @{ action = $action }
        if ($params) { foreach ($k in $params.Keys) { $payload[$k] = $params[$k] } }
        $tmp = Join-Path $this.Dir "cmd-$n.json.part"
        $req = Join-Path $this.Dir "cmd-$n.json"
        Set-Content -Path $tmp -Value ($payload | ConvertTo-Json -Compress) -Encoding utf8
        Move-Item $tmp $req
        $reply = Join-Path $this.Dir "r$n.json"
        $deadline = (Get-Date).AddSeconds($timeoutSec)
        while ((Get-Date) -lt $deadline) {
            if ($this.Proc.HasExited) {
                throw "app exited (code $($this.Proc.ExitCode)) during '$action'"
            }
            if (Test-Path $reply) {
                Start-Sleep -Milliseconds 40
                return (Get-Content $reply -Raw | ConvertFrom-Json)
            }
            Start-Sleep -Milliseconds 150
        }
        throw "command '$action' timed out after ${timeoutSec}s"
    }

    [object] Post([string]$action, [hashtable]$params) {
        return $this.Post($action, $params, 60)
    }

    [object] Require([string]$action, [hashtable]$params) {
        $r = $this.Post($action, $params, 60)
        if ($r.ok -ne 1) { throw "$action failed: $($r.detail)" }
        return $r
    }

    # Poll get-geometry until `pred` accepts it.
    [object] WaitFor([string]$what, [scriptblock]$pred, [int]$timeoutSec) {
        $deadline = (Get-Date).AddSeconds($timeoutSec)
        while ((Get-Date) -lt $deadline) {
            $geo = $null
            try { $geo = $this.Post('get-geometry', $null, 30) } catch { }
            if ($geo -and $geo.ok -eq 1 -and (& $pred $geo)) { return $geo }
            Start-Sleep -Seconds 1
        }
        throw "timed out after ${timeoutSec}s waiting for $what"
    }

    [void] Quit() {
        try { $this.Post('quit', $null, 5) | Out-Null } catch { }
        if (-not $this.Proc.WaitForExit(10000)) { $this.Proc.Kill() }
    }
}

function Validate-Shot([string]$path, [int]$w, [int]$h) {
    Add-Type -AssemblyName System.Drawing
    $img = [System.Drawing.Image]::FromFile($path)
    $gotW = $img.Width; $gotH = $img.Height
    $img.Dispose()
    if ($gotW -ne $w -or $gotH -ne $h) {
        throw "$path is ${gotW}x${gotH}, the shell reported ${w}x${h}"
    }
    $problems = @()
    if ($gotW -lt $MIN_W -or $gotH -lt $MIN_H) {
        $problems += "below the Store minimum ${MIN_W}x${MIN_H}"
    }
    if ($gotW -gt $MAX_W -or $gotH -gt $MAX_H) {
        $problems += "above the Store maximum ${MAX_W}x${MAX_H}"
    }
    if ($problems) { throw "$path is ${gotW}x${gotH} - $($problems -join '; ')" }
    Log "shot OK: ${gotW}x${gotH}  $(Split-Path $path -Leaf)"
}

# ------------------------------------------------------------------- main --
$winSize = Parse-Size $Window
$center = if ($ShotCenter) { Parse-Pair $ShotCenter } else { $null }
$cursorAt = if ($Cursor) { Parse-Pair $Cursor } else { $null }

if (-not (Test-Path $Frames)) { throw "no such frames directory: $Frames" }
$frameCount = (Get-ChildItem $Frames -File).Count
if (-not $frameCount) { throw "no files in $Frames" }

# Prefer the STAGED PACKAGE. It is self-contained - Qt, the Swift runtime and
# the vcpkg imaging DLLs all sit beside the executable - so it launches with no
# build environment loaded, which a child process started from here does not
# inherit. A dev build out of QtShell\build*\ resolves none of those unless the
# caller dot-sourced Scripts\windows-env.ps1 first, and the failure is an
# instant exit with 0xC0000135 (DLL not found) rather than anything readable.
# Capturing from the package is also just correct: store media should show the
# build users install.
if (-not $Exe) {
    $staged = Get-ChildItem (Join-Path $root 'dist') -Directory -Filter 'Hyperfocal-*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'hyperfocal-qt.exe' } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($staged) {
        $Exe = $staged
    } else {
        foreach ($cand in @('QtShell\build-release\hyperfocal-qt.exe',
                            'QtShell\build\hyperfocal-qt.exe')) {
            $p = Join-Path $root $cand
            if (Test-Path $p) { $Exe = $p; break }
        }
        if ($Exe) {
            Log "WARNING: no staged package in dist\; using $Exe"
            Log "         a dev build needs '. Scripts\windows-env.ps1' in THIS shell,"
            Log "         or it exits immediately with 0xC0000135 (DLL not found)."
        }
    }
}
if (-not $Exe -or -not (Test-Path $Exe)) {
    throw "no hyperfocal-qt.exe (run Scripts\package-windows.ps1, or pass -Exe)"
}

$langs = if ($Lang -eq 'all') { $LANGS } else { $Lang.Split(',') }
$unknown = $langs | Where-Object { $LANGS -notcontains $_ }
if ($unknown) {
    throw "unknown language tag(s) $($unknown -join ','); catalog: $($LANGS -join ',')"
}
$wanted = $Shots.Split(',') | ForEach-Object { $_.Trim() }
$knownShots = @('fused', 'retouch', 'depth')
$badShots = $wanted | Where-Object { $knownShots -notcontains $_ }
if ($badShots) {
    throw "unknown shot(s) $($badShots -join ','); known: $($knownShots -join ',')"
}

New-Item -ItemType Directory -Force $Out | Out-Null
$stage = Join-Path $env:TEMP 'hyperfocal-store-media'
Log "exe    : $Exe"
Log "frames : $Frames ($frameCount files)"
Log "shots  : $($wanted -join ', ')"
Log "langs  : $($langs -join ', ')"

$i = 0
foreach ($lang in $langs) {
    $i++
    Log "language $lang ($i/$($langs.Count))"
    $session = [Session]::new($Exe, (Resolve-Path $Frames).Path,
                              (Join-Path $stage $lang), $lang,
                              (Join-Path $stage "$lang.log"))
    try {
        $session.WaitReady(60)
        # Ingest first - the frame list has to exist before anything can fuse.
        $session.WaitFor('stack ingest', { param($g) $g.phase -eq 'loaded' }, 180) | Out-Null

        $session.Require('set-window', @{ w = $winSize[0]; h = $winSize[1] })
        $dpr = ($session.Post('get-geometry', $null)).dpr
        $expectW = [int]($winSize[0] * $dpr)
        $expectH = [int]($winSize[1] * $dpr)
        Log "window $($winSize[0])x$($winSize[1]) pt at dpr $dpr -> ${expectW}x${expectH} px"

        if ($Exposure)   { $session.Require('set-slider', @{ id = 'tone.slider.exposure';   value = $Exposure }) }
        if ($Highlights) { $session.Require('set-slider', @{ id = 'tone.slider.highlights'; value = $Highlights }) }
        if ($Shadows)    { $session.Require('set-slider', @{ id = 'tone.slider.shadows';    value = $Shadows }) }

        $session.Require('fuse', $null)
        $session.WaitFor('fuse', { param($g) $g.phase -eq 'done' }, $FuseTimeout) | Out-Null

        $zoom = @{ scale = $ShotZoom }
        if ($center) { $zoom['cx'] = $center[0]; $zoom['cy'] = $center[1] }

        if ($wanted -contains 'fused') {
            # The whole sidebar stays expanded: this is the "what the app is"
            # shot, and the stack list plus the fusion controls are the story.
            $session.Require('set-sections', @{ collapsed = '' })
            $session.Require('set-zoom', $zoom)
            $path = Join-Path $Out "win-$lang-fused-${expectW}x${expectH}.png"
            $r = $session.Require('grab', @{ path = $path })
            Validate-Shot $path $r.w $r.h
        }

        if ($wanted -contains 'depth') {
            $session.Require('set-depth', @{ on = 1 })
            $session.Require('set-zoom', $zoom)
            $path = Join-Path $Out "win-$lang-depth-${expectW}x${expectH}.png"
            $r = $session.Require('grab', @{ path = $path })
            Validate-Shot $path $r.w $r.h
            $session.Require('set-depth', @{ on = 0 })
        }

        if ($wanted -contains 'retouch') {
            # Frames Tone + Retouching, like the macOS retouch shot.
            $session.Require('set-sections', @{ collapsed = 'stack,fusion' })
            # Retouch needs the result and its depth plane settled; the
            # command reports not-ready rather than blocking, so poll.
            $ok = $false
            foreach ($try in 1..60) {
                if (($session.Post('enter-retouch', $null)).ok -eq 1) { $ok = $true; break }
                Start-Sleep -Seconds 2
            }
            if (-not $ok) { throw "enter-retouch never became ready" }
            $session.Require('set-retouch', @{ source = 'pmax' })
            $session.WaitFor('PMax retouch source',
                             { param($g) $g.canPaint -eq 1 -and $g.sourceLoading -eq 0 },
                             $FuseTimeout) | Out-Null
            $session.Require('set-zoom', $zoom)
            if ($cursorAt) {
                # Draws the brush circle in both panes - no real pointer
                # needed, the circle is a QML overlay.
                $session.Require('set-hover', @{ x = $cursorAt[0]; y = $cursorAt[1] })
            }
            $path = Join-Path $Out "win-$lang-retouch-${expectW}x${expectH}.png"
            $r = $session.Require('grab', @{ path = $path })
            Validate-Shot $path $r.w $r.h
        }
    } finally {
        $session.Quit()
    }
}
Log "done -> $Out"
