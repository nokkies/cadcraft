# check-f1.ps1 -- card M4-F1: the title block lives in paper space, not model space.
#
# The empty-plot defect (psa/REVIEW-0.053.md section 2) was that the generators inserted a SECOND
# copy of A1 BORDER / A1 TITLE TEXT into model space at 0,0 over the panel, while the template's own
# title block sat in the paper-space layout. The plotted sheet showed only the template's (empty)
# title block. Card M4-F1 stops the model-space insert and sets the attribute values on the
# template's existing paper-space title-block reference instead.
#
# This check, over every generated sheet in $D\fusion\out:
#   1. model space contains NO Insert whose block is A1 BORDER or A1 TITLE TEXT;
#   2. the paper-space layout contains an A1 TITLE TEXT reference whose DWG_NO attribute equals the
#      drawing's file name (the stem, without the .dwg extension).
#
# This is a structural check (the review's M4-F1 check). It is NOT the plot; the plot is the check
# and comes at M4-F5. Exit 0 when every sheet passes both, 1 otherwise.

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
foreach ($dwg in $sheets) {
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($dwg.Name)
    # The title block's DWG_NO holds the drawing number WITHOUT the revision suffix (the file name
    # is <drawing-number>_A.dwg; the block stores <drawing-number>). Strip a trailing _<rev> to match.
    $dwgNoExpected = ($stem -replace '_[A-Za-z]$', '')

    # 1. model-space inserts (current space after open is model space).
    $mjson = (pwsh -NoProfile -File $runStep $dwg.FullName 'entities {"type":"Insert","limit":5000}' | Select-Object -Last 1)
    $modelBad = 0
    if ($mjson) {
        try {
            $mo = $mjson | ConvertFrom-Json
            $modelBad = @($mo.entities | Where-Object { $_.geometry.block -in 'A1 BORDER', 'A1 TITLE TEXT' }).Count
        } catch { Write-Host "  $($dwg.Name) : could not read model inserts"; $failCount++; continue }
    }

    # 2. the paper-space layout's title block DWG_NO.
    $ll = (pwsh -NoProfile -File $runStep $dwg.FullName 'layout.list {}' | Select-Object -Last 1)
    $layout = ''
    if ($ll) {
        $layout = @([regex]::Matches($ll, '"name":"([^"]*)"') | ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $_ -and $_ -ne 'Model' }) | Select-Object -First 1
    }
    $dwgNo = ''
    $hasTb = $false
    if ($layout) {
        $lj = (pwsh -NoProfile -File $runStep $dwg.FullName ('layout.set {"name":"' + $layout + '"}') 'entities {"type":"Insert","limit":200}' | Select-Object -Last 1)
        if ($lj) {
            try {
                $lo = $lj | ConvertFrom-Json
                foreach ($e in $lo.entities) {
                    if ([string]$e.geometry.block -eq 'A1 TITLE TEXT') {
                        $hasTb = $true
                        foreach ($a in $e.geometry.attribs) {
                            if ([string]$a.tag -eq 'DWG_NO') { $dwgNo = [string]$a.text.value }
                        }
                        break
                    }
                }
            } catch { }
        }
    }

    $ok = ($modelBad -eq 0) -and $hasTb -and ($dwgNo -eq $dwgNoExpected)
    if ($ok) {
        Write-Host ("PASS  {0}  (no model-space title block; layout DWG_NO = {1})" -f $dwg.Name, $dwgNo)
    } else {
        $why = @()
        if ($modelBad -gt 0) { $why += "$modelBad model-space A1 insert(s)" }
        if (-not $hasTb) { $why += 'no A1 TITLE TEXT in layout' }
        if ($hasTb -and $dwgNo -ne $dwgNoExpected) { $why += "layout DWG_NO '$dwgNo' != '$dwgNoExpected'" }
        Write-Host ("FAIL  {0}  ({1})" -f $dwg.Name, ($why -join '; '))
        $failCount++
    }
}

if ($failCount -eq 0) {
    Write-Host ("PASS M4-F1 (all {0} sheets: title block in paper space only, DWG_NO matches the file name)" -f $sheets.Count)
    exit 0
} else {
    Write-Host ("FAIL M4-F1 ({0} sheet(s) failed)" -f $failCount)
    exit 1
}
