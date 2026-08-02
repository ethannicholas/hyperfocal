# Builds a distribution-ready Windows package into dist/ - the Windows
# analogue of Scripts/package-app.sh.
#
#   Scripts\package-windows.ps1                 build + stage + zip
#   Scripts\package-windows.ps1 -SkipBuild      re-stage an existing build
#   Scripts\package-windows.ps1 -Msix           ...and pack an .msix
#
#   -Version x.y.z    override the marketing version (default: latest git tag)
#   -QtKit <dir>      Qt kit (default: QT_KIT, else newest matching C:\Qt\6.*)
#   -OutDir <dir>     output root (default: dist)
#   -NoZip            skip the archive
#
# MSIX identity (all three required for -Msix; Store submission rejects the
# placeholders otherwise):
#   -Identity              package name from the Store reservation
#   -Publisher             the CN=... subject, matching the signing cert
#   -PublisherDisplayName  human-readable publisher
# or the environment: HYPERFOCAL_MSIX_{IDENTITY,PUBLISHER,PUBLISHER_NAME}.
#
# The package satisfies the Qt LGPL-3.0 checklist in ROADMAP: Qt ships as
# replaceable DLLs (never static), the GPL-3.0 + LGPL-3.0 texts ride along,
# the GPLv3-only `qsb` build tool is NOT redistributed (asserted below), and
# the same build is published off-Store so a user can substitute a modified
# Qt - which the locked WindowsApps copy would otherwise prevent.
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
    [switch]$NoZip,
    [switch]$Msix,
    [string]$Identity = $env:HYPERFOCAL_MSIX_IDENTITY,
    [string]$Publisher = $env:HYPERFOCAL_MSIX_PUBLISHER,
    [string]$PublisherDisplayName = $env:HYPERFOCAL_MSIX_PUBLISHER_NAME
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Scripts\windows-env.ps1')
Push-Location $root
try {

# A release must ship what is committed: verify the checked-in derived
# artifacts (the staged notices slice, the i18n catalogs) match their
# masters instead of silently packaging stale or uncommitted content.
$py = Get-Command python3, python -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $py) { throw "python not found (needed to verify generated artifacts)" }
& $py.Source (Join-Path $root 'Scripts\gen-notices.py') --check
if ($LASTEXITCODE) { throw "per-platform notices are stale - run Scripts/gen-notices.py and commit" }
& $py.Source (Join-Path $root 'Scripts\gen-translations.py') --check
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
if (-not $SkipBuild) {
    Write-Host "== building HyperfocalBridge (release)"
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
$exe = Join-Path $qtBuild 'hyperfocal-qt.exe'
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
$searchDirs = @($stage, $swiftRuntime, $vcpkgBin) | Where-Object { Test-Path $_ }
function Get-Imports([string]$binary) {
    (& dumpbin /nologo /dependents $binary) |
        ForEach-Object { if ($_ -match '^\s{4}(\S+\.[Dd][Ll][Ll])\s*$') { $Matches[1] } }
}
$copied = New-Object 'System.Collections.Generic.HashSet[string]'
$queue = New-Object 'System.Collections.Generic.Queue[string]'
$queue.Enqueue((Join-Path $stage 'hyperfocal-qt.exe'))
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
Write-Host "== $($copied.Count) runtime DLLs resolved from swift/vcpkg"

# Qt, via windeployqt - the supported way, and the one that keeps every Qt
# library a separate replaceable DLL (LGPL-3.0 section 4(d)(1)).
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
    (Join-Path $stage 'hyperfocal-qt.exe')
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
    throw "Qt6Core.dll not staged - Qt must ship as replaceable DLLs, never static"
}

# --------------------------------------------------------------- notices ---
# The notices and license texts must travel with the binary, not only in the
# source tree. The staged NOTICE.md is the Windows/Linux slice of the master
# (Scripts/gen-notices.py) — this package should not list macOS-only detail.
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
library in this folder is a separate, replaceable DLL.

- The LGPL-3.0 and GPL-3.0 texts are bundled in ``licenses\``.
- **Corresponding source.** The exact Qt source this build links against is
  Qt $qtVersion, available from https://download.qt.io/archive/qt/ - and, for
  three years from the date of this distribution, the maintainer will supply
  that exact source on request at no more than the cost of distribution.
  (A bare vendor link is not on its own sufficient under the LGPL, hence the
  standing written offer.)
- **Replacing Qt.** You may substitute modified, interface-compatible Qt
  libraries and relink simply by replacing the DLLs in this folder. If you
  obtained Hyperfocal from the Microsoft Store, its installed copy lives under
  a write-protected ``WindowsApps`` directory; the identical build is published
  outside the Store as a plain archive for exactly this purpose, and the source
  is public (MIT) with a reproducible build.
- The ``qsb`` shader compiler (GPL-3.0-only) is a build tool and is **not**
  redistributed here. Only its compiled shader output ships, inside the
  executable's own resources.

## Microsoft DirectX shader compiler

``dxcompiler.dll`` and ``dxil.dll`` are Microsoft binaries, copied from the
Windows SDK's ``Redist\D3D`` directory and loaded at runtime by Qt's Direct3D 12
backend. They are **not** covered by Hyperfocal's MIT license: they are
redistributed as "Distributable Code" under the Microsoft Software License Terms
for the Windows Software Development Kit, unmodified and with their copyright,
trademark and patent notices intact.

``dxcompiler.dll`` is built from Microsoft's DirectX Shader Compiler, which
incorporates LLVM and Clang under the University of Illinois/NCSA Open Source
License. Microsoft's notice for those components is reproduced verbatim in
``licenses\DirectXShaderCompiler-ThirdPartyNotices.txt``.

> Copyright (c) Microsoft Corporation. All rights reserved.

Hyperfocal's MIT license covers Hyperfocal's own code. Every third-party
component bundled here remains under its own license, listed in ``NOTICE.md``.

## Adobe DNG SDK

Linear-DNG export uses the Adobe DNG SDK. This product includes DNG technology
under license by Adobe Systems Incorporated. See ``NOTICE.md``.

## LibRaw

Camera-raw decoding uses LibRaw under the **CDDL-1.0** arm of its dual license
(``licenses\CDDL-1.0.txt``). LibRaw's optional Adobe-DNG-SDK integration is not
enabled in this build.
"@
Set-Content -Path (Join-Path $stage 'COMPLIANCE.md') -Value $compliance -Encoding utf8

# ------------------------------------------------------------------ MSIX ---
# The layout is always MSIX-ready: assets + a filled manifest. Packing is
# opt-in because it needs Store identity and a signing certificate.
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
$placeholders = @()
if (-not $Identity) { $Identity = 'PUBLISHER-RESERVED-NAME-HERE'; $placeholders += 'Identity' }
if (-not $Publisher) { $Publisher = 'CN=PUBLISHER-CERTIFICATE-SUBJECT-HERE'; $placeholders += 'Publisher' }
if (-not $PublisherDisplayName) { $PublisherDisplayName = 'PUBLISHER-DISPLAY-NAME-HERE'; $placeholders += 'PublisherDisplayName' }
$manifest = $manifest.
    Replace('@MSIX_IDENTITY@', $Identity).
    Replace('@MSIX_PUBLISHER@', $Publisher).
    Replace('@MSIX_PUBLISHER_DISPLAY_NAME@', $PublisherDisplayName).
    Replace('@MSIX_VERSION@', "$Version.0").
    Replace('@MSIX_ARCH@', $arch)
Set-Content -Path (Join-Path $stage 'AppxManifest.xml') -Value $manifest -Encoding utf8
if ($placeholders) {
    Write-Host "   AppxManifest.xml written with PLACEHOLDER $($placeholders -join ', ') - supply the Store values before submitting"
}

if ($Msix) {
    if ($placeholders) {
        throw "-Msix needs real identity: pass -Identity/-Publisher/-PublisherDisplayName (or the HYPERFOCAL_MSIX_* environment variables)"
    }
    $makeappx = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Filter 'makeappx.exe' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\$arch\\" } | Select-Object -First 1
    if (-not $makeappx) { throw "makeappx.exe not found (install the Windows SDK)" }
    $msixPath = Join-Path $root "$OutDir\$name.msix"
    if (Test-Path $msixPath) { Remove-Item $msixPath }
    & $makeappx.FullName pack /d $stage /p $msixPath /o
    if ($LASTEXITCODE) { throw "makeappx failed" }
    Write-Host "== packed $msixPath (unsigned; sign it with the cert matching $Publisher)"
}

# ------------------------------------------------------------------- zip ---
if (-not $NoZip) {
    $zip = Join-Path $root "$OutDir\$name.zip"
    if (Test-Path $zip) { Remove-Item $zip }
    Compress-Archive -Path $stage -DestinationPath $zip
    Write-Host "== archived $zip"
}

$files = Get-ChildItem $stage -Recurse -File
$size = ($files | Measure-Object -Property Length -Sum).Sum
Write-Host "== staged $stage ($([math]::Round($size / 1MB, 1)) MB, $($files.Count) files)"

} finally {
    Pop-Location
}
