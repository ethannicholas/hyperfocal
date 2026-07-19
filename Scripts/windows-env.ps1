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

# Swift: the installer records its PATH additions in the user registry, which
# an already-running shell won't have picked up.
if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
    $userPath = (Get-ItemProperty HKCU:\Environment -ErrorAction SilentlyContinue).Path
    if ($userPath) {
        $swiftDirs = ($userPath -split ';') | Where-Object { $_ -match 'Swift' }
        if ($swiftDirs) { $env:Path = ($swiftDirs -join ';') + ';' + $env:Path }
    }
}
if (-not $env:SDKROOT) {
    $sdkRoot = (Get-ItemProperty HKCU:\Environment -ErrorAction SilentlyContinue).SDKROOT
    if ($sdkRoot) { $env:SDKROOT = $sdkRoot }
}

if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
    if (Test-Path "$env:ProgramFiles\CMake\bin") {
        $env:Path = "$env:ProgramFiles\CMake\bin;" + $env:Path
    }
}

if (-not (Get-Command ninja -ErrorAction SilentlyContinue)) {
    $ninjaDir = Get-ChildItem "$env:LocalAppData\Microsoft\WinGet\Packages" `
        -Filter 'Ninja-build.Ninja*' -Directory -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($ninjaDir) { $env:Path = "$($ninjaDir.FullName);" + $env:Path }
}

if (-not $env:VCPKG_ROOT) {
    # Conventional layout: vcpkg checked out beside this repo.
    $sibling = Join-Path (Split-Path $PSScriptRoot -Parent) '..\vcpkg'
    if (Test-Path $sibling) { $env:VCPKG_ROOT = (Resolve-Path $sibling).Path }
}

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

# vcpkg's DLLs must be findable at runtime (dynamic triplet).
if ($env:VCPKG_ROOT) {
    $triplet = if ($env:VCPKG_TRIPLET) { $env:VCPKG_TRIPLET }
               elseif ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64-windows' }
               else { 'x64-windows' }
    $env:VCPKG_TRIPLET = $triplet
    $bin = Join-Path $env:VCPKG_ROOT "installed\$triplet\bin"
    if (Test-Path $bin) { $env:Path = "$bin;" + $env:Path }
}

Write-Host "swift : $((Get-Command swift -ErrorAction SilentlyContinue).Source)"
Write-Host "cl    : $((Get-Command cl -ErrorAction SilentlyContinue).Source)"
Write-Host "cmake : $((Get-Command cmake -ErrorAction SilentlyContinue).Source)"
Write-Host "vcpkg : $env:VCPKG_ROOT ($env:VCPKG_TRIPLET)"
