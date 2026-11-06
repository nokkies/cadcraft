# cable-schedule.ps1 -- derive a cable schedule CSV from the tidy signal table.
#
# The cable schedule (the register's LST-003) lists every interconnection cable: its number, where it
# runs from and to, the field device it serves, and the conductors (wires) inside it. That data is
# already in the normalised signal table (one row per channel, carrying CableNo, WireNo, TerminalNo,
# FieldDevice, Station); this step reshapes it into schedule rows and sorts them so a cable's wires sit
# together. It adds nothing -- a cable with no number in the source does not appear, and a field with no
# value stays blank.
#
# One row per cable, with the wires rolled up into a single cell, because a schedule reads as "cable
# 1072-ES2, from Q-1072-C to ..., conductors 24-062, 24-063, ...". A cable with many wires lists them
# comma-separated in the Conductors column.
#
# Usage:
#   pwsh -File psa/scripts/cable-schedule.ps1 -SignalsCsv <io-signals.csv> -OutCsv <cable-schedule.csv>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SignalsCsv,
    [Parameter(Mandatory = $true)][string]$OutCsv
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SignalsCsv)) { throw "no such file: $SignalsCsv" }
$sig = @(Import-Csv -LiteralPath $SignalsCsv)

# Only rows that name a cable belong in a cable schedule.
$cabled = @($sig | Where-Object { $_.CableNo -and $_.CableNo.Trim() })

# Group by cable number (a cable can appear under more than one station; the group key is the number).
$byCable = @{}
$order = New-Object System.Collections.Generic.List[string]
foreach ($r in $cabled) {
    $cn = $r.CableNo.Trim()
    if (-not $byCable.ContainsKey($cn)) {
        $byCable[$cn] = New-Object System.Collections.Generic.List[object]
        $order.Add($cn)
    }
    $byCable[$cn].Add($r)
}

$out = New-Object System.Collections.Generic.List[object]
foreach ($cn in ($order | Sort-Object)) {
    $grp = $byCable[$cn]
    $station = ''
    $device = ''
    $wires = New-Object System.Collections.Generic.List[string]
    $conds = New-Object System.Collections.Generic.List[string]
    foreach ($g in $grp) {
        if (-not $station -and $g.Station) { $station = [string]$g.Station }
        if (-not $device -and $g.FieldDevice) { $device = [string]$g.FieldDevice }
        if ($g.WireNo) { $wires.Add([string]$g.WireNo) }
        # a conductor is a wire plus the terminal it lands on, when both are known
        $cond = ''
        if ($g.WireNo) { $cond = [string]$g.WireNo }
        if ($g.TerminalNo) { $cond = ($cond + ' to ' + [string]$g.TerminalNo) }
        if ($cond) { $conds.Add($cond) }
    }
    $out.Add([pscustomobject]@{
        Station    = $station
        CableNo    = $cn
        From       = ''                       # panel side is not in the signal table; left blank, not invented
        To         = $device
        FieldDevice= $device
        WireNo     = (($wires | Select-Object -Unique) -join ', ')
        Conductors = (($conds | Select-Object -Unique) -join '; ')
        Condition  = ''
    })
}

$outDir = Split-Path -Parent $OutCsv
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$out | Export-Csv -LiteralPath $OutCsv -NoTypeInformation -Encoding UTF8
Write-Host ("cable-schedule: {0} cables from {1} cabled signal rows -> {2}" -f $out.Count, $cabled.Count, $OutCsv)
