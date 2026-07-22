# Stage a self-contained hyperfocal-cli distribution (ROADMAP Windows
# residual: CLI DLL deployment). The dev loop resolves DLLs via PATH
# (windows-env.ps1); a shipped CLI needs them beside the exe. This script
# computes the exe's transitive DLL closure with dumpbin /dependents,
# copies it into the dist folder, and proves the result by running a
# synth -> fuse -> compare smoke with PATH stripped to the Windows dirs.
#
# Usage (after . Scripts\windows-env.ps1, plus HYPERFOCAL_WGPU/WGPU_ROOT
# if the build used them):
#   powershell -File Scripts\deploy-cli.ps1 [-Config release] [-Out dist\cli]
#
# Ships everything the exe needs except the OS itself. The VC++ runtime
# (vcruntime140/msvcp140/concrt140) rides along too — the Swift runtime
# directory carries copies, so the closure resolves and stages them
# app-locally and no redistributable install is required.
param(
    [string]$Config = 'release',
    [string]$Out = 'dist\cli'
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

Write-Host "== building ($Config)"
swift build -c $Config
if ($LASTEXITCODE) { throw "swift build failed" }
$exe = ".build\$Config\hyperfocal-cli.exe"
if (-not (Test-Path $exe)) { throw "$exe not found" }

# Tool + search-dir discovery. Everything comes from the loaded build
# environment: dumpbin from the VS tools on PATH, the Swift runtime dir
# from wherever swiftCore.dll resolves, vcpkg from VCPKG_ROOT, wgpu from
# WGPU_ROOT when the build was a wgpu build.
$dumpbin = (Get-Command dumpbin.exe -ErrorAction Stop).Source
$swiftCore = (where.exe swiftCore.dll 2>$null | Select-Object -First 1)
if (-not $swiftCore) { throw "swiftCore.dll not on PATH - load Scripts\windows-env.ps1 first" }
$vcpkgRoot = if ($env:VCPKG_ROOT) { $env:VCPKG_ROOT } else { throw "VCPKG_ROOT not set" }
$triplet = if ($env:VCPKG_TRIPLET) { $env:VCPKG_TRIPLET } else { 'arm64-windows' }
$searchDirs = @(
    (Split-Path -Parent $swiftCore),
    "$vcpkgRoot\installed\$triplet\bin"
)
if ($env:WGPU_ROOT) { $searchDirs += "$env:WGPU_ROOT\lib" }

# Breadth-first closure over dumpbin /dependents. Names that resolve in no
# search dir are OS/system DLLs (kernel32, api-ms-*, vcruntime, ...) and
# stay behind.
function Get-Dependents([string]$file) {
    (& $dumpbin /nologo /dependents $file) |
        Where-Object { $_ -match '^\s+(\S+\.dll)\s*$' } |
        ForEach-Object { $Matches[1] }
}
$closure = @{}   # dll name (lower) -> full source path
$queue = [System.Collections.Queue]::new()
$queue.Enqueue($exe)
while ($queue.Count) {
    $file = $queue.Dequeue()
    foreach ($name in Get-Dependents $file) {
        $key = $name.ToLowerInvariant()
        if ($closure.ContainsKey($key)) { continue }
        foreach ($dir in $searchDirs) {
            $candidate = Join-Path $dir $name
            if (Test-Path $candidate) {
                $closure[$key] = $candidate
                $queue.Enqueue($candidate)
                break
            }
        }
    }
}

Write-Host "== staging $Out ($($closure.Count) DLLs)"
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force $Out | Out-Null
Copy-Item $exe $Out
$closure.Values | Sort-Object | ForEach-Object {
    Write-Host "   $(Split-Path -Leaf $_)"
    Copy-Item $_ $Out
}

# Prove the staging is complete: run the shipped exe with PATH stripped to
# the OS. A missing DLL fails the launch; the synth gate catches a subtly
# broken imaging stack.
Write-Host "== smoke test (stripped PATH)"
$smoke = Join-Path $env:TEMP "hyperfocal-deploy-smoke"
if (Test-Path $smoke) { Remove-Item -Recurse -Force $smoke }
New-Item -ItemType Directory -Force $smoke | Out-Null
$distExe = (Resolve-Path (Join-Path $Out 'hyperfocal-cli.exe')).Path
$oldPath = $env:PATH
try {
    $env:PATH = "C:\Windows\System32;C:\Windows"
    & $distExe synth -o "$smoke\s" | Out-Null
    if ($LASTEXITCODE) { throw "smoke: synth failed" }
    & $distExe fuse (Get-ChildItem "$smoke\s\frame_*.tif").FullName -o "$smoke\out.tif" --color-space p3 | Out-Null
    if ($LASTEXITCODE) { throw "smoke: fuse failed" }
    $line = & $distExe compare "$smoke\out.tif" "$smoke\s\ground_truth.tif"
    if ($LASTEXITCODE) { throw "smoke: compare failed" }
    Write-Host "   $line"
    if ($line -notmatch 'PSNR: (\d+\.\d+)' -or [double]$Matches[1] -lt 35) {
        throw "smoke: implausible fusion output ($line)"
    }
} finally {
    $env:PATH = $oldPath
    Remove-Item -Recurse -Force $smoke -ErrorAction SilentlyContinue
}
Write-Host "== DEPLOY OK: $Out is self-contained"
