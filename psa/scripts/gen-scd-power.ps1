# gen-scd-power.ps1 -- build a PANEL POWER DISTRIBUTION SCHEMATIC from the order schedule.
#
# The producer for the power half of the schematic discipline. A power distribution schematic is a
# radial tree, not a free-form wiring diagram: a supply enters top-left, passes a surge protector and a
# main switch, lands on an AC bus, and drops a branch per outgoing circuit (a breaker feeding a load).
# The 24 VDC side repeats the pattern below it: the power supply feeds a DC bus that drops a branch per
# 24 V circuit. That regularity is what makes it producible from data; the I/O signal schematic (the
# other half of the discipline) is a per-card wiring diagram and is not attempted here.
#
# Geometry and symbols follow the reference job's power schematic: a horizontal bus with vertical drops,
# IEC breaker (a switch line with a trip cross), fuse (a rectangle on the line), and earth symbols drawn
# as line geometry on the schematic layers, wire numbers per the convention (net name plus sequence,
# A1/N1 in, A2/N2 on the bus, A3/N3, A4/N4 ... down the branches; 24V/n and 0V/n on the DC side).
#
# The branches are driven by the panel's order schedule: the breakers, fuses, power supply and switches
# it buys. Spares are drawn as spare branches (a spare capacity is shown on the drawings, never
# deleted), so the sheet shows what the panel can feed, not only what is connected today.
#
# Inputs (all read, none written):
#   -Template, -PlanCsv, -DrawingNumber   the sheet identity from the register.
#   -OrderScheduleCsv                     the panel's power devices.
#   -HardwareJson                         module definitions (a friendly label per part).
#
# Output: a cadcraft .scr, the generated DWG, and a .run.log beside it.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Template,
    [Parameter(Mandatory = $true)][string]$OutDwg,
    [Parameter(Mandatory = $true)][string]$HardwareJson,
    [Parameter(Mandatory = $true)][string]$PlanCsv,
    [Parameter(Mandatory = $true)][string]$OrderScheduleCsv,
    [string]$DrawingNumber,
    [string]$ScrPath,
    [string]$ProjectNumber = '',
    [string]$Scope1 = '',
    [string]$Scale = 'NTS',
    [string]$DrawnBy = 'PSA FUSION',
    [string]$DrawnDate = '',
    [string]$LayoutName = ''
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
    $esc = $esc -replace '\r', ' '
    $esc = $esc -replace "`n", ' '
    return '"' + $esc + '"'
}
function JNum($v) { return ([double]$v).ToString([System.Globalization.CultureInfo]::InvariantCulture) }
function PropStr($obj, [string]$name) {
    if ($null -eq $obj) { return '' }
    if ($obj -is [System.Management.Automation.PSCustomObject] -and -not ($obj.PSObject.Properties.Name -contains $name)) { return '' }
    try { $v = $obj.$name } catch { return '' }
    if ($null -eq $v) { return '' }
    return [string]$v
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
        if ($pi.ExitCode -ne 0) { return $null }
        $text = [System.IO.File]::ReadAllText($tmpOut)
        $jsonLines = @($text -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') -or $_.Trim().StartsWith('[') })
        if ($jsonLines.Count -eq 0) { return $null }
        try { return ($jsonLines[-1] | ConvertFrom-Json) } catch { return $null }
    } catch { return $null } finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr, $bat -Force -ErrorAction SilentlyContinue
    }
}
function Norm-Station([string]$s) {
    if ($null -eq $s) { return '' }
    $t = ($s.ToUpperInvariant() -replace '[^A-Z0-9]', '')
    $t = $t -replace 'REMOTEIO$', ''
    return $t
}

foreach ($p in @($Template, $HardwareJson, $PlanCsv, $OrderScheduleCsv)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "no such file: $p" }
}
$cli = Resolve-CadcraftCli

# --- the plan row ------------------------------------------------------------------
$plan = @(Import-Csv -LiteralPath $PlanCsv)
$row = $null
if ($DrawingNumber) { $row = $plan | Where-Object { $_.Number -eq $DrawingNumber } | Select-Object -First 1 }
if ($null -eq $row) { $row = $plan | Where-Object { $_.Discipline -eq 'SCD' -and $_.Title -match 'POWER DISTRIBUTION' } | Select-Object -First 1 }
if ($null -eq $row) { throw 'no power-distribution SCD row found in the plan.' }
$number = [string]$row.Number
$station = [string]$row.Station
$title = [string]$row.Title
$rev = [string]$row.Revision
if (-not $rev) { $rev = 'A' }

# --- hardware ----------------------------------------------------------------------
$hw = Get-Content -LiteralPath $HardwareJson -Raw | ConvertFrom-Json

# --- the panel's power devices from the order schedule -----------------------------
$osLines = @(Get-Content -LiteralPath $OrderScheduleCsv)
$hdrIdx = -1
for ($i = 0; $i -lt [math]::Min(6, $osLines.Count); $i++) {
    if ($osLines[$i] -match '(?i)part number' -and $osLines[$i] -match '(?i)panel') { $hdrIdx = $i; break }
}
if ($hdrIdx -lt 0) { throw 'order schedule header not found in the first 6 lines.' }
$osTmp = [System.IO.Path]::GetTempFileName() + '.csv'
try {
    $body = @($osLines[$hdrIdx..($osLines.Count - 1)])
    [System.IO.File]::WriteAllLines($osTmp, $body, (New-Object System.Text.UTF8Encoding($false)))
    $osRows = @(Import-Csv -LiteralPath $osTmp)
} finally { Remove-Item -LiteralPath $osTmp -Force -ErrorAction SilentlyContinue }

$panelKey = Norm-Station $station
$loose = $panelKey -replace 'REMOTEIO', ''
$panelLines = @($osRows | Where-Object {
    $pk = Norm-Station ([string]$_.PSObject.Properties['Panel'].Value)
    ($pk -eq $panelKey) -or ($loose -and ($pk -like "*$loose*"))
})

# Classify the panel's devices into the roles a power schematic shows. The order schedule descriptions
# carry the role words; matching on them is how the generator knows what feeds what.
$acBreakers = New-Object System.Collections.Generic.List[object]
$fuses = New-Object System.Collections.Generic.List[object]
$psus = New-Object System.Collections.Generic.List[object]
$switches = New-Object System.Collections.Generic.List[object]
$spds = New-Object System.Collections.Generic.List[object]
foreach ($ln in $panelLines) {
    $part = ([string]$ln.PSObject.Properties['Part number'].Value) -replace '\s', ''
    $desc = [string]$ln.PSObject.Properties['Description'].Value
    $qty = 1
    [void][int]::TryParse([string]$ln.PSObject.Properties['Qty'].Value, [ref]$qty)
    if ($qty -lt 1) { $qty = 1 }
    $d = $desc.ToUpperInvariant()
    $role = ''
    if ($d -match 'SURGE|SPD') { $role = 'spd' }
    elseif ($d -match 'SITOP|PSU|POWER SUPPLY') { $role = 'psu' }
    elseif ($d -match 'FUSE|SILIZER|NEOZED') { $role = 'fuse' }
    elseif ($d -match 'MICRO|MCB|CIRCUIT BREAK|BREAKER|3RV|5SY') { $role = 'breaker' }
    elseif ($d -match 'DISCONNECT|SWITCH|ISOLAT') { $role = 'switch' }
    if (-not $role) { continue }
    $item = [pscustomobject]@{ Part = $part; Qty = $qty; Desc = $desc; Role = $role }
    switch ($role) {
        'spd' { for ($k = 0; $k -lt $qty; $k++) { $spds.Add($item) } }
        'psu' { for ($k = 0; $k -lt $qty; $k++) { $psus.Add($item) } }
        'fuse' { for ($k = 0; $k -lt $qty; $k++) { $fuses.Add($item) } }
        'breaker' { for ($k = 0; $k -lt $qty; $k++) { $acBreakers.Add($item) } }
        'switch' { for ($k = 0; $k -lt $qty; $k++) { $switches.Add($item) } }
    }
}

# --- layout constants (model units on the A1, matching the reference schematic) -----
$originX = 120.0
$acBusY = 470.0
$dcBusY = 250.0
$branchPitch = 55.0
$busX0 = 260.0
$hSmall = 2.5; $hLabel = 3.5; $hHead = 5.0
$styleName = 'isocp2'

# --- build the script --------------------------------------------------------------
$lines = New-Object System.Collections.Generic.List[string]
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
function Emit-Text([double]$x, [double]$y, [string]$Text, [double]$Height, [string]$Layer, [string]$Justify) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    Emit-Layer $Layer
    $script:lines.Add('style.current {"name":' + (ConvertTo-JsonStringValue -Value $styleName) + '}')
    $j = ''
    if ($Justify) { $j = ',"justify":"' + $Justify + '"' }
    $script:lines.Add('text {"at":[' + (JNum $x) + ',' + (JNum $y) + '],"text":' + (ConvertTo-JsonStringValue -Value $Text) + ',"height":' + (JNum $Height) + $j + '}')
}
# An IEC breaker: a vertical line with a diagonal switch blade and a small trip cross.
function Emit-Breaker([double]$x, [double]$yTop, [string]$Tag, [string]$Layer) {
    Emit-Line $x $yTop $x ($yTop - 10.0) $Layer
    Emit-Line $x ($yTop - 10.0) ($x + 8.0) ($yTop - 24.0) $Layer   # blade
    Emit-Line $x ($yTop - 24.0) $x ($yTop - 34.0) $Layer
    Emit-Text ($x + 4.0) ($yTop - 18.0) $Tag $hLabel '2T' 'L'
}
# A fuse: a rectangle on the line.
function Emit-Fuse([double]$x, [double]$yTop, [string]$Tag, [string]$Layer) {
    Emit-Line $x $yTop $x ($yTop - 6.0) $Layer
    Emit-Line ($x - 4.0) ($yTop - 6.0) ($x + 4.0) ($yTop - 6.0) $Layer
    Emit-Line ($x + 4.0) ($yTop - 6.0) ($x + 4.0) ($yTop - 20.0) $Layer
    Emit-Line ($x + 4.0) ($yTop - 20.0) ($x - 4.0) ($yTop - 20.0) $Layer
    Emit-Line ($x - 4.0) ($yTop - 20.0) ($x - 4.0) ($yTop - 6.0) $Layer
    Emit-Line $x ($yTop - 20.0) $x ($yTop - 26.0) $Layer
    Emit-Text ($x + 6.0) ($yTop - 15.0) $Tag $hLabel '2T' 'L'
}
# An earth symbol: three horizontal lines of decreasing width.
function Emit-Earth([double]$x, [double]$y, [string]$Layer) {
    Emit-Line $x $y $x ($y - 8.0) $Layer
    Emit-Line ($x - 8.0) ($y - 8.0) ($x + 8.0) ($y - 8.0) $Layer
    Emit-Line ($x - 5.0) ($y - 11.0) ($x + 5.0) ($y - 11.0) $Layer
    Emit-Line ($x - 2.0) ($y - 14.0) ($x + 2.0) ($y - 14.0) $Layer
}

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

# --- heading -----------------------------------------------------------------------
# One heading line, not two stacked at the same height (the first version drew the sheet title and the
# section title at overlapping y, which rendered as garbled text).
Emit-Text $originX 508.0 'PANEL POWER DISTRIBUTION SCHEMATIC' $hHead '5T' 'L'
Emit-Text $originX 500.0 "$number  -  $station" $hLabel '5T' 'L'

# --- AC section --------------------------------------------------------------------
# The section title sits on its own line clear of the input labels below it. The first version put the
# section title and the A1/N1 labels at nearly the same y and x, so they rendered on top of each other.
Emit-Text $originX ($acBusY + 26.0) '240VAC SUPPLY AND DISTRIBUTION' $hLabel '2T' 'L'
# supply input: A1 / N1 / E into an SPD and a main switch, then the bus
$inX = $originX
Emit-Text $inX ($acBusY + 14.0) 'A1' $hLabel '1T' 'L'
Emit-Text ($inX + 14.0) ($acBusY + 14.0) 'N1' $hLabel '1T' 'L'
Emit-Line ($inX + 3.0) ($acBusY + 12.0) ($inX + 3.0) $acBusY '1C'
Emit-Line ($inX + 17.0) ($acBusY + 12.0) ($inX + 17.0) $acBusY '1C'
Emit-Earth ($inX + 30.0) ($acBusY + 12.0) '1C'
# main switch on the live line
$swTag = 'Q1'
if ($switches.Count -gt 0) { $swTag = 'Q1' }
Emit-Breaker ($inX + 3.0) ($acBusY - 2.0) $swTag '1C'
# the AC bus
$acBusX1 = $busX0 + [math]::Max(6, $acBreakers.Count) * $branchPitch
Emit-Line $busX0 $acBusY $acBusX1 $acBusY '1C'
Emit-Text ($busX0 + 4.0) ($acBusY + 4.0) 'A2' $hLabel '1T' 'L'
Emit-Text ($busX0 + 4.0) ($acBusY - 8.0) 'N2' $hLabel '1T' 'L'
# AC branches: one per breaker bought, plus spares to fill the row
$acBranches = $acBreakers.ToArray()
$spareAC = 0
$acSeq = 3
$bx = $busX0 + $branchPitch
$drawnAC = 0
foreach ($br in $acBranches) {
    $tag = 'Q' + ($drawnAC + 2)
    Emit-Line $bx $acBusY $bx ($acBusY - 6.0) '1C'
    Emit-Breaker $bx ($acBusY - 6.0) $tag '1C'
    Emit-Line $bx ($acBusY - 40.0) $bx ($acBusY - 55.0) '1C'
    Emit-Text ($bx + 3.0) ($acBusY - 48.0) ("A$acSeq") $hSmall '1T' 'L'
    Emit-Text ($bx + 3.0) ($acBusY - 53.0) ("N$acSeq") $hSmall '1T' 'L'
    $acSeq++; $bx += $branchPitch; $drawnAC++
}
# a fuse branch if the panel has fuses
foreach ($fz in ($fuses | Select-Object -First 4)) {
    Emit-Line $bx $acBusY $bx ($acBusY - 6.0) '1C'
    Emit-Fuse $bx ($acBusY - 6.0) ('F' + ($spareAC + 1)) '1C'
    Emit-Line $bx ($acBusY - 32.0) $bx ($acBusY - 55.0) '1C'
    $bx += $branchPitch; $spareAC++
}

# --- DC section --------------------------------------------------------------------
Emit-Text $originX ($dcBusY + 44.0) '24VDC DISTRIBUTION' $hLabel '2T' 'L'
# The power supply is fed from the AC bus and feeds the DC bus. Place it directly above the DC bus
# start so the connections are vertical and unambiguous: AC bus drops into the PSU top, the PSU bottom
# drops onto the DC bus. The first version placed the PSU at a different x from the bus and drew leads
# that reached neither, so the 24 V bus looked orphaned.
$psuCx = $busX0            # the PSU sits above the left end of the DC bus
$psuW = 44.0
$psuTop = $dcBusY + 40.0
$psuBot = $dcBusY + 20.0
$psuL = $psuCx - ($psuW / 2.0)
$psuR = $psuCx + ($psuW / 2.0)
# AC feed: from the AC bus (at the PSU's centre x) straight down into the PSU top.
$feedX = $psuCx
if ($feedX -lt $busX0) { $feedX = $busX0 + 2.0 }
if ($feedX -gt $acBusX1) { $feedX = $acBusX1 }
Emit-Line $feedX $acBusY $feedX $psuTop '1C'
if ($psus.Count -gt 0) {
    Emit-Line $psuL $psuTop $psuR $psuTop '1C'
    Emit-Line $psuR $psuTop $psuR $psuBot '1C'
    Emit-Line $psuR $psuBot $psuL $psuBot '1C'
    Emit-Line $psuL $psuBot $psuL $psuTop '1C'
    Emit-Text $psuCx ($psuBot + 7.0) 'PSU' $hLabel '2T' 'MC'
}
# PSU output: straight down from the PSU bottom onto the DC bus.
Emit-Line $psuCx $psuBot $psuCx $dcBusY '1C'
$dcBusX1 = $busX0 + [math]::Max(6, ($psus.Count + 4)) * $branchPitch
Emit-Line $busX0 $dcBusY $dcBusX1 $dcBusY '1C'
Emit-Text ($busX0 + 4.0) ($dcBusY + 4.0) '+24V' $hLabel '1T' 'L'
Emit-Text ($busX0 + 4.0) ($dcBusY - 8.0) '0V' $hLabel '1T' 'L'
# DC branches: PLC power, switch power, spares. Start one pitch right of the PSU feed so the first
# branch does not sit on top of the PSU's drop onto the bus.
$dcLabels = @('PLC MOD POWER', 'PLC SA POWER', 'SWITCH POWER', 'SPARE', 'SPARE', 'SPARE')
$dcSeq = 1
$bx = $busX0 + 2.0 * $branchPitch
foreach ($lab in $dcLabels) {
    Emit-Line $bx $dcBusY $bx ($dcBusY - 30.0) '1C'
    Emit-Text ($bx + 3.0) ($dcBusY - 16.0) ("24V/$dcSeq") $hSmall '1T' 'L'
    Emit-Text ($bx + 3.0) ($dcBusY - 22.0) ("0V/$dcSeq") $hSmall '1T' 'L'
    Emit-Text ($bx) ($dcBusY - 40.0) $lab $hSmall '2T' 'MC'
    $dcSeq++; $bx += $branchPitch
}

# --- the honest gap ----------------------------------------------------------------
# The AC branch circuits (the breakers and what each feeds) are electrical-distribution data. They are
# not in the automation order schedule, which lists modules, PSUs and switches -- not the panel's AC
# final circuits. So the AC bus is drawn but its outgoing branches cannot be populated from the data
# this generator has. Say so on the sheet rather than draw a bus that looks finished and is not.
if ($acBreakers.Count -eq 0) {
    Emit-Text $busX0 ($acBusY - 20.0) 'AC FINAL CIRCUITS NOT IN THE ORDER SCHEDULE - BRANCH COUNT AND RATINGS FROM THE ELECTRICAL BOM, TO BE ADDED' $hLabel '5T' 'L'
}

# --- notes -------------------------------------------------------------------------
Emit-Text ($acBusX1 + 20.0) 505.0 'NOTES' $hLabel '1T' 'L'
$ny = 498.0
foreach ($n in @('SUPPLY 240VAC FROM CLIENT GPO', 'SPD AND MAIN SWITCH AT ENTRY', 'SPARE BRANCHES PROVIDED FOR EXTENSION', 'EARTH PER EARTHING SCHEDULE')) {
    Emit-Text ($acBusX1 + 20.0) $ny $n $hSmall '3T' 'L'
    $ny -= 7.0
}

# --- draft stamps (paper space) ----------------------------------------------------
if ($tplLayout) {
    $lines.Add('layout.set {"name":' + (ConvertTo-JsonStringValue -Value $tplLayout) + '}')
}
$lines.Add('layer.current {"name":"Preliminary Not For Construction"}')
$lines.Add('style {"name":"Romans"}')
$lines.Add('text {"at":[768,72],"text":"PRELIMINARY","height":4}')
$lines.Add('text {"at":[753,66],"text":"NOT FOR CONSTRUCTION","height":4}')

# --- frame the content viewport ----------------------------------------------------
if ($tplLayout -and $tplVpHandle) {
    $lines.Add('layout.set {"name":' + (ConvertTo-JsonStringValue -Value $tplLayout) + '}')
    $lines.Add('viewport.set {"handle":' + (ConvertTo-JsonStringValue -Value $tplVpHandle) + ',"locked":false}')
    $lines.Add('viewport.set {"handle":' + (ConvertTo-JsonStringValue -Value $tplVpHandle) + ',"center":[420,300],"viewHeight":520}')
    $lines.Add('viewport.set {"handle":' + (ConvertTo-JsonStringValue -Value $tplVpHandle) + ',"locked":true}')
    $lines.Add('layout.set {"name":"Model"}')
}
$lines.Add('saveas {"path":' + (ConvertTo-JsonStringValue -Value $OutDwg) + ',"version":"2018"}')

# --- write and run -----------------------------------------------------------------
$scr = $ScrPath
if (-not $scr) { $scr = [System.IO.Path]::ChangeExtension($OutDwg, '.scr') }
$scrDir = Split-Path -Parent $scr
if ($scrDir -and -not (Test-Path -LiteralPath $scrDir)) { New-Item -ItemType Directory -Force -Path $scrDir | Out-Null }
[System.IO.File]::WriteAllLines($scr, $lines, (New-Object System.Text.ASCIIEncoding))
$outParent = Split-Path -Parent $OutDwg
if ($outParent -and -not (Test-Path -LiteralPath $outParent)) { New-Item -ItemType Directory -Force -Path $outParent | Out-Null }
if (Test-Path -LiteralPath $OutDwg) { Remove-Item -LiteralPath $OutDwg -Force }

$log = [System.IO.Path]::ChangeExtension($OutDwg, '.run.log')
$exit = 1
$bat = [System.IO.Path]::GetTempFileName() + '.cmd'
$tmpOut = [System.IO.Path]::GetTempFileName()
$tmpErr = [System.IO.Path]::GetTempFileName()
$runLine = '"' + $cli + '" run "' + $Template + '" --script-file "' + $scr + '"'
[System.IO.File]::WriteAllText($bat, "@echo off`r`n$runLine`r`n", (New-Object System.Text.ASCIIEncoding))
try {
    $p = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', (Get-ArgumentForNative -Value $bat)) `
            -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
    if (-not $p.WaitForExit(300000)) { try { $p.Kill() } catch { } }
    $exit = $p.ExitCode
} finally {
    try {
        $runLog = [System.IO.File]::ReadAllText($tmpOut) + [System.IO.File]::ReadAllText($tmpErr)
        [System.IO.File]::WriteAllText($log, $runLog)
    } catch { }
    Remove-Item -LiteralPath $bat, $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
}
$bytes = 0
if (Test-Path -LiteralPath $OutDwg) { $bytes = (Get-Item -LiteralPath $OutDwg).Length }
Write-Host ("{0}  station={1}  acBreakers={2}  fuses={3}  psus={4}  bytes={5}  exit={6}" -f `
        $number, $station, $acBreakers.Count, $fuses.Count, $psus.Count, $bytes, $exit)
if ($exit -ne 0 -or $bytes -eq 0) { exit 1 }
exit 0
