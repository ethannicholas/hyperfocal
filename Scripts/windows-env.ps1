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

Write-Host "swift : $((Get-Command swift -ErrorAction SilentlyContinue).Source)"
Write-Host "cl    : $((Get-Command cl -ErrorAction SilentlyContinue).Source)"
Write-Host "cmake : $((Get-Command cmake -ErrorAction SilentlyContinue).Source)"
Write-Host "ninja : $((Get-Command ninja -ErrorAction SilentlyContinue).Source)"
Write-Host "vcpkg : $env:VCPKG_ROOT ($env:VCPKG_TRIPLET)"
