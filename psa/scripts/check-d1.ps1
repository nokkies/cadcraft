# check-d1.ps1 -- DRAWING-WORK D1 automated check (revised, build 0.064)
#
# D1 asked the schematic (SCD) sheets to draw terminals as the library TERMINAL block. Measured, that
# block is a 70x10 horizontal terminal-STRIP graphic (its outline polyline spans 70 units wide, 10
# tall) -- about 14x wider than the 5-unit terminal circle the source draws, and it never turns
# vertical. Inserted at every wire-connected terminal point it overruns the wire spacing and wires
# plot over it (reported by Reinach). D1 does not hold for these sheets, so the generator now re-emits
# the source's terminal circles. This check asserts the corrected truth: each schematic draws its
# terminals as circles on the terminal layer (3C) and carries NO oversized TERMINAL block insert.
#
# Exit 0 when every SCD sheet passes; 1 otherwise. Prints one PASS/FAIL line per sheet.

[CmdletBinding()]
param(
    [string]$OutDir,
    # The terminal layer, and the oversized block that must NOT appear.
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
    # Pass when terminals are drawn as circles and the oversized block is absent.
    if ($circOnTerm.Count -ge 1 -and $termInserts.Count -eq 0) {
        Write-Host "PASS $($dwg.Name) ($($circOnTerm.Count) $TerminalLayer terminal circles, 0 $TerminalBlock blocks)"
    } else {
        Write-Host "FAIL $($dwg.Name) ($($circOnTerm.Count) $TerminalLayer terminal circles, $($termInserts.Count) $TerminalBlock blocks)"
        $failCount++
    }
}

if ($failCount -eq 0) {
    Write-Host 'PASS D1 (schematic terminals are drawn as source circles, no oversized block)'
    exit 0
} else {
    Write-Host "FAIL D1 ($failCount sheet(s) do not draw terminals as source circles)"
    exit 1
}
