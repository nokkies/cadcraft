# gen-scd.ps1 -- cadcraft card M4-C4 (and the pattern for the other SCD sheets)
#
# Builds a schematic diagram (SCD) sheet with cadcraft. The working SCD draws its terminals as
# small circles (layer 3C, radius 2.5) -- DRAWING-WORK D1 asks for the library TERMINAL block
# instead. This generator reads the working drawing's model-space geometry and re-emits it:
# every line and text is carried across, and each 3C terminal circle becomes an `insert` of the
# library TERMINAL block at the same centre. The title block and border are inserted with the
# attributes read from the working drawing's paper-space layout.
#
# It is a faithful rebuild, not a redraw: the geometry comes from the source so the sheet matches
# the working drawing, and the one deliberate change is circles -> TERMINAL blocks (D1).
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

# --- model-space geometry ----------------------------------------------------------
$ents = Invoke-CliSteps -Cli $cli -Drawing $SchematicDrawing -Steps @('entities {"limit":5000}')
if ($null -eq $ents) { throw 'could not read the SCD model entities' }

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
$lines.Add('mtext {"at":[768,72],"text":"PRELIMINARY","height":4,"style":"Romans","layer":"Preliminary Not For Construction"}')
$lines.Add('mtext {"at":[753,66],"text":"NOT FOR CONSTRUCTION","height":4,"style":"Romans","layer":"Preliminary Not For Construction"}')

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
            $isTerminal = ($e.layer -eq $TerminalLayer) -and ([Math]::Abs([double]$g.radius - $TerminalRadius) -lt 0.1)
            if ($isTerminal) {
                # DRAWING-WORK D1: the library terminal block replaces the drawn circle, and its
                # number goes into the block's TERM_NO attribute (M4-C3).
                $key = ([Math]::Round([double]$g.center.x, 0)).ToString([System.Globalization.CultureInfo]::InvariantCulture) + ',' +
                       ([Math]::Round([double]$g.center.y, 0)).ToString([System.Globalization.CultureInfo]::InvariantCulture)
                $attribs = ''
                if ($numByPos.ContainsKey($key)) {
                    $attribs = ',"attribs":{"TERM_NO":' + (ConvertTo-JsonStringValue -Value $numByPos[$key]) + '}'
                    [void]$consumedNums.Add($key)
                }
                $lines.Add('insert {"name":"TERMINAL","at":[' + (JNum $g.center.x) + ',' + (JNum $g.center.y) + ']' + $attribs + ',"layer":' + (ConvertTo-JsonStringValue -Value $e.layer) + '}')
                $terminalCount++
            } else {
                $lines.Add('circle {"center":[' + (JNum $g.center.x) + ',' + (JNum $g.center.y) + '],"radius":' + (JNum $g.radius) + ',"layer":' + (ConvertTo-JsonStringValue -Value $e.layer) + '}')
            }
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
            $lines.Add('insert {"name":' + (ConvertTo-JsonStringValue -Value $blockName) + ',"at":[' + (JNum $insX) + ',' + (JNum $insY) + ']' + $attribPart + ',"layer":' + (ConvertTo-JsonStringValue -Value $e.layer) + '}')
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
        $noteText = $noteLines -join '\n'
        # Place the note in a clear area (lower-left of the GA interior).
        $lines.Add('mtext {"at":[40,120],"text":' + (ConvertTo-JsonStringValue $noteText) + ',"height":3,"layer":"1T"}')
    }
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
