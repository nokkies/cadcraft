# gen-cbd-comms.ps1 -- build a COMMUNICATIONS SYSTEM BLOCK DIAGRAM from the order schedule.
#
# The producer for the register's CBD-002 (communications system block diagram). This is a new-design
# drawing, not an as-built markup: it shows the control network -- the core switch, the panels that
# connect to it, and the class of link between them -- derived from the communications hardware the job
# buys. It is a block diagram, so it is boxes and labelled connectors, which a data-driven generator
# lays out cleanly; it is not the as-built cable routing (that is a different register row, marked
# "updated to as constructed", and needs field data this generator does not have).
#
# Topology read from the order schedule:
#   - the core/distribution switch is the managed layer-2 switch bought once at project level
#     (identified by its role words, not a part name);
#   - every panel that buys an industrial switch, a bus adapter or a comms module is a network node;
#   - each node is drawn as a box with its panel name and its switch type, and a link drops to the
#     core switch. Link type (managed IE switch / remote I/O / serial) is taken from the device words.
#
# Nothing is invented: a panel with no comms device is not drawn as a node, and a link is labelled with
# the device class the schedule actually names. Where the schedule is ambiguous the box carries the
# part description, so a reader can see what the node is rather than a guessed label.
#
# Inputs (all read, none written):
#   -Template, -PlanCsv, -DrawingNumber   the sheet identity from the register.
#   -OrderScheduleCsv                     the comms devices per panel.
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

$plan = @(Import-Csv -LiteralPath $PlanCsv)
$row = $null
if ($DrawingNumber) { $row = $plan | Where-Object { $_.Number -eq $DrawingNumber } | Select-Object -First 1 }
if ($null -eq $row) { $row = $plan | Where-Object { $_.Discipline -eq 'CBD' -and $_.Title -match 'COMMUNICATION' } | Select-Object -First 1 }
if ($null -eq $row) { throw 'no communications block diagram row found in the plan.' }
$number = [string]$row.Number
$title = [string]$row.Title
$rev = [string]$row.Revision
if (-not $rev) { $rev = 'A' }

$hw = Get-Content -LiteralPath $HardwareJson -Raw | ConvertFrom-Json

# --- read the order schedule -------------------------------------------------------
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

# Nodes: each panel that buys a comms device. Core: the managed layer-2 backbone switch at project level.
$coreDesc = ''
$nodes = New-Object System.Collections.Generic.List[object]
$byPanel = @{}
foreach ($ln in $osRows) {
    $panel = [string]$ln.PSObject.Properties['Panel'].Value
    $desc = [string]$ln.PSObject.Properties['Description'].Value
    $d = $desc.ToUpperInvariant()
    # The core is the managed layer-2 backbone switch bought once at project level. It is identified by
    # role words (a managed switch that is NOT a panel's access switch), and its label is taken from the
    # schedule's own description -- the generator carries no vendor part names of its own.
    if ($d -match 'MANAGED LAYER 2|MANAGED L2' -and $d -match 'SWITCH|IE SW|IE SW\b|\bSW\b' -and (Norm-Station $panel) -eq 'PROJECT') {
        if (-not $coreDesc) {
            $coreDesc = 'CORE SWITCH - ' + ($desc.ToUpperInvariant() -replace '\s+',' ').Trim()
            if ($coreDesc.Length -gt 60) { $coreDesc = $coreDesc.Substring(0,60) }
        }
        continue
    }
    $cls = ''
    if ($d -match 'MANAGED|IE SW|INDUSTRIAL ETHERNET|ETHERNET SWITCH') { $cls = 'INDUSTRIAL ETHERNET SWITCH' }
    elseif ($d -match 'SWITCH MODULE|CSM ') { $cls = 'SWITCH MODULE' }
    elseif ($d -match 'BUSADAPTOR|BUS ADAPTER|BA 2X|REMOTE I/O|ET200|ET 200') { $cls = 'REMOTE I/O' }
    elseif ($d -match 'CP 1|CM 1|COMMUNICATION PROCESSOR|SERIAL|MOBILE RADIO|4G') { $cls = 'COMMS MODULE' }
    if (-not $cls) { continue }
    $pk = Norm-Station $panel
    if (-not $byPanel.ContainsKey($pk)) {
        $byPanel[$pk] = [pscustomobject]@{ Panel = $panel; Class = $cls; Seen = New-Object System.Collections.Generic.List[string] }
        $nodes.Add($byPanel[$pk])
    }
    # keep the most capable class seen for the panel (a switch beats a comms module)
    $rank = @{ 'COMMS MODULE'=1; 'REMOTE I/O'=2; 'SWITCH MODULE'=3; 'INDUSTRIAL ETHERNET SWITCH'=4 }
    if ($rank[$cls] -gt $rank[$byPanel[$pk].Class]) { $byPanel[$pk].Class = $cls }
}
if (-not $coreDesc) { $coreDesc = 'CORE SWITCH' }

# --- layout constants (model units on the A1) ----------------------------------------
$originX = 120.0
$coreY = 470.0
$nodeTopY = 380.0
$boxW = 70.0; $boxH = 34.0
$coreW = 150.0; $coreH = 30.0
$hSmall = 2.5; $hLabel = 3.5; $hHead = 5.0
$styleName = 'isocp2'

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

# --- title block -------------------------------------------------------------------
$tplLayout = $LayoutName
$tplTbHandle = ''
$tplVpHandle = ''
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
            if (($w * $h) -gt $best) { $best = $w * $h; $tplVpHandle = [string]$e.handle }
        }
    }
}
$attribs = [ordered]@{}
if ($ProjectNumber) { $attribs['PROJECTNO.'] = $ProjectNumber }
if ($Scope1) { $attribs['SCOPE1'] = $Scope1 }
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
Emit-Text $originX 505.0 'COMMUNICATIONS SYSTEM BLOCK DIAGRAM' $hHead '5T' 'L'
Emit-Text $originX 498.0 "$number" $hLabel '5T' 'L'

# --- core switch (top centre) ------------------------------------------------------
$coreCx = 420.0
$coreX = $coreCx - ($coreW / 2.0)
Emit-Rect $coreX $coreY $coreW $coreH '1C'
Emit-Text $coreCx ($coreY + $coreH - 12.0) 'CORE / BACKBONE' $hLabel '2T' 'MC'
# wrap the core description over two lines
$coreWords = $coreDesc -split ' '
$cl1 = ''; $cl2 = ''
foreach ($wd in $coreWords) {
    if (($cl1 + ' ' + $wd).Trim().Length -le 26 -and $cl2 -eq '') { $cl1 = ($cl1 + ' ' + $wd).Trim() }
    else { $cl2 = ($cl2 + ' ' + $wd).Trim() }
}
Emit-Text $coreCx ($coreY + $coreH - 20.0) $cl1 $hSmall '1T' 'MC'
Emit-Text $coreCx ($coreY + $coreH - 27.0) $cl2 $hSmall '1T' 'MC'

# --- nodes arranged in a row below, each linked up to the core ---------------------
# Fit the node boxes across the sheet width; if there are too many for one row, wrap to a second row.
# Each row hangs off its own collector bus just above that row, and the row buses tie back to the core
# -- so a node's link is a short stub to its own row bus, not a long line running up through the rows
# above it (which read as a shared trunk in the first render).
$rowWidth = 760.0
$perRow = [math]::Max(1, [math]::Floor($rowWidth / ($boxW + 12.0)))
$nx = $originX
$ny = $nodeTopY
$inRow = 0
$nodeCount = 0
$rowBusY = New-Object System.Collections.Generic.List[double]
$rowBusX1 = 0.0
$nodeTops = New-Object System.Collections.Generic.List[object]   # {X, TopY, Row} for each node's stub
$curRow = 0
foreach ($nd in $nodes) {
    if ($inRow -ge $perRow) {
        $rowBusX1 = $nx - 12.0
        $rowBusY.Add($ny + $boxH + 10.0)
        $nx = $originX
        $ny -= ($boxH + 55.0)
        $inRow = 0
        $curRow++
    }
    $cx = $nx + ($boxW / 2.0)
    Emit-Rect $nx $ny $boxW $boxH '1C'
    $pn = $nd.Panel
    if ($pn.Length -gt 16) { $pn = $pn.Substring(0, 16) }
    Emit-Text $cx ($ny + $boxH - 12.0) $pn $hLabel '1T' 'MC'
    $cls = $nd.Class
    if ($cls.Length -gt 20) { $cls = $cls.Substring(0, 20) }
    Emit-Text $cx ($ny + $boxH - 20.0) $cls $hSmall '2T' 'MC'
    $nodeTops.Add([pscustomobject]@{ X = $cx; TopY = ($ny + $boxH); Row = $curRow })
    $nodeCount++
    $nx += ($boxW + 12.0)
    $inRow++
}
# close the last row
$rowBusX1 = $nx - 12.0
$rowBusY.Add($ny + $boxH + 10.0)
# draw each row's collector bus and its tie back to the core
$busX0 = $originX
$busX1 = $originX + ($perRow * ($boxW + 12.0)) - 12.0
for ($ri = 0; $ri -lt $rowBusY.Count; $ri++) {
    $by = $rowBusY[$ri]
    $spanX1 = $busX1
    if ($ri -eq ($rowBusY.Count - 1)) { $spanX1 = $rowBusX1 }
    Emit-Line $busX0 $by $spanX1 $by '3C'
    # node stubs rise from each box top to this row's own bus (a short link, not through other rows)
    foreach ($nt in $nodeTops) {
        if ($nt.Row -ne $ri) { continue }
        Emit-Line $nt.X $nt.TopY $nt.X $by '3C'
    }
    # riser on the left edge joining this row's bus to the topmost bus (skip the topmost row itself,
    # whose bus is already the top one -- a line from a point to itself is invalid)
    if ($by -ne $rowBusY[0]) { Emit-Line $busX0 $by $busX0 $rowBusY[0] '3C' }
}
# from the topmost bus up into the core switch
Emit-Line $busX0 $rowBusY[0] $coreCx $rowBusY[0] '3C'
Emit-Line $coreCx $rowBusY[0] $coreCx $coreY '3C'

# --- notes -------------------------------------------------------------------------
Emit-Text 700.0 505.0 'NOTES' $hLabel '1T' 'L'
$ny2 = 498.0
foreach ($n in @('CONTROL NETWORK TOPOLOGY FROM THE ORDER SCHEDULE', 'LINK CLASSES PER COMMS DEVICE BOUGHT', 'AS-BUILT ROUTING AND CABLE NUMBERS ON THE AS-BUILT SET', 'FIBRE COPPER AND PORT ALLOCATION PER NETWORK SCHEDULE')) {
    Emit-Text 700.0 $ny2 $n $hSmall '3T' 'L'
    $ny2 -= 7.0
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
    $lines.Add('viewport.set {"handle":' + (ConvertTo-JsonStringValue -Value $tplVpHandle) + ',"center":[420,300],"viewHeight":560}')
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
Write-Host ("{0}  nodes={1}  core='{2}'  bytes={3}  exit={4}" -f $number, $nodeCount, $coreDesc, $bytes, $exit)
if ($exit -ne 0 -or $bytes -eq 0) { exit 1 }
exit 0
