# gen-lst-pack.ps1 -- paginate one list CSV across as many A1 sheets as it needs.
#
# gen-lst-data.ps1 draws exactly one page (a single DWG has one model space). A list longer than one
# A1 -- the I/O list is 2,789 rows, about 35 sheets -- is issued as a run of sheets, one per page.
# This driver loops the pages, calls the generator once per page with the right -RowOffset, and writes
# a manifest. It is the list counterpart of gen-pack.ps1.
#
# Sheet numbering: the register gives the list one number (e.g. NNNN-IC-LST-001). Each page is that
# number with a page suffix, so the set is traceable back to the register row.
#
# Usage:
#   pwsh -File psa/scripts/gen-lst-pack.ps1 -Template <t.dwg> -SourceCsv <data.csv> -OutDir <dir> `
#        -Kind io -Title "I/O LIST - ALL STATIONS" -Number NNNN-IC-LST-001 [-ProjectNumber NNNN]

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Template,
    [Parameter(Mandatory = $true)][string]$SourceCsv,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string]$Kind = 'generic',
    [string]$Title = 'SCHEDULE',
    [string]$Number = 'LIST',
    [string]$Columns = '',
    [string]$Headers = '',
    [string]$ProjectNumber = '',
    [string]$Scope1 = '',
    [int]$RowPitch = 6,
    [int]$TopY = 540,
    [int]$BottomY = 60,
    [int]$MaxSheets = 0
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

foreach ($p in @($Template, $SourceCsv)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "no such file: $p" }
}
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$gen = Join-Path $PSScriptRoot 'gen-lst-data.ps1'

$rows = @(Import-Csv -LiteralPath $SourceCsv)
$rowsPerPage = [math]::Floor(($TopY - $BottomY) / [double]$RowPitch)
if ($rowsPerPage -lt 1) { $rowsPerPage = 1 }
$totalPages = [math]::Ceiling($rows.Count / [double]$rowsPerPage)
if ($MaxSheets -gt 0 -and $totalPages -gt $MaxSheets) { $totalPages = $MaxSheets }

Write-Host ("list: {0} rows, {1} per sheet, {2} sheets" -f $rows.Count, $rowsPerPage, $totalPages)

$manifest = New-Object System.Collections.Generic.List[object]
$fail = 0
for ($pg = 0; $pg -lt $totalPages; $pg++) {
    $offset = $pg * $rowsPerPage
    $sheetNum = "{0}-{1:D2}" -f $Number, ($pg + 1)
    $outDwg = Join-Path $OutDir ($sheetNum + '_A.dwg')
    $args1 = @(
        '-Template', $Template,
        '-OutDwg', $outDwg,
        '-SourceCsv', $SourceCsv,
        '-Kind', $Kind,
        '-Title', $Title,
        '-DrawingNumber', $sheetNum,
        '-RowOffset', $offset
    )
    if ($Columns) { $args1 += @('-Columns', $Columns) }
    if ($Headers) { $args1 += @('-Headers', $Headers) }
    if ($ProjectNumber) { $args1 += @('-ProjectNumber', $ProjectNumber) }
    if ($Scope1) { $args1 += @('-Scope1', $Scope1) }

    $out = ''
    $code = 1
    try {
        $out = (& pwsh -NoProfile -File $gen @args1 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } catch { $out = $_.Exception.Message }
    $made = Test-Path -LiteralPath $outDwg
    if (-not $made) { $code = 1 }
    $rowsShown = ''
    $m = [regex]::Match([string]$out, 'rows=(\d+)')
    if ($m.Success) { $rowsShown = $m.Groups[1].Value }
    $manifest.Add([pscustomobject]@{
        Number = $sheetNum; Page = $pg + 1; Of = $totalPages; RowOffset = $offset
        RowsShown = $rowsShown; Dwg = if ($made) { $outDwg } else { '' }
        Bytes = if ($made) { (Get-Item -LiteralPath $outDwg).Length } else { 0 }; ExitCode = $code
    })
    if ($code -ne 0) { $fail++ }
    Write-Host ("{0}  page {1}/{2}  offset={3}  rows={4}  {5}" -f `
        $sheetNum, ($pg + 1), $totalPages, $offset, $rowsShown, $(if ($code -eq 0) { 'OK' } else { 'FAIL' }))
}
$manPath = Join-Path $OutDir 'list-manifest.csv'
$manifest | Export-Csv -LiteralPath $manPath -NoTypeInformation -Encoding UTF8
Write-Host ("done: {0} sheets, {1} failed -> {2}" -f $totalPages, $fail, $manPath)
if ($fail -gt 0) { exit 1 }
exit 0
