# gen-pack.ps1 -- generate a whole drawing pack from the sheet plan.
#
# One command over a set of sheets: for each plan row it picks the generator for that discipline,
# runs it, and collects the result. It exists because the deliverable is a pack (262 termination
# sheets across 20 panels), and a per-sheet loop written inline in a shell would be re-invented
# every time someone regenerates.
#
# Selection, in order of narrowing:
#   -Station   one panel (e.g. P01) or several, comma separated
#   -Discipline TMD (default when -Station is given), or GAD / SCD
#   -Number    exact drawing numbers, comma separated
#   -Limit     stop after N sheets (for a smoke run)
#
# Every sheet is written to -OutDir as <number>_<rev>.dwg, with its .scr and .run.log beside it.
# A per-sheet PDF is optional (-Pdf) because plotting is the slow half.
#
# The pack is not "done" when the files exist: gen-pack writes a manifest CSV next to them with the
# row counts, the order number used, whether the pinout is verified, and any warning. The manifest
# is what the hand-back list is built from.
#
# Usage:
#   pwsh -File psa/scripts/gen-pack.ps1 -Template <template.dwg> -PlanCsv <sheet-plan.csv> `
#        -SignalsCsv <io-signals.csv> -HardwareJson <modules.json> -OutDir <dir> `
#        [-Station P01,P02] [-Discipline TMD] [-Number ...] [-Limit N] [-Pdf] [-ProjectNumber NNNN]

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Template,
    [Parameter(Mandatory = $true)][string]$PlanCsv,
    [Parameter(Mandatory = $true)][string]$SignalsCsv,
    [Parameter(Mandatory = $true)][string]$HardwareJson,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string]$Station,
    [string]$Discipline = 'TMD',
    [string]$Number,
    [int]$Limit = 0,
    [switch]$Pdf,
    [string]$ProjectNumber = '',
    [string]$Scope1 = '',
    [string]$OrderScheduleCsv = ''   # panel line items, needed by the comms and power sheets
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Resolve-CadcraftCli {
    $cmd = Get-Command 'cadcraft-cli' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $here = Split-Path -Parent $PSScriptRoot
    $exe = Join-Path $here '..\target\release\cadcraft-cli.exe'
    if (Test-Path -LiteralPath $exe) { return (Resolve-Path -LiteralPath $exe).Path }
    throw 'cadcraft-cli not found.'
}

foreach ($p in @($Template, $PlanCsv, $SignalsCsv, $HardwareJson)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "no such file: $p" }
}
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$cli = Resolve-CadcraftCli
$sheetsDir = $PSScriptRoot

$plan = @(Import-Csv -LiteralPath $PlanCsv)
$sel = @($plan | Where-Object { $_.Discipline -eq $Discipline })
if ($Station) {
    $want = @($Station -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $sel = @($sel | Where-Object { $s = [string]$_.Station; ($want | Where-Object { $s -eq $_ }) })
}
if ($Number) {
    $wantN = @($Number -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $sel = @($sel | Where-Object { $n = [string]$_.Number; ($wantN | Where-Object { $n -eq $_ }) })
}
$sel = @($sel | Sort-Object Number)
if ($Limit -gt 0 -and $sel.Count -gt $Limit) { $sel = @($sel | Select-Object -First $Limit) }

Write-Host ("pack: {0} sheets ({1})" -f $sel.Count, $Discipline)

$manifest = New-Object System.Collections.Generic.List[object]
$fail = 0
$started = Get-Date

foreach ($row in $sel) {
    $num = [string]$row.Number
    $rev = [string]$row.Revision
    if (-not $rev) { $rev = 'A' }
    $outDwg = Join-Path $OutDir ($num + '_' + $rev + '.dwg')
    # The generator depends on the discipline. TMD builds a termination table from the I/O list; GAD
    # builds a placement diagram from the order schedule. SCD (a wired schematic) has no producer yet.
    $gen = Join-Path $sheetsDir 'gen-tmd-data.ps1'
    if ($Discipline -eq 'GAD') { $gen = Join-Path $sheetsDir 'gen-gad-data.ps1' }

    $args1 = @(
        '-Template', $Template,
        '-OutDwg', $outDwg,
        '-HardwareJson', $HardwareJson,
        '-PlanCsv', $PlanCsv,
        '-DrawingNumber', $num
    )
    if ($Discipline -eq 'GAD') {
        # A GA needs the order schedule (the modules to place), not the I/O signal table.
        if (-not $OrderScheduleCsv -or -not (Test-Path -LiteralPath $OrderScheduleCsv)) {
            Write-Warning "$num : GAD needs -OrderScheduleCsv; skipping"
            continue
        }
        $args1 += @('-OrderScheduleCsv', $OrderScheduleCsv)
    } else {
        $args1 = @('-Template', $Template, '-OutDwg', $outDwg, '-HardwareJson', $HardwareJson,
            '-PlanCsv', $PlanCsv, '-SignalsCsv', $SignalsCsv, '-DrawingNumber', $num)
        # The comms and power sheets read the panel's line items from the order schedule.
        if ($OrderScheduleCsv -and (Test-Path -LiteralPath $OrderScheduleCsv)) {
            $args1 += @('-OrderScheduleCsv', $OrderScheduleCsv)
        }
    }
    if ($ProjectNumber) { $args1 += @('-ProjectNumber', $ProjectNumber) }
    if ($Scope1) { $args1 += @('-Scope1', $Scope1) }

    $out = ''
    $code = 1
    try {
        $out = (& pwsh -NoProfile -File $gen @args1 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } catch {
        $out = $_.Exception.Message
    }
    $lastLine = (($out -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1))
    $made = Test-Path -LiteralPath $outDwg
    if (-not $made) { $code = 1 }

    # Pull the generator's own summary numbers out of its last line.
    $rowsShown = ''; $rowsTotal = ''; $order = ''; $verified = ''
    $m = [regex]::Match([string]$lastLine, 'order=(\S+)\s+rows=(\d+)/(\d+)\s+verified=(\S+)')
    if ($m.Success) {
        $order = $m.Groups[1].Value; $rowsShown = $m.Groups[2].Value; $rowsTotal = $m.Groups[3].Value; $verified = $m.Groups[4].Value
    }
    $warn = ''
    $wm = [regex]::Matches($out, 'WARNING[^\r\n]*')
    if ($wm.Count -gt 0) { $warn = (($wm | ForEach-Object { $_.Value }) -join ' | ') }

    if ($Pdf -and $made) {
        $pdfPath = [System.IO.Path]::ChangeExtension($outDwg, '.pdf')
        # The template's own layout name; the generator uses the first non-model layout.
        $layName = 'Layout1'
        $env:CADCRAFT_FONTALT = 'arial.ttf'
        $null = & $cli run $outDwg --cmd ('layout.set {"name":"' + $layName + '"}') --cmd ('exportpdf {"path":"' + ($pdfPath -replace '\\', '\\') + '","layout":"' + $layName + '","fit":true,"lineweights":true}') 2>&1
    }

    $manifest.Add([pscustomobject]@{
        Number     = $num
        Revision   = $rev
        Station    = [string]$row.Station
        Card       = [string]$row.Card
        Instance   = [string]$row.Instance
        Of         = [string]$row.Of
        Order      = $order
        RowsShown  = $rowsShown
        RowsTotal  = $rowsTotal
        Verified   = $verified
        Hours      = [string]$row.Hours
        Dwg        = if ($made) { $outDwg } else { '' }
        Bytes      = if ($made) { (Get-Item -LiteralPath $outDwg).Length } else { 0 }
        ExitCode   = $code
        Warning    = $warn
    })
    if ($code -ne 0) { $fail++ }
    Write-Host ("{0}  {1,-16} {2,-28} rows={3}/{4} verified={5} {6}" -f `
        $num, [string]$row.Station, [string]$row.Card, $rowsShown, $rowsTotal, $verified, `
        $(if ($code -eq 0) { 'OK' } else { 'FAIL' }))
}

$manPath = Join-Path $OutDir 'manifest.csv'
$manifest | Export-Csv -LiteralPath $manPath -NoTypeInformation -Encoding UTF8
$elapsed = ((Get-Date) - $started).TotalSeconds
Write-Host ("done: {0} sheets, {1} failed, {2:N0}s -> {3}" -f $sel.Count, $fail, $elapsed, $manPath)
if ($fail -gt 0) { exit 1 }
exit 0
