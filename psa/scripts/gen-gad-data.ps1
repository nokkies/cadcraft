# gen-gad-data.ps1 -- build a PLC panel GENERAL ARRANGEMENT FROM DATA.
#
# The producer counterpart of the TMD generator, for the other big discipline in a panel pack. A GA
# sheet is a placement diagram: the enclosure outline, the DIN rails inside it, and the modules the
# order schedule buys placed along those rails, each with its tag balloon and label. Nothing here is
# invented: the modules come from the job's order schedule, the sheet identity from the document
# register, and the geometry from the reference job's GA, measured and reproduced below.
#
# Geometry, measured from the reference GA (model space, drawn at 2.23 paper units per paper unit on
# an A1, so the enclosure is 800 x 1000 model units):
#   enclosure outer  0..800 x 0..1000        (layer 2C)
#   inner door frame 20..780 x 20..980       (layer 2H)
#   side view        x 930..950, y 0..1000   (the panel depth)
#   rails            three, x 110..760, at y 828/582/302 (34-tall strips, layer 2C)
#   module bands     y 800..900 / 555..655 / 275..375, modules 100 tall, 40-unit pitch, ~36 wide
#   labels           module name at h5.5 on 1T, just above each module
#   balloons         _TagCircle at scale 6 on 3C, item number as the TAGNUMBER attribute
#
# The reference draws module bodies as line rectangles (not block inserts), so this generator does the
# same: a rectangle per module on layer 1C, a label, and a balloon. That keeps the sheet faithful to
# how the house actually drafts a GA and avoids depending on module blocks that differ per vendor.
#
# Inputs (all read, none written):
#   -Template       the PSA blank sheet (A1 BORDER, A1 TITLE TEXT, layers, styles, content viewport).
#   -PlanCsv        the sheet plan; -DrawingNumber selects the GAD row.
#   -OrderScheduleCsv  the panel line items; the modules to place.
#   -HardwareJson   module definitions, used for a friendly label when the schedule description is raw.
#   -PanelCode      the order schedule's code for this panel (CEPIO, BUS1, ...). The register's
#                   station name and the schedule's panel code differ, so both are normalised to match.
#
# Output: a cadcraft .scr plus the generated DWG, and a .run.log beside it.

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
if ($null -eq $row) { $row = $plan | Where-Object { $_.Discipline -eq 'GAD' } | Select-Object -First 1 }
if ($null -eq $row) { throw 'no GAD row found in the plan.' }
$number = [string]$row.Number
$station = [string]$row.Station
$title = [string]$row.Title
$rev = [string]$row.Revision
if (-not $rev) { $rev = 'A' }

# --- hardware ----------------------------------------------------------------------
$hw = Get-Content -LiteralPath $HardwareJson -Raw | ConvertFrom-Json

# --- the panel's modules from the order schedule -------------------------------------
# The order schedule's header is not row 1 (row 1 is a title line), so Import-Csv would take the title
# as the column names and every lookup would come back empty. Find the header by content.
$osLines = @(Get-Content -LiteralPath $OrderScheduleCsv)
$hdrIdx = -1
for ($i = 0; $i -lt [math]::Min(6, $osLines.Count); $i++) {
    if ($osLines[$i] -match '(?i)part number' -and $osLines[$i] -match '(?i)panel') { $hdrIdx = $i; break }
}
if ($hdrIdx -lt 0) { throw 'order schedule header (with "part number" and "panel") not found in the first 6 lines.' }
$osTmp = [System.IO.Path]::GetTempFileName() + '.csv'
try {
    $body = @($osLines[$hdrIdx..($osLines.Count - 1)])
    [System.IO.File]::WriteAllLines($osTmp, $body, (New-Object System.Text.UTF8Encoding($false)))
    $osRows = @(Import-Csv -LiteralPath $osTmp)
} finally { Remove-Item -LiteralPath $osTmp -Force -ErrorAction SilentlyContinue }

$panelKey = Norm-Station $station
$panelLines = @($osRows | Where-Object { (Norm-Station ([string]$_.PSObject.Properties['Panel'].Value)) -eq $panelKey })
if ($panelLines.Count -eq 0) {
    # The schedule codes panels differently (CEPIO vs "CEP REMOTE I/O"); fall back to a contains match.
    $loose = $panelKey -replace 'REMOTEIO', ''
    $panelLines = @($osRows | Where-Object {
        $pk = Norm-Station ([string]$_.PSObject.Properties['Panel'].Value)
        ($loose -and ($pk -like "*$loose*"))
    })
}

# Which schedule lines are rail modules (a SIMATIC/ET200 part that occupies rail space) versus
# accessories (switches, power supplies, HMIs, patch panels). A module has a hardware definition; the
# rest are placed in a separate band. This keeps the rail to the cards the GA is about.
$modules = New-Object System.Collections.Generic.List[object]
$accessories = New-Object System.Collections.Generic.List[object]
foreach ($ln in $panelLines) {
    $part = ([string]$ln.PSObject.Properties['Part number'].Value) -replace '\s', ''
    $desc = [string]$ln.PSObject.Properties['Description'].Value
    $qty = 1
    [void][int]::TryParse([string]$ln.PSObject.Properties['Qty'].Value, [ref]$qty)
    if ($qty -lt 1) { $qty = 1 }
    if (-not $part) { continue }
    $isMod = ($hw.modules.PSObject.Properties.Name -contains $part)
    if ($isMod) {
        $m = $hw.modules.$part
        $modules.Add([pscustomobject]@{ Part = $part; Qty = $qty; Desc = $desc; Label = (PropStr $m 'cardTitle'); Kind = (PropStr $m 'kind') })
    } else {
        $accessories.Add([pscustomobject]@{ Part = $part; Qty = $qty; Desc = $desc })
    }
}

# --- layout constants (model units, matching the reference GA) ---------------------
$encX0 = 0.0; $encY0 = 0.0; $encX1 = 800.0; $encY1 = 1000.0
$doorX0 = 20.0; $doorY0 = 20.0; $doorX1 = 780.0; $doorY1 = 980.0
$sideX0 = 930.0; $sideX1 = 950.0
$railX0 = 110.0; $railX1 = 760.0
# Three rails, top to bottom. Each rail: the module band top y, and the label y.
$railTops = @(900.0, 655.0, 405.0)
$moduleH = 100.0
$modPitch = 40.0
$modW = 36.0
$labelDy = 45.0
$hLabel = 5.5; $hSmall = 6.0; $hHead = 9.0
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
$balloonCount = 0
function Emit-Balloon([double]$x, [double]$y, [string]$ItemNo) {
    $script:balloonCount++
    $script:lines.Add('insert {"name":"_TagCircle","at":[' + (JNum $x) + ',' + (JNum $y) + '],"scale":6,"attribs":{"TAGNUMBER":' + (ConvertTo-JsonStringValue -Value $ItemNo) + '}}')
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
Emit-Text 400.0 1030.0 'FRONT VIEW (DOOR REMOVED)' $hHead '1T' 'MC'
Emit-Text ($sideX0 + 10.0) 1030.0 'SIDE VIEW' $hHead '1T' 'MC'

# --- enclosure ---------------------------------------------------------------------
Emit-Rect $encX0 $encY0 ($encX1 - $encX0) ($encY1 - $encY0) '2C'
Emit-Rect $doorX0 $doorY0 ($doorX1 - $doorX0) ($doorY1 - $doorY0) '2H'
# side view (panel depth)
Emit-Rect $sideX0 $encY0 ($sideX1 - $sideX0) ($encY1 - $encY0) '2C'

# --- rails and modules -------------------------------------------------------------
# Lay modules across the rails in register order, wrapping to the next rail when one is full.
$placed = New-Object System.Collections.Generic.List[object]
$ri = 0
$cx = $railX0
$onRail = 0
$itemNo = 1
# Distribute the modules evenly across the rails rather than filling one then wrapping. The reference
# GA put 9 narrow terminal modules on a rail, but a real S7 CPU or power supply is far wider and its
# label needs room, so a fixed 40-unit pitch crammed 15 modules onto one rail with overlapping text.
# Target a per-rail count that leaves each module enough width for its label to read.
$totalMods = 0
foreach ($m in $modules) { $totalMods += $m.Qty }
$perRail = [math]::Max(1, [math]::Ceiling($totalMods / [double]$railTops.Count))
# Width per module: the rail width divided by the per-rail count, capped so a module stays a plausible
# DIN-rail proportion (taller than wide) and its label has somewhere to sit.
$slotW = [math]::Min(90.0, [math]::Floor(($railX1 - $railX0) / [double]$perRail))
if ($slotW -lt 40.0) { $slotW = 40.0 }
$modW2 = $slotW - 6.0   # a 6-unit gap between modules
foreach ($m in $modules) {
    for ($q = 0; $q -lt $m.Qty; $q++) {
        if ($ri -ge $railTops.Count) { break }   # more modules than rails: reported below
        if ($onRail -ge $perRail) { $ri++; $cx = $railX0; $onRail = 0 }
        if ($ri -ge $railTops.Count) { break }
        $bandTop = $railTops[$ri]
        $bandBottom = $bandTop - $moduleH
        Emit-Rect $cx $bandBottom $modW2 $moduleH '1C'
        $label = $m.Label
        if (-not $label) { $label = $m.Part }
        # A CPU's cardTitle is "CPU 1214C ONBOARD I/O"; on a GA the "ONBOARD I/O" is noise (the balloon
        # and the module body already say what it is), so drop it. The model number is the useful part.
        $label = $label -replace '\s+ONBOARD I/O$', ''
        # A label must fit inside its slot. isocp2 at height 5.5 is roughly 4.6 units per character
        # (measured: a 21-character label overflowed an 84-unit slot at the 3.4 estimate), so the
        # budget is the slot width over that. Truncate on a word boundary, not mid-word.
        $maxChars = [math]::Max(4, [math]::Floor(($modW2 - 6.0) / 4.6))
        if ($label.Length -gt $maxChars) {
            $cut = $label.Substring(0, $maxChars)
            $sp = $cut.LastIndexOf(' ')
            if ($sp -ge 4) { $cut = $cut.Substring(0, $sp) }
            $label = $cut
        }
        Emit-Text ($cx + ($modW2 / 2.0)) ($bandBottom + 55.0) $label $hLabel '1T' 'MC'
        Emit-Balloon ($cx + ($modW2 / 2.0)) ($bandTop + 12.0) ([string]$itemNo)
        $placed.Add([pscustomobject]@{ Rail = $ri; X = $cx; Part = $m.Part; Item = $itemNo })
        $itemNo++
        $cx += $slotW
        $onRail++
    }
}
# rail lines and labels
for ($r = 0; $r -lt $railTops.Count; $r++) {
    $bandTop = $railTops[$r]
    $bandBottom = $bandTop - $moduleH
    # the rail strip sits near the bottom of the band
    $railY = $bandBottom + 28.0
    Emit-Line $railX0 $railY $railX1 $railY '2C'
    Emit-Line $railX0 ($railY + 34.0) $railX1 ($railY + 34.0) '2C'
    Emit-Text 112.0 ($bandBottom - 12.0) ("RAIL " + ($r + 1)) $hSmall '1T' 'L'
}

# --- accessories band --------------------------------------------------------------
# Switches, power supplies and HMIs are not rail cards; list them as a note rather than placing them
# on the rails, so the GA stays a controller/IO layout and nothing bought is left off the sheet.
if ($accessories.Count -gt 0) {
    $ay = 150.0
    Emit-Text 112.0 $ay 'PANEL ACCESSORIES (SEE BOM SHEET FOR ITEM NUMBERS):' $hSmall '1T' 'L'
    $ay -= 20.0
    foreach ($a in $accessories) {
        $d = $a.Desc
        if ($d.Length -gt 70) { $d = $d.Substring(0, 67) + '...' }
        Emit-Text 130.0 $ay ("x$($a.Qty)  $d") $hSmall '3T' 'L'
        $ay -= 16.0
        if ($ay -lt 40.0) { break }
    }
}

# --- notes -------------------------------------------------------------------------
$notes = @(
    'ENCLOSURE RAL7035, IP54, WITH MOUNTING PLATE',
    'SUPPLY 240VAC FROM CLIENT GPO, SEE SCHEMATIC',
    'ITEM NUMBERS REFER TO THE BOM SHEET',
    'CABLE ENTRY: GLAND PLATE (BOTTOM), POSITIONS TBC',
    'DO NOT DRILL THROUGH LIVE BUSBARS OR CABLE TRUNKING'
)
$ny = 1000.0
Emit-Text 1250.0 $ny 'NOTES' $hSmall '1T' 'L'
$ny -= 22.0
foreach ($n in $notes) {
    Emit-Text 1250.0 $ny $n $hSmall '3T' 'L'
    $ny -= 18.0
}

# --- the honest gap ----------------------------------------------------------------
# More modules than the three rails hold: say so, do not drop them silently.
$unplaced = $modules.Count - $placed.Count
if ($unplaced -gt 0) {
    Emit-Text 112.0 60.0 ("$($modules.Count) MODULES ON THE ORDER SCHEDULE, $(($perRail * $railTops.Count)) RAIL SPACES ON THIS SHEET - $unplaced NOT PLACED, CHECK ENCLOSURE SIZE") $hLabel '5T' 'L'
}

# --- draft stamps (paper space) ----------------------------------------------------
# A draft that looks issued is worse than no draft. The stamps live in paper space on their own layer,
# matching the working drawings (same as the TMD generator).
if ($tplLayout) {
    $lines.Add('layout.set {"name":' + (ConvertTo-JsonStringValue -Value $tplLayout) + '}')
}
$lines.Add('layer.current {"name":"Preliminary Not For Construction"}')
$lines.Add('style {"name":"Romans"}')
$lines.Add('text {"at":[768,72],"text":"PRELIMINARY","height":4}')
$lines.Add('text {"at":[753,66],"text":"NOT FOR CONSTRUCTION","height":4}')

# --- frame the content viewport on the drawn GA --------------------------------------
if ($tplLayout -and $tplVpHandle) {
    $lines.Add('layout.set {"name":' + (ConvertTo-JsonStringValue -Value $tplLayout) + '}')
    # The GA spans model x -70..1250, y -50..1070. Centre the window on it.
    $cxv = 600.0; $cyv = 500.0; $vh = 1250.0
    # The template's content viewport ships locked, and viewport.set refuses a locked viewport and
    # aborts the rest of the script (including saveas). Unlock, set, re-lock.
    $lines.Add('viewport.set {"handle":' + (ConvertTo-JsonStringValue -Value $tplVpHandle) + ',"locked":false}')
    $lines.Add('viewport.set {"handle":' + (ConvertTo-JsonStringValue -Value $tplVpHandle) + ',"center":[' + (JNum $cxv) + ',' + (JNum $cyv) + '],"viewHeight":' + (JNum $vh) + '}')
    $lines.Add('viewport.set {"handle":' + (ConvertTo-JsonStringValue -Value $tplVpHandle) + ',"locked":true}')
    $lines.Add('layout.set {"name":"Model"}')
}

$lines.Add('saveas {"path":' + (ConvertTo-JsonStringValue -Value $OutDwg) + ',"version":"2018"}')

# --- write and run -----------------------------------------------------------------
$scr = $ScrPath
if (-not $scr) { $scr = [System.IO.Path]::ChangeExtension($OutDwg, '.scr') }
$outDir = Split-Path -Parent $OutDwg
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
[System.IO.File]::WriteAllLines($scr, $lines, (New-Object System.Text.UTF8Encoding($false)))

# Run against the template. The flag is --script-file (not --script, which cadcraft reads as a
# command string and splits on the path's spaces). The script's own saveas writes OutDwg, so run on
# the template and let saveas produce the output. Paths contain spaces, so go through a .cmd wrapper.
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
Write-Host ("{0}  station={1}  modules={2}  accessories={3}  balloons={4}  bytes={5}  exit={6}" -f `
        $number, $station, $modules.Count, $accessories.Count, $balloonCount, $bytes, $exit)
if ($exit -ne 0 -or $bytes -eq 0) { exit 1 }
exit 0
