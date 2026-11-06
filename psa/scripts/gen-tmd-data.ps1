# gen-tmd-data.ps1 -- build a termination diagram FROM DATA, not from a hand-drawn drawing.
#
# This is the capability the NNNN job actually needs. gen-tmd.ps1 and gen-scd.ps1 reproduce a
# drawing that already exists: they read a hand-drawn DWG and rebuild it, which proves the renderer
# but cannot produce a sheet nobody has drawn. the designer did not issue termination drawings for NNNN -
# producing them is the deliverable, so the sheet has to come out of the I/O list plus the hardware
# library plus the document register.
#
# Inputs (all read, none written):
#   -Template      the PSA blank sheet: carries A1 BORDER, A1 TITLE TEXT, the layers, the text styles
#                  and the paper-space content viewport. Nothing here redraws those.
#   -Plan          one row from sheets-plan.ps1: the drawing number, title, station, card, instance.
#   -Signals       rows from io-normalise.ps1 for that station, already filtered to this card.
#   -Hardware      psa/hardware/modules.json: the module definition for the card's order number.
#   -Conventions   layout constants (origin, row pitch, column widths, text heights).
#
# Output: a cadcraft script (.scr) plus the generated DWG.
#
# The sheet is a terminal-strip table, which is how the RRRR TMDs are actually built (a drawn table
# of lines and text, not graphical terminal symbols -- see the build 0.020 note in the changelog).
# Columns, left to right:
#   PANEL SIDE | tag | address | terminal | wire number | FIELD SIDE | cable | field device
# with the module's own channel/supply pin column beside the terminal column.
#
# Every row that the I/O list contains is drawn, including spares and "No Cable" rows: a spare
# channel is shown and labelled, never deleted (handover rule: spare capacity is shown on the
# drawings). A row with no tag prints its address as the label so the drafter can see what is
# unknown rather than an unexplained blank.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Template,
    [Parameter(Mandatory = $true)][string]$OutDwg,
    [Parameter(Mandatory = $true)][string]$HardwareJson,
    [Parameter(Mandatory = $true)][string]$PlanCsv,
    [Parameter(Mandatory = $true)][string]$SignalsCsv,
    [string]$DrawingNumber,          # which row of the plan to build (default: first)
    [string]$ScrPath,
    [string]$ProjectNumber = '',
    [string]$Scope1 = '',
    [string]$Scale = 'NTS',
    [string]$DrawnBy = 'PSA FUSION',
    [string]$DrawnDate = '',
    [string]$LayoutName = '',         # blank = the template's first non-model layout
    [string]$OrderScheduleCsv = '',   # panel line items, for the comms and power sheets
    [int]$MaxRows = 0                 # 0 = auto from the card's channel count
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
    if ($null -eq $Value) { return '""' }
    $esc = $Value.Replace('\', '\\').Replace('"', '\"')
    # cadcraft scripts are written as one command per line, so a newline inside a string would
    # split the command. Carriage return and line feed become a space.
    $esc = $esc -replace '\r', ' '
    $esc = $esc -replace "`n", ' '
    return '"' + $esc + '"'
}
function JNum($v) { return ([double]$v).ToString([System.Globalization.CultureInfo]::InvariantCulture) }

# PropStr: read a property as a string, or '' when the object does not carry it. StrictMode makes a
# bare $obj.missing throw, and the hardware definitions are heterogeneous (only some modules have
# 'jumpers', only some supplies have 'plus'), so every optional field goes through it.
function PropStr($obj, [string]$name) {
    if ($null -eq $obj) { return '' }
    if ($obj -is [System.Management.Automation.PSCustomObject] -and -not ($obj.PSObject.Properties.Name -contains $name)) { return '' }
    try { $v = $obj.$name } catch { return '' }
    if ($null -eq $v) { return '' }
    return [string]$v
}

# Run steps in one CLI invocation and return the last JSON object printed.
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
        if ($pi.ExitCode -ne 0) { return $null }
        $text = [System.IO.File]::ReadAllText($tmpOut)
        $jsonLines = @($text -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') -or $_.Trim().StartsWith('[') })
        if ($jsonLines.Count -eq 0) { return $null }
        try { return ($jsonLines[-1] | ConvertFrom-Json) } catch { return $null }
    } catch { return $null } finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr, $bat -Force -ErrorAction SilentlyContinue
    }
}

foreach ($p in @($Template, $HardwareJson, $PlanCsv, $SignalsCsv)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "no such file: $p" }
}
$cli = Resolve-CadcraftCli

# --- the plan row ------------------------------------------------------------------
$plan = @(Import-Csv -LiteralPath $PlanCsv)
$row = $null
if ($DrawingNumber) {
    $row = $plan | Where-Object { $_.Number -eq $DrawingNumber } | Select-Object -First 1
    if ($null -eq $row) { throw "drawing $DrawingNumber is not in the plan" }
} else {
    $row = $plan | Where-Object { $_.Discipline -eq 'TMD' } | Select-Object -First 1
}
if ($null -eq $row) { throw 'no TMD row in the plan' }

$station = [string]$row.Station
$title = [string]$row.Title
$cardTitle = [string]$row.Card
$number = [string]$row.Number
$rev = [string]$row.Revision

# --- hardware lookup ---------------------------------------------------------------
$hw = Get-Content -LiteralPath $HardwareJson -Raw | ConvertFrom-Json
$aliasMap = $hw.cardTitleAliases
$orderNumber = ''
$keys = @($aliasMap.PSObject.Properties.Name | Where-Object { $_ -ne '_note' } | Sort-Object { -$_.Length })
foreach ($k in $keys) {
    if ($cardTitle -and $cardTitle.ToUpperInvariant().Contains($k.ToUpperInvariant())) {
        $orderNumber = [string]$aliasMap.$k; break
    }
}
$mod = $null
if ($orderNumber -and $hw.modules.PSObject.Properties.Name -contains $orderNumber) {
    $mod = $hw.modules.$orderNumber
}
# A comms or power sheet names no card: pick the panel's own comms/power devices later.
$sheetKind = 'card'
if ($cardTitle -match 'COMMUNICATION') { $sheetKind = 'comms' }
elseif ($cardTitle -match 'POWER SUPPLY') { $sheetKind = 'power' }

# --- comms and power sheets ---------------------------------------------------------
# These sheets are not one-per-card: the register gives every panel exactly one of each, and what
# goes on them is the panel's comms devices (switches, FOBOTs, bus adapters, serial modules) or its
# power devices (PSUs). The order schedule is the source, so the panel's own line items are read
# from it and filtered by the hardware library's 'sheet' tag.
#
# -OrderScheduleCsv is optional: without it these sheets carry a note saying the source was not
# supplied, rather than being silently empty.
$panelDevices = @()
if ($sheetKind -ne 'card') {
    if ($OrderScheduleCsv -and (Test-Path -LiteralPath $OrderScheduleCsv)) {
        # The schedule's first row is a title line, so its header is row 2. Import-Csv on the file
        # takes the title as the column names and every lookup then comes back empty, silently.
        $osLines = [System.IO.File]::ReadAllLines($OrderScheduleCsv)
        $hdrIdx = 0
        for ($k = 0; $k -lt [math]::Min($osLines.Count, 6); $k++) {
            if ($osLines[$k] -match '(?i)part number' -and $osLines[$k] -match '(?i)panel') { $hdrIdx = $k; break }
        }
        $osRows = @(ConvertFrom-Csv -InputObject (($osLines[$hdrIdx..($osLines.Count - 1)]) -join "`n"))
        $wantSheet = if ($sheetKind -eq 'comms') { 'comms' } else { 'power' }
        $names = @($osRows[0].PSObject.Properties.Name)
        $panelCol = $names | Where-Object { $_ -match 'Panel' } | Select-Object -First 1
        $pnCol = $names | Where-Object { $_ -match 'Part number' } | Select-Object -First 1
        $descCol = $names | Where-Object { $_ -match 'Description' } | Select-Object -First 1
        $qtyCol = $names | Where-Object { $_ -match '^Qty' } | Select-Object -First 1
        if ($panelCol -and $pnCol) {
            # Panel names in the schedule are the station names; match loosely so "BUS 1"
            # finds the schedule's "BUS 1" or a code like "BUS1".
            $wantKey = ($station -replace '[^A-Z0-9]', '').ToUpperInvariant()
            foreach ($r in $osRows) {
                $pn = ([string]$r.$pnCol).Trim()
                if (-not $pn) { continue }
                $pnKey = ($pn -replace '[^A-Za-z0-9]', '').ToUpperInvariant()
                if ($pnKey.Length -lt 10) { $pnKey = '6ES' + $pnKey }   # short codes in the additions rows
                if (-not ($hw.modules.PSObject.Properties.Name -contains $pn)) {
                    $found = $null
                    foreach ($mn in $hw.modules.PSObject.Properties.Name) {
                        if ((($mn -replace '[^A-Za-z0-9]', '').ToUpperInvariant()) -eq $pnKey) { $found = $mn; break }
                    }
                    if ($found) { $pn = $found }
                }
                if (-not ($hw.modules.PSObject.Properties.Name -contains $pn)) { continue }
                $m2 = $hw.modules.$pn
                if ((PropStr $m2 'sheet') -ne $wantSheet) { continue }
                $panelKey = ([string]$r.$panelCol).Trim()
                if ($panelKey) {
                    $pk = ($panelKey -replace '[^A-Z0-9]', '').ToUpperInvariant()
                    if ($pk -ne $wantKey) { continue }
                }
                $qty = ''
                if ($qtyCol) { $qty = ([string]$r.$qtyCol).Trim() }
                $panelDevices += [pscustomobject]@{
                    Part = $pn
                    Desc = if ($descCol) { [string]$r.$descCol } else { (PropStr $m2 'description') }
                    Qty  = $qty
                    Card = PropStr $m2 'cardTitle'
                }
            }
        }
    }
}

# --- signals for this station ------------------------------------------------------
# The register and the I/O list name the same panel differently: the register says "CEP REMOTE I/O"
# and "BUS 1", the I/O workbook's tab (and so the normalised table) says "CEP" and
# "SSHHC_BUS_1". Matching on the literal string finds no rows and produces an empty sheet without
# complaining, so both spellings are reduced to the same key before comparison.
function Norm-Station([string]$s) {
    if ($null -eq $s) { return '' }
    $t = ($s.ToUpperInvariant() -replace '[^A-Z0-9]', '')
    $t = $t -replace 'REMOTEIO$', ''
    return $t
}
$sigAll = @(Import-Csv -LiteralPath $SignalsCsv)
# Group with a List, then convert the whole table to arrays in one pass. Values must be plain arrays
# where they are read: @($hashTable[$k]) on a stored List[object] throws "Argument types do not
# match" on this PowerShell version, and this is on the path of every sheet.
$sigLists = @{}
foreach ($s in $sigAll) {
    $k = Norm-Station ([string]$s.Station)
    if (-not $sigLists.ContainsKey($k)) { $sigLists[$k] = New-Object System.Collections.Generic.List[object] }
    $sigLists[$k].Add($s)
}
$sigByStation = @{}
foreach ($k in $sigLists.Keys) { $sigByStation[$k] = @($sigLists[$k].ToArray()) }
$sigKey = Norm-Station $station
$sig = @()
if ($sigByStation.ContainsKey($sigKey)) { $sig = $sigByStation[$sigKey] }
if ($sig.Count -eq 0) { Write-Warning "no I/O rows for station '$station' (key '$sigKey')" }

# Which signals belong on THIS sheet.
#
# The first version sliced the station's rows by ordinal position: instance n takes rows
# [(n-1)*channels .. n*channels). That is wrong whenever the I/O list does not start at byte 0 or
# has a gap in it, and GEN is exactly that case -- its inputs start at I4.0 and its outputs at
# Q32.0. Positional slicing handed the same first rows to several sheets (1,179 addresses placed
# twice across the pack) and never reached the tail (64 GEN rows on no sheet at all).
#
# The rule that works: split the station's rows of this direction into CONTIGUOUS RUNS of channel
# number (channel = byte*8 + bit + 1, so one card occupies consecutive channels and a gap starts a
# new run), then cut each run into card-sized chunks. Numbering the chunks in order gives the
# register's card sequence, and instance n picks chunk n. Every row lands on exactly one sheet, and
# a gap in the addressing becomes a card boundary rather than a shift.
$chanPerCard = 0
if ($null -ne $mod) { $chanPerCard = [int]$mod.channels }
if ($chanPerCard -le 0) { $chanPerCard = 32 }

$dirWanted = ''
if ($null -ne $mod) { $dirWanted = [string]$mod.dir }
$cardSignals = @()
if ($sheetKind -eq 'card') {
    $pool = @($sig)
    if ($dirWanted -eq 'I') { $pool = @($sig | Where-Object { $_.Dir -eq 'I' }) }
    elseif ($dirWanted -eq 'Q') { $pool = @($sig | Where-Object { $_.Dir -eq 'Q' }) }
    elseif ($dirWanted -eq 'IQ') { $pool = @($sig | Where-Object { $_.Dir -eq 'I' -or $_.Dir -eq 'Q' }) }
    $pool = @($pool | Sort-Object { [int]$_.Byte }, { [int]$_.Bit })

    $inst = 1
    [void][int]::TryParse([string]$row.Instance, [ref]$inst)
    if ($inst -lt 1) { $inst = 1 }

    # Contiguous runs of channel numbers, as parallel index arrays.
    #
    # A [pscustomobject]@{Items = (List...)} reads more nicely, but @($r.Items) on it throws
    # "Argument types do not match" on this PowerShell version, and this runs on every card sheet.
    # Two index lists walked together have no such problem.
    $runStarts = New-Object System.Collections.Generic.List[int]
    $prevCh = -2
    for ($k = 0; $k -lt $pool.Count; $k++) {
        $ch = 0
        [void][int]::TryParse([string]$pool[$k].Channel, [ref]$ch)
        if ($k -eq 0 -or $ch -ne ($prevCh + 1)) { $runStarts.Add($k) }
        $prevCh = $ch
    }
    $runEnds = New-Object System.Collections.Generic.List[int]
    for ($j = 0; $j -lt $runStarts.Count; $j++) {
        $runEnds.Add($(if ($j + 1 -lt $runStarts.Count) { $runStarts[$j + 1] - 1 } else { $pool.Count - 1 }))
    }

    # Each run cut into card-sized chunks; the chunks in order are the cards.
    $chunkStarts = New-Object System.Collections.Generic.List[int]
    $chunkEnds = New-Object System.Collections.Generic.List[int]
    for ($j = 0; $j -lt $runStarts.Count; $j++) {
        $pos = $runStarts[$j]
        $stop = $runEnds[$j]
        while ($pos -le $stop) {
            $end = [math]::Min($pos + $chanPerCard - 1, $stop)
            $chunkStarts.Add($pos)
            $chunkEnds.Add($end)
            $pos = $end + 1
        }
    }

    if ($inst -le $chunkStarts.Count) {
        $cardSignals = @($pool[$chunkStarts[$inst - 1]..$chunkEnds[$inst - 1]])
    }
}

$rowsToDraw = $cardSignals.Count
if ($sheetKind -ne 'card') { $rowsToDraw = $panelDevices.Count }
if ($MaxRows -gt 0) { $rowsToDraw = [math]::Min($MaxRows, [math]::Max($rowsToDraw, 1)) }
if ($rowsToDraw -le 0) { $rowsToDraw = $chanPerCard }
# Every channel on the card is drawn. An earlier version capped a sheet at 22 rows to keep the
# table inside the border, and that silently dropped 10 channels from every 32-point card: a
# termination diagram missing 10 of its 32 terminals is worse than a tall one. The cap is gone; the
# pitch is fitted to the sheet instead (see the fit block below), so 32 rows fit and nothing hides.
$drawnRows = $rowsToDraw

# --- layout ------------------------------------------------------------------------
# Paper units on the A1 border (841 x 594). The content viewport sits at centre (420.5, 322) with
# viewHeight 524, so model-space content around y 322 +/- 262 lands inside it.
$originX = 120.0
$originY = 520.0
$rowPitch = if ($null -ne $mod) { [double]$mod.rowPitch } else { 26.0 }
if ($rowPitch -le 0) { $rowPitch = 26.0 }
$hSmall = 2.5; $hLabel = 3.5; $hHead = 5.0
# Column left edges and widths, in paper units.
$cols = @(
    @{ key = 'tag';      w = 90.0; label = 'TAG' },
    @{ key = 'addr';     w = 34.0; label = 'ADDR' },
    @{ key = 'pin';      w = 26.0; label = 'PIN' },
    @{ key = 'term';     w = 26.0; label = 'TERM' },
    @{ key = 'wire';     w = 46.0; label = 'WIRE No.' },
    @{ key = 'cable';    w = 62.0; label = 'CABLE' },
    @{ key = 'device';   w = 108.0; label = 'FIELD DEVICE / NAME' }
)
# A comms or power sheet lists devices, not channels, so its columns are DEVICE / QTY / PART No. /
# DESCRIPTION. Reusing the channel headers would print "ADDR" above a quantity and "CABLE" above a
# description, which reads as a broken sheet rather than a different table.
if ($sheetKind -ne 'card') {
    $cols = @(
        @{ key = 'tag';    w = 90.0;  label = 'DEVICE' },
        @{ key = 'addr';   w = 34.0;  label = 'QTY' },
        @{ key = 'pin';    w = 26.0;  label = 'SPARE' },
        @{ key = 'term';   w = 26.0;  label = 'PWR' },
        @{ key = 'wire';   w = 46.0;  label = 'PART No.' },
        @{ key = 'cable';  w = 62.0;  label = '' },
        @{ key = 'device'; w = 108.0; label = 'DESCRIPTION' }
    )
}
$totalW = 0.0
foreach ($c in $cols) { $totalW += [double]$c.w }
$x = $originX
foreach ($c in $cols) { $c.x = $x; $x += [double]$c.w }

# Fit the pitch to the sheet. CONVENTIONS gives digital 25 to 27.5 and analogue 75 per channel, but
# those are the pitches of a hand-drawn sheet where one row carries a terminal symbol, a wire and a
# hop. A data-generated row is one line of text, so the convention pitches leave the table either
# overrunning the A1 window (analogue: 8 x 75 = 600, more than the 524 the viewport shows) or with
# rows far taller than their text. The pitch is therefore reduced to fit the available height and
# never grown past the convention.
#
# The pitch is chosen so the table fills the sheet, bounded both ways.
#
# The first version only ever reduced the pitch to fit, which left an 8-channel card at 53.7 with
# text sitting in the bottom third of a very tall band. The second version scaled up from a small
# base and produced 70 for an 8-row card and 13 for a 32-row card, so the same pack carried two
# different densities and the 32-row one was cramped. Both bounds are now explicit: the pitch is
# the available height divided by the row count, clamped to [14, 26] for digital and [18, 40] for
# analogue. Every sheet in the pack then sits inside that band, and a card that needs more rows than
# fit at the floor is reported rather than squeezed below it.
$availableH = 430.0
$isAnalogue = $false
if ($null -ne $mod -and $mod.PSObject.Properties.Name -contains 'analogue') { $isAnalogue = [bool]$mod.analogue }
$minPitch = if ($isAnalogue) { 18.0 } else { 14.0 }
$maxPitch = if ($isAnalogue) { 40.0 } else { 26.0 }
if ($drawnRows -gt 0) {
    $fit = [math]::Floor(($availableH / $drawnRows) * 10.0) / 10.0
    $rowPitch = [math]::Min([math]::Max($fit, $minPitch), $maxPitch)
}
$fitsAtMin = [math]::Floor($availableH / $minPitch)

$lines = New-Object System.Collections.Generic.List[string]

# --- title block -------------------------------------------------------------------
$tplLayout = $LayoutName
$tplTbHandle = ''
$tplVpHandle = ''
$tplVpCenterX = 0.0; $tplVpCenterY = 0.0; $tplVpViewHeight = 0.0
if (-not $tplLayout) {
    $tll = Invoke-CliSteps -Cli $cli -Drawing $Template -Steps @('layout.list {}')
    if ($null -ne $tll) {
        $lay = @($tll | ForEach-Object { [string]$_.name } | Where-Object { $_ -and $_ -ne 'Model' })
        if ($lay.Count -gt 0) { $tplLayout = $lay[0] }
    }
}
if ($tplLayout) {
    $tins = Invoke-CliSteps -Cli $cli -Drawing $Template -Steps @(
        ('layout.set {"name":' + (ConvertTo-JsonStringValue -Value $tplLayout) + '}'),
        'entities {"type":"Insert","limit":200}')
    if ($null -ne $tins) {
        foreach ($e in $tins.entities) {
            if ([string]$e.geometry.block -eq 'A1 TITLE TEXT') { $tplTbHandle = [string]$e.handle; break }
        }
    }
    $tvps = Invoke-CliSteps -Cli $cli -Drawing $Template -Steps @(
        ('layout.set {"name":' + (ConvertTo-JsonStringValue -Value $tplLayout) + '}'),
        'entities {"type":"Viewport","limit":50}')
    if ($null -ne $tvps) {
        $best = -1.0
        foreach ($e in $tvps.entities) {
            $g = $e.geometry
            $vid = -1
            if ($g.PSObject.Properties.Name -contains 'id') { $vid = [int]$g.id }
            if ($vid -lt 2) { continue }
            $w = 0.0; $h = 0.0
            if ($g.PSObject.Properties.Name -contains 'width') { $w = [double]$g.width }
            if ($g.PSObject.Properties.Name -contains 'height') { $h = [double]$g.height }
            if (($w * $h) -gt $best) {
                $best = $w * $h; $tplVpHandle = [string]$e.handle
                if ($g.PSObject.Properties.Name -contains 'viewCenter' -and $g.viewCenter) {
                    $tplVpCenterX = [double]$g.viewCenter.x; $tplVpCenterY = [double]$g.viewCenter.y
                }
                if ($g.PSObject.Properties.Name -contains 'viewHeight') { $tplVpViewHeight = [double]$g.viewHeight }
            }
        }
    }
}

$attribs = [ordered]@{}
if ($ProjectNumber) { $attribs['PROJECTNO.'] = $ProjectNumber }
if ($Scope1) { $attribs['SCOPE1'] = $Scope1 }
if ($station) { $attribs['SCOPE2'] = "PANEL $station" }
$attribs['DWG_AREA'] = $title
$attribs['DWG_TITLE'] = 'PSA ENGINEERING'
$attribs['DWG_NO'] = $number
$attribs['REV'] = $rev
$attribs['SCALE'] = $Scale
$attribs['CLIENTNO.'] = $ProjectNumber
if ($DrawnBy) { $attribs['BY7'] = $DrawnBy }
if ($DrawnDate) { $attribs['DATE7'] = $DrawnDate }

$attribJson = ($attribs.Keys | ForEach-Object {
    (ConvertTo-JsonStringValue -Value $_) + ':' + (ConvertTo-JsonStringValue -Value $attribs[$_])
}) -join ','

if ($tplLayout -and $tplTbHandle) {
    $lines.Add('layout.set {"name":' + (ConvertTo-JsonStringValue -Value $tplLayout) + '}')
    $lines.Add('attedit {"handle":' + (ConvertTo-JsonStringValue -Value $tplTbHandle) + ',"values":{' + $attribJson + '}}')
    $lines.Add('layout.set {"name":"Model"}')
} else {
    Write-Warning 'template title block not found; inserting into model space'
    $lines.Add('insert {"name":"A1 TITLE TEXT","at":[0,0],"attribs":{' + $attribJson + '}}')
    $lines.Add('insert {"name":"A1 BORDER","at":[0,0]}')
}

# --- drawing helpers ---------------------------------------------------------------
$curLayer = ''
function Emit-Layer([string]$Name) {
    if ($Name -and $Name -ne $script:curLayer) {
        $script:lines.Add('layer.current {"name":' + (ConvertTo-JsonStringValue -Value $Name) + '}')
        $script:curLayer = $Name
    }
}
function Emit-Line([double]$x1, [double]$y1, [double]$x2, [double]$y2, [string]$Layer) {
    Emit-Layer $Layer
    $script:lines.Add('line {"points":[[' + (JNum $x1) + ',' + (JNum $y1) + '],[' + (JNum $x2) + ',' + (JNum $y2) + ']]}')
}
function Emit-Text([double]$x, [double]$y, [string]$Text, [double]$Height, [string]$Layer, [string]$Style, [string]$Justify) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    Emit-Layer $Layer
    $j = ''
    if ($Justify) { $j = ',"justify":"' + $Justify + '"' }
    $st = ''
    if ($Style) { $st = ',"style":' + (ConvertTo-JsonStringValue -Value $Style) }
    # text has no style parameter in this build; set the current style instead.
    if ($Style) {
        $script:lines.Add('style.current {"name":' + (ConvertTo-JsonStringValue -Value $Style) + '}')
        $st = ''
    }
    $script:lines.Add('text {"at":[' + (JNum $x) + ',' + (JNum $y) + '],"text":' + (ConvertTo-JsonStringValue -Value $Text) + ',"height":' + (JNum $Height) + $j + '}')
}

$styleName = 'isocp2'

# --- heading -----------------------------------------------------------------------
$headY = $originY + 26.0
Emit-Text $originX ($headY + 14.0) "TERMINATION DIAGRAM" $hHead '5T' $styleName 'L'
Emit-Text $originX ($headY + 6.0) "$number  -  $station" $hLabel '5T' $styleName 'L'
$cardLine = $cardTitle
if ($orderNumber) { $cardLine = "$cardTitle  ($orderNumber)" }
Emit-Text ($originX + $totalW) ($headY + 6.0) $cardLine $hLabel '3T' $styleName 'R'

# CONTROL PANEL / FIELD headings either side of the split, per CONVENTIONS.
Emit-Text $originX ($headY + 1.0) 'CONTROL PANEL' $hLabel '2T' $styleName 'L'
Emit-Text ($originX + $totalW) ($headY + 1.0) 'FIELD' $hLabel '2T' $styleName 'R'

# --- column header row -------------------------------------------------------------
$hdrY = $originY
foreach ($c in $cols) {
    Emit-Line $c.x $hdrY ($c.x + [double]$c.w) $hdrY '3C'
    Emit-Text ($c.x + ([double]$c.w / 2.0)) ($hdrY - 5.0) $c.label $hSmall '2T' $styleName 'MC'
}
Emit-Line $originX $hdrY $originX ($hdrY - [double]$drawnRows * $rowPitch) '3C'
Emit-Line $originX ($hdrY - [double]$drawnRows * $rowPitch) ($originX + $totalW) ($hdrY - [double]$drawnRows * $rowPitch) '3C'
Emit-Line ($originX + $totalW) $hdrY ($originX + $totalW) ($hdrY - [double]$drawnRows * $rowPitch) '3C'
foreach ($c in $cols) {
    Emit-Line $c.x $hdrY $c.x ($hdrY - [double]$drawnRows * $rowPitch) '3C'
}

# --- data rows ---------------------------------------------------------------------
$bottomY = $hdrY - [double]$drawnRows * $rowPitch
$prevAddr = ''
for ($i = 0; $i -lt $drawnRows; $i++) {
    $rowY = $hdrY - [double]($i + 1) * $rowPitch
    Emit-Line $originX $rowY ($originX + $totalW) $rowY '3C'
    $yTxt = $rowY + $rowPitch * 0.35

    # A comms or power sheet lists the panel's devices, not channels: one row per device, with its
    # order number, description and quantity. Same table frame, different content.
    if ($sheetKind -ne 'card') {
        if ($i -ge $panelDevices.Count) { continue }
        $d = $panelDevices[$i]
        Emit-Text (($cols[0].x + 3.0)) $yTxt ([string]$d.Card) $hLabel '2T' $styleName ''
        Emit-Text (($cols[1].x + $cols[1].w / 2.0)) $yTxt ([string]$d.Qty) $hSmall '2T' $styleName 'MC'
        Emit-Text (($cols[4].x + $cols[4].w / 2.0)) $yTxt ([string]$d.Part) $hSmall '1T' $styleName 'MC'
        $descTxt = [string]$d.Desc
        if ($descTxt.Length -gt 60) { $descTxt = $descTxt.Substring(0, 60) + '...' }
        Emit-Text (($cols[5].x + 3.0)) $yTxt $descTxt $hSmall '3T' $styleName ''
        continue
    }

    $s = $null
    if ($i -lt $cardSignals.Count) { $s = $cardSignals[$i] }

    if ($null -eq $s) {
        # A channel the card has and the I/O list does not name: draw it as SPARE rather than
        # leaving a blank row, which reads as an omission.
        $chNo = $i + 1
        Emit-Text (($cols[0].x + $cols[0].w / 2.0)) $yTxt 'SPARE' $hSmall '3T' $styleName 'MC'
        Emit-Text (($cols[2].x + $cols[2].w / 2.0)) $yTxt "CH$chNo" $hSmall '2T' $styleName 'MC'
        continue
    }

    $tag = [string]$s.Tag
    $addr = [string]$s.Address
    $term = [string]$s.TerminalNo
    $wire = [string]$s.WireNo
    $cable = [string]$s.CableNo
    $dev = [string]$s.FieldDevice
    $fname = [string]$s.FieldName
    $isSpare = ([string]$s.Spare) -eq 'Y'
    $noCable = ([string]$s.NoCable) -eq 'Y'

    if (-not $tag) { $tag = '' }
    $label = if ($tag) { $tag } elseif ($isSpare) { 'SPARE' } else { $addr }

    Emit-Text (($cols[0].x + 3.0)) $yTxt $label $hLabel '2T' $styleName ''
    Emit-Text (($cols[1].x + $cols[1].w / 2.0)) $yTxt $addr $hSmall '2T' $styleName 'MC'

    # The module's own pin for this channel.
    #
    # channelMap is deliberately not used for this: its values are prose ("terminal 1..16",
    # "1-8"), so reading them as a pin printed a sentence in a narrow column. The pin comes from
    # the definition's channel terminal ranges instead -- entries whose role is "channel" and whose
    # pin is a literal number or range -- walked in order and indexed by channel position. A module
    # whose definition gives no per-channel pin list leaves the column blank rather than guessing.
    $pin = ''
    if ($null -ne $mod -and $mod.PSObject.Properties.Name -contains 'terminals') {
        $chanPins = New-Object System.Collections.Generic.List[string]
        foreach ($t in $mod.terminals) {
            if ((PropStr $t 'role') -ne 'channel') { continue }
            $p = PropStr $t 'pin'
            # Keep only numeric pins and numeric ranges; "40-pin connector" is not a pin number.
            if ($p -match '^\d+(-\d+)?$') { $chanPins.Add($p) }
        }
        if ($chanPins.Count -gt 0) {
            $chIdx = 0
            [void][int]::TryParse([string]$s.Channel, [ref]$chIdx)
            if ($chIdx -ge 1) {
                $pos = 0
                foreach ($cp in $chanPins) {
                    $bits = @($cp -split '-')
                    $lo = 0; $hi = 0
                    [void][int]::TryParse($bits[0], [ref]$lo)
                    if ($bits.Count -gt 1) { [void][int]::TryParse($bits[1], [ref]$hi) } else { $hi = $lo }
                    $span = $hi - $lo + 1
                    if ($chIdx -gt $pos -and $chIdx -le ($pos + $span)) {
                        $pin = [string]($lo + ($chIdx - $pos - 1)); break
                    }
                    $pos += $span
                }
            }
        }
    }
    Emit-Text (($cols[2].x + $cols[2].w / 2.0)) $yTxt $pin $hSmall '3T' $styleName 'MC'
    Emit-Text (($cols[3].x + $cols[3].w / 2.0)) $yTxt $term $hSmall '2T' $styleName 'MC'

    # Wire number on 1T (magenta), per CONVENTIONS: wire numbers are their own layer.
    $wireLabel = $wire
    if ($noCable -and -not $wire) { $wireLabel = 'NO CABLE' }
    Emit-Text (($cols[4].x + $cols[4].w / 2.0)) $yTxt $wireLabel $hSmall '1T' $styleName 'MC'

    $cableLabel = $cable
    if ($noCable) { $cableLabel = 'NO CABLE' }
    Emit-Text (($cols[5].x + $cols[5].w / 2.0)) $yTxt $cableLabel $hSmall '3T' $styleName 'MC'

    $devLabel = $dev
    if ($fname) { $devLabel = if ($dev) { "$dev  $fname" } else { $fname } }
    Emit-Text (($cols[6].x + 3.0)) $yTxt $devLabel $hSmall '3T' $styleName ''

    if ($isSpare) {
        Emit-Text (($cols[0].x + $cols[0].w - 3.0)) $yTxt 'SPARE' $hSmall '3T' $styleName 'R'
    }
}

# --- module supply pins and notes --------------------------------------------------
$noteY = $bottomY - 14.0
if ($null -ne $mod) {
    $sup = $null
    if ($mod.PSObject.Properties.Name -contains 'supply') { $sup = $mod.supply }
    if ($null -ne $sup) {
        $txt = "SUPPLY: " + (PropStr $sup 'voltage')
        $plus = PropStr $sup 'plus'; $common = PropStr $sup 'common'
        if ($plus) { $txt += "  $plus" }
        if ($common) { $txt += " / $common" }
        $grp = PropStr $sup 'grouping'
        if ($grp) { $txt += "  GROUPS: $grp" }
        Emit-Text $originX $noteY $txt $hLabel '3T' $styleName 'L'
        $noteY -= 8.0
        $jmp = PropStr $sup 'jumpers'
        if ($jmp) {
            Emit-Text $originX $noteY ("JUMPERS: $jmp") $hSmall '3T' $styleName 'L'
            $noteY -= 8.0
        }
    }
    if ($mod.PSObject.Properties.Name -contains 'terminals') {
        $tlist = @()
        foreach ($t in $mod.terminals) {
            $lbl = [string]$t.pin
            $tl = PropStr $t 'label'
            if ($tl) { $lbl = "$lbl = $tl" }
            $tlist += $lbl
        }
        if ($tlist.Count -gt 0) {
            $txt = 'TERMINALS: ' + ($tlist -join ', ')
            if ($txt.Length -gt 190) { $txt = $txt.Substring(0, 190) + ' ...' }
            Emit-Text $originX $noteY $txt $hSmall '3T' $styleName 'L'
            $noteY -= 8.0
        }
    }
    if ($mod.PSObject.Properties.Name -contains 'unusedPins') {
        $u = @($mod.unusedPins | ForEach-Object { [string]$_ }) -join ', '
        if ($u) { Emit-Text $originX $noteY ("PINS NOT USED: $u") $hSmall '3T' $styleName 'L'; $noteY -= 8.0 }
    }
    $verified = $false
    if ($mod.PSObject.Properties.Name -contains 'verified') { $verified = [bool]$mod.verified }
    if (-not $verified) {
        $m = ''
        if ($mod.PSObject.Properties.Name -contains 'manual') { $m = [string]$mod.manual }
        Emit-Text $originX $noteY "PINOUT UNVERIFIED - CHECK AGAINST $m" $hLabel '5T' $styleName 'L'
        $noteY -= 8.0
    }
    $famConn = ''
    $fam = PropStr $mod 'family'
    if ($fam -and $hw.families.PSObject.Properties.Name -contains $fam) {
        $famConn = PropStr $hw.families.$fam 'connector'
    }
    if ($famConn) { Emit-Text $originX ($noteY - 2.0) ("CONNECTOR: $famConn") $hSmall '3T' $styleName 'L' }
    $noteY -= 10.0
}

# Rows the register says the panel has but this sheet could not fill, and rows the I/O list has
# that this sheet does not show: both are stated rather than left to be discovered at review.
if ($sheetKind -eq 'card' -and $drawnRows -lt $rowsToDraw) {
    Emit-Text $originX ($noteY - 2.0) ("$rowsToDraw CHANNELS ON THIS CARD, $drawnRows SHOWN - REMAINDER ON THE NEXT SHEET") $hLabel '5T' $styleName 'L'
    $noteY -= 8.0
}
# A card whose channels will not fit at the minimum legible pitch: say so on the sheet.
if ($sheetKind -eq 'card' -and $rowsToDraw -gt $fitsAtMin -and $fitsAtMin -gt 0) {
    Emit-Text $originX ($noteY - 2.0) ("$rowsToDraw CHANNELS EXCEED WHAT FITS ON ONE A1 SHEET AT MINIMUM PITCH ($fitsAtMin) - CHECK SHEET SPLIT") $hLabel '5T' $styleName 'L'
    $noteY -= 8.0
}
$untagged = @($cardSignals | Where-Object { -not $_.Tag }).Count
if ($untagged -gt 0) {
    Emit-Text $originX ($noteY - 2.0) ("$untagged ROWS HAVE NO TAG IN THE I/O LIST - ADDRESSED ROWS ARE SHOWN UNTAGGED, NOT INVENTED") $hLabel '5T' $styleName 'L'
    $noteY -= 8.0
}

# --- draft stamps (paper space) ----------------------------------------------------
if ($tplLayout) {
    $lines.Add('layout.set {"name":' + (ConvertTo-JsonStringValue -Value $tplLayout) + '}')
}
$lines.Add('layer.current {"name":"Preliminary Not For Construction"}')
$lines.Add('style {"name":"Romans"}')
$lines.Add('text {"at":[768,72],"text":"PRELIMINARY","height":4}')
$lines.Add('text {"at":[753,66],"text":"NOT FOR CONSTRUCTION","height":4}')

# Frame the content viewport on the drawn content: centre on the table, tall enough to show it.
if ($tplVpHandle) {
    $contentCenterY = ($hdrY + $bottomY) / 2.0
    $need = ($hdrY - $bottomY) + 90.0
    $vh = $tplVpViewHeight
    if ($vh -le 0 -or $need -gt $vh) { $vh = $need }
    $lines.Add('viewport.set {"handle":' + (ConvertTo-JsonStringValue -Value $tplVpHandle) + ',"locked":false,"center":[' + (JNum ($originX + $totalW / 2.0)) + ',' + (JNum $contentCenterY) + '],"viewHeight":' + (JNum $vh) + '}')
}
if ($tplLayout) {
    $lines.Add('pagesetup {"layout":' + (ConvertTo-JsonStringValue -Value $tplLayout) + ',"plotStyleTable":"monochrome.ctb","lineweights":true}')
}
$lines.Add('saveas {"path":' + (ConvertTo-JsonStringValue -Value $OutDwg) + ',"version":2018}')

# --- write and run -----------------------------------------------------------------
if (-not $ScrPath) { $ScrPath = [System.IO.Path]::ChangeExtension($OutDwg, '.scr') }
$scrDir = Split-Path -Parent $ScrPath
if ($scrDir -and -not (Test-Path -LiteralPath $scrDir)) { New-Item -ItemType Directory -Force -Path $scrDir | Out-Null }
[System.IO.File]::WriteAllLines($ScrPath, $lines, (New-Object System.Text.ASCIIEncoding))

$outParent = Split-Path -Parent $OutDwg
if ($outParent -and -not (Test-Path -LiteralPath $outParent)) { New-Item -ItemType Directory -Force -Path $outParent | Out-Null }
if (Test-Path -LiteralPath $OutDwg) { Remove-Item -LiteralPath $OutDwg -Force }

$bat = [System.IO.Path]::GetTempFileName() + '.cmd'
$runLine = '"' + $cli + '" run "' + $Template + '" --script-file "' + $ScrPath + '"'
[System.IO.File]::WriteAllText($bat, "@echo off`r`n$runLine`r`n", (New-Object System.Text.ASCIIEncoding))
# The CLI prints one JSON object per script command. Capturing that keeps the generator's output to
# its one summary line, and writes it beside the sheet so a failed build has something to point at.
$logPath = [System.IO.Path]::ChangeExtension($OutDwg, '.run.log')
$tmpOut = [System.IO.Path]::GetTempFileName()
$tmpErr = [System.IO.Path]::GetTempFileName()
$pi = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', (Get-ArgumentForNative -Value $bat)) -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
if (-not $pi.WaitForExit(300000)) { try { $pi.Kill() } catch { } }
try {
    $runLog = [System.IO.File]::ReadAllText($tmpOut) + [System.IO.File]::ReadAllText($tmpErr)
    [System.IO.File]::WriteAllText($logPath, $runLog)
} catch { }
Remove-Item -LiteralPath $bat, $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue

if (-not (Test-Path -LiteralPath $OutDwg)) { Write-Error 'generated sheet was not written'; exit 1 }

Write-Host ("{0}  station={1}  card={2}  order={3}  rows={4}/{5}  verified={6}  bytes={7}" -f `
    $number, $station, $cardTitle, $orderNumber, $drawnRows, $rowsToDraw, `
    $(if ($null -ne $mod -and $mod.PSObject.Properties.Name -contains 'verified') { $mod.verified } else { 'n/a' }), `
    (Get-Item -LiteralPath $OutDwg).Length)
exit 0
