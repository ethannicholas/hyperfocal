# Builds a distribution-ready Windows package into dist/ - the Windows
# analogue of Scripts/package-app.sh.
#
#   Scripts\package-windows.ps1                 build + stage + pack the .msix
#   Scripts\package-windows.ps1 -SkipBuild      re-stage an existing build
#
#   -Version x.y.z    override the marketing version (default: latest git tag)
#   -QtKit <dir>      Qt kit (default: QT_KIT, else newest matching C:\Qt\6.*)
#   -OutDir <dir>     output root (default: dist)
#
# Two outputs, always both:
#
#   dist\Hyperfocal-<version>-<arch>\      the staged layout
#   dist\Hyperfocal-<version>-<arch>.msix  the Microsoft Store deliverable
#
# The layout is not a leftover - it is what a local install test registers
# (`Add-AppxPackage -Register <layout>\AppxManifest.xml`, developer mode) and
# what Scripts\store-media.ps1 captures screenshots from. Both want the loose
# files, and both get them from a normal run; neither needs packing skipped.
# There is deliberately no flag to skip it: packing measures 6.4 s for this
# payload (1468 files -> 83.3 MB), which buys nothing worth the risk of
# leaving dist\ holding a layout and an .msix that disagree - and the .msix is
# the artifact that gets submitted.
#
# There is deliberately NO archive either. An earlier version zipped the layout
# by default, which produced the one artifact nothing consumes while making the
# only real deliverable opt-in - and a Hyperfocal-<version>.zip sitting in
# dist\ reads as a downloadable release, which is exactly the thing this
# project does not ship.
#
# MSIX identity comes from the Store reservation and is baked in below - no
# need to pass anything for a normal release build. Override with
# -Identity / -Publisher / -PublisherDisplayName, or the environment
# HYPERFOCAL_MSIX_{IDENTITY,PUBLISHER,PUBLISHER_NAME}.
#
# The package satisfies the Qt LGPL-3.0 checklist in ROADMAP: Qt ships as
# separate DLLs (never static), the GPL-3.0 + LGPL-3.0 texts ride along, and
# the GPLv3-only `qsb` build tool is NOT redistributed (asserted below). The
# section 4(d)(0) relinking right is satisfied by SOURCE - the app is MIT and public
# with a reproducible build, so anyone can rebuild it against a modified Qt.
# There is deliberately no off-Store binary: Hyperfocal ships through the
# Mac App Store and Microsoft Store, or you build it yourself. Do not add one,
# and do not reintroduce an archive of the staged layout to stand in for one.
#
# ASCII ONLY, deliberately. Windows PowerShell 5.1 decodes a BOM-less .ps1 as
# the ANSI codepage, where the last byte of a UTF-8 em dash lands on CP1252's
# closing curly quote - which PowerShell accepts as a string delimiter. An em
# dash inside a string therefore ends it early and the file stops parsing.
param(
    [string]$Version,
    [string]$OutDir = "dist",
    [string]$QtKit = $env:QT_KIT,
    [switch]$SkipBuild,
    [string]$Identity,
    [string]$Publisher,
    [string]$PublisherDisplayName
)

# -------------------------------------------------------- Store identity ----
# From the Microsoft Store reservation (Partner Center > Product identity).
#
# These are PUBLIC values, not credentials, which is why they are checked in
# rather than passed every time: Identity and PublisherDisplayName are written
# into every installed package's manifest (readable with Get-AppxPackage, and
# shown on the Store listing), and Publisher is the subject of the certificate
# the package is signed with - a certificate subject ships inside the signature
# by construction. The secrets in this area are the Partner Center account
# login and, if submission is ever automated, the Azure AD client secret for
# the Store submission API. Neither is an input to this script, and neither
# belongs in this repo.
#
# Store submissions are signed BY the Store, so no code-signing certificate is
# needed here; the .msix this produces is deliberately unsigned.
$defaultIdentity = 'EthanNicholas.Hyperfocal'
$defaultPublisher = 'CN=AE9F9BE8-6C95-400D-8361-0E58C58DAEF9'
$defaultPublisherDisplayName = 'Ethan Nicholas'

if (-not $Identity) {
    $Identity = if ($env:HYPERFOCAL_MSIX_IDENTITY) { $env:HYPERFOCAL_MSIX_IDENTITY }
                else { $defaultIdentity }
}
if (-not $Publisher) {
    $Publisher = if ($env:HYPERFOCAL_MSIX_PUBLISHER) { $env:HYPERFOCAL_MSIX_PUBLISHER }
                 else { $defaultPublisher }
}
if (-not $PublisherDisplayName) {
    $PublisherDisplayName = if ($env:HYPERFOCAL_MSIX_PUBLISHER_NAME) { $env:HYPERFOCAL_MSIX_PUBLISHER_NAME }
                            else { $defaultPublisherDisplayName }
}
# Catches a typo'd override, which would otherwise surface as a Store rejection
# long after the build. Identity/Publisher must match the reservation exactly.
if ($Publisher -notmatch '^CN=') {
    throw "Publisher must be a distinguished name starting with CN= (got '$Publisher')"
}

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Scripts\windows-env.ps1')
Push-Location $root
try {

# A release must ship what is committed: verify the checked-in derived
# artifacts (the staged notices slice, the i18n catalogs) match their
# masters instead of silently packaging stale or uncommitted content.
# Finding Python on Windows needs the same care as Scripts/python-interpreter.sh:
# a python.org/winget install ships python.exe and py.exe but NO python3.exe,
# while Windows 11 puts an "app execution alias" STUB at
# WindowsApps\python3.exe. The stub is on PATH, so Get-Command finds it, and
# then it prints "Python was not found..." and exits non-zero. Testing that a
# candidate actually runs is the only reliable check.
#
# The probe must tolerate a candidate that fails, and on PS 5.1 that means
# NOT redirecting its stderr with 2>$null: redirecting a native command's
# stderr raises NativeCommandError all by itself, which -ErrorAction Stop
# turns into a terminating error - the stub's own "Python was not found"
# message would abort the release. Merge the stream instead (2>&1 into
# Out-Null) with the preference relaxed for the length of the probe.
$py = $null
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
foreach ($cand in @('python3', 'python', 'py')) {
    foreach ($cmd in @(Get-Command $cand -All -ErrorAction SilentlyContinue)) {
        & $cmd.Source -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $py = $cmd.Source; break }
    }
    if ($py) { break }
}
$ErrorActionPreference = $prevEAP
if (-not $py) {
    throw "no working Python 3 found (tried python3, python, py) - needed to verify generated artifacts"
}
Write-Host "== python: $py"
& $py (Join-Path $root 'Scripts\gen-notices.py') --check
if ($LASTEXITCODE) { throw "per-platform notices are stale - run Scripts/gen-notices.py and commit" }
& $py (Join-Path $root 'Scripts\gen-translations.py') --check
if ($LASTEXITCODE) { throw "generated translations are stale - run Scripts/gen-translations.py and commit" }

# ---------------------------------------------------------------- version --
# Same derivation as package-app.sh and QtShell/CMakeLists.txt: marketing
# version from the latest tag (leading v stripped), build number = commit count.
# `git describe` on a repo with no tags writes to stderr and fails, which
# under -ErrorAction Stop aborts the script; ask whether any tag exists first
# rather than redirecting (redirecting a native command's stderr in PS 5.1
# raises NativeCommandError all by itself).
if (-not $Version) {
    $Version = '1.0.0'
    if (& git tag) {
        $tag = & git describe --tags --abbrev=0
        if ($tag) { $Version = $tag -replace '^v', '' }
    }
}
$build = & git rev-list --count HEAD
if (-not $build) { $build = '1' }
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$name = "Hyperfocal-$Version-$arch"
$stage = Join-Path $root "$OutDir\$name"
Write-Host "== packaging Hyperfocal $Version ($build) for $arch"

# ------------------------------------------------------------------ build --
# ------------------------------------------------------------------ wgpu ---
# The GPU compute backend, now compiled into every Windows build (Package.swift
# stops the build without it) rather than opted into here. This check stays
# because it runs earlier and says more: it names the directory it looked in,
# and the staging below needs $wgpuLib anyway. A Store build that quietly fused
# on the CPU is what shipped before 2026-08-06, and the difference is a 45 MP
# dmap fuse at 13.9 s instead of 17.9 s and a 100 MP one at 26.5 s instead of
# 33.7 s, with a third less device memory - Scripts\fetch-wgpu.sh puts the tree
# where WGPU_ROOT (or the sibling default) points.
if (-not $env:WGPU_ROOT) {
    $siblingWgpu = Join-Path $root '..\wgpu-native'
    if (Test-Path $siblingWgpu) { $env:WGPU_ROOT = (Resolve-Path $siblingWgpu).Path }
}
$wgpuLib = if ($env:WGPU_ROOT) { Join-Path $env:WGPU_ROOT 'lib' } else { $null }
if (-not $wgpuLib -or -not (Test-Path (Join-Path $wgpuLib 'wgpu_native.dll'))) {
    throw "wgpu-native not found (looked in '$wgpuLib') - run Scripts/fetch-wgpu.sh, or set WGPU_ROOT. The GPU backend is not optional in a release build."
}
# Dynamic on purpose: wgpu ships as its own DLL, like every other library in
# this package. Nothing licensing-related forces it (wgpu is MIT), it just
# keeps the staged layout honest about what is in it and lets a user swap in
# their own build. HYPERFOCAL_WGPU_STATIC would fold it into the executable, so
# clear an inherited one - the staging step below expects the DLL.
Remove-Item Env:\HYPERFOCAL_WGPU_STATIC -ErrorAction SilentlyContinue
Write-Host "== wgpu-native: $wgpuLib"

# The notices for wgpu's ~140-crate Rust dependency graph are generated, not
# hand-written (the upstream release archive carries no license text at all).
# Verify they were generated for the tag actually pinned - a wgpu bump without
# a regeneration would ship attribution for the wrong versions.
& $py (Join-Path $root 'Scripts\gen-wgpu-notices.py') --check
if ($LASTEXITCODE) { throw "wgpu third-party notices are stale - run Scripts/gen-wgpu-notices.py and commit" }

if (-not $SkipBuild) {
    Write-Host "== building HyperfocalBridge (release, wgpu)"
    swift build -c release --product HyperfocalBridge
    if ($LASTEXITCODE) { throw "bridge build failed" }
}
$bridgeDir = Join-Path $root '.build\release'

if (-not $QtKit) {
    $kitArch = if ($arch -eq 'arm64') { 'msvc2022_arm64' } else { 'msvc2022_64' }
    $QtKit = Get-ChildItem 'C:\Qt' -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^6\.' } |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName $kitArch } |
        Where-Object { Test-Path (Join-Path $_ 'lib\cmake\Qt6\qt.toolchain.cmake') } |
        Select-Object -First 1
}
if (-not $QtKit -or -not (Test-Path "$QtKit\lib\cmake\Qt6\qt.toolchain.cmake")) {
    throw "Qt kit not found (set QT_KIT)"
}
$qtVersion = Split-Path (Split-Path $QtKit -Parent) -Leaf
Write-Host "== Qt $qtVersion at $QtKit"

# A separate build dir from QtShell\build so packaging never clobbers (or
# inherits) the dev loop's configuration - that one links a debug bridge.
$qtBuild = Join-Path $root 'QtShell\build-release'
if (-not $SkipBuild) {
    Write-Host "== building the Qt shell (release bridge)"
    cmake -S QtShell -B $qtBuild -G Ninja `
        -DCMAKE_BUILD_TYPE=Release `
        -DCMAKE_TOOLCHAIN_FILE="$QtKit\lib\cmake\Qt6\qt.toolchain.cmake" `
        -DHYPERFOCAL_BRIDGE_DIR="$bridgeDir"
    if ($LASTEXITCODE) { throw "cmake configure failed" }
    cmake --build $qtBuild --parallel
    if ($LASTEXITCODE) { throw "cmake build failed" }
}
$exe = Join-Path $qtBuild 'Hyperfocal.exe'
if (-not (Test-Path $exe)) { throw "no shell executable at $exe (drop -SkipBuild)" }

# ------------------------------------------------------------------ stage --
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item $exe $stage

# The Swift runtime redistributable, beside the toolchain rather than in it.
$swiftBin = Split-Path (Get-Command swift).Source -Parent
$swiftRoot = (Resolve-Path (Join-Path $swiftBin '..\..\..\..')).Path   # ...\Swift
$swiftRuntime = Get-ChildItem (Join-Path $swiftRoot 'Runtimes') -Directory -ErrorAction SilentlyContinue |
    Sort-Object { [version]$_.Name } -Descending |
    ForEach-Object { Join-Path $_.FullName 'usr\bin' } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $swiftRuntime) { throw "Swift runtime redistributable not found under $swiftRoot\Runtimes" }
$vcpkgBin = Join-Path $env:VCPKG_ROOT "installed\$env:VCPKG_TRIPLET\bin"
Write-Host "== runtime sources:"
Write-Host "   swift : $swiftRuntime"
Write-Host "   vcpkg : $vcpkgBin"

# Transitive import walk. Hardcoding a DLL list is how a package ships broken
# after a dependency changes: ask the binaries instead. Anything that resolves
# in our own runtime directories gets copied; everything else (kernel32,
# user32, the api-ms-win-* set) is a system DLL and deliberately left alone.
$searchDirs = @($stage, $swiftRuntime, $vcpkgBin, $wgpuLib) | Where-Object { Test-Path $_ }
function Get-Imports([string]$binary) {
    (& dumpbin /nologo /dependents $binary) |
        ForEach-Object { if ($_ -match '^\s{4}(\S+\.[Dd][Ll][Ll])\s*$') { $Matches[1] } }
}
$copied = New-Object 'System.Collections.Generic.HashSet[string]'
$queue = New-Object 'System.Collections.Generic.Queue[string]'
$queue.Enqueue((Join-Path $stage 'Hyperfocal.exe'))
# The bridge is loaded by name from the same directory, so seed it explicitly.
$bridgeDll = Join-Path $bridgeDir 'HyperfocalBridge.dll'
if (-not (Test-Path $bridgeDll)) { throw "no bridge DLL at $bridgeDll" }
Copy-Item $bridgeDll $stage
[void]$copied.Add('hyperfocalbridge.dll')
$queue.Enqueue((Join-Path $stage 'HyperfocalBridge.dll'))

while ($queue.Count -gt 0) {
    $current = $queue.Dequeue()
    foreach ($dep in Get-Imports $current) {
        if ($copied.Contains($dep.ToLower())) { continue }
        $src = $searchDirs | ForEach-Object { Join-Path $_ $dep } |
               Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $src) { continue }        # system DLL - not ours to ship
        [void]$copied.Add($dep.ToLower())
        $dest = Join-Path $stage $dep
        if (-not (Test-Path $dest)) { Copy-Item $src $dest }
        $queue.Enqueue($dest)
    }
}
Write-Host "== $($copied.Count) runtime DLLs resolved from swift/vcpkg/wgpu"

# The import walk found wgpu only if the bridge was actually built against it.
# Without this assertion a release silently reverts to CPU fusion the moment
# the environment loses WGPU_ROOT - which is exactly how it shipped CPU-only
# for its whole life before 2026-08-06.
if (-not (Test-Path (Join-Path $stage 'wgpu_native.dll'))) {
    throw "wgpu_native.dll not staged - the bridge was not built with the GPU backend (stale .build? drop -SkipBuild)"
}

# Qt, via windeployqt - the supported way, and the one that keeps every Qt
# library a separate DLL rather than statically linked. That is not on its own
# the compliance route (see the header: section 4(d)(0) is satisfied by public MIT
# source), but a static Qt would put the whole app under section 4's relinking
# duty in a form the release model cannot absorb, so it stays asserted below.
#
# --no-compiler-runtime: windeployqt otherwise drops an 11 MB
# vc_redist.<arch>.exe INSTALLER into the package (it does this by default,
# not only under --compiler-runtime). The MSVC runtime it would install is
# already here app-locally - the Swift runtime redistributable ships
# MSVCP140/VCRUNTIME140/CONCRT140 and the import walk above picks them up -
# and an installer executable inside the payload is not something an MSIX can
# run anyway. The assertion below keeps the app-local copies honest.
Write-Host "== windeployqt"
& "$QtKit\bin\windeployqt.exe" --release --no-compiler-runtime `
    --qmldir (Join-Path $root 'QtShell') `
    (Join-Path $stage 'Hyperfocal.exe')
if ($LASTEXITCODE) { throw "windeployqt failed" }
foreach ($dll in @('VCRUNTIME140.dll', 'MSVCP140.dll')) {
    if (-not (Test-Path (Join-Path $stage $dll))) {
        throw "$dll missing - the MSVC runtime must ship app-locally"
    }
}

# LGPL checklist (e): the GPLv3-only shader compiler must never ship. It is
# not deployed today; assert it so a future windeployqt or CMake change can't
# quietly start shipping it. Compiled .qsb output is fine - that is our data,
# and it lives inside the executable's resources anyway.
$forbidden = Get-ChildItem $stage -Recurse -Include 'qsb.exe','lupdate.exe','lrelease.exe' -ErrorAction SilentlyContinue
if ($forbidden) {
    throw "GPL build tools staged (must not ship): $($forbidden.Name -join ', ')"
}
# Qt must be dynamically linked; a static Qt would put the whole app under
# LGPL section 4's relinking duty, which the release model cannot absorb.
if (-not (Test-Path (Join-Path $stage 'Qt6Core.dll'))) {
    throw "Qt6Core.dll not staged - Qt must ship as separate DLLs, never static"
}

# --------------------------------------------------------------- notices ---
# The notices and license texts must travel with the binary, not only in the
# source tree. The staged NOTICE.md is the Windows/Linux slice of the master
# (Scripts/gen-notices.py) - this package should not list macOS-only detail.
Copy-Item (Join-Path $root 'Packaging\notices\windows-linux\NOTICE.md') $stage
Copy-Item (Join-Path $root 'LICENSE') (Join-Path $stage 'LICENSE.txt')
New-Item -ItemType Directory -Force (Join-Path $stage 'licenses') | Out-Null
Copy-Item (Join-Path $root 'licenses\*.txt') (Join-Path $stage 'licenses')

$compliance = @"
# Hyperfocal $Version ($build) - Windows package compliance

Hyperfocal itself is MIT-licensed; see ``LICENSE.txt``. Third-party components
and their licenses are listed in ``NOTICE.md``, and the full texts of the
standard licenses are in ``licenses\``.

## Qt $qtVersion - LGPL-3.0

This package uses the Qt framework under the **GNU Lesser General Public
License, version 3**. Qt is unmodified and dynamically linked: every Qt
library in this folder is a separate DLL, never statically linked into the
executable.

- The LGPL-3.0 and GPL-3.0 texts are bundled in ``licenses\``.
- **Corresponding source.** The exact Qt source this build links against is
  Qt $qtVersion, available from https://download.qt.io/archive/qt/ - and, for
  three years from the date of this distribution, the maintainer will supply
  that exact source on request at no more than the cost of distribution.
  (A bare vendor link is not on its own sufficient under the LGPL, hence the
  standing written offer.)
- **Using a modified Qt.** Hyperfocal's own source is MIT-licensed and public
  at https://github.com/ethannicholas/hyperfocal, and its build is
  reproducible, so you may rebuild the application against a modified,
  interface-compatible Qt and run the result - the relinking right under
  LGPL-3.0 section 4(d)(0), satisfied by source rather than by shipping object
  files. Build instructions are in the repository's README.
  (Hyperfocal is distributed as a Microsoft Store package, whose installed copy
  lives under a write-protected ``WindowsApps`` directory, so replacing DLLs
  in place is not the supported route; rebuilding from source is.)
- The ``qsb`` shader compiler (GPL-3.0-only) is a build tool and is **not**
  redistributed here. Only its compiled shader output ships, inside the
  executable's own resources.

## Microsoft DirectX shader compilers

``dxcompiler.dll``, ``dxil.dll`` and ``d3dcompiler_47.dll`` are Microsoft
binaries, copied from the Windows SDK's ``Redist\D3D`` directory and loaded at
runtime by Qt's Direct3D backends (the first two for Direct3D 12, the third for
HLSL compilation on Direct3D 11). They are **not** covered by Hyperfocal's MIT
license: they are redistributed as "Distributable Code" under the Microsoft
Software License Terms for the Windows Software Development Kit, unmodified and
with their copyright, trademark and patent notices intact.

``dxcompiler.dll`` is built from Microsoft's DirectX Shader Compiler, which
incorporates LLVM and Clang under the University of Illinois/NCSA Open Source
License. Microsoft's notice for those components is reproduced verbatim in
``licenses\DirectXShaderCompiler-ThirdPartyNotices.txt``.

> Copyright (c) Microsoft Corporation. All rights reserved.

Hyperfocal's MIT license covers Hyperfocal's own code. Every third-party
component bundled here remains under its own license, listed in ``NOTICE.md``.

## Mesa 3D - llvmpipe software OpenGL

``opengl32sw.dll`` is Mesa's llvmpipe software rasterizer (MIT, embedding LLVM
under Apache-2.0 WITH LLVM-exception), staged by ``windeployqt`` and used by Qt
only when a machine offers no usable hardware OpenGL. It is unmodified, and kept
deliberately so the package still runs on GPU-less machines. See ``NOTICE.md``.

## Microsoft Visual C++ runtime

``MSVCP140.dll``, ``VCRUNTIME140.dll``, ``VCRUNTIME140_1.dll`` and
``CONCRT140.dll`` ship app-locally as "Distributable Code" under the Microsoft
Software License Terms for Visual Studio.

## Swift runtime and ICU

The Swift runtime redistributable ships beside the executable (Apache-2.0 WITH
Runtime Library Exception). It carries ICU (``_FoundationICU.dll``,
``icuuc.dll``), which is under the Unicode License and is **not** covered by that
exception; its required attribution is in ``NOTICE.md``.

## Adobe DNG SDK

Linear-DNG export uses the Adobe DNG SDK. This product includes DNG technology
under license by Adobe Systems Incorporated. See ``NOTICE.md``.

## LibRaw

Camera-raw decoding uses LibRaw under the **CDDL-1.0** arm of its dual license
(``licenses\CDDL-1.0.txt``). LibRaw's optional Adobe-DNG-SDK integration is not
enabled in this build.

## wgpu-native

GPU fusion uses ``wgpu_native.dll``, an unmodified prebuilt of wgpu-native,
under the **MIT** arm of its ``MIT OR Apache-2.0`` dual license. It is a Rust
library and statically links its own dependency graph, so the complete
component list - every crate, its version, its SPDX license and the verbatim
license texts - is bundled in
``licenses\wgpu-native-ThirdPartyNotices.txt``. Every component is under a
permissive license; none is copyleft.
"@
Set-Content -Path (Join-Path $stage 'COMPLIANCE.md') -Value $compliance -Encoding utf8

# ------------------------------------------------------------------ MSIX ---
# The layout is always MSIX-ready: assets + a filled manifest. Packing stays
# opt-in because the loose layout is what a local install test registers
# (Add-AppxPackage -Register on the AppxManifest.xml, developer mode), while
# the .msix is only wanted when something is actually going to Partner Center.
$assets = Join-Path $stage 'Assets'
New-Item -ItemType Directory -Force $assets | Out-Null
Add-Type -AssemblyName System.Drawing
$icon = [System.Drawing.Image]::FromFile((Join-Path $root 'App\AppIcon.png'))
foreach ($logo in @(@{n='Square44x44Logo'; s=44}, @{n='Square150x150Logo'; s=150}, @{n='StoreLogo'; s=50})) {
    $bmp = New-Object System.Drawing.Bitmap($logo.s, $logo.s)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($icon, 0, 0, $logo.s, $logo.s)
    $g.Dispose()
    $bmp.Save((Join-Path $assets "$($logo.n).png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}
$icon.Dispose()

# MSIX Identity.Version is four parts and the Store requires the revision to
# be 0, so the commit count cannot ride there; it stays the build number the
# About box shows.
$manifest = Get-Content (Join-Path $root 'Packaging\windows\AppxManifest.xml.in') -Raw
$manifest = $manifest.
    Replace('@MSIX_IDENTITY@', $Identity).
    Replace('@MSIX_PUBLISHER@', $Publisher).
    Replace('@MSIX_PUBLISHER_DISPLAY_NAME@', $PublisherDisplayName).
    Replace('@MSIX_VERSION@', "$Version.0").
    Replace('@MSIX_ARCH@', $arch)
Set-Content -Path (Join-Path $stage 'AppxManifest.xml') -Value $manifest -Encoding utf8
Write-Host "== identity $Identity / $Publisher ($PublisherDisplayName)"

# makeappx ships with the Windows SDK, which is already a prerequisite for
# this script (Scripts\windows-env.ps1 - and dumpbin above comes from the same
# toolchain install), so packing by default adds no new requirement.
$msixPath = Join-Path $root "$OutDir\$name.msix"
$makeappx = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Filter 'makeappx.exe' -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "\\$arch\\" } | Select-Object -First 1
if (-not $makeappx) { throw "makeappx.exe not found (install the Windows SDK)" }
if (Test-Path $msixPath) { Remove-Item $msixPath }
# /nv skips signature validation of the payload, which has none - this is
# an unsigned package on purpose. Partner Center signs Store submissions
# with the Store certificate; uploading a self-signed one is not wanted.
& $makeappx.FullName pack /d $stage /p $msixPath /o /nv
if ($LASTEXITCODE) { throw "makeappx failed" }
Write-Host "== packed $msixPath (unsigned - the Store signs it on submission)"

$files = Get-ChildItem $stage -Recurse -File
$size = ($files | Measure-Object -Property Length -Sum).Sum
Write-Host "== staged $stage ($([math]::Round($size / 1MB, 1)) MB, $($files.Count) files)"

} finally {
    Pop-Location
}
