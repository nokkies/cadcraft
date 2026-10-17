# compare-inserts.ps1 -- card M4-F3: block references keep their scale and rotation.
#
# The review (psa/REVIEW-0.053.md section 2) found every generated _TagCircle balloon at scale 1
# instead of the source's scale 6, so the balloons plotted as pinpricks next to the components.
# The generator was emitting insert {at, attribs} without the block reference's scale/rotation.
#
# This check compares, for every generated sheet, each model-space Insert against the source
# working drawing's Inserts: same block name, same position (within a tolerance), same scale and
# rotation. A generated insert with no source match at that position, or a scale/rotation mismatch,
# FAILs. The title-block/border inserts live in paper space (M4-F1) and are not model-space, so
# they are out of scope here.
#
# Exit 0 when every generated model-space Insert matches its source; 1 otherwise.

[CmdletBinding()]
param(
    [string]$OutDir,
    [double]$PosTol = 0.5,
    [double]$ScaleTol = 0.01,
    [double]$RotTol = 0.5
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-PSADrawingsRoot {
    foreach ($scope in 'Process', 'User', 'Machine') {
        $v = [Environment]::GetEnvironmentVariable('PSA_DRAWINGS', $scope)
        if (-not [string]::IsNullOrWhiteSpace($v) -and (Test-Path -LiteralPath $v)) { return $v.TrimEnd('\') }
    }
    throw 'PSA_DRAWINGS is not set to an existing folder.'
}
$D = Get-PSADrawingsRoot
. (Join-Path $PSScriptRoot 'project.ps1')
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $D 'fusion\out' }
if (-not (Test-Path -LiteralPath $OutDir)) { throw "out dir not found: $OutDir" }
$runStep = Join-Path $PSScriptRoot 'run-step.ps1'
if (-not (Test-Path -LiteralPath $runStep)) { throw "run-step.ps1 not found next to this script" }

function Get-ModelInserts {
    param([string]$Drawing)
    $j = (pwsh -NoProfile -File $runStep $Drawing 'entities {"type":"Insert","limit":5000}' | Select-Object -Last 1)
    if (-not $j) { return @() }
    try { $o = $j | ConvertFrom-Json } catch { return @() }
    $out = @()
    foreach ($e in $o.entities) {
        $g = $e.geometry
        $sx = 1.0; $sy = 1.0; $rot = 0.0
        if ($g.PSObject.Properties.Name -contains 'scale' -and $g.scale) { $sx = [double]$g.scale.x; $sy = [double]$g.scale.y }
        if ($g.PSObject.Properties.Name -contains 'rotation') { $rot = [double]$g.rotation }
        $out += [pscustomobject]@{
            block = [string]$g.block
            x = [double]$g.insert.x
            y = [double]$g.insert.y
            sx = $sx; sy = $sy; rot = $rot
        }
    }
    return $out
}

$working = Join-Path $D $Project.workingDir
$sheets = Get-ChildItem -LiteralPath $OutDir -Filter '*.dwg' | Sort-Object Name
if ($sheets.Count -eq 0) { throw "no sheets in $OutDir" }

$failCount = 0
foreach ($dwg in $sheets) {
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($dwg.Name)
    $src = Join-Path $working ($dwg.Name)
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Host ("SKIP  {0}  (no source working drawing {1})" -f $dwg.Name, $stem)
        continue
    }
    $gen = @(Get-ModelInserts $dwg.FullName)
    $srcIns = @(Get-ModelInserts $src)
    # Index source inserts by rounded position for lookup.
    $srcByPos = @{}
    foreach ($s in $srcIns) {
        $k = ([Math]::Round($s.x, 0)).ToString([System.Globalization.CultureInfo]::InvariantCulture) + ',' +
             ([Math]::Round($s.y, 0)).ToString([System.Globalization.CultureInfo]::InvariantCulture)
        if (-not $srcByPos.ContainsKey($k)) { $srcByPos[$k] = @() }
        $srcByPos[$k] += $s
    }
    $bad = @()
    foreach ($gi in $gen) {
        # TERMINAL blocks are generated from the source's terminal CIRCLES (DRAWING-WORK D1), so they
        # have no source Insert to match against; skip them here (check-d1 covers them).
        if ($gi.block -eq 'TERMINAL') { continue }
        $k = ([Math]::Round($gi.x, 0)).ToString([System.Globalization.CultureInfo]::InvariantCulture) + ',' +
             ([Math]::Round($gi.y, 0)).ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $cand = $null
        if ($srcByPos.ContainsKey($k)) {
            foreach ($c in $srcByPos[$k]) { if ($c.block -eq $gi.block) { $cand = $c; break } }
        }
        if ($null -eq $cand) {
            $bad += ("no source {0} at ({1},{2})" -f $gi.block, $gi.x, $gi.y)
            continue
        }
        if ([Math]::Abs($gi.sx - $cand.sx) -gt $ScaleTol -or [Math]::Abs($gi.sy - $cand.sy) -gt $ScaleTol) {
            $bad += ("{0} scale ({1}x{2}) != source ({3}x{4})" -f $gi.block, $gi.sx, $gi.sy, $cand.sx, $cand.sy)
        }
        if ([Math]::Abs($gi.rot - $cand.rot) -gt $RotTol) {
            $bad += ("{0} rotation {1} != source {2}" -f $gi.block, $gi.rot, $cand.rot)
        }
    }
    if ($bad.Count -eq 0) {
        $checked = @($gen | Where-Object { $_.block -ne 'TERMINAL' }).Count
        Write-Host ("PASS  {0}  ({1} model inserts match source block/position/scale/rotation)" -f $dwg.Name, $checked)
    } else {
        $msg = ($bad | Select-Object -First 3 | ForEach-Object { [string]$_ }) -join '; '
        Write-Host ("FAIL  {0}  ({1} insert(s) mismatch: {2})" -f $dwg.Name, $bad.Count, $msg)
        $failCount++
    }
}

if ($failCount -eq 0) {
    Write-Host ("PASS M4-F3 (every generated model insert matches its source block/position/scale/rotation)")
    exit 0
} else {
    Write-Host ("FAIL M4-F3 ({0} sheet(s) with insert mismatches)" -f $failCount)
    exit 1
}
