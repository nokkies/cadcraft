# check-f7.ps1 -- card M4-C19: every generated sheet is content-complete against its source.
#
# The generators rebuild each sheet's model space from the working drawing (gen-scd/gen-tmd/gen-bom).
# A silent regression would drop or alter source content: a missing text, a lost line, a circle that
# stops being drawn, or a text whose height no longer matches. check-f1/f2/f5 check structure and
# plots; this checks the DATA: for every generated sheet, each entity type the source has must appear
# in the generated sheet at the same count (except MText, where the generators legitimately ADD
# annotations -- the PRELIMINARY/NOT FOR CONSTRUCTION watermark, the D4 terminal-number labels, and
# the D3 rail-lengths note -- so generated MText count >= source is required, not ==), and every
# source text must be present in the generated sheet at the same height.
#
# Viewports are excluded: the generators erase the duplicate model windows on purpose (build 0.066),
# so the generated layout legitimately has fewer viewports than the source.
#
# Exit 0 when every generated sheet is content-complete, 1 otherwise.

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
if (-not (Test-Path -LiteralPath $runStep)) { throw "run-step.ps1 not found next to this script" }

function Get-Entities {
    param([string]$Drawing)
    $j = (pwsh -NoProfile -File $runStep $Drawing 'entities {"limit":10000}' | Select-Object -Last 1)
    if (-not $j) { return $null }
    try { return ($j | ConvertFrom-Json) } catch { return $null }
}

$failCount = 0
foreach ($n in @($Project.sheets | Sort-Object)) {
    $src = Join-Path $D "3. Working\$n.dwg"
    $gen = Join-Path $OutDir "$n.dwg"
    if (-not (Test-Path -LiteralPath $gen)) { Write-Host "FAIL $n (no generated sheet)"; $failCount++; continue }
    if (-not (Test-Path -LiteralPath $src)) { Write-Host "FAIL $n (no source sheet to compare)"; $failCount++; continue }
    $js = Get-Entities $src
    $jg = Get-Entities $gen
    if ($null -eq $js -or $null -eq $jg) { Write-Host "FAIL $n (could not read entities)"; $failCount++; continue }

    # Entity-type counts, excluding Viewport (the generators erase duplicate model windows on purpose).
    $st = @{}; foreach ($e in $js.entities) { $st[$e.type] = 1 + ($st[$e.type] ?? 0) }
    $gt = @{}; foreach ($e in $jg.entities) { $gt[$e.type] = 1 + ($gt[$e.type] ?? 0) }
    $typeProblems = @()
    foreach ($t in (($st.Keys + $gt.Keys) | Sort-Object -Unique)) {
        if ($t -eq 'Viewport') { continue }
        $s = $st[$t] ?? 0; $g = $gt[$t] ?? 0
        if ($t -eq 'MText') {
            # Generators legitimately ADD MText annotations; require generated >= source.
            if ($g -lt $s) { $typeProblems += ("MText $s->$g (dropped)") }
        } elseif ($s -ne $g) {
            $typeProblems += ("$t $s->$g")
        }
    }

    # Every source text must appear in the generated sheet at the same height.
    $genByContent = @{}
    foreach ($e in $jg.entities) {
        if ($e.type -eq 'MText' -or $e.type -eq 'Text') {
            $k = [string]$e.geometry.contents
            if (-not $genByContent.ContainsKey($k)) { $genByContent[$k] = @() }
            $genByContent[$k] += [double]$e.geometry.height
        }
    }
    $missingText = 0; $heightMismatch = 0
    foreach ($e in $js.entities) {
        if ($e.type -ne 'MText' -and $e.type -ne 'Text') { continue }
        $k = [string]$e.geometry.contents
        if (-not $genByContent.ContainsKey($k)) { $missingText++; continue }
        if ($genByContent[$k][0] -ne [double]$e.geometry.height) { $heightMismatch++ }
    }

    $problems = @()
    if ($typeProblems.Count) { $problems += ($typeProblems -join ', ') }
    if ($missingText -gt 0) { $problems += "$missingText source text(s) missing" }
    if ($heightMismatch -gt 0) { $problems += "$heightMismatch text height mismatch(es)" }

    if ($problems.Count -eq 0) {
        Write-Host "PASS $n (content-complete: all entity types match source, MText >= source, every source text present at matching height)"
    } else {
        Write-Host "FAIL $n ($($problems -join '; '))"
        $failCount++
    }
}

if ($failCount -eq 0) {
    Write-Host 'PASS M4-C19 (every generated sheet is content-complete against its source)'
    exit 0
} else {
    Write-Host "FAIL M4-C19 ($failCount sheet(s) not content-complete)"
    exit 1
}
