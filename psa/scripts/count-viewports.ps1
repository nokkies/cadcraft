# count-viewports.ps1 -- card M4-G1: a generated sheet has the same paper-space viewports as its source.
#
# Background (psa/REVIEW-0.125.md section 1). The template and the source sheets used to carry, in a
# `*Paper_Space0` block that no layout owned, two extra viewports (a second sheet window and an empty
# detail window). cadcraft read that orphan block's entities into the live layout and wrote them back on
# save, so every file that went through cadcraft gained two viewports and every measurement made through
# cadcraft saw four where the file actually had two. The template and sources were regenerated with the
# orphan emptied; ACadSharp (an independent reader) confirms every source sheet has exactly two
# paper-space viewports: the sheet-border window and the content window.
#
# This check is the guard for that, and it replaces check-detail (which measured the ink inside the
# phantom detail window). For each generated sheet in the out dir it finds the matching source sheet,
# counts paper-space viewports in each sheet's own layout, and requires the two counts to be equal. It
# uses cadcraft-cli only -- which is legitimate here because the count was first confirmed to agree with
# ACadSharp's expected value (two) on the regenerated sources, so cadcraft is no longer over-counting.
#
# The layout name differs by side and is read per file, never hard-coded: a source sheet names its layout
# after the sheet type (SCD, GAD, TMD, BOM), a generated sheet names it Layout1.
#
# Exit 0 when every generated sheet's viewport count equals its source's, 1 otherwise.

[CmdletBinding()]
param(
    [string]$OutDir
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
if (-not (Test-Path -LiteralPath $runStep)) { throw 'run-step.ps1 not found next to this script' }
$SrcDir = Join-Path $D ($Project.workingDir)

# @(): a single-sheet dir returns a bare FileInfo and StrictMode 3 rejects .Count on it.
$dwgs = @(Get-ChildItem -LiteralPath $OutDir -Filter '*.dwg' | Sort-Object Name)
if ($dwgs.Count -eq 0) { throw "no sheets in $OutDir" }

function Get-FirstLayout { param([string]$File)
    $j = (pwsh -NoProfile -File $runStep $File 'layout.list {}' | Select-Object -Last 1)
    if (-not $j) { return '' }
    $lay = @(([regex]::Matches($j, '"name":"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }) | Where-Object { $_ -ne 'Model' })
    if ($lay.Count -gt 0) { return $lay[0] } else { return '' }
}

# Count paper-space viewports in a file's own first (non-Model) layout.
function Get-ViewportCount { param([string]$File)
    $lay = Get-FirstLayout -File $File
    if (-not $lay) { return -1 }
    $j = (pwsh -NoProfile -File $runStep $File ('layout.set {"name":' + ($lay | ConvertTo-Json) + '}') 'entities {"type":"Viewport","limit":100}' | Select-Object -Last 1)
    if (-not $j) { return -1 }
    $o = $j | ConvertFrom-Json
    return @($o.entities).Count
}

$failCount = 0
foreach ($dwg in $dwgs) {
    $src = Join-Path $SrcDir $dwg.Name
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Host "FAIL $($dwg.Name) (no source sheet to compare against at $src)"
        $failCount++
        continue
    }
    $gen = Get-ViewportCount -File $dwg.FullName
    $srcN = Get-ViewportCount -File $src
    if ($gen -lt 0) { Write-Host "FAIL $($dwg.Name) (could not read generated viewports)"; $failCount++; continue }
    if ($srcN -lt 0) { Write-Host "FAIL $($dwg.Name) (could not read source viewports)"; $failCount++; continue }
    if ($gen -ne $srcN) {
        Write-Host "FAIL $($dwg.Name) (generated has $gen paper-space viewports, source has $srcN)"
        $failCount++
        continue
    }
    Write-Host "PASS $($dwg.Name) ($gen paper-space viewports, matching its source)"
}

if ($failCount -gt 0) {
    Write-Host "FAIL M4-G1 ($failCount sheet(s) whose paper-space viewport count differs from its source)"
    exit 1
}
Write-Host "PASS M4-G1 (every generated sheet has the same paper-space viewports as its source)"
exit 0
