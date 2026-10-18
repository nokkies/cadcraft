# diff-modelspace.ps1 -- report model-space text differences between a generated sheet and its source.
#
# Report only: prints counts and, for texts, how many are added/removed by content key. It prints
# only the count and the LAYER of each differing text, never the text itself, so the output is safe to
# paste into a repository or a log (the two-folder rule).
#
#   diff-modelspace.ps1 -Source <src.dwg> -Generated <gen.dwg>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Generated
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$runStep = Join-Path $PSScriptRoot 'run-step.ps1'

function Get-Entities {
    param([string]$Drawing)
    $out = (& $runStep $Drawing 'entities {"limit":30000}' | Select-Object -Last 1)
    if (-not $out) { return @() }
    try { return @(($out | ConvertFrom-Json).entities) } catch { return @() }
}

$s = @(Get-Entities -Drawing $Source)
$g = @(Get-Entities -Drawing $Generated)

$sc = @{}; $gc = @{}
foreach ($e in $s) { if ($sc.ContainsKey($e.type)) { $sc[$e.type]++ } else { $sc[$e.type] = 1 } }
foreach ($e in $g) { if ($gc.ContainsKey($e.type)) { $gc[$e.type]++ } else { $gc[$e.type] = 1 } }

Write-Host ("model space: source={0} generated={1}" -f $s.Count, $g.Count)
foreach ($t in @($sc.Keys + $gc.Keys | Sort-Object -Unique)) {
    $a = 0; $b = 0
    if ($sc.ContainsKey($t)) { $a = $sc[$t] }
    if ($gc.ContainsKey($t)) { $b = $gc[$t] }
    if ($a -ne $b) { Write-Host ("  TYPE {0}: {1} -> {2} ({3})" -f $t, $a, $b, $(if ($b -gt $a) { 'added' } else { 'removed' })) }
}

# Text-level multiset diff, reported by (layer, height) so no drawing text is printed.
function Get-TextKeyMap {
    param($Ents)
    $m = @{}
    foreach ($e in $Ents) {
        if ($e.type -ne 'MText' -and $e.type -ne 'Text') { continue }
        $val = ''
        if ($e.geometry.PSObject.Properties.Name -contains 'contents') { $val = [string]$e.geometry.contents }
        elseif ($e.geometry.PSObject.Properties.Name -contains 'value') { $val = [string]$e.geometry.value }
        $key = $e.layer + '|' + $val
        if ($m.ContainsKey($key)) { $m[$key]++ } else { $m[$key] = 1 }
    }
    return $m
}

$st = Get-TextKeyMap -Ents $s
$gt = Get-TextKeyMap -Ents $g
$added = 0; $removed = 0
$addedLayers = @{}; $removedLayers = @{}
foreach ($k in $gt.Keys) {
    $a = 0; if ($st.ContainsKey($k)) { $a = $st[$k] }
    $d = $gt[$k] - $a
    if ($d -gt 0) {
        $added += $d
        $lay = $k.Split('|')[0]
        if ($addedLayers.ContainsKey($lay)) { $addedLayers[$lay] += $d } else { $addedLayers[$lay] = $d }
    }
}
foreach ($k in $st.Keys) {
    $b = 0; if ($gt.ContainsKey($k)) { $b = $gt[$k] }
    $d = $st[$k] - $b
    if ($d -gt 0) {
        $removed += $d
        $lay = $k.Split('|')[0]
        if ($removedLayers.ContainsKey($lay)) { $removedLayers[$lay] += $d } else { $removedLayers[$lay] = $d }
    }
}

Write-Host ("  texts added by generator: {0}" -f $added)
foreach ($lay in ($addedLayers.Keys | Sort-Object)) { Write-Host ("    layer {0}: +{1}" -f $lay, $addedLayers[$lay]) }
Write-Host ("  texts missing from generated: {0}" -f $removed)
foreach ($lay in ($removedLayers.Keys | Sort-Object)) { Write-Host ("    layer {0}: -{1}" -f $lay, $removedLayers[$lay]) }
