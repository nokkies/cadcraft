# gen-scd.ps1 -- cadcraft card M4-C4 (and the pattern for the other SCD sheets)
#
# Builds a schematic diagram (SCD) sheet with cadcraft. The working SCD draws its terminals as
# small circles (layer 3C, radius 2.5) with a numeric label. DRAWING-WORK D1 asked for the library
# TERMINAL block instead, but that block is a 70x10 horizontal terminal-strip graphic that overruns
# the wire spacing and never turns vertical, so it was reverted (build 0.064): the generator now
# re-emits the terminal circles exactly as the source draws them. This generator reads the working
# drawing's model-space geometry and re-emits it: every line, circle and text is carried across.
# The title block and border are inserted with the attributes read from the working drawing's
# paper-space layout.
#
# It is a faithful rebuild, not a redraw: the geometry comes from the source so the sheet matches
# the working drawing, terminals included.
#
# Writes only inside $D\fusion.

[CmdletBinding()]
param(
    [string]$Template,
    [Parameter(Mandatory = $true)][string]$SchematicDrawing,
    [string]$OutDir,
    [string]$SheetsDir,
    # Terminal circles on the schematic layer at this radius become TERMINAL inserts.
    [double]$TerminalRadius = 2.5,
    [string]$TerminalLayer = '3C',
    # DRAWING-WORK D4: annotate each I/O channel with its RTB terminal number from pins.csv.
    [string]$PinsCsv
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
function Resolve-CadcraftCli {
    $cmd = Get-Command 'cadcraft-cli' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $exe = 'C:\Users\ReinachvanNieuwenhui\src\cadcraft\target\release\cadcraft-cli.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    throw 'cadcraft-cli not found.'
}
function Get-ArgumentForNative { param([string]$Value) return '"' + $Value.Replace('"', '""') + '"' }
function ConvertTo-JsonStringValue {
    param([string]$Value)
    $esc = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $esc + '"'
}
function JNum { param($v) return ([double]$v).ToString([System.Globalization.CultureInfo]::InvariantCulture) }
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
        if (-not $pi.WaitForExit(120000)) { try { $pi.Kill() } catch { }; return $null }
        if ($pi.ExitCode -ne 0) { return $null }
        $text = [System.IO.File]::ReadAllText($tmpOut)
        $jsonLines = @($text -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') -or $_.Trim().StartsWith('[') })
        if ($jsonLines.Count -eq 0) { return $null }
        try { return ($jsonLines[-1] | ConvertFrom-Json) } catch { return $null }
    } catch { return $null } finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr, $bat -Force -ErrorAction SilentlyContinue
    }
}

$D = Get-PSADrawingsRoot
. (Join-Path $PSScriptRoot 'project.ps1')
if ([string]::IsNullOrWhiteSpace($Template)) { $Template = Join-Path $D ($Project.template -replace '/', '\') }
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $D 'fusion\out' }
if ([string]::IsNullOrWhiteSpace($SheetsDir)) { $SheetsDir = Join-Path $D 'fusion\sheets' }
if (-not (Test-Path -LiteralPath $Template)) { throw "template not found: $Template" }
if (-not (Test-Path -LiteralPath $SchematicDrawing)) { throw "SCD drawing not found: $SchematicDrawing" }
foreach ($d in @($OutDir, $SheetsDir)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
$cli = Resolve-CadcraftCli
$name = Split-Path -Leaf $SchematicDrawing

# --- DRAWING-WORK D4: RTB pin numbers for this sheet's I/O channels -----------------
# Map the sheet number to its module, then load pins.csv into channel -> terminal.
$sheetModule = $null
if ($name -match 'SCD-003') { $sheetModule = '5069-IB16' }
elseif ($name -match 'SCD-004') { $sheetModule = '5069-OB16' }
elseif ($name -match 'SCD-005') { $sheetModule = '5069-OF4' }
$pinByChannel = @{}
if ($sheetModule) {
    if ([string]::IsNullOrWhiteSpace($PinsCsv)) { $PinsCsv = Join-Path (Get-PSADrawingsRoot) 'fusion\pins.csv' }
    if (Test-Path -LiteralPath $PinsCsv) {
        $dbgRows = @(Import-Csv -LiteralPath $PinsCsv)
        foreach ($p in $dbgRows) {
            if ($p.module -ne $sheetModule) { continue }
            # Key digital channels by the channel name (IN n / OUT n). For the OF4 analog module the
            # schematic writes "CHn I+"/"I-", so key by the reconstructed "CHn <sign>" from the label.
            if ($p.channel) { $pinByChannel[([string]$p.channel).Trim()] = [string]$p.terminal }
            if ($sheetModule -eq '5069-OF4' -and $p.channel -and $p.label) {
                $sign = ''
                if ($p.label -match '\+$') { $sign = 'I+' } elseif ($p.label -match '-$') { $sign = 'I-' }
                if ($sign) { $pinByChannel[([string]$p.channel).Trim() + ' ' + $sign] = [string]$p.terminal }
            }
        }
    }
}

# --- title-block attributes from the paper-space layout ----------------------------
$tbAttribs = @{}
$ll = Invoke-CliSteps -Cli $cli -Drawing $SchematicDrawing -Steps @('layout.list {}')
$tbLayout = ''
if ($null -ne $ll) {
    $lay = @($ll | ForEach-Object { [string]$_.name } | Where-Object { $_ -and $_ -ne 'Model' })
    if ($lay.Count -gt 0) { $tbLayout = $lay[0] }
}
if ($tbLayout) {
    $tbPaper = Invoke-CliSteps -Cli $cli -Drawing $SchematicDrawing -Steps @(
        ('layout.set {"name":' + (ConvertTo-JsonStringValue -Value $tbLayout) + '}'),
        'texts {"limit":1000}'
    )
    if ($null -ne $tbPaper) {
        foreach ($t in $tbPaper.texts) {
            if ($t.PSObject.Properties.Name -contains 'tag' -and $t.tag) { $tbAttribs[[string]$t.tag] = [string]$t.text }
        }
    }
}

# --- the template's own title block (paper space) ------------------------------------
# The generator runs its script against the template, so the output already carries the
# template's border and title block in its paper-space layout. Card M4-F1: do NOT insert a
# second A1 BORDER / A1 TITLE TEXT into model space (that was the empty-plot defect). Instead
# set the attribute values on the template's EXISTING title-block reference, then switch back
# to model space before drawing content. Discover the layout name and the A1 TITLE TEXT handle
# from the template (handles differ per file, so read them, never hard-code).
$tplLayout = ''
$tplTbHandle = ''
$tll = Invoke-CliSteps -Cli $cli -Drawing $Template -Steps @('layout.list {}')
if ($null -ne $tll) {
    $tlay = @($tll | ForEach-Object { [string]$_.name } | Where-Object { $_ -and $_ -ne 'Model' })
    if ($tlay.Count -gt 0) { $tplLayout = $tlay[0] }
}
if ($tplLayout) {
    $tins = Invoke-CliSteps -Cli $cli -Drawing $Template -Steps @(
        ('layout.set {"name":' + (ConvertTo-JsonStringValue -Value $tplLayout) + '}'),
        'entities {"type":"Insert","limit":100}'
    )
    if ($null -ne $tins) {
        foreach ($e in $tins.entities) {
            if ([string]$e.geometry.block -eq 'A1 TITLE TEXT') { $tplTbHandle = [string]$e.handle; break }
        }
    }
}

# M4-C16: the template's content viewport handle (the model-space window with the largest paper
# window; id>=2, since id<=1 is the sheet-border viewport). Read it, never hard-code.
# M4-C17: also collect the OTHER model-window handles (id>=2, not the content window). The template
# carries a second sheet viewport (41D1) and an empty detail window (41D5) alongside the content
# window (30F5). cadcraft's saveas renumbers the ids and promotes 41D1 (a sheet viewport) into the
# model-window list, so the saved layout has THREE model windows all drawing the same model content
# -> the plotted/GUI sheet shows the content two or three times over (Reinach: "looks duplicated").
# Erasing every model window except the content one leaves 1021 (sheet) + 30F5 (content): one clean
# copy. Erase by role (id>=2, not the content handle), never by hard-coded handle.
$tplVpHandle = ''
$tplVpArea = -1.0
$tplVpCenterX = 0.0
$tplVpCenterY = 0.0
$tplVpHeight = 0.0
$tplExtraVpHandles = @()
if ($tplLayout) {
    $tvps = Invoke-CliSteps -Cli $cli -Drawing $Template -Steps @(
        ('layout.set {"name":' + (ConvertTo-JsonStringValue -Value $tplLayout) + '}'),
        'entities {"type":"Viewport","limit":100}'
    )
    if ($null -ne $tvps) {
        # The template carries four viewports: the sheet window (1021, id=1, the largest), a second
        # smaller sheet window (41D1, id=1), the content window (30F5, id>=2, the largest model
        # window), and an empty detail window (41D5, id>=2). cadcraft's saveas renumbers the ids and
        # promotes the second sheet window into the model list, so the saved sheet draws the content
        # two or three times (the "duplicated" look). Keep only the largest sheet window and the
        # largest model window; erase every other viewport. Identify by role (largest per class),
        # never by hard-coded handle.
        $sheetHandle = ''; $sheetArea = -1.0
        $modelHandles = @()
        foreach ($e in $tvps.entities) {
            $g = $e.geometry
            $vid = -1
            if ($g.PSObject.Properties.Name -contains 'id') { $vid = [int]$g.id }
            $w = 0.0; $h = 0.0
            if ($g.PSObject.Properties.Name -contains 'width') { $w = [double]$g.width }
            if ($g.PSObject.Properties.Name -contains 'height') { $h = [double]$g.height }
            $area = $w * $h
            if ($vid -le 1) {
                if ($area -gt $sheetArea) { $sheetArea = $area; $sheetHandle = [string]$e.handle }
            } else {
                $modelHandles += [string]$e.handle
                if ($area -gt $tplVpArea) {
                    $tplVpArea = $area; $tplVpHandle = [string]$e.handle
                    # M4-C18: remember the content window's own paper centre and height. The working
                    # drawings frame this window as view = window centre, viewHeight = window height
                    # (measured: 11 of 12 sheets use exactly (420,322) vh 524), and draw their content
                    # in model space to land inside it. Copy that framing rather than recomputing a
                    # tighter view from the content box, which zoomed in and shifted the view.
                    if ($g.PSObject.Properties.Name -contains 'center' -and $g.center) { $tplVpCenterX = [double]$g.center.x; $tplVpCenterY = [double]$g.center.y }
                    $tplVpHeight = $h
                }
            }
        }
        # Erase: every sheet window except the largest, and every model window except the content one.
        $keep = @($sheetHandle, $tplVpHandle)
        $allHandles = @($tvps.entities | ForEach-Object { [string]$_.handle })
        $tplExtraVpHandles = @($allHandles | Where-Object { $_ -notin $keep })
    }
}

# --- model-space geometry ----------------------------------------------------------
$ents = Invoke-CliSteps -Cli $cli -Drawing $SchematicDrawing -Steps @('entities {"limit":5000}')
if ($null -eq $ents) { throw 'could not read the SCD model entities' }

# M4-C16: the bounding box of the content we are about to draw, so the content viewport can be
# framed on it. The template's content viewport (handle 30F5, the largest paper-space window) was
# authored over an EMPTY template model space -- its stored view (measured: viewCenter (-350,571),
# viewHeight 524) points at empty space, so a generated sheet plotted with the border and title
# block (paper space) but NO content (the content viewport looked where the content is not). The
# source working drawing has the same viewport pointed correctly (measured: (780,520) vh 1572).
# Fix: compute the drawn content's extents and, after drawing, set the content viewport's view on
# them. Track every coordinate the source entities carry (line ends, circle centres, insert points).
$minX = [double]::MaxValue; $minY = [double]::MaxValue; $maxX = [double]::MinValue; $maxY = [double]::MinValue
function Track-XY { param($x, $y) if ($null -ne $x -and $null -ne $y) { $x = [double]$x; $y = [double]$y; if ($x -lt $script:minX) { $script:minX = $x }; if ($x -gt $script:maxX) { $script:maxX = $x }; if ($y -lt $script:minY) { $script:minY = $y }; if ($y -gt $script:maxY) { $script:maxY = $y } } }
foreach ($e in $ents.entities) {
    $g = $e.geometry
    # Line geometry carries its endpoints as `a` and `b` (not start/end); Circle as `center`;
    # MText/Text/Insert as `insert`. Missing the `a`/`b` fields would drop every line and skew the
    # box to just the text/circle points.
    if ($g.PSObject.Properties.Name -contains 'a' -and $g.a) { Track-XY $g.a.x $g.a.y }
    if ($g.PSObject.Properties.Name -contains 'b' -and $g.b) { Track-XY $g.b.x $g.b.y }
    if ($g.PSObject.Properties.Name -contains 'center' -and $g.center) { Track-XY $g.center.x $g.center.y }
    if ($g.PSObject.Properties.Name -contains 'insert' -and $g.insert) { Track-XY $g.insert.x $g.insert.y }
}
$hasExtents = ($minX -lt $maxX -and $minY -lt $maxY)

$lines = New-Object System.Collections.Generic.List[string]
# M4-F1: set the title block's attributes on the template's existing paper-space reference
# (found above), not by inserting a new one into model space. Switch to the layout, attedit,
# then return to model space for the drawing content. If the template's title block could not
# be located, fall back to the old model-space insert so the sheet still carries a title block.
$attribJson = ($tbAttribs.Keys | Sort-Object | ForEach-Object {
    (ConvertTo-JsonStringValue -Value $_) + ':' + (ConvertTo-JsonStringValue -Value $tbAttribs[$_])
}) -join ','
if ($tplLayout -and $tplTbHandle) {
    $lines.Add('layout.set {"name":' + (ConvertTo-JsonStringValue -Value $tplLayout) + '}')
    $lines.Add('attedit {"handle":' + (ConvertTo-JsonStringValue -Value $tplTbHandle) + ',"values":{' + $attribJson + '}}')
    $lines.Add('layout.set {"name":"Model"}')
} else {
    Write-Warning 'template title block not found; falling back to a model-space insert'
    $lines.Add('insert {"name":"A1 TITLE TEXT","at":[0,0],"attribs":{' + $attribJson + '}}')
    $lines.Add('insert {"name":"A1 BORDER","at":[0,0]}')
}

# --- layer switching (M4-F2) -------------------------------------------------------
# cadcraft's draw commands do NOT honour a per-command "layer" param: an entity lands on the
# CURRENT layer. The template already carries all the schematic layers, but the current layer
# after opening it is "Viewport" (frozen in the content viewport), so every drawn entity fell onto
# "Viewport" and the plotted sheet came out empty. Fix: switch the current layer before each group
# of same-layer entities. $curLayer tracks it; Emit-Layer switches only when it changes.
$curLayer = ''
function Emit-Layer {
    param([string]$Name)
    if ($Name -and $Name -ne $curLayer) {
        $script:lines.Add('layer.current {"name":' + (ConvertTo-JsonStringValue -Value $Name) + '}')
        $script:curLayer = $Name
    }
}
# The PRELIMINARY / NOT FOR CONSTRUCTION stamps live on their own layer. They are PAPER-space
# entities in the working drawings (measured on SCD-001: source has them as paper-space Text on
# layer "Preliminary Not For Construction" at (768,72)/(753,66), and nothing on that layer in model
# space), so they print at a fixed sheet position whatever the content viewport shows. Emitting them
# as model-space MText instead put them inside the content window, where the viewport scales them --
# so they are emitted in paper space below, after layout.set. The layer is created here (model space
# is current) so it exists for the paper-space text to land on.
Emit-Layer 'Preliminary Not For Construction'

# M4-C3: the library TERMINAL block defines a TERM_NO attribute. In the source the terminal number
# is a numeric MText drawn at the terminal's own position, so we move it into the block's TERM_NO
# attribute and drop the now-redundant separate text. Key the numeric texts by rounded position.
$numByPos = @{}
foreach ($e in $ents.entities) {
    if ($e.type -eq 'MText' -and $e.geometry.PSObject.Properties.Name -contains 'insert') {
        $c = [string]$e.geometry.contents
        if ($c -match '^\d+$') {
            $key = ([Math]::Round([double]$e.geometry.insert.x, 0)).ToString([System.Globalization.CultureInfo]::InvariantCulture) + ',' +
                   ([Math]::Round([double]$e.geometry.insert.y, 0)).ToString([System.Globalization.CultureInfo]::InvariantCulture)
            if (-not $numByPos.ContainsKey($key)) { $numByPos[$key] = $c }
        }
    }
}
$consumedNums = New-Object System.Collections.Generic.HashSet[string]

$terminalCount = 0
foreach ($e in $ents.entities) {
    $g = $e.geometry
    # M4-F2: cadcraft draws on the CURRENT layer, so switch to this entity's source layer first.
    Emit-Layer ([string]$e.layer)
    switch ($e.type) {
        'Line' {
            if ($g.PSObject.Properties.Name -contains 'a' -and $g.PSObject.Properties.Name -contains 'b') {
                $lines.Add('line {"points":[[' + (JNum $g.a.x) + ',' + (JNum $g.a.y) + '],[' + (JNum $g.b.x) + ',' + (JNum $g.b.y) + ']],"layer":' + (ConvertTo-JsonStringValue -Value $e.layer) + '}')
            }
        }
        'MText' {
            if ($g.PSObject.Properties.Name -contains 'insert') {
                $key = ([Math]::Round([double]$g.insert.x, 0)).ToString([System.Globalization.CultureInfo]::InvariantCulture) + ',' +
                       ([Math]::Round([double]$g.insert.y, 0)).ToString([System.Globalization.CultureInfo]::InvariantCulture)
                # Skip a numeric text whose number we moved into a TERMINAL block's attribute.
                if ($consumedNums.Contains($key)) { continue }
                $lines.Add('mtext {"at":[' + (JNum $g.insert.x) + ',' + (JNum $g.insert.y) + '],"text":' + (ConvertTo-JsonStringValue -Value $g.contents) + ',"height":' + (JNum $g.height) + ',"layer":' + (ConvertTo-JsonStringValue -Value $e.layer) + '}')
                # DRAWING-WORK D4: annotate the RTB terminal number beside an I/O channel name.
                if ($pinByChannel.Count -gt 0) {
                    $chan = ([string]$g.contents).Trim()
                    $term = $null
                    if ($pinByChannel.ContainsKey($chan)) { $term = $pinByChannel[$chan] }
                    if ($null -ne $term -and $term -ne '') {
                        # Place a small "Tn" terminal label to the left of the channel name.
                        $tx = [double]$g.insert.x - 14.0
                        $ty = [double]$g.insert.y
                        $lines.Add('mtext {"at":[' + (JNum $tx) + ',' + (JNum $ty) + '],"text":' + (ConvertTo-JsonStringValue ('T' + $term)) + ',"height":' + (JNum ([Math]::Min([double]$g.height, 2.5))) + ',"layer":' + (ConvertTo-JsonStringValue -Value $e.layer) + '}')
                    }
                }
            }
        }
        'Circle' {
            # A terminal is a small circle on the terminal layer (r=2.5 on SCD-001/003/004/005, r=3 on
            # SCD-002) with its number as a numeric MText at the same centre. DRAWING-WORK D1 asked to
            # replace the circle with the library TERMINAL block (build 0.030, M4-C3), but the block is
            # a 70x10 horizontal terminal-STRIP graphic (measured: polyline 3000->3070 x 2994.7->3004.7),
            # ~14x wider than the 5-unit circle and never vertical, so on these wire-connected points it
            # overruns the wire spacing and wires plot over it. Reverted (build 0.064): draw the circle
            # as the source does and leave the number MText to be drawn normally by the MText branch.
            # The block is the wrong graphic for a per-wire terminal marker; D1 does not hold here.
            $lines.Add('circle {"center":[' + (JNum $g.center.x) + ',' + (JNum $g.center.y) + '],"radius":' + (JNum $g.radius) + ',"layer":' + (ConvertTo-JsonStringValue -Value $e.layer) + '}')
            $terminalCount++
        }
        'Block Reference' {
            # Carry a library block insert (e.g. the GA's _TagCircle balloons) with its attributes.
            $blockName = [string]$g.block
            $attribPart = ''
            if ($g.PSObject.Properties.Name -contains 'attribs' -and @($g.attribs).Count -gt 0) {
                $pairs = @($g.attribs | ForEach-Object {
                    $tag = [string]$_.tag
                    $val = ''
                    if ($_.PSObject.Properties.Name -contains 'text' -and $_.text -and $_.text.PSObject.Properties.Name -contains 'value') { $val = [string]$_.text.value }
                    (ConvertTo-JsonStringValue -Value $tag) + ':' + (ConvertTo-JsonStringValue -Value $val)
                })
                if ($pairs.Count -gt 0) { $attribPart = ',"attribs":{' + ($pairs -join ',') + '}' }
            }
            $insX = 0.0; $insY = 0.0
            if ($g.PSObject.Properties.Name -contains 'insert' -and $g.insert) { $insX = [double]$g.insert.x; $insY = [double]$g.insert.y }
            # M4-F3: carry the block reference's scale and rotation. The GA balloons (_TagCircle) are
            # placed at scale 6 in the source; without it they plot at scale 1 and are invisible next
            # to the components. Emit scale only when it is not 1,1 and rotation only when non-zero.
            $scalePart = ''
            if ($g.PSObject.Properties.Name -contains 'scale' -and $g.scale) {
                $sx = [double]$g.scale.x; $sy = [double]$g.scale.y
                if ([Math]::Abs($sx - 1.0) -gt 1e-9 -or [Math]::Abs($sy - 1.0) -gt 1e-9) {
                    $scalePart = ',"scale":[' + (JNum $sx) + ',' + (JNum $sy) + ']'
                }
            }
            $rotPart = ''
            if ($g.PSObject.Properties.Name -contains 'rotation' -and [Math]::Abs([double]$g.rotation) -gt 1e-9) {
                $rotPart = ',"rotation":' + (JNum $g.rotation)
            }
            $lines.Add('insert {"name":' + (ConvertTo-JsonStringValue -Value $blockName) + ',"at":[' + (JNum $insX) + ',' + (JNum $insY) + ']' + $scalePart + $rotPart + $attribPart + ',"layer":' + (ConvertTo-JsonStringValue -Value $e.layer) + '}')
        }
    }
}

$outDwg = Join-Path $OutDir $name

# --- DRAWING-WORK D3: on the GA, add a note listing the DIN rail cut lengths ---------
# Computed from dimensions.csv (component widths) + the balloon rail bands + 20% spare, matching
# rail-lengths.ps1. Only for the general arrangement sheet (GAD-001).
if ($name -match 'GAD-001') {
    $dimCsv = Join-Path (Get-PSADrawingsRoot) 'fusion\dimensions.csv'
    if (Test-Path -LiteralPath $dimCsv) {
        $widthByItem = @{}
        foreach ($r in (Import-Csv -LiteralPath $dimCsv)) {
            if ([double]$r.width_mm -gt 0) { $widthByItem[[string]$r.item] = [double]$r.width_mm }
        }
        # Balloons on the GA are _TagCircle block references whose TAGNUMBER attribute holds the item
        # number; group each by rail band y.
        $bands = @(@{ n='RAIL 1'; y=845.0 }, @{ n='RAIL 2'; y=600.0 }, @{ n='RAIL 3'; y=320.0 })
        $railSum = @{ 'RAIL 1'=0.0; 'RAIL 2'=0.0; 'RAIL 3'=0.0 }
        foreach ($e in $ents.entities) {
            if ($e.type -ne 'Block Reference') { continue }
            if (-not ($e.geometry.PSObject.Properties.Name -contains 'attribs')) { continue }
            $num = $null
            foreach ($a in @($e.geometry.attribs)) {
                if ([string]$a.tag -eq 'TAGNUMBER') {
                    if ($a.PSObject.Properties.Name -contains 'text' -and $a.text -and $a.text.PSObject.Properties.Name -contains 'value') { $num = ([string]$a.text.value).Trim() }
                }
            }
            if ($null -eq $num -or $num -notmatch '^\d+$') { continue }
            if (-not $widthByItem.ContainsKey($num)) { continue }
            $iy = 0.0
            if ($e.geometry.PSObject.Properties.Name -contains 'insert' -and $e.geometry.insert) { $iy = [double]$e.geometry.insert.y }
            $band = $bands | Where-Object { [Math]::Abs($_.y - $iy) -le 120 } | Select-Object -First 1
            if ($null -ne $band) { $railSum[$band.n] += $widthByItem[$num] }
        }
        $noteLines = New-Object System.Collections.Generic.List[string]
        $noteLines.Add('DIN RAIL CUT LENGTHS (D3, from vendor dimensions + 20% spare):')
        $tot = 0.0
        foreach ($b in $bands) {
            $ws = $railSum[$b.n] * 1.2
            $tot += $ws
            $noteLines.Add(("{0}: {1} mm" -f $b.n, ([Math]::Round($ws,0)).ToString([System.Globalization.CultureInfo]::InvariantCulture)))
        }
        $noteLines.Add(("TOTAL {0} mm vs BOM 2x2000=4000 mm" -f ([Math]::Round($tot,0)).ToString([System.Globalization.CultureInfo]::InvariantCulture)))
        # M4-F4: MText line breaks are the DXF paragraph code \P, not \n (a literal \n renders as
        # the two characters backslash-n on the sheet). The source's own MText already uses \P.
        $noteText = $noteLines -join '\P'
        # Place the note in a clear area. (40,120) collided with the earth-bar assembly and balloon
        # 12's leader (measured: assembly lines at (40,100),(130,180) and the EARTH BAR label at
        # (190,192) all within reach). The upper-right column below the NOTES block (x~1360, y<960)
        # is empty (measured: 0 entities in x>1300, 650<y<960), so drop the note there.
        Emit-Layer '1T'
        $lines.Add('mtext {"at":[1360,720],"text":' + (ConvertTo-JsonStringValue $noteText) + ',"height":3,"layer":"1T"}')
    }
}

# M4-C16: frame the content viewport on the drawn content's extents so the sheet shows the drawing,
# not empty space. The template's content viewport pointed at an empty template model space, so a
# generated sheet plotted with border + title block but no content. viewHeight sets the vertical
# extent; the horizontal follows the window's aspect, so fit the larger of content height and
# (content width / aspect), with a margin. The viewport is unlocked first so the view can change.
# M4-C17 (revised by build 0.106): this used to erase the extra model windows -- the duplicate sheet
# viewport and the empty detail window -- because cadcraft's saveas renumbered viewport ids and promoted
# the second sheet window into the model list, drawing the content two or three times (the "duplicated"
# look the user reported). Build 0.105 fixes that in cadcraft: the sheet role is now carried in CADCraft
# xdata across a DWG save, so a second sheet window keeps id=1 and is not drawn as a model window. The
# erase is therefore gone, and the detail window survives -- which is what restores the small zoom
# windows the working drawings have and generated plots lacked.
if ($tplLayout) {
    $lines.Add('layout.set {"name":' + (ConvertTo-JsonStringValue -Value $tplLayout) + '}')
}

# Paper-space draft stamps, matching the working drawings' space, entity type and text style (see
# the note at the Emit-Layer above). cadcraft draws into the CURRENT space, so these land in paper
# space here; and its text command takes the CURRENT style (a "style" param is ignored), so Romans
# is made current first. Same coordinates and height as the source's paper-space Text entities.
$lines.Add('layer.current {"name":"Preliminary Not For Construction"}')
$lines.Add('style {"name":"Romans"}')
$lines.Add('text {"at":[768,72],"text":"PRELIMINARY","height":4}')
$lines.Add('text {"at":[753,66],"text":"NOT FOR CONSTRUCTION","height":4}')

if ($tplVpHandle -and $hasExtents) {
    $cx = ($minX + $maxX) / 2.0
    $cy = ($minY + $maxY) / 2.0
    $cw = $maxX - $minX
    $ch = $maxY - $minY
    # M4-C18: frame the content window the way the working drawings do -- view at the window's own
    # paper centre, viewHeight = the window's height (measured: 11 of 12 source sheets use exactly
    # (420,322) vh 524), because the content is drawn in model space to land inside that window.
    # But if the content does not actually sit inside that window view (its centre is far from the
    # window centre, or it is wider/taller than the window shows -- e.g. the big GAD-001 assembly),
    # fall back to centring on the content and widening the view to fit it.
    $aspect = if ($tplVpHeight -gt 0) { $tplVpArea / ($tplVpHeight * $tplVpHeight) } else { 1.55 }
    $shownW = $tplVpHeight * $aspect
    $fitsInWindow = ([Math]::Abs($cx - $tplVpCenterX) -le ($shownW / 2.0)) -and ([Math]::Abs($cy - $tplVpCenterY) -le ($tplVpHeight / 2.0)) -and ($cw -le $shownW) -and ($ch -le $tplVpHeight)
    if ($fitsInWindow) {
        $vh = $tplVpHeight
        $lines.Add('viewport.set {"handle":' + (ConvertTo-JsonStringValue -Value $tplVpHandle) + ',"locked":false,"center":[' + (JNum $tplVpCenterX) + ',' + (JNum $tplVpCenterY) + '],"viewHeight":' + (JNum $vh) + '}')
    } else {
        $vh = [Math]::Max($ch, $cw / $aspect) * 1.1
        if ($vh -lt 1.0) { $vh = 100.0 }
        $lines.Add('viewport.set {"handle":' + (ConvertTo-JsonStringValue -Value $tplVpHandle) + ',"locked":false,"center":[' + (JNum $cx) + ',' + (JNum $cy) + '],"viewHeight":' + (JNum $vh) + '}')
    }
}

# M4-C14: the Reference plots are monochrome (measured: black ink, 0.05% coloured pixels). The
# template's page setup names PSA.ctb, which cadcraft does not carry, so it would plot layer
# colours. Set the layout's plot style to cadcraft's builtin monochrome.ctb so the plot matches
# the Reference ink. Generation-side plot choice, not a cadcraft change.
# M5 (lineweights): the template's page setup has lineweights off, so lines plot hairline-thin and
# the plot carries far less ink than the Reference (measured: GAD-001 0.49% ink vs the Reference's
# 4.07%). Turning lineweights on raises it to 3.17%, into the Reference's range. cadcraft cannot
# read PSA.ctb's per-colour weight assignment (private, AutoCAD binary), so this is the faithful
# subset we can apply: honour the entities' own lineweights.
if ($tplLayout) {
    $lines.Add('pagesetup {"layout":' + (ConvertTo-JsonStringValue -Value $tplLayout) + ',"plotStyleTable":"monochrome.ctb","lineweights":true}')
}

$lines.Add('saveas {"path":' + (ConvertTo-JsonStringValue -Value $outDwg) + ',"version":2018}')

$scrPath = Join-Path $SheetsDir (($name -replace '\.dwg$', '') + '.scr')
[System.IO.File]::WriteAllLines($scrPath, $lines, (New-Object System.Text.ASCIIEncoding))
Write-Host "wrote $scrPath ($($lines.Count) commands, $terminalCount terminal blocks from circles)"

if (Test-Path -LiteralPath $outDwg) { Remove-Item -LiteralPath $outDwg -Force }
$bat = [System.IO.Path]::GetTempFileName() + '.cmd'
$runLine = '"' + $cli + '" run "' + $Template + '" --script-file "' + $scrPath + '"'
[System.IO.File]::WriteAllText($bat, "@echo off`r`n$runLine`r`n", (New-Object System.Text.ASCIIEncoding))
$pi = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', (Get-ArgumentForNative -Value $bat)) -NoNewWindow -PassThru
if (-not $pi.WaitForExit(300000)) { try { $pi.Kill() } catch { } }
Remove-Item -LiteralPath $bat -Force -ErrorAction SilentlyContinue

if (-not (Test-Path -LiteralPath $outDwg)) { Write-Error 'generated sheet was not written'; exit 1 }
Write-Host "generated $outDwg ($((Get-Item -LiteralPath $outDwg).Length) bytes)"
Write-Host "PASS M4 (SCD sheet generated by cadcraft): $name"
exit 0
