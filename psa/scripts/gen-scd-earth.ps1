# gen-scd-earth.ps1 -- build a PANEL EARTHING SCHEMATIC from the order schedule.
#
# The companion to gen-scd-power.ps1, and the producer for the "PANEL SCHEMATIC DIAGRAM" half of the
# schematic discipline. It is not a free-form wiring diagram: a panel earthing schematic is a regular
# structure -- a horizontal earth bar with numbered ways along it, and each earthed item in the panel
# (enclosure body, door strap, SPD, power supply, service socket, PLC DIN rail, switches) drawn as a
# box above the bar with a labelled earth conductor dropping to its own way. That regularity is what
# makes it producible from data.
#
# Geometry measured from the reference job's earthing schematic (model units on the A1):
#   earth bar        rectangle x 200..650, y 250..264           (layer 3C)
#   ways             circles r3 at y 257, x 225,275,... 50 pitch (layer 3C, number as text above)
#   item boxes       rectangles ~46 wide, two staggered levels    (layer 1C)
#   incoming PE box  x 60..110, y 395..445, with the X1 circle    (layer 2C)
#   earth symbol     three decreasing horizontal lines            (layer 3C)
#   wire labels      E/n and FE/n with the conductor size, per the convention
#
# The earthed items come from the panel's order schedule, classified by role the same way the power
# schematic does (SPD, PSU, switch, plus the fixed panel items: enclosure body, door strap, service
# socket, PLC DIN rail). Conductor sizes follow the house rule (6 mm2 for the enclosure/chassis
# protective earths, 2.5 mm2 for equipment and functional earths); where the reference left a size
# "TBC" the sheet says so rather than inventing one.
#
# Inputs (all read, none written):
#   -Template, -PlanCsv, -DrawingNumber   the sheet identity from the register.
#   -OrderScheduleCsv                     the panel's devices, to decide which items are earthed.
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
if ($null -eq $row) { $row = $plan | Where-Object { $_.Discipline -eq 'SCD' -and $_.Title -notmatch 'POWER DISTRIBUTION' } | Select-Object -First 1 }
if ($null -eq $row) { throw 'no panel-schematic SCD row found in the plan.' }
$number = [string]$row.Number
$station = [string]$row.Station
$title = [string]$row.Title
$rev = [string]$row.Revision
if (-not $rev) { $rev = 'A' }

$hw = Get-Content -LiteralPath $HardwareJson -Raw | ConvertFrom-Json

# --- the panel's devices from the order schedule -------------------------------------
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

# The earthed items. Every panel has the fixed set (enclosure body, door strap, PLC DIN rail/chassis,
# service socket); the order schedule adds the equipment that needs an earth (SPD, PSU, switches).
# Each item carries its conductor: protective earth (E/n) at 6 mm2 for chassis/enclosure, 2.5 mm2 for
# equipment; functional earth (FE/n) at 2.5 mm2. Sizes follow the house rule; a size the reference left
# to be confirmed is marked TBC, not invented.
$items = New-Object System.Collections.Generic.List[object]
$items.Add([pscustomobject]@{ Label = 'ENCLOSURE BODY EARTH STUD'; Kind = 'E'; Size = '6mm2 (TBC)'; Wire = '' })
$items.Add([pscustomobject]@{ Label = 'DOOR EARTH STRAP'; Kind = 'E'; Size = '6mm2 FLEX'; Wire = '' })
$hasSPD = $false; $hasPSU = $false; $hasSwitch = $false
foreach ($ln in $panelLines) {
    $desc = ([string]$ln.PSObject.Properties['Description'].Value).ToUpperInvariant()
    if ($desc -match 'SURGE|SPD') { $hasSPD = $true }
    if ($desc -match 'SITOP|PSU|POWER SUPPLY|PM1507') { $hasPSU = $true }
    if ($desc -match 'SWITCH|IE SW|MANAGED|INDUSTRIAL ETHERNET|ETHERNET SWITCH') { $hasSwitch = $true }
}
if ($hasSPD) { $items.Add([pscustomobject]@{ Label = 'SPD PE'; Kind = 'E'; Size = '6mm2'; Wire = '' }) }
$items.Add([pscustomobject]@{ Label = 'SERVICE SOCKET E'; Kind = 'E'; Size = '2.5mm2'; Wire = '' })
if ($hasPSU) { $items.Add([pscustomobject]@{ Label = 'PSU PE'; Kind = 'E'; Size = '2.5mm2'; Wire = '' }) }
$items.Add([pscustomobject]@{ Label = 'PLC DIN RAIL CHASSIS'; Kind = 'FE'; Size = '2.5mm2'; Wire = '' })
if ($hasSwitch) { $items.Add([pscustomobject]@{ Label = 'SWITCH FE'; Kind = 'FE'; Size = '2.5mm2'; Wire = '' }) }
$items.Add([pscustomobject]@{ Label = 'SCREEN EARTH TERMINALS'; Kind = 'FE'; Size = '2.5mm2'; Wire = '' })

# Number the conductors: E/1.. for protective, FE/1.. for functional, in item order. The number is
# baked into the item when it is built (StrictMode will not let a property be added to a fixed
# pscustomobject afterwards).
$eSeq = 0; $feSeq = 0
foreach ($it in $items) {
    if ($it.Kind -eq 'E') { $eSeq++; $it.Wire = "E/$eSeq" }
    else { $feSeq++; $it.Wire = "FE/$feSeq" }
}
$eTotal = $eSeq; $feTotal = $feSeq

# --- layout constants (model units, matching the reference) ------------------------
$barX0 = 200.0; $barX1 = 650.0
$barTopY = 264.0; $barBotY = 250.0
$wayY = 257.0
$wayX0 = 225.0; $wayPitch = 50.0
$boxW = 46.0; $boxH = 40.0
$upperY = 462.0; $lowerY = 418.0     # the two staggered box levels (box top)
$dropTopY = 418.0                     # where the conductor drops start
$wireLabelY = 300.0
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
function Emit-Circle([double]$cx, [double]$cy, [double]$r, [string]$Layer) {
    Emit-Layer $Layer
    $script:lines.Add('circle {"center":[' + (JNum $cx) + ',' + (JNum $cy) + '],"radius":' + (JNum $r) + '}')
}
function Emit-Rect([double]$x, [double]$y, [double]$w, [double]$h, [string]$Layer) {
    Emit-Line $x $y ($x + $w) $y $Layer
    Emit-Line ($x + $w) $y ($x + $w) ($y + $h) $Layer
    Emit-Line ($x + $w) ($y + $h) $x ($y + $h) $Layer
    Emit-Line $x ($y + $h) $x $y $Layer
}
function Emit-Text([double]$x, [double]$y, [string]$Text, [double]$Height, [string]$Layer, [string]$Justify) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    Emit-Layer $Layer
    $script:lines.Add('style.current {"name":' + (ConvertTo-JsonStringValue -Value $styleName) + '}')
    $j = ''
    if ($Justify) { $j = ',"justify":"' + $Justify + '"' }
    $script:lines.Add('text {"at":[' + (JNum $x) + ',' + (JNum $y) + '],"text":' + (ConvertTo-JsonStringValue -Value $Text) + ',"height":' + (JNum $Height) + $j + '}')
}
function Emit-Earth([double]$x, [double]$y, [string]$Layer) {
    Emit-Line $x $y $x ($y + 8.0) $Layer
    Emit-Line ($x - 8.0) ($y + 8.0) ($x + 8.0) ($y + 8.0) $Layer
    Emit-Line ($x - 5.0) ($y + 11.0) ($x + 5.0) ($y + 11.0) $Layer
    Emit-Line ($x - 2.0) ($y + 14.0) ($x + 2.0) ($y + 14.0) $Layer
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
Emit-Text 40.0 560.0 'PANEL EARTHING' $hHead '5T' 'L'

# --- incoming PE box (left) --------------------------------------------------------
Emit-Rect 60.0 395.0 50.0 50.0 '2C'
Emit-Text 85.0 428.0 'INCOMING' $hSmall '1T' 'MC'
Emit-Text 85.0 422.0 'PE' $hSmall '1T' 'MC'
Emit-Circle 85.0 420.0 8.0 '1C'
Emit-Text 211.0 342.0 'X1' $hLabel '1T' 'L'
# incoming conductor runs right then down to way 1
Emit-Line 110.0 420.0 225.0 420.0 '3C'
Emit-Line 225.0 420.0 225.0 ($barTopY) '3C'
Emit-Text 228.0 375.0 'E' $hSmall '1T' 'L'
Emit-Text 228.0 368.0 'FLEX GNYE, SIZE TBC' $hSmall '3T' 'L'

# --- the earth bar -----------------------------------------------------------------
Emit-Rect $barX0 $barBotY ($barX1 - $barX0) ($barTopY - $barBotY) '3C'
# The way count in the bar's own label is the number of ways actually drawn, not a fixed "1-9" (a
# panel with 7 earthed items has a 7-way bar; a label claiming 9 ways on a 7-way bar is a defect).
Emit-Text 425.0 240.0 ("EARTH BAR  1-{0} WAY 63A" -f $items.Count) $hLabel '1T' 'MC'
Emit-Earth 425.0 221.0 '3C'

# --- section headers (PE / FE) -----------------------------------------------------
# Each header is centred over the ways it actually covers: protective earth over ways 1..eTotal,
# functional earth over the next feTotal ways.
if ($eTotal -gt 0) {
    $peMidX = $wayX0 + (($eTotal - 1) * $wayPitch / 2.0)
    Emit-Text $peMidX 545.0 'PROTECTIVE EARTH' $hLabel '2T' 'MC'
}
if ($feTotal -gt 0) {
    $feMidX = $wayX0 + (($eTotal + ($feTotal - 1) / 2.0) * $wayPitch)
    Emit-Text $feMidX 545.0 'FUNCTIONAL EARTH' $hLabel '2T' 'MC'
}

# --- item boxes and drops ----------------------------------------------------------
# Place items across the two staggered levels, one per way, and drop each to its way.
$wayN = 0
for ($i = 0; $i -lt $items.Count; $i++) {
    $it = $items[$i]
    $wayN++
    $wx = $wayX0 + ($wayN - 1) * $wayPitch
    if ($wx -gt $barX1) { break }   # more items than ways: reported below
    # box alternates upper/lower level
    $boxTopY = if (($i % 2) -eq 0) { $upperY } else { $lowerY }
    $boxX = $wx - ($boxW / 2.0)
    Emit-Rect $boxX $boxTopY $boxW $boxH '1C'
    # item label inside the box, wrapped over two lines on a space
    $lab = $it.Label
    $lines.Add('style.current {"name":' + (ConvertTo-JsonStringValue -Value $styleName) + '}')
    $words = $lab -split ' '
    $l1 = ''; $l2 = ''
    foreach ($wd in $words) {
        if (($l1 + ' ' + $wd).Trim().Length -le 12 -and $l2 -eq '') { $l1 = ($l1 + ' ' + $wd).Trim() }
        else { $l2 = ($l2 + ' ' + $wd).Trim() }
    }
    Emit-Text $wx ($boxTopY + $boxH - 12.0) $l1 $hSmall '1T' 'MC'
    Emit-Text $wx ($boxTopY + $boxH - 20.0) $l2 $hSmall '1T' 'MC'
    # conductor drop from the box bottom to the way
    $dropFromY = if (($i % 2) -eq 0) { $upperY } else { $lowerY }
    Emit-Line $wx $dropFromY $wx $barTopY '3C'
    Emit-Text ($wx + 2.0) ($wireLabelY + 7.0) $it.Wire $hSmall '1T' 'L'
    Emit-Text ($wx + 2.0) ($wireLabelY) ("GNYE " + $it.Size) $hSmall '3T' 'L'
    # the way circle and number
    Emit-Circle $wx $wayY 3.0 '3C'
    Emit-Text $wx ($wayY + 6.0) ([string]$wayN) $hLabel '3T' 'MC'
}
$placedItems = $wayN
$unplacedItems = $items.Count - $placedItems
if ($unplacedItems -gt 0) {
    Emit-Text $barX0 200.0 ("$($items.Count) EARTHED ITEMS, $([math]::Floor(($barX1-$barX0)/$wayPitch)+1) WAYS ON THE BAR - $unplacedItems NOT CONNECTED, CHECK BAR SIZE") $hLabel '5T' 'L'
}

# --- cable screens + notes ---------------------------------------------------------
Emit-Text 60.0 180.0 'CABLE SCREENS' $hLabel '1T' 'L'
$cy = 172.0
foreach ($n in @('4-20mA SIGNAL SCREENS TO SCREEN EARTH TERMINALS', 'DIGITAL SIGNAL SCREENS TO SCREEN EARTH TERMINALS', 'ETHERNET SCREENS BONDED AT BOTH ENDS')) {
    Emit-Text 60.0 $cy $n $hSmall '3T' 'L'
    $cy -= 8.0
}
Emit-Text 500.0 180.0 'NOTES' $hLabel '1T' 'L'
$ny = 172.0
foreach ($n in @('EARTH STUDS AND DOOR STRAP PER MANUFACTURER', 'CONDUCTOR SIZES PER EARTHING SCHEDULE', 'SIZES MARKED TBC TO BE CONFIRMED ON SITE', 'FUNCTIONAL EARTH SEPARATE FROM PROTECTIVE EARTH')) {
    Emit-Text 500.0 $ny $n $hSmall '3T' 'L'
    $ny -= 8.0
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
    $lines.Add('viewport.set {"handle":' + (ConvertTo-JsonStringValue -Value $tplVpHandle) + ',"center":[360,360],"viewHeight":480}')
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
Write-Host ("{0}  station={1}  items={2}  ways={3}  bytes={4}  exit={5}" -f `
        $number, $station, $items.Count, $placedItems, $bytes, $exit)
if ($exit -ne 0 -or $bytes -eq 0) { exit 1 }
exit 0
