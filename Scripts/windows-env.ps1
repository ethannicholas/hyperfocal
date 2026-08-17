# Loads the Hyperfocal Windows build environment into the current PowerShell:
# the swift.org toolchain, CMake, and the MSVC + Windows SDK variables
# (vcvarsall) for the native architecture. Dot-source it:
#
#   . Scripts\windows-env.ps1
#
# Prerequisites (see README "Building on Windows"): VS 2022 Build Tools with
# the native VC tools + a Windows 11 SDK, the swift.org toolchain, CMake, and
# a bootstrapped vcpkg with the imaging ports installed.

$ErrorActionPreference = 'Stop'

# Prepend a directory to PATH unless it is already on it. Without the
# already-on-it check, every load prepends another copy of everything it
# resolves, and the vcvarsall import below re-emits the WHOLE PATH on top of
# that, so each load grows it by ~500 characters. Scripts\build.ps1
# dot-sources this file, so a terminal that runs Scripts\run.ps1 a dozen
# times crosses ~8000 characters - and there the `cmd /c vcvarsall && set`
# round-trip comes back truncated, so the import silently installs a
# half-initialized environment. The tail of PATH is what gets cut, which is
# exactly where the toolchains live: cl goes first, then swift, and the
# build dies with "The term 'swift' is not recognized" in a shell that
# worked ten minutes earlier. Idempotent loads keep PATH bounded however
# many times the build runs from one terminal.
function Add-PathDir {
    param([string]$Dir)
    if (-not $Dir) { return }
    $trimmed = $Dir.TrimEnd('\')
    foreach ($entry in ($env:Path -split ';')) {
        if ($entry -and $entry.TrimEnd('\') -ieq $trimmed) { return }
    }
    $env:Path = "$Dir;" + $env:Path
}

# The Windows core directories, put back when the shell has lost them. No
# build should have to think about these - but PATH is process state that
# anything in a long-lived terminal can overwrite, and once System32 is gone
# `cmd.exe` cannot be resolved, which is how vcvarsall is invoked below. The
# error that produces ("The term 'cmd' is not recognized") names the build
# script rather than the environment, and the shell cannot repair itself
# because the repair needs cmd. Restoring them is the same move the Swift and
# winget blocks below make, one layer down. Added in reverse so System32 ends
# up foremost.
$coreDirs = @("$env:SystemRoot\System32\WindowsPowerShell\v1.0",
              "$env:SystemRoot\System32\Wbem",
              $env:SystemRoot,
              "$env:SystemRoot\System32")
foreach ($core in $coreDirs) {
    if ($core -and (Test-Path $core)) { Add-PathDir $core }
}

# Swift: the installer records its PATH additions in the registry — the user
# hive for a per-user install, the machine hive for an elevated/CI install —
# which an already-running shell won't have picked up. Check both.
if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
    $regPaths = @(
        (Get-ItemProperty HKCU:\Environment -ErrorAction SilentlyContinue).Path,
        (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -ErrorAction SilentlyContinue).Path
    )
    foreach ($regPath in $regPaths) {
        if (-not $regPath) { continue }
        $swiftDirs = @(($regPath -split ';') | Where-Object { $_ -match 'Swift' })
        if ($swiftDirs) {
            # Added back to front so the registry's own order survives the
            # prepend.
            for ($i = $swiftDirs.Count - 1; $i -ge 0; $i--) {
                Add-PathDir $swiftDirs[$i]
            }
            break
        }
    }
}
if (-not $env:SDKROOT) {
    foreach ($hive in @('HKCU:\Environment',
                        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment')) {
        $sdkRoot = (Get-ItemProperty $hive -ErrorAction SilentlyContinue).SDKROOT
        if ($sdkRoot) { $env:SDKROOT = $sdkRoot; break }
    }
}

# CMake and Ninja: winget is the documented install route (README "Building on
# Windows"), and a *user-scope* winget install reaches the shell through none
# of the obvious paths — the binaries land under WinGet\Packages\<id>\, the
# shims under WinGet\Links, and the PATH entry is written to the user hive that
# an already-running shell hasn't re-read. A machine-scope install or a manual
# one uses Program Files instead. Check every one of them, per tool.
$wingetLinks    = "$env:LocalAppData\Microsoft\WinGet\Links"
$wingetPackages = "$env:LocalAppData\Microsoft\WinGet\Packages"

function Add-BuildTool {
    param([string]$Name, [string]$PackagePrefix, [string[]]$FallbackDirs = @())

    if (Get-Command $Name -ErrorAction SilentlyContinue) { return }
    foreach ($dir in $FallbackDirs) {
        if ($dir -and (Test-Path (Join-Path $dir "$Name.exe"))) {
            Add-PathDir $dir
            return
        }
    }
    if (Test-Path (Join-Path $wingetLinks "$Name.exe")) {
        Add-PathDir $wingetLinks
        return
    }
    # Last resort: the package directory itself. Nested arbitrarily deep (CMake
    # keeps its versioned zip layout, Ninja unpacks flat), hence the recursion.
    $exe = Get-ChildItem $wingetPackages -Filter "$Name.exe" -Recurse `
               -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -like "*$PackagePrefix*" } |
           Select-Object -First 1
    if ($exe) { Add-PathDir $exe.Directory.FullName }
}

Add-BuildTool -Name cmake -PackagePrefix 'Kitware.CMake' `
              -FallbackDirs @("$env:ProgramFiles\CMake\bin")
Add-BuildTool -Name ninja -PackagePrefix 'Ninja-build.Ninja'

if (-not $env:VCPKG_ROOT) {
    # Conventional layout: vcpkg checked out beside this repo.
    $sibling = Join-Path (Split-Path $PSScriptRoot -Parent) '..\vcpkg'
    if (Test-Path $sibling) { $env:VCPKG_ROOT = (Resolve-Path $sibling).Path }
}

# The vcpkg we intend to build against, remembered across the vcvarsall import
# below. vcvarsall exports its OWN VCPKG_ROOT whenever the VS install bundles
# vcpkg — Enterprise does, Build Tools usually doesn't — and the import loop
# copies every variable it emits, so an inherited or sibling-derived
# VCPKG_ROOT would be silently replaced by VS's manifest-mode-only copy. That
# is exactly what failed the Windows CI job: the workflow set
# VCPKG_ROOT=C:\hf-vcpkg, vcvarsall overwrote it with the VS one, and the
# build died on a missing tiffio.h.
$chosenVcpkgRoot = $env:VCPKG_ROOT

# MSVC + Windows SDK via vcvarsall for the native arch. vcvarsall locates the
# toolset with vswhere.exe and silently produces a half-initialized
# environment when that isn't on PATH — put the Installer dir there first.
#
# Skipped when vcvarsall has already run in this process FOR THIS TARGET ARCH
# (VSCMD_VER + VSCMD_ARG_TGT_ARCH, which it sets itself): the import copies
# every variable the batch file emits, PATH included, so re-running it
# concatenates the toolchain directories onto a PATH that already has them.
# That is the growth Add-PathDir cannot prevent - the duplicate comes from
# vcvarsall's own output, not from us - and it is what eventually truncates.
# Matching on the arch too keeps a Developer PowerShell that was opened for a
# different target (x86) from being mistaken for an environment we can reuse.
$installer = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer"
$arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' { 'arm64' } default { 'x64' } }
$vcvarsDone = $env:VSCMD_VER -and $env:VSCMD_ARG_TGT_ARCH -eq $arch
if ((Test-Path "$installer\vswhere.exe") -and -not $vcvarsDone) {
    Add-PathDir $installer
    $vsRoot = & "$installer\vswhere.exe" -products * -latest `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if (-not $vsRoot) { $vsRoot = & "$installer\vswhere.exe" -products * -latest -property installationPath }
    $vcvars = "$vsRoot\VC\Auxiliary\Build\vcvarsall.bat"
    if (Test-Path $vcvars) {
        # cmd.exe by absolute path (ComSpec), never as a bare `cmd`: this line
        # runs against whatever PATH the calling shell has, and if that PATH
        # has lost System32 - which is precisely the state a bad import below
        # leaves behind - a bare `cmd` cannot be resolved. The shell then fails
        # with "The term 'cmd' is not recognized" from a build script, with no
        # hint that its own PATH is the casualty, and cannot repair itself
        # because repairing it needs this very call.
        $comSpec = if ($env:ComSpec) { $env:ComSpec }
                   else { Join-Path $env:SystemRoot 'System32\cmd.exe' }
        $emitted = & $comSpec /c "`"$vcvars`" $arch > nul 2>&1 && set"
        # Nothing is applied unless what came back is a *complete* environment.
        # The import copies every line verbatim, so installing a partial or
        # truncated `set` dump would replace PATH with one that has neither
        # System32 nor the toolchains on it. That shell then fails every later
        # build ("the term 'swift' is not recognized", then 'cmd'), and
        # nothing says the environment has been overwritten. System32 is the
        # canary: vcvarsall always emits it, so its absence means the dump is
        # not one to trust.
        $system32 = (Join-Path $env:SystemRoot 'System32').TrimEnd('\')
        $emittedPath = @($emitted | Where-Object { $_ -match '^Path=' } |
                         Select-Object -First 1) -replace '^Path=', ''
        $complete = $emittedPath -and
            @($emittedPath -split ';' |
              Where-Object { $_ -and $_.TrimEnd('\') -ieq $system32 }).Count -gt 0
        if ($complete) {
            foreach ($line in $emitted) {
                if ($line -match '^([^=]+)=(.*)$') {
                    [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
                }
            }
        } else {
            Write-Warning ("vcvarsall returned an incomplete environment " +
                           "(no System32 on the Path it emitted); keeping this " +
                           "shell's environment instead of overwriting it - " +
                           "MSVC will be missing, so open a fresh terminal")
        }
    }
}

if ($chosenVcpkgRoot) { $env:VCPKG_ROOT = $chosenVcpkgRoot }

# vcpkg's DLLs must be findable at runtime (dynamic triplet).
if ($env:VCPKG_ROOT) {
    $triplet = if ($env:VCPKG_TRIPLET) { $env:VCPKG_TRIPLET }
               elseif ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64-windows' }
               else { 'x64-windows' }
    $env:VCPKG_TRIPLET = $triplet
    $bin = Join-Path $env:VCPKG_ROOT "installed\$triplet\bin"
    if (Test-Path $bin) { Add-PathDir $bin }
}

# wgpu_native.dll must be findable at runtime too, and by exactly the same
# argument as vcpkg's DLLs above: every Windows build links the bridge (and
# hyperfocal-cli) against the import stub, so the loader needs the directory
# holding the DLL or the process dies at start with "wgpu_native.dll was not
# found" — before any of our code runs, so nothing can report it usefully.
# WGPU_ROOT falls back to a checkout beside this repo, matching Package.swift's
# default and Scripts\package-windows.ps1; resolving it here rather than only in
# the packaging script is what lets a plain `. Scripts\windows-env.ps1` shell
# run the executables it just built. Scripts\deploy-cli.ps1 already had to know
# this for its DLL walk, and Scripts/run.sh does the same for
# LD_LIBRARY_PATH on Linux.
if (-not $env:WGPU_ROOT) {
    $siblingWgpu = Join-Path (Split-Path $PSScriptRoot -Parent) '..\wgpu-native'
    if (Test-Path $siblingWgpu) { $env:WGPU_ROOT = (Resolve-Path $siblingWgpu).Path }
}
if ($env:WGPU_ROOT) {
    $wgpuLib = Join-Path $env:WGPU_ROOT 'lib'
    if (Test-Path (Join-Path $wgpuLib 'wgpu_native.dll')) {
        Add-PathDir $wgpuLib
    }
}

# Qt: QT_KIT wins; otherwise the newest 6.x kit under C:\Qt whose architecture
# matches this machine (aqt names them msvc2022_64 on x64, msvc2022_arm64 on
# ARM64). Hardcoding one of those was an artifact of the ARM64 dev VM and left
# x64 desktops unable to build without QT_KIT.
#
# Resolved here rather than inside the build script because the kit is needed
# twice over: CMake wants the toolchain file, and the built executable wants
# the kit's bin on PATH to find the Qt DLLs at all (no rpath on Windows).
# Keeping it in the build script meant the launch only worked because build and
# run happened in one process and $env: edits are process-wide — true, but
# invisible, and it put a runtime concern inside a build step. (The shell also
# needs HyperfocalBridge.dll from .build\debug, which is build output rather
# than environment — Scripts\run.ps1 adds that itself.)
if (-not $env:QT_KIT) {
    $kitArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'msvc2022_arm64' }
               else { 'msvc2022_64' }
    $env:QT_KIT = Get-ChildItem 'C:\Qt' -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^6\.' } |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName $kitArch } |
        Where-Object { Test-Path (Join-Path $_ 'lib\cmake\Qt6\qt.toolchain.cmake') } |
        Select-Object -First 1
}
if ($env:QT_KIT) {
    $qtBin = Join-Path $env:QT_KIT 'bin'
    if (Test-Path $qtBin) { Add-PathDir $qtBin }
}

Write-Host "swift : $((Get-Command swift -ErrorAction SilentlyContinue).Source)"
Write-Host "cl    : $((Get-Command cl -ErrorAction SilentlyContinue).Source)"
Write-Host "cmake : $((Get-Command cmake -ErrorAction SilentlyContinue).Source)"
Write-Host "ninja : $((Get-Command ninja -ErrorAction SilentlyContinue).Source)"
Write-Host "vcpkg : $env:VCPKG_ROOT ($env:VCPKG_TRIPLET)"
# Reported like the others because a missing wgpu tree now fails the build
# rather than quietly producing a CPU-only binary — seeing "(none)" here is the
# early warning.
$wgpuRootShown = if ($env:WGPU_ROOT) { $env:WGPU_ROOT } else { '(none - run Scripts/fetch-wgpu.sh)' }
Write-Host "wgpu  : $wgpuRootShown"
$qtKitShown = if ($env:QT_KIT) { $env:QT_KIT } else { '(none - see README, or set QT_KIT)' }
Write-Host "qt    : $qtKitShown"
