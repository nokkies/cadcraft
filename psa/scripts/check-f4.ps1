# check-f4.ps1 -- card M4-F4: MText line breaks use the DXF paragraph code \P, not \n.
#
# A multi-line MText in DXF/DWG separates its lines with the paragraph code \P. A literal "\n"
# (backslash followed by the letter n) is not a line break -- it renders on the sheet as the two
# characters "\n" (REVIEW-0.053 section 2 found a note with a literal \n). The generators now join
# their own multi-line notes with \P, and carry the source's MText contents (which already use \P).
#
# This check reads every MText in every generated sheet and FAILs if any text contains a literal
# backslash-n. It also reports the count of \P breaks seen, so a note that lost its breaks entirely
# is visible. Exit 0 when no generated text carries a literal \n, 1 otherwise.

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
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $D 'fusion\out' }
if (-not (Test-Path -LiteralPath $OutDir)) { throw "out dir not found: $OutDir" }
$runStep = Join-Path $PSScriptRoot 'run-step.ps1'
if (-not (Test-Path -LiteralPath $runStep)) { throw "run-step.ps1 not found next to this script" }

$sheets = Get-ChildItem -LiteralPath $OutDir -Filter '*.dwg' | Sort-Object Name
if ($sheets.Count -eq 0) { throw "no sheets in $OutDir" }

$failCount = 0
$totalP = 0
foreach ($dwg in $sheets) {
    $j = (pwsh -NoProfile -File $runStep $dwg.FullName 'entities {"type":"MText","limit":2000}' | Select-Object -Last 1)
    if (-not $j) { Write-Host ("  {0}: no MText read" -f $dwg.Name); continue }
    try { $o = $j | ConvertFrom-Json } catch { Write-Host ("  {0}: could not parse MText" -f $dwg.Name); $failCount++; continue }
    $badTexts = @()
    $pCount = 0
    foreach ($e in $o.entities) {
        $c = [string]$e.geometry.contents
        # A literal backslash-n: a backslash immediately followed by 'n'. In the parsed object this
        # is the two characters '\' 'n'. \P is a backslash followed by 'P' and is fine.
        if ($c -match '\\n') { $badTexts += $c }
        $pCount += ([regex]::Matches($c, '\\P')).Count
    }
    $totalP += $pCount
    if ($badTexts.Count -eq 0) {
        Write-Host ("PASS  {0}  ({1} MText, {2} paragraph breaks, no literal backslash-n)" -f $dwg.Name, $o.entities.Count, $pCount)
    } else {
        $sample = ($badTexts[0]); if ($sample.Length -gt 60) { $sample = $sample.Substring(0,60) + '...' }
        Write-Host ("FAIL  {0}  ({1} MText carry a literal backslash-n, e.g. '{2}')" -f $dwg.Name, $badTexts.Count, $sample)
        $failCount++
    }
}

if ($failCount -eq 0) {
    Write-Host ("PASS M4-F4 (no generated MText carries a literal backslash-n; {0} paragraph breaks in total)" -f $totalP)
    exit 0
} else {
    Write-Host ("FAIL M4-F4 ({0} sheet(s) with literal backslash-n in text)" -f $failCount)
    exit 1
}
