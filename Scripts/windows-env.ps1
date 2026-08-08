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
        $swiftDirs = ($regPath -split ';') | Where-Object { $_ -match 'Swift' }
        if ($swiftDirs) {
            $env:Path = ($swiftDirs -join ';') + ';' + $env:Path
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
            $env:Path = "$dir;" + $env:Path
            return
        }
    }
    if (Test-Path (Join-Path $wingetLinks "$Name.exe")) {
        $env:Path = "$wingetLinks;" + $env:Path
        return
    }
    # Last resort: the package directory itself. Nested arbitrarily deep (CMake
    # keeps its versioned zip layout, Ninja unpacks flat), hence the recursion.
    $exe = Get-ChildItem $wingetPackages -Filter "$Name.exe" -Recurse `
               -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -like "*$PackagePrefix*" } |
           Select-Object -First 1
    if ($exe) { $env:Path = "$($exe.Directory.FullName);" + $env:Path }
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
$installer = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer"
if (Test-Path "$installer\vswhere.exe") {
    $env:Path = "$installer;" + $env:Path
    $vsRoot = & "$installer\vswhere.exe" -products * -latest `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if (-not $vsRoot) { $vsRoot = & "$installer\vswhere.exe" -products * -latest -property installationPath }
    $arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' { 'arm64' } default { 'x64' } }
    $vcvars = "$vsRoot\VC\Auxiliary\Build\vcvarsall.bat"
    if (Test-Path $vcvars) {
        foreach ($line in (cmd /c "`"$vcvars`" $arch > nul 2>&1 && set")) {
            if ($line -match '^([^=]+)=(.*)$') {
                [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
            }
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
    if (Test-Path $bin) { $env:Path = "$bin;" + $env:Path }
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
        $env:Path = "$wgpuLib;" + $env:Path
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
    if (Test-Path $qtBin) { $env:Path = "$qtBin;" + $env:Path }
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
