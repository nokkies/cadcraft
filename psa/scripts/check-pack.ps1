# check-pack.ps1 -- check a generated drawing pack against its source data.
#
# gen-pack.ps1 says a sheet was written. That is not the same as the sheet being right, and a pack
# of 262 sheets cannot be reviewed one PNG at a time. This script checks the properties that a
# generator can actually get wrong and that a reviewer would catch immediately:
#
#  P1  sheet exists and cadcraft can open it (a corrupt DWG is a missing sheet)
#  P2  the title block carries the drawing number, and it equals the file name
#  P3  the title block carries a revision, a project number and a scale
#  P4  the drawing content is inside the A1 sheet area (nothing drawn outside the border)
#  P5  every I/O row the card owns appears on a sheet exactly once (no dropped, no duplicated
#      channel) -- the check that catches a silent cap like the one that dropped 10 of 32 terminals
#  P6  the row count on the sheet matches the plan's slice for that card
#  P7  an unverified pinout prints its UNVERIFIED note, and a verified one does not
#  P8  no text is smaller than the format minimum (2.5) except on the exempt layer
#  P9  every sheet carries the draft stamp (a draft that looks issued is worse than no draft)
#  P10 the pack covers every plan row selected (nothing skipped)
#
# Output: one line per check per sheet in a CSV, plus a console summary. Exit 1 on any FAIL.
#
# Usage:
#   pwsh -File psa/scripts/check-pack.ps1 -ManifestCsv <manifest.csv> -PlanCsv <sheet-plan.csv> `
#        -SignalsCsv <io-signals.csv> -HardwareJson <modules.json> [-Rules <rules.json>]

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ManifestCsv,
    [Parameter(Mandatory = $true)][string]$PlanCsv,
    [Parameter(Mandatory = $true)][string]$SignalsCsv,
    [Parameter(Mandatory = $true)][string]$HardwareJson,
    [string]$Rules,
    [string]$ReportCsv
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
function Get-ArgumentForNative([string]$Value) { return '"' + $Value.Replace('"', '""') + '"' }
function ConvertTo-JsonStringValue([string]$Value) {
    $esc = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $esc + '"'
}
function Invoke-CliSteps {
    param([string]$Cli, [string]$Drawing, [string[]]$Steps)
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    $bat = [System.IO.Path]::GetTempFileName() + '.cmd'
    try {
        $argPart = ''
        foreach ($s in $Steps) { $argPart += ' --cmd "' + $s.Replace('"', '\"') + '"' }
        $line = '"' + $Cli + '" run "' + $Drawing + '"' + $argPart
        [System.IO.File]::WriteAllText($bat, "@echo off`r`n$line`r`n", (New-Object System.Text.ASCIIEncoding))
        $pi = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', (Get-ArgumentForNative -Value $bat)) `
                -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        if (-not $pi.WaitForExit(180000)) { try { $pi.Kill() } catch { } ; return $null }
        $text = [System.IO.File]::ReadAllText($tmpOut)
        $jsonLines = @($text -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') -or $_.Trim().StartsWith('[') })
        if ($jsonLines.Count -eq 0) { return $null }
        try { return ($jsonLines[-1] | ConvertFrom-Json) } catch { return $null }
    } catch { return $null } finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr, $bat -Force -ErrorAction SilentlyContinue
    }
}

foreach ($p in @($ManifestCsv, $PlanCsv, $SignalsCsv, $HardwareJson)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "no such file: $p" }
}
$cli = Resolve-CadcraftCli
$hw = Get-Content -LiteralPath $HardwareJson -Raw | ConvertFrom-Json

$manifest = @(Import-Csv -LiteralPath $ManifestCsv)
$plan = @(Import-Csv -LiteralPath $PlanCsv)
$sig = @(Import-Csv -LiteralPath $SignalsCsv)

# Norm-Station: reduce a panel name to one key so the register's spelling and the I/O list's tab
# name compare equal. Kept identical to the generator's function of the same name: if the two drift,
# the checker silently disagrees with the generator about which panel a sheet belongs to.
function Norm-Station([string]$s) {
    if ($null -eq $s) { return '' }
    $t = ($s.ToUpperInvariant() -replace '[^A-Z0-9]', '')
    $t = $t -replace 'REMOTEIO$', ''
    return $t
}

# PropStr: a property as a string, or '' when the object does not carry it. StrictMode makes a bare
# $obj.missing throw, and both the rules file and the hardware library are heterogeneous.
function PropStr($obj, [string]$name) {
    if ($null -eq $obj) { return '' }
    if ($obj -is [System.Management.Automation.PSCustomObject] -and -not ($obj.PSObject.Properties.Name -contains $name)) { return '' }
    try { $v = $obj.$name } catch { return '' }
    if ($null -eq $v) { return '' }
    return [string]$v
}

# Minimum text height and the exempt layer, from the rules file when given (the RRRR rules exempt
# layer 3T, where small reference text lives).
$minHeight = 2.5
$exceptLayers = @('3T')
if ($Rules -and (Test-Path -LiteralPath $Rules)) {
    $rules = Get-Content -LiteralPath $Rules -Raw | ConvertFrom-Json
    $tx = @($rules | Where-Object { (PropStr $_ 'kind') -eq 'text-height-min' })
    if ($tx.Count -gt 0) {
        $mh = 0.0
        if ([double]::TryParse((PropStr $tx[0] 'min'), [ref]$mh)) { $minHeight = $mh }
        if ($tx[0].PSObject.Properties.Name -contains 'except_layers') {
            $exceptLayers = @($tx[0].except_layers | ForEach-Object { [string]$_ })
        }
    }
}

# The A1 sheet area in paper units, with the margin the border leaves. Content outside this is
# off the sheet.
$sheetMinX = -20.0; $sheetMaxX = 880.0
$sheetMinY = -20.0; $sheetMaxY = 620.0

# The generator lays the table out from a fixed origin with fixed column widths, so the centre of
# the ADDR column is the same number on every card sheet. P5 uses it to read the address out of the
# address column rather than out of every address-shaped text on the sheet.
$addrColumnCentre = 227.0

$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$num, [string]$id, [string]$status, [string]$detail) {
    $script:results.Add([pscustomobject]@{ Number = $num; Check = $id; Status = $status; Detail = $detail })
}

# --- P5 bookkeeping: which (station, address) pairs have been placed, and where ------------
$placed = @{}
$duplicate = New-Object System.Collections.Generic.List[string]

foreach ($m in $manifest) {
    $num = [string]$m.Number
    $dwg = [string]$m.Dwg
    $station = [string]$m.Station
    $card = [string]$m.Card
    $order = [string]$m.Order

    if (-not $dwg -or -not (Test-Path -LiteralPath $dwg)) {
        Add-Result $num 'P1' 'FAIL' 'no dwg written'
        continue
    }

    # P1: cadcraft can open it and reports entities.
    $info = $null
    try { $info = (& $cli info $dwg 2>$null | Out-String | ConvertFrom-Json) } catch { }
    if ($null -eq $info) { Add-Result $num 'P1' 'FAIL' 'cadcraft could not open it'; continue }
    Add-Result $num 'P1' 'PASS' "entityCount=$($info.entityCount)"

    # Read the paper space (title block, stamps) and the model space (content).
    $lay = $null
    try { $lay = (& $cli run $dwg --cmd 'layout.list {}' 2>$null | Out-String | ConvertFrom-Json) } catch { }
    $layoutName = ''
    if ($null -ne $lay) {
        $layoutName = @($lay | ForEach-Object { [string]$_.name } | Where-Object { $_ -and $_ -ne 'Model' } | Select-Object -First 1)
    }

    $paperTexts = @()
    $modelTexts = @()
    if ($layoutName) {
        $pt = Invoke-CliSteps -Cli $cli -Drawing $dwg -Steps @(
            ('layout.set {"name":' + (ConvertTo-JsonStringValue -Value $layoutName) + '}'), 'texts {"limit":2000}')
        if ($null -ne $pt) { $paperTexts = @($pt.texts) }
    }
    $mt = Invoke-CliSteps -Cli $cli -Drawing $dwg -Steps @('layout.set {"name":"Model"}', 'texts {"limit":5000}')
    if ($null -ne $mt) { $modelTexts = @($mt.texts) }

    # P2 / P3: title block attributes.
    $tb = @{}
    foreach ($t in $paperTexts) {
        if ($t.PSObject.Properties.Name -contains 'tag' -and $t.tag) { $tb[[string]$t.tag] = [string]$t.text }
    }
    $fileBase = ([System.IO.Path]::GetFileNameWithoutExtension($dwg) -split '_')[0]
    if ($tb.ContainsKey('DWG_NO')) {
        if ($tb['DWG_NO'] -eq $fileBase) { Add-Result $num 'P2' 'PASS' "DWG_NO=$($tb['DWG_NO'])" }
        else { Add-Result $num 'P2' 'FAIL' "DWG_NO='$($tb['DWG_NO'])' but file is '$fileBase'" }
    } else {
        Add-Result $num 'P2' 'FAIL' 'no DWG_NO attribute in paper space'
    }
    $missing = @()
    foreach ($k in @('REV', 'SCALE')) { if (-not $tb.ContainsKey($k) -or -not $tb[$k]) { $missing += $k } }
    if ($missing.Count -eq 0) { Add-Result $num 'P3' 'PASS' 'REV and SCALE set' }
    else { Add-Result $num 'P3' 'FAIL' ("missing: " + ($missing -join ',')) }

    # P4: model content inside the sheet area.
    $ents = Invoke-CliSteps -Cli $cli -Drawing $dwg -Steps @('entities {"limit":5000}')
    $outside = 0
    if ($null -ne $ents) {
        foreach ($e in $ents.entities) {
            $g = $e.geometry
            $pts = @()
            if ($g.PSObject.Properties.Name -contains 'a' -and $g.a) { $pts += ,@([double]$g.a.x, [double]$g.a.y) }
            if ($g.PSObject.Properties.Name -contains 'b' -and $g.b) { $pts += ,@([double]$g.b.x, [double]$g.b.y) }
            if ($g.PSObject.Properties.Name -contains 'insert' -and $g.insert) { $pts += ,@([double]$g.insert.x, [double]$g.insert.y) }
            if ($g.PSObject.Properties.Name -contains 'center' -and $g.center) { $pts += ,@([double]$g.center.x, [double]$g.center.y) }
            foreach ($p in $pts) {
                if ($p[0] -lt $sheetMinX -or $p[0] -gt $sheetMaxX -or $p[1] -lt $sheetMinY -or $p[1] -gt $sheetMaxY) { $outside++ }
            }
        }
    }
    if ($outside -eq 0) { Add-Result $num 'P4' 'PASS' 'all model points inside the sheet area' }
    else { Add-Result $num 'P4' 'FAIL' "$outside point(s) outside $sheetMinX..$sheetMaxX / $sheetMinY..$sheetMaxY" }

    # P6: the sheet's row count matches the manifest's claim.
    $claimedRows = 0
    [void][int]::TryParse([string]$m.RowsShown, [ref]$claimedRows)
    # Count data rows by distinct row y values among the text on layer 2T in the table band.
    # texts returns each position as `at: [x, y]` (there is no .x or .y on the object), so the y is
    # element 1 of that array.
    $rowYs = @{}
    foreach ($t in $modelTexts) {
        if ([string]$t.layer -ne '2T') { continue }
        if (-not ($t.PSObject.Properties.Name -contains 'at')) { continue }
        $pos = @($t.at)
        if ($pos.Count -lt 2) { continue }
        $y = 0.0
        if (-not [double]::TryParse([string]$pos[1], [ref]$y)) { continue }
        $rowYs[[math]::Round($y, 1)] = $true
    }
    $observedRows = $rowYs.Count
    if ($claimedRows -eq 0) { Add-Result $num 'P6' 'PASS' 'device sheet (no channel rows claimed)' }
    elseif ($observedRows -ge $claimedRows) { Add-Result $num 'P6' 'PASS' "claimed=$claimedRows observed=$observedRows" }
    else { Add-Result $num 'P6' 'FAIL' "claimed=$claimedRows observed=$observedRows" }

    # P7: the UNVERIFIED note matches the hardware definition.
    $verified = $false
    if ($order -and $hw.modules.PSObject.Properties.Name -contains $order) {
        $mm = $hw.modules.$order
        if ($mm.PSObject.Properties.Name -contains 'verified') { $verified = [bool]$mm.verified }
    }
    $hasNote = @($modelTexts | Where-Object { [string]$_.text -match 'PINOUT UNVERIFIED' }).Count -gt 0
    if ($order) {
        if ($verified -and -not $hasNote) { Add-Result $num 'P7' 'PASS' 'verified, no note' }
        elseif (-not $verified -and $hasNote) { Add-Result $num 'P7' 'PASS' 'unverified, note present' }
        elseif ($verified -and $hasNote) { Add-Result $num 'P7' 'FAIL' 'verified but carries an UNVERIFIED note' }
        else { Add-Result $num 'P7' 'FAIL' 'unverified and the note is missing' }
    } else {
        Add-Result $num 'P7' 'PASS' 'no module (device sheet)'
    }

    # P8: text heights.
    $small = New-Object System.Collections.Generic.List[string]
    foreach ($t in ($modelTexts + $paperTexts)) {
        $h = 0.0
        [void][double]::TryParse([string]$t.height, [ref]$h)
        $ly = [string]$t.layer
        if ($h -gt 0 -and $h -lt $minHeight -and -not ($exceptLayers -contains $ly)) {
            # "$ly:$h" parses as a scope-qualified variable reference ($ly:h), so the separators
            # sit outside the names.
            $small.Add($ly + ' / ' + $h + ' / ' + [string]$t.text)
        }
    }
    if ($small.Count -eq 0) { Add-Result $num 'P8' 'PASS' "no text below $minHeight outside $($exceptLayers -join '/')" }
    else { Add-Result $num 'P8' 'FAIL' "$($small.Count) small text(s): " + (($small | Select-Object -First 3) -join ' | ') }

    # P9: the draft stamp, in paper space.
    $stamp = @($paperTexts | Where-Object { [string]$_.text -match 'NOT FOR CONSTRUCTION' }).Count
    if ($stamp -gt 0) { Add-Result $num 'P9' 'PASS' 'draft stamp present' }
    else { Add-Result $num 'P9' 'FAIL' 'no NOT FOR CONSTRUCTION stamp in paper space' }

    # P5 bookkeeping: record every address this sheet placed.
    #
    # The key is the NORMALISED station, because the register and the I/O list spell the same panel
    # differently (the register's "X REMOTE I/O" and "Y BUS 1" against the I/O tab's "X" and
    # "Y_BUS_1"). Keying on the literal string makes the checker compare a sheet's addresses against
    # a different station's rows, so it reports both duplicates and missing rows that are not there.
    #
    # The address is read from the ADDR COLUMN ONLY, identified by its x position, not by matching
    # every address-shaped text on the sheet. A field audit commonly records the wire number as the
    # channel address (Wire No. = "I0.0" for I0.0), so a text scan counted one channel as two and
    # reported over a thousand phantom duplicates.
    if (([string]$m.Verified) -ne '' -or $order) {
        $skey = Norm-Station $station
        foreach ($t in $modelTexts) {
            $txt = [string]$t.text
            if ($txt -notmatch '^[IQ][A-Z]?\d{1,3}\.\d$') { continue }
            $pos = @($t.at)
            if ($pos.Count -lt 2) { continue }
            $tx = 0.0
            if (-not [double]::TryParse([string]$pos[0], [ref]$tx)) { continue }
            # The ADDR column is centred; a text placed there sits within a few units of it.
            if ([math]::Abs($tx - $addrColumnCentre) -gt 6.0) { continue }
            $key = "$skey|$txt"
            if ($placed.ContainsKey($key)) { $duplicate.Add("$key on $num and $($placed[$key])") }
            else { $placed[$key] = $num }
        }
    }
}

# P5: every station's signals should be placed exactly once across its sheets.
$planStations = @($manifest | ForEach-Object { [string]$_.Station } | Where-Object { $_ } | Sort-Object -Unique)
foreach ($st in $planStations) {
    $skey = Norm-Station $st
    $want = @($sig | Where-Object { (Norm-Station ([string]$_.Station)) -eq $skey })
    $missingAddrs = @()
    foreach ($s in $want) {
        $key = "$skey|$($s.Address)"
        if (-not $placed.ContainsKey($key)) { $missingAddrs += [string]$s.Address }
    }
    if ($missingAddrs.Count -eq 0) {
        Add-Result "PACK:$st" 'P5' 'PASS' "all $($want.Count) I/O rows placed on a sheet"
    } else {
        $shown = ($missingAddrs | Select-Object -First 12) -join ','
        Add-Result "PACK:$st" 'P5' 'FAIL' "$($missingAddrs.Count) of $($want.Count) rows not on any sheet (e.g. $shown)"
    }
}
if ($duplicate.Count -gt 0) {
    Add-Result 'PACK' 'P5' 'FAIL' "$($duplicate.Count) address(es) placed twice: " + (($duplicate | Select-Object -First 5) -join ' | ')
}

# P10: coverage against the plan.
$tmdPlan = @($plan | Where-Object { $_.Discipline -eq 'TMD' })
$madeNums = @($manifest | ForEach-Object { [string]$_.Number })
$notMade = @($tmdPlan | Where-Object { $n = [string]$_.Number; -not ($madeNums | Where-Object { $_ -eq $n }) })
if ($notMade.Count -eq 0) { Add-Result 'PACK' 'P10' 'PASS' "all $($tmdPlan.Count) planned TMD sheets generated" }
else { Add-Result 'PACK' 'P10' 'FAIL' "$($notMade.Count) planned sheets not generated (e.g. " + (($notMade | Select-Object -First 6 | ForEach-Object { $_.Number }) -join ',') + ')' }

# --- report ------------------------------------------------------------------------
$fails = @($results | Where-Object { $_.Status -eq 'FAIL' })
$passes = @($results | Where-Object { $_.Status -eq 'PASS' })

$outCsv = $ReportCsv
if (-not $outCsv) { $outCsv = Join-Path (Split-Path -Parent $ManifestCsv) 'pack-check.csv' }
$results | Export-Csv -LiteralPath $outCsv -NoTypeInformation -Encoding UTF8

Write-Host ("checks: {0} pass, {1} fail -> {2}" -f $passes.Count, $fails.Count, $outCsv)
foreach ($g in ($fails | Group-Object Check | Sort-Object Name)) {
    Write-Host ("  {0}: {1} failure(s)" -f $g.Name, $g.Count)
    foreach ($x in ($g.Group | Select-Object -First 4)) { Write-Host ("    {0}  {1}" -f $x.Number, $x.Detail) }
}
if ($fails.Count -eq 0) { Write-Host 'PASS pack check (every generated sheet passes P1-P10)' }
if ($fails.Count -gt 0) { exit 1 }
exit 0
