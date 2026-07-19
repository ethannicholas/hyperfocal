# Build the Qt shell on Windows against a freshly built bridge DLL — the
# Windows analogue of build.sh.
#
#   QtShell\build.ps1           build everything
#   QtShell\build.ps1 -Run      ...and launch the shell
#
# Qt: an aqt/online-installer kit with qtbase, qtdeclarative, and
# qtshadertools (see README "Building on Windows"). Point QT_KIT at the kit
# directory if it isn't the default below.
param([switch]$Run)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

. (Join-Path $root 'Scripts\windows-env.ps1')
Push-Location $root
try {
    Write-Host "== building HyperfocalBridge (SwiftPM)"
    swift build --product HyperfocalBridge
    if ($LASTEXITCODE) { throw "bridge build failed" }
    $bridgeDir = Join-Path $root '.build\debug'

    $qtKit = if ($env:QT_KIT) { $env:QT_KIT } else { 'C:\Qt\6.10.3\msvc2022_arm64' }
    if (-not (Test-Path "$qtKit\lib\cmake\Qt6\qt.toolchain.cmake")) {
        throw "Qt kit not found at $qtKit (set QT_KIT)"
    }

    Write-Host "== configuring + building Qt shell"
    # The shell builds Release: Qt's debug DLLs use the debug CRT, which the
    # Swift runtime (always release-CRT) can't join. The bridge boundary is
    # pure C, so a debug bridge under a release shell stays a fine dev loop.
    cmake -S QtShell -B QtShell\build -G Ninja `
        -DCMAKE_BUILD_TYPE=Release `
        -DCMAKE_TOOLCHAIN_FILE="$qtKit\lib\cmake\Qt6\qt.toolchain.cmake" `
        -DHYPERFOCAL_BRIDGE_DIR="$bridgeDir"
    if ($LASTEXITCODE) { throw "cmake configure failed" }
    cmake --build QtShell\build --parallel
    if ($LASTEXITCODE) { throw "cmake build failed" }

    Write-Host "== built QtShell\build\hyperfocal-qt.exe"
    # No rpath on Windows: the DLLs (Qt, bridge, Swift runtime, vcpkg) resolve
    # via PATH — windows-env.ps1 supplies the Swift/vcpkg parts.
    $env:Path = "$qtKit\bin;$bridgeDir;" + $env:Path
    if ($Run) { & QtShell\build\hyperfocal-qt.exe }
} finally {
    Pop-Location
}
