# check-d4.ps1 -- DRAWING-WORK D4: verify the I/O schematic channels map to RTB pin numbers.
#
# D4: the I/O schematics show channel names (IN 0, OUT 0, CH0 I+) but no removable terminal block
# pin numbers. The pin-to-channel mapping is sourced from the Rockwell wiring diagrams into
# $D\fusion\pins.csv. This cross-references each generated I/O schematic's channel texts against
# pins.csv: every channel the schematic draws must have a pins.csv row (so the pin number is known),
# and reports whether the schematic already annotates the terminal number beside the channel.
#
# Sheets: SCD-003 = DI (5069-IB16), SCD-004 = DO (5069-OB16), SCD-005 = AO (5069-OF4).
# Exit 0 when every drawn channel has a pins.csv mapping (the pin numbers are sourced and available
# to annotate); it also prints how many channels already carry a terminal number on the sheet.

[CmdletBinding()]
param(
    [string]$PinsCsv,
    [string]$TextsDir
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
if ([string]::IsNullOrWhiteSpace($PinsCsv)) { $PinsCsv = Join-Path $D 'fusion\pins.csv' }
if ([string]::IsNullOrWhiteSpace($TextsDir)) { $TextsDir = Join-Path $D 'fusion\texts' }
if (-not (Test-Path -LiteralPath $PinsCsv)) { throw "pins.csv not found: $PinsCsv (run the D4 datasheet step)" }

# module -> sheet, and the channel-name regex that sheet uses. The sheet file names come from the
# private project settings ($Project.ioSheets: DI, DO, AO); the module and channel pattern are
# per I/O type, not per project.
$ioCfg = @{
    DI = @{ module='5069-IB16'; pattern='^IN\s+(\d+)$' }
    DO = @{ module='5069-OB16'; pattern='^OUT\s+(\d+)$' }
    AO = @{ module='5069-OF4';  pattern='^CH(\d)\s+(I\+|I-|V\+|V-)$' }
}
$sheetToModule = [ordered]@{}
foreach ($role in 'DI', 'DO', 'AO') {
    $sheet = [string]$Project.ioSheets.$role
    if ($sheet) { $sheetToModule[$sheet] = $ioCfg[$role] }
}

# pins.csv -> per module, the set of channels (and their terminal numbers).
$pins = Import-Csv -LiteralPath $PinsCsv
$byModule = @{}
foreach ($p in $pins) {
    if (-not $byModule.ContainsKey($p.module)) { $byModule[$p.module] = @{} }
    if ($p.channel) { $byModule[$p.module][$p.channel.Trim()] = $p.terminal }
}

$missing = 0
foreach ($sheet in $sheetToModule.Keys) {
    $cfg = $sheetToModule[$sheet]
    $module = $cfg.module
    $tf = Join-Path $TextsDir ('fusion__out__' + $sheet + '.json')
    if (-not (Test-Path -LiteralPath $tf)) { Write-Host "  $sheet : texts not captured (run capture-json)"; $missing++; continue }
    $j = Get-Content -LiteralPath $tf -Raw | ConvertFrom-Json
    $texts = @($j.model.texts | Where-Object { -not ($_.PSObject.Properties.Name -contains 'tag' -and $_.tag) })
    $channels = @($texts | Where-Object { ([string]$_.text).Trim() -match $cfg.pattern })
    $known = 0; $unknown = 0
    foreach ($c in $channels) {
        $name = ([string]$c.text).Trim()
        # Normalise the schematic channel name to the pins.csv channel key.
        $key = $name
        if ($module -eq '5069-OF4') { $key = ($name -replace '\s+','') }  # CH0 I+ -> CH0I+ won't match; use CHn
        if ($byModule.ContainsKey($module) -and $byModule[$module].ContainsKey($key)) { $known++ }
        else {
            # For OF4, match on the CHn prefix.
            if ($module -eq '5069-OF4' -and $name -match '^(CH\d)') {
                $ch = $matches[1]
                $hasCh = @($byModule[$module].Keys | Where-Object { $_ -eq $ch }).Count -gt 0
                if ($hasCh) { $known++; continue }
            }
            $unknown++
        }
    }
    # Does the sheet already annotate a terminal number next to a channel? Look for a "Tn" label
    # (the gen-scd D4 annotation) or a bare integer just left of the channel. The vertical window is
    # tight (+/- rows are ~10 units apart) so a channel matches only its own terminal, not its
    # neighbour's.
    $annotated = 0
    foreach ($c in $channels) {
        $cx = [double]$c.at[0]; $cy = [double]$c.at[1]
        $near = @($texts | Where-Object {
            $t = ([string]$_.text).Trim()
            (($t -match '^T\d{1,2}$') -or ($t -match '^\d{1,2}$')) -and ([Math]::Abs([double]$_.at[0]-$cx) -le 20) -and ([Math]::Abs([double]$_.at[1]-$cy) -le 5)
        })
        if ($near.Count -gt 0) { $annotated++ }
    }
    Write-Host ("  {0} ({1}): {2} channels drawn, {3} mapped in pins.csv, {4} unmapped, {5} already show a terminal number" -f $sheet, $module, $channels.Count, $known, $unknown, $annotated)
    if ($unknown -gt 0) { $missing += $unknown }
}

if ($missing -eq 0) {
    Write-Host 'PASS D4 (every schematic channel has a sourced RTB pin mapping in pins.csv; pin numbers available to annotate)'
    exit 0
} else {
    Write-Host "FAIL D4 ($missing channel(s) have no pins.csv mapping)"
    exit 1
}
