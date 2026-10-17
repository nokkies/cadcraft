# check-d1.ps1 -- DRAWING-WORK D1 automated check
#
# D1: the schematic (SCD) sheets must draw terminals as the library TERMINAL block, not as circles.
# The check (from psa/DRAWING-WORK.md): each schematic has no Circle on the terminal layer (3C) and
# at least one Insert whose block name is the terminal block. This runs over the generated sheets in
# $D\fusion\out (the cadcraft output), since that is where the improvement lands.
#
# Exit 0 when every SCD sheet passes; 1 otherwise. Prints one PASS/FAIL line per sheet.

[CmdletBinding()]
param(
    [string]$OutDir,
    # The terminal layer and the library block that replaces the drawn circle.
    [string]$TerminalLayer = '3C',
    [string]$TerminalBlock = 'TERMINAL'
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
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $D 'fusion\out' }
if (-not (Test-Path -LiteralPath $OutDir)) { throw "out dir not found: $OutDir" }
$runStep = Join-Path $PSScriptRoot 'run-step.ps1'
if (-not (Test-Path -LiteralPath $runStep)) { throw "run-step.ps1 not found next to this script" }

$scdSheets = Get-ChildItem -LiteralPath $OutDir -Filter '*-SCD-*.dwg' | Sort-Object Name
if ($scdSheets.Count -eq 0) { throw "no SCD sheets in $OutDir" }

$failCount = 0
foreach ($dwg in $scdSheets) {
    $last = (pwsh -NoProfile -File $runStep $dwg.FullName 'entities {"limit":5000}' | Select-Object -Last 1)
    if (-not $last) { Write-Host "FAIL $($dwg.Name) could not read entities"; $failCount++; continue }
    $j = $last | ConvertFrom-Json
    $circOnTerm = @($j.entities | Where-Object { $_.type -eq 'Circle' -and $_.layer -eq $TerminalLayer })
    $termInserts = @($j.entities | Where-Object { $_.type -eq 'Block Reference' -and $_.geometry.block -eq $TerminalBlock })
    if ($circOnTerm.Count -eq 0 -and $termInserts.Count -ge 1) {
        Write-Host "PASS $($dwg.Name) ($($termInserts.Count) $TerminalBlock inserts, 0 $TerminalLayer circles)"
    } else {
        Write-Host "FAIL $($dwg.Name) ($($termInserts.Count) $TerminalBlock inserts, $($circOnTerm.Count) $TerminalLayer circles)"
        $failCount++
    }
}

if ($failCount -eq 0) {
    Write-Host 'PASS D1 (schematic terminals are library blocks, not circles)'
    exit 0
} else {
    Write-Host "FAIL D1 ($failCount sheet(s) still draw terminals as circles)"
    exit 1
}
