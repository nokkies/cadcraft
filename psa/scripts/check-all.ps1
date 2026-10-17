# check-all.ps1 -- cadcraft card M2-C3
#
# Runs check-drawing.ps1 over every drawing in the inventory and writes a combined
# $D\fusion\check-report.md. Exit code 0 when every drawing passes every rule, 1 otherwise.
#
# The card's check: the checker passes every rule on every drawing in $D\3. Working, or each
# FAIL is a true problem that M3 then fixes.

[CmdletBinding()]
param(
    [string]$Inventory,
    [string]$RulesFile,
    [string]$ReportFile,
    [string]$Checker,
    # When set, check every *.dwg in this directory (e.g. $D\fusion\out for the M4 generated
    # sheets) instead of the inventory. Each drawing's info/texts JSON is captured first.
    [string]$Dir,
    [string]$Capture
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-PSADrawingsRoot {
    foreach ($scope in 'Process', 'User', 'Machine') {
        $v = [Environment]::GetEnvironmentVariable('PSA_DRAWINGS', $scope)
        if (-not [string]::IsNullOrWhiteSpace($v) -and (Test-Path -LiteralPath $v)) { return $v.TrimEnd('\') }
    }
    throw 'PSA_DRAWINGS is not set to an existing folder. Ask Reinach for it (see psa/PLAN.md).'
}

$D = Get-PSADrawingsRoot
if ([string]::IsNullOrWhiteSpace($Inventory)) { $Inventory = Join-Path $D 'fusion\inventory.csv' }
if ([string]::IsNullOrWhiteSpace($RulesFile)) { $RulesFile = Join-Path $D 'fusion\rules.json' }
if ([string]::IsNullOrWhiteSpace($ReportFile)) { $ReportFile = Join-Path $D 'fusion\check-report.md' }
if ([string]::IsNullOrWhiteSpace($Checker)) {
    $Checker = Join-Path $PSScriptRoot 'check-drawing.ps1'
}
if ([string]::IsNullOrWhiteSpace($Capture)) { $Capture = Join-Path $PSScriptRoot 'capture-json.ps1' }

if (-not (Test-Path -LiteralPath $Checker)) { throw "checker not found: $Checker" }
if (-not (Test-Path -LiteralPath $RulesFile)) { throw "rules not found: $RulesFile (run card M2-C2)" }

# Build the list of drawings to check: a directory glob (M4 generated sheets) or the inventory.
$rows = @()
if (-not [string]::IsNullOrWhiteSpace($Dir)) {
    if (-not (Test-Path -LiteralPath $Dir)) { throw "dir not found: $Dir" }
    foreach ($dwg in (Get-ChildItem -LiteralPath $Dir -Filter *.dwg | Sort-Object Name)) {
        # Capture the info/texts JSON the checker reads, then add the row.
        & pwsh -NoProfile -File $Capture -Drawing $dwg.FullName | Out-Null
        $rows += [pscustomobject]@{ path = $dwg.FullName }
    }
    if ($rows.Count -eq 0) { throw "no .dwg files in $Dir" }
    if ([string]::IsNullOrWhiteSpace($ReportFile) -or $ReportFile -eq (Join-Path $D 'fusion\check-report.md')) {
        $ReportFile = Join-Path $D 'fusion\check-report-generated.md'
    }
} else {
    if (-not (Test-Path -LiteralPath $Inventory)) { throw "inventory not found: $Inventory" }
    $rows = @(Import-Csv -LiteralPath $Inventory)
}
$nl = "`n"
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('# Drawing check report -- card M2-C3').Append($nl).Append($nl)
[void]$sb.Append("Rules: ``$RulesFile``").Append($nl).Append($nl)

$totalFail = 0
$drawingsFailed = 0
$perDrawing = @()

foreach ($r in $rows) {
    $path = $r.path
    $name = Split-Path -Leaf $path
    # Run the checker in-process (dot-source would pollute; a child pwsh is clean and its
    # exit code is authoritative).
    $out = (& pwsh -NoProfile -File $Checker $path $RulesFile 2>&1 | Out-String)
    $code = $LASTEXITCODE
    $lines = ($out -split "`r?`n") | Where-Object { $_ -match '^(PASS|FAIL) ' }
    $fails = @($lines | Where-Object { $_ -match '^FAIL ' })
    if ($code -ne 0 -and $lines.Count -eq 0) {
        # Checker errored out (exit 2) rather than reporting rule failures.
        $lines = @("FAIL CHECKER the checker did not run: " + (($out -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -First 1)))
        $fails = $lines
    }
    if ($fails.Count -gt 0) { $drawingsFailed++; $totalFail += $fails.Count }

    $perDrawing += [pscustomobject]@{ name = $name; lines = $lines; fails = $fails; code = $code }
}

# Summary table first.
[void]$sb.Append('| drawing | rules | pass | fail |').Append($nl)
[void]$sb.Append('|---|---|---|---|').Append($nl)
foreach ($d in $perDrawing) {
    $pass = @($d.lines | Where-Object { $_ -match '^PASS ' }).Count
    [void]$sb.Append('| ').Append($d.name).Append(' | ').Append($d.lines.Count).Append(' | ').Append($pass).Append(' | ').Append($d.fails.Count).Append(' |').Append($nl)
}
[void]$sb.Append($nl).Append('## Per-drawing detail').Append($nl).Append($nl)
foreach ($d in $perDrawing) {
    [void]$sb.Append("### ").Append($d.name).Append($nl).Append($nl)
    [void]$sb.Append('```').Append($nl)
    foreach ($l in $d.lines) { [void]$sb.Append($l).Append($nl) }
    [void]$sb.Append('```').Append($nl).Append($nl)
}
[void]$sb.Append('## Totals').Append($nl).Append($nl)
[void]$sb.Append("- drawings: $($rows.Count)").Append($nl)
[void]$sb.Append("- drawings with at least one FAIL: $drawingsFailed").Append($nl)
[void]$sb.Append("- total rule failures: $totalFail").Append($nl)

[System.IO.File]::WriteAllText($ReportFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

# Console summary.
Write-Host "checked $($rows.Count) drawings -> $ReportFile"
foreach ($d in $perDrawing) {
    if ($d.fails.Count -gt 0) {
        Write-Host "FAIL $($d.name): $($d.fails.Count) rule(s)"
        foreach ($f in $d.fails) { Write-Host "    $f" }
    }
}
Write-Host ''
Write-Host "drawings with failures: $drawingsFailed   total failures: $totalFail"
if ($totalFail -gt 0) { Write-Host 'M2-C3: not all rules pass -- each FAIL is a finding for M3'; exit 1 }
Write-Host 'PASS M2-C3 (every rule passes on every drawing)'
exit 0
