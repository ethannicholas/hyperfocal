# Store-listing media capture for the Qt shell - the Windows analogue of
# Scripts/store-media.py, and the same idea: stage the real app and capture
# store-ready screenshots repeatably, in every catalog language, without a
# human at the mouse.
#
#   Scripts\store-media.ps1 -Frames <stack-dir> -Out <dir>
#   Scripts\store-media.ps1 -Frames <dir> -Out <dir> -Lang de     # one language
#   Scripts\store-media.ps1 -Frames <dir> -Out <dir> -Video       # video only
#   Scripts\store-media.ps1 -Frames <dir> -Out <dir> -Screenshot  # shot only
#
# A run PACKAGES FIRST (Scripts\package-windows.ps1) and captures what it just
# produced - the macOS driver rebuilds the app the same way, and for the same
# reason: media that does not show the code in the tree is worse than no media,
# because nothing about it looks wrong. There is deliberately no flag to skip
# the packaging step; -Exe captures a specific binary.
#
# Produces the same two things per language the macOS driver does: a video of
# the fusion workflow, and the retouch screenshot.
#
# Microsoft Store screenshots: PNG, 1366x768 minimum, 3840x2160 maximum, at
# most 10 per listing. Trailers: MP4 or MOV at exactly 1920x1080, under 2 GB,
# 60s or less, each with a 1920x1080 PNG thumbnail and a title - and an audio
# track, because uploads without one are rejected (the same trap App Store
# Connect sets, so the encode mixes in silence). The script validates what it
# actually wrote rather than assuming.
#
# The video needs ffmpeg and ffprobe on PATH (winget install Gyan.FFmpeg);
# nothing else on Windows can mux that required audio track. A screenshot-only
# run does not.
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
# Screenshots are grabbed from the window, not the screen, so the app does NOT
# need to be frontmost for them. The VIDEO is different and there is no way
# around it: Windows has no window recorder. gdigrab aimed at a window reads
# the window's GDI surface, and a Qt Quick window is composited by D3D through
# the RHI, so that route records black. Recording the composited desktop and
# cropping to the window rect is what works, which means that during a video
# capture the window is raised and must stay unobscured - the run DOES take
# over the screen for the length of each fuse. Screenshot-only runs do not.
#
# ASCII ONLY, for the reason spelled out at the top of package-windows.ps1:
# Windows PowerShell 5.1 decodes a BOM-less .ps1 as the ANSI codepage, where
# the last byte of a UTF-8 em dash is CP1252's closing curly quote, which
# terminates a string early and stops the file parsing.
param(
    [Parameter(Mandatory = $true)][string]$Frames,
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$Lang = "all",
    # Which media to capture. Neither switch means both, matching the macOS
    # driver's --video / --screenshot.
    [switch]$Video,
    [switch]$Screenshot,
    [string]$Window = "1600x900",
    [double]$Exposure = 0,
    [double]$Highlights = 0,
    [double]$Shadows = 0,
    [double]$ShotZoom = 1.0,
    # Framing for the capture, in fused-output pixels. Defaults matching the
    # macOS driver's documented run, so both stores show the same crop of the
    # same subject rather than whatever the pane happened to be showing.
    [string]$ShotCenter = "2522,945",
    [string]$Cursor = "2638,1040",
    # Seconds. The Store's ceiling is 60; the recording is sped up to land
    # here, never slowed down.
    [double]$VideoDuration = 25,
    [switch]$KeepRaw,
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
    hidden [System.IO.FileStream]$OutFile
    hidden [System.IO.FileStream]$ErrFile

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

        # Drain both streams to $log, and note what happens if you don't: a
        # redirected stream is a PIPE, and a pipe nobody reads fills at a few
        # KB and blocks the writer *forever*. The shell logs a line per frame
        # per stage - decode, register, depth, render, pyramid - so on any real
        # stack it froze partway into the fuse, every time, while the driver
        # sat in WaitFor watching a phase that would never change. It looked
        # exactly like a slow fuse, which is the worst thing it could look
        # like. The macOS driver (Scripts/store-media.py) hands Popen a file
        # object and so never has a pipe at all; this port kept its `log`
        # parameter and lost the file it named. CopyToAsync gets it back:
        # nothing here ever has to remember to read.
        $this.OutFile = [System.IO.File]::Create($log)
        $this.ErrFile = [System.IO.File]::Create("$log.err")
        $this.Proc.StandardOutput.BaseStream.CopyToAsync($this.OutFile) | Out-Null
        $this.Proc.StandardError.BaseStream.CopyToAsync($this.ErrFile) | Out-Null
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
            # Checked before the poll, because the poll's own failure is
            # swallowed below: a single get-geometry can legitimately time out
            # while a fuse has the shell busy, but a process that has *exited*
            # never answers again, and without this the run waited out the
            # whole FuseTimeout - 30 minutes by default - before saying so.
            if ($this.Proc.HasExited) {
                throw "app exited (code $($this.Proc.ExitCode)) while waiting for $what"
            }
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
        # After the writer is gone the copies complete on their own; closing
        # the files flushes what the run captured.
        foreach ($f in @($this.OutFile, $this.ErrFile)) {
            if ($f) { try { $f.Dispose() } catch { } }
        }
    }
}

# ------------------------------------------------------------------ video --
# Raising the window and finding where it actually is on screen. Both are Win32
# calls with no PowerShell equivalent, and DWM makes the second less obvious
# than it looks: GetWindowRect includes the invisible resize border Windows 10
# and 11 put around a window, so cropping to it records a stripe of desktop on
# three sides. DWMWA_EXTENDED_FRAME_BOUNDS (9) is the visible frame.
#
# Guarded: a type can only be added once per PowerShell session, and running
# this script twice in one shell is the normal case.
if (-not ('HFStore.Win' -as [type])) {
    Add-Type -Namespace HFStore -Name Win -MemberDefinition @'
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(
        IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(
        IntPtr h, int attr, out RECT r, int size);
    public struct RECT { public int Left, Top, Right, Bottom; }
'@
}

function Require-FFmpeg {
    foreach ($tool in @('ffmpeg', 'ffprobe')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "$tool not on PATH - the fusion video needs it (winget install Gyan.FFmpeg). Use -Screenshot to skip the video."
        }
    }
}

# The window's visible bounds, raised to the front, moved fully onto its screen
# and rounded to even pixels (x264 with yuv420p refuses odd dimensions).
#
# The move is not optional. gdigrab reads the desktop, so it rejects a capture
# area extending past the screen - and the frame is wider than the size
# set-window asked for, because the DWM frame carries a border the client area
# does not: a 1600x900 window measures 1602x932 here, which at the window's
# default position ran one pixel past a 1920-wide screen and failed the whole
# run. Nudging the window beats cropping the rect, which would shave that
# column off the trailer instead.
function Get-CaptureRect([System.Diagnostics.Process]$proc) {
    Add-Type -AssemblyName System.Windows.Forms
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { throw "no main window to record" }
    [HFStore.Win]::ShowWindow($h, 9) | Out-Null   # SW_RESTORE
    [HFStore.Win]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 600

    $bounds = { param($hw)
        $r = New-Object HFStore.Win+RECT
        $hr = [HFStore.Win]::DwmGetWindowAttribute($hw, 9, [ref]$r, 16)
        if ($hr -ne 0) { throw ("DwmGetWindowAttribute failed (0x{0:X})" -f $hr) }
        return @{ x = $r.Left; y = $r.Top
                  w = $r.Right - $r.Left; h = $r.Bottom - $r.Top }
    }
    $f = & $bounds $h
    $screen = [System.Windows.Forms.Screen]::FromHandle($h).Bounds
    $nx = [Math]::Min([Math]::Max($f.x, $screen.X), $screen.X + $screen.Width - $f.w)
    $ny = [Math]::Min([Math]::Max($f.y, $screen.Y), $screen.Y + $screen.Height - $f.h)
    if ($nx -ne $f.x -or $ny -ne $f.y) {
        # SetWindowPos positions the GetWindowRect rectangle, which includes
        # the invisible border, while $nx/$ny are in visible-frame coordinates
        # - the two differ by that border (7px here). Asking for the visible
        # position directly lands the window a border-width off, which put it
        # back over the screen edge and left the clamp below shaving pixels off
        # the recording. Convert through the delta.
        $raw = New-Object HFStore.Win+RECT
        [HFStore.Win]::GetWindowRect($h, [ref]$raw) | Out-Null
        $dx = $f.x - $raw.Left
        $dy = $f.y - $raw.Top
        Log "moving window to $nx,$ny so the capture area fits the screen"
        # SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
        [HFStore.Win]::SetWindowPos($h, [IntPtr]::Zero, ($nx - $dx), ($ny - $dy),
                                    0, 0, 0x15) | Out-Null
        Start-Sleep -Milliseconds 400
        $f = & $bounds $h
    }
    # Backstop for a window larger than its screen, which no -Window value
    # should produce but which would otherwise fail the same way.
    $w = [Math]::Min($f.w, $screen.X + $screen.Width - $f.x)
    $ht = [Math]::Min($f.h, $screen.Y + $screen.Height - $f.y)
    return @{ x = $f.x; y = $f.y; w = $w - ($w % 2); h = $ht - ($ht % 2) }
}

# gdigrab on the composited desktop, cropped to the window. -draw_mouse 0 is
# why this needs no cursor helper: the macOS driver has to physically park the
# pointer outside the capture rect, here the recorder simply omits it.
function Start-Recorder([hashtable]$rect, [string]$raw) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'ffmpeg'
    $psi.Arguments = "-y -v error -f gdigrab -framerate 30 -draw_mouse 0 " +
        "-offset_x $($rect.x) -offset_y $($rect.y) " +
        "-video_size $($rect.w)x$($rect.h) -i desktop " +
        "-c:v libx264 -preset ultrafast -crf 18 -pix_fmt yuv420p `"$raw`""
    $psi.UseShellExecute = $false
    # stdin only: 'q' is how ffmpeg is asked to finalize the file. stdout and
    # stderr stay attached to this console on purpose - redirecting them
    # without draining is what deadlocked the shell (see Session above), and
    # -v error keeps them quiet anyway.
    $psi.RedirectStandardInput = $true
    $rec = [System.Diagnostics.Process]::Start($psi)
    # ffmpeg reports a bad capture area by exiting at once. Without this check
    # the run recorded nothing, fused for a minute, and only complained when
    # ffprobe found no file - a wasted fuse and an error naming the wrong tool.
    Start-Sleep -Milliseconds 1500
    if ($rec.HasExited) {
        throw "ffmpeg exited immediately (code $($rec.ExitCode)); its error is above"
    }
    return $rec
}

function Stop-Recorder([System.Diagnostics.Process]$rec) {
    try { $rec.StandardInput.Write('q'); $rec.StandardInput.Flush() } catch { }
    if (-not $rec.WaitForExit(60000)) {
        $rec.Kill()
        throw "ffmpeg did not finalize the recording"
    }
}

function Probe-Duration([string]$path) {
    $json = & ffprobe -v error -show_entries format=duration -of json $path
    if ($LASTEXITCODE) { throw "ffprobe failed on $path" }
    return [double]($json | ConvertFrom-Json).format.duration
}

function Encode-Video([string]$raw, [string]$out, [double]$targetSeconds) {
    $duration = Probe-Duration $raw
    # Only ever sped up: a fuse shorter than the target is simply a short
    # trailer, and stretching it would just be a slideshow.
    $speed = [Math]::Max($duration / $targetSeconds, 1.0)
    Log ("raw recording {0:n1}s -> {1:n2}x to fit {2}s" -f $duration, $speed, $targetSeconds)
    $vf = ("setpts=PTS/{0:n6},fps=30,scale=1920:1080:flags=lanczos,format=yuv420p" -f $speed)
    & ffmpeg -y -v error -i $raw `
        -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 `
        -map 0:v -map 1:a -vf $vf `
        -c:v libx264 -profile:v high -crf 18 `
        -c:a aac -b:a 96k -shortest -movflags +faststart $out
    if ($LASTEXITCODE) { throw "ffmpeg encode failed" }
}

# The Store wants a 1920x1080 PNG alongside every trailer. Taken a second from
# the end, so the still shows the finished fusion rather than a half-rendered
# frame - the video is already 1920x1080, so no rescale is involved.
function Write-Thumbnail([string]$video, [string]$out) {
    & ffmpeg -y -v error -sseof -1 -i $video -frames:v 1 -update 1 $out
    if ($LASTEXITCODE) { throw "ffmpeg thumbnail failed" }
}

function Validate-Video([string]$path) {
    $json = & ffprobe -v error -show_entries `
        "stream=codec_type,codec_name,width,height,channels:format=duration,size" `
        -of json $path
    if ($LASTEXITCODE) { throw "ffprobe failed on $path" }
    $probe = $json | ConvertFrom-Json
    $video = $probe.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
    $audio = $probe.streams | Where-Object { $_.codec_type -eq 'audio' }
    $duration = [double]$probe.format.duration
    $sizeGB = [double]$probe.format.size / 1GB
    $problems = @()
    if ($video.width -ne 1920 -or $video.height -ne 1080) {
        $problems += "size $($video.width)x$($video.height) != 1920x1080"
    }
    if ($video.codec_name -ne 'h264') { $problems += "codec $($video.codec_name) != h264" }
    if (-not $audio) { $problems += "no audio track (the Store rejects trailers without one)" }
    elseif ($audio[0].channels -ne 2) { $problems += "audio not stereo" }
    if ($duration -gt 60) { $problems += ("duration {0:n1}s over the Store's 60s" -f $duration) }
    if ($sizeGB -gt 2) { $problems += ("size {0:n2} GB over the Store's 2 GB" -f $sizeGB) }
    if ($problems) { throw "$path - $($problems -join '; ')" }
    Log ("video OK: 1920x1080 h264 + stereo audio, {0:n1}s  $(Split-Path $path -Leaf)" -f $duration)
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

# PACKAGE FIRST, then capture what was just produced - the same order the
# macOS driver uses (it rebuilds the app unless --skip-build). Discovery alone
# is not enough: dist\ is a snapshot nothing here refreshes, so an edit made
# after the last packaging run is invisible and the capture silently ships the
# previous build. That is not hypothetical - a full localized set was captured
# from a package predating the fix for the shell's untranslated AppCore
# strings, and the screenshots came out half-English with nothing about them
# looking wrong.
#
# In a CHILD PowerShell, deliberately. package-windows.ps1 dot-sources
# Scripts\windows-env.ps1, and $env: edits are process-wide, so packaging in
# THIS process would leave Qt, the Swift runtime and the vcpkg DLLs on the PATH
# that the captured app inherits - hiding a package that is missing a DLL,
# which is precisely the class of bug capturing from the package catches.
#
# The capture then runs against the STAGED PACKAGE it just wrote, never a dev
# build out of QtShell\build*\: the package is self-contained - Qt, the Swift
# runtime and the vcpkg imaging DLLs all sit beside the executable - so it
# launches with no build environment, which a child process started from here
# does not inherit (a dev build exits instantly with 0xC0000135, DLL not
# found). It is also just what the media should show: the build users install.
if (-not $Exe) {
    Log "packaging (Scripts\package-windows.ps1)"
    & powershell -NoProfile -ExecutionPolicy Bypass -File `
        (Join-Path $root 'Scripts\package-windows.ps1')
    if ($LASTEXITCODE) { throw "package-windows.ps1 failed (exit $LASTEXITCODE)" }
    # Newest by write time, which is the layout the run above just staged -
    # not by version name, which would reach for a higher-numbered leftover.
    $Exe = Get-ChildItem (Join-Path $root 'dist') -Directory -Filter 'Hyperfocal-*' |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object { Join-Path $_.FullName 'hyperfocal-qt.exe' } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $Exe) { throw "packaging left no hyperfocal-qt.exe under dist\" }
}
if (-not (Test-Path $Exe)) { throw "no hyperfocal-qt.exe at $Exe" }

$langs = if ($Lang -eq 'all') { $LANGS } else { $Lang.Split(',') }
$unknown = $langs | Where-Object { $LANGS -notcontains $_ }
if ($unknown) {
    throw "unknown language tag(s) $($unknown -join ','); catalog: $($LANGS -join ',')"
}
$doVideo = $Video -or -not $Screenshot
$doShot  = $Screenshot -or -not $Video
if ($doVideo) { Require-FFmpeg }

New-Item -ItemType Directory -Force $Out | Out-Null
$stage = Join-Path $env:TEMP 'hyperfocal-store-media'
Log "exe    : $Exe"
Log "frames : $Frames ($frameCount files)"
$media = @(); if ($doVideo) { $media += 'video' }; if ($doShot) { $media += 'retouch shot' }
Log "media  : $($media -join ', ')"
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

        if ($doVideo) {
            # Zoomed out and every section left expanded: the stack list is the
            # visual feedback during the fuse, and the Fusion panel is where a
            # user would just have clicked.
            # Every section left expanded: the stack list is the visual
            # feedback during the fuse, and the Fusion panel is where a user
            # would just have clicked.
            #
            # Deliberately NO set-zoom here, unlike the macOS driver's
            # --video-zoom. The pane already fits the progressive result (0.17
            # for this stack), which is the framing the video wants and what a
            # real user sees. Asking for an absolute scale *before* the fuse
            # instead produces 3%: setAbsoluteScale converts the scale into a
            # fit-relative zoom factor using the fit scale at that instant
            # (PaneItem.cpp), and before a fuse there is no output image to
            # fit, so the ratio is meaningless - then the real result arrives
            # with its true fit scale and the stale ratio multiplies through.
            $session.Require('set-sections', @{ collapsed = '' }) | Out-Null
            Start-Sleep -Seconds 1
            $rect = Get-CaptureRect $session.Proc
            $raw = Join-Path $stage "raw-$lang.mkv"
            Remove-Item $raw -Force -ErrorAction SilentlyContinue
            Log "recording $($rect.w)x$($rect.h) at $($rect.x),$($rect.y)"
            $rec = Start-Recorder $rect $raw
            # A beat of settled window before the work starts, so the trailer
            # does not open mid-repaint.
            Start-Sleep -Seconds 2
            $session.Require('fuse', $null) | Out-Null
            $session.WaitFor('fuse', { param($g) $g.phase -eq 'done' }, $FuseTimeout) | Out-Null
            Start-Sleep -Seconds 3   # let the finished result render
            Stop-Recorder $rec
            $videoOut = Join-Path $Out "win-$lang-fusion-1920x1080.mp4"
            Encode-Video $raw $videoOut $VideoDuration
            Validate-Video $videoOut
            Write-Thumbnail $videoOut (Join-Path $Out "win-$lang-fusion-thumb-1920x1080.png")
            if (-not $KeepRaw) { Remove-Item $raw -Force -ErrorAction SilentlyContinue }
        }

        $zoom = @{ scale = $ShotZoom }
        if ($center) { $zoom['cx'] = $center[0]; $zoom['cy'] = $center[1] }

        if ($doShot) {
            if (-not $doVideo) {   # otherwise the recorded fuse above already ran
                $session.Require('fuse', $null) | Out-Null
                $session.WaitFor('fuse', { param($g) $g.phase -eq 'done' }, $FuseTimeout) | Out-Null
            }
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
