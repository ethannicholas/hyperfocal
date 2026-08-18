# Audits a staged Windows package for dependencies it does not ship.
#
#   Scripts\check-package-deps.ps1 -Stage dist\Hyperfocal-1.0.0-x64
#
# Runs from Scripts\package-windows.ps1 on every package build, and standalone
# against an already-staged layout when investigating one.
#
# The constraint it enforces: a package that imports a redistributable it does
# not ship launches here and nowhere else. Qt6Gui and Qt6Quick import
# MSVCP140_2.dll, five Qt DLLs import MSVCP140_1.dll, and any machine with
# Visual Studio installed resolves both from System32 - so the box that builds
# the package is the one box that cannot find the defect by running the app.
# Store certification can, and reports it as an undisclosed dependency on
# VC_redist.x64 days after submission. This audit reports it in seconds.
#
# A dependency is legitimate only if it is one of:
#
#   - shipped in the package ROOT. That is the application directory, and the
#     loader searches it first for every binary in the package - plugins in
#     subdirectories included, since they are loaded by full path and resolve
#     their own imports against the process's application directory, not their
#     own. A DLL sitting only in a subdirectory therefore does NOT satisfy an
#     import, and this audit says so.
#   - an API set (api-ms-win-*, ext-ms-*), which the loader resolves through
#     the API set schema and which has no file on disk at all.
#   - a Windows component: present in System32 AND declaring itself part of
#     the Windows operating system in its version resource.
#
# Everything else fails. That last discriminator is the load-bearing one:
# MSVCP140_2.dll IS in System32 on a developer box, so "can I find it in
# System32" cannot tell an operating-system DLL from a redistributable one.
# The version resource can - the redistributable CRT declares its product as
# Visual Studio, the operating system declares itself - and a name found under
# the VC redist directory is reported as redistributable regardless, together
# with the path it should have been staged from.
#
# ASCII ONLY, deliberately - see the note at the top of
# Scripts\package-windows.ps1 for what a UTF-8 dash does to Windows
# PowerShell 5.1.
param(
    [Parameter(Mandatory = $true)][string]$Stage,
    [string]$VCRedistRoot,
    [string]$Arch
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Stage)) { throw "no staged layout at $Stage" }
$Stage = (Resolve-Path $Stage).Path
if (-not $Arch) {
    $Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
}

# dumpbin comes from the MSVC toolchain, which package-windows.ps1 has already
# loaded; a standalone run loads it here.
if (-not (Get-Command dumpbin -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'windows-env.ps1')
}
if (-not (Get-Command dumpbin -ErrorAction SilentlyContinue)) {
    throw "dumpbin not found - dot-source Scripts\windows-env.ps1 first"
}

# ------------------------------------------------------ redistributables ---
# vcvarsall sets VCToolsRedistDir; derive it from the tools directory when a
# caller has neither set nor inherited it.
if (-not $VCRedistRoot) { $VCRedistRoot = $env:VCToolsRedistDir }
if (-not $VCRedistRoot -and $env:VCToolsInstallDir) {
    $vcDir = Split-Path (Split-Path (Split-Path $env:VCToolsInstallDir.TrimEnd('\') -Parent) -Parent) -Parent
    $VCRedistRoot = Get-ChildItem (Join-Path $vcDir 'Redist\MSVC') -Directory -ErrorAction SilentlyContinue |
        Sort-Object { $_.Name } -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $VCRedistRoot -or -not (Test-Path $VCRedistRoot)) {
    throw "VC redistributable directory not found (set VCToolsRedistDir or pass -VCRedistRoot) - the audit cannot tell a redistributable DLL from an operating-system one without it"
}
$redist = @{}
foreach ($f in (Get-ChildItem (Join-Path $VCRedistRoot $Arch) -Recurse -Filter '*.dll' -ErrorAction SilentlyContinue)) {
    # debug_nonredist is exactly what its name says - never shippable, and its
    # presence in the map would turn a real problem into a misleading hint.
    if ($f.FullName -match 'debug_nonredist') { continue }
    if (-not $redist.ContainsKey($f.Name.ToLower())) { $redist[$f.Name.ToLower()] = $f.FullName }
}

# ---------------------------------------------------------- import graph ---
$pes = @(Get-ChildItem $Stage -Recurse -File -Include '*.dll', '*.exe')
if (-not $pes) { throw "no binaries under $Stage" }
# Root only: see the header. A subdirectory copy does not satisfy an import.
$shipped = @{}
foreach ($f in (Get-ChildItem (Join-Path $Stage '*') -File -Include '*.dll', '*.exe')) {
    $shipped[$f.Name.ToLower()] = $true
}

$importers = @{}
foreach ($pe in $pes) {
    $rel = $pe.FullName.Substring($Stage.Length).TrimStart('\')
    foreach ($line in (& dumpbin /nologo /dependents $pe.FullName)) {
        if ($line -match '^\s{4}(\S+\.[Dd][Ll][Ll])\s*$') {
            $dep = $Matches[1].ToLower()
            if (-not $importers.ContainsKey($dep)) {
                $importers[$dep] = New-Object System.Collections.ArrayList
            }
            [void]$importers[$dep].Add($rel)
        }
    }
}
Write-Host "== audited $($pes.Count) binaries, $($importers.Count) distinct imports"

# ---------------------------------------------------------------- verdicts --
$problems = New-Object System.Collections.ArrayList
$osCount = 0
foreach ($dep in ($importers.Keys | Sort-Object)) {
    if ($shipped.ContainsKey($dep)) { continue }
    if ($dep -like 'api-ms-win-*' -or $dep -like 'ext-ms-*') { $osCount++; continue }

    $by = ($importers[$dep] | Sort-Object -Unique) -join ', '
    if ($redist.ContainsKey($dep)) {
        [void]$problems.Add("$dep - Visual C++ redistributable, must ship in the package root (stage it from $($redist[$dep])); imported by $by")
        continue
    }
    $sys = Join-Path $env:SystemRoot "System32\$dep"
    if (-not (Test-Path $sys)) {
        [void]$problems.Add("$dep - not in the package and not an operating-system DLL (nothing at $sys); imported by $by")
        continue
    }
    $product = (Get-Item $sys).VersionInfo.ProductName
    if ($product -notlike '*Windows*Operating System*') {
        [void]$problems.Add("$dep - resolves only to $sys, which declares itself '$product' rather than part of Windows: a redistributable this machine happens to have installed, not something a clean machine will have; imported by $by")
        continue
    }
    $osCount++
}
Write-Host "== $osCount operating-system dependencies, $($problems.Count) undisclosed"

# The CRT must be one version throughout. Mixing a newer MSVCP140_2.dll onto an
# older MSVCP140.dll is a supported-looking configuration that is not one, and
# it is the shape a partial fix produces: the Visual Studio redistributable and
# the Swift runtime redistributable both carry the CRT and track different
# toolsets, so taking some DLLs from each mixes versions silently.
$crt = @(Get-ChildItem (Join-Path $Stage '*') -File -Include 'msvcp140*.dll', 'vcruntime140*.dll', 'concrt140*.dll', 'vcomp140*.dll')
$crtVersions = @($crt | ForEach-Object { $_.VersionInfo.FileVersion } | Sort-Object -Unique)
if ($crtVersions.Count -gt 1) {
    $detail = ($crt | ForEach-Object { "$($_.Name) $($_.VersionInfo.FileVersion)" }) -join ', '
    [void]$problems.Add("the staged MSVC runtime mixes versions ($detail) - stage the whole CRT from one redistributable")
}
if ($crt.Count) { Write-Host "== MSVC runtime: $($crt.Count) DLLs, version $($crtVersions -join ' + ')" }

if ($problems.Count) {
    Write-Host ""
    Write-Host "== UNDISCLOSED DEPENDENCIES - this package will not launch on a clean machine:"
    foreach ($p in $problems) { Write-Host "   $p" }
    throw "package dependency audit failed ($($problems.Count) problem(s))"
}
Write-Host "== package dependency audit PASSED"
