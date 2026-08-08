# Build Hyperfocal on Windows against a freshly built bridge DLL — the one
# build entry point here, and the analogue of Scripts/build.sh --qt (the Qt
# shell is the Windows UI, so there is no app/--qt split to make).
#
#   Scripts\build.ps1           build everything
#
# Build-and-launch is Scripts\run.ps1, which delegates the build here.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

. (Join-Path $root 'Scripts\windows-env.ps1')
Push-Location $root
try {
    # Regenerate the checked-in derived artifacts this build compiles into
    # the executable (the windows-linux notices slice, the i18n catalogs) so
    # master edits always take. Skipped when Python is absent — the
    # checked-in copies then apply, and the commit gate keeps those fresh.
    # Skip Windows' App Execution Aliases: a stock Windows 11 has a
    # `python3.exe` under WindowsApps that Get-Command finds and that exits
    # non-zero with "Python was not found" when run, so picking the first
    # *resolvable* name fails the build on a machine that has a perfectly
    # good `python`. Take the first that actually runs.
    $py = Get-Command python3, python -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notlike '*\WindowsApps\*' } |
        Select-Object -First 1
    if ($py) {
        & $py.Source (Join-Path $root 'Scripts\gen-notices.py')
        if ($LASTEXITCODE) { throw "gen-notices.py failed" }
        & $py.Source (Join-Path $root 'Scripts\gen-translations.py') | Out-Null
        if ($LASTEXITCODE) { throw "gen-translations.py failed" }
    } else {
        Write-Host "== python not found; building with checked-in generated artifacts"
    }

    Write-Host "== building HyperfocalBridge (SwiftPM)"
    swift build --product HyperfocalBridge
    if ($LASTEXITCODE) { throw "bridge build failed" }
    $bridgeDir = Join-Path $root '.build\debug'

    # windows-env.ps1 resolved the kit (and put its bin on PATH, which is what
    # the built executable needs to start) — the same place the Swift, MSVC,
    # vcpkg and wgpu environments come from.
    $qtKit = $env:QT_KIT
    if (-not $qtKit -or -not (Test-Path "$qtKit\lib\cmake\Qt6\qt.toolchain.cmake")) {
        throw "Qt kit not found$(if ($qtKit) { " at $qtKit" }) (set QT_KIT)"
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
} finally {
    Pop-Location
}
