# gen-tmd.ps1 -- cadcraft card M4-C3 (and the pattern for the other TMD sheets)
#
# Builds a termination-diagram (TMD) sheet with cadcraft. A TMD is a terminal-strip table: a
# header row (PANEL SIDE: FROM | WIRE No | <strip tag> | WIRE No | FIELD SIDE: TO | CABLE) and
# one row per terminal. Like gen-bom.ps1 it reads the current working drawing (its title-block
# attributes from the paper-space layout, and the schedule rows from model space), emits a
# cadcraft script to $D\fusion\sheets\<name>.scr, and runs it against the template to produce
# $D\fusion\out\<name>.dwg.
#
# The terminal rows are carried as a table (line + mtext), matching how the working TMD is built
# (a drawn table, not graphical terminal symbols -- see the note in the changelog for build
# 0.020). The library terminal blocks are for the SCD schematic sheets, not the schedules.
#
# Writes only inside $D\fusion.

[CmdletBinding()]
param(
    [string]$Template,
    [Parameter(Mandatory = $true)][string]$BomDrawing,   # the working TMD to read
    [string]$OutDir,
    [string]$SheetsDir
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
# Run steps in one invocation, return the last step's JSON.
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
if (-not (Test-Path -LiteralPath $BomDrawing)) { throw "TMD drawing not found: $BomDrawing" }
foreach ($d in @($OutDir, $SheetsDir)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
$cli = Resolve-CadcraftCli
$name = Split-Path -Leaf $BomDrawing                       # e.g. <project>-IC-TMD-001_A.dwg

# --- title-block attributes from the paper-space layout ----------------------------
$tbAttribs = @{}
$ll = Invoke-CliSteps -Cli $cli -Drawing $BomDrawing -Steps @('layout.list {}')
$tbLayout = ''
if ($null -ne $ll) {
    $lay = @($ll | ForEach-Object { [string]$_.name } | Where-Object { $_ -and $_ -ne 'Model' })
    if ($lay.Count -gt 0) { $tbLayout = $lay[0] }
}
if ($tbLayout) {
    $tbPaper = Invoke-CliSteps -Cli $cli -Drawing $BomDrawing -Steps @(
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
# M4-F1: the generator runs against the template, which already carries the border and title
# block in its paper-space layout. Set the attribute values on that existing reference instead
# of inserting a second one into model space. Read the layout name and A1 TITLE TEXT handle from
# the template (handles differ per file).
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

# M4-C16/C17: keep only the largest sheet window and the largest model (content) window; erase every
# other viewport. The template carries a second sheet window (41D1) and an empty detail window (41D5)
# that cadcraft's saveas promotes into the model list, so the saved sheet draws the content two or
# three times (the "duplicated" look). Identify by role (largest per id class), never by handle.
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
        $sheetHandle = ''; $sheetArea = -1.0
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
                if ($area -gt $tplVpArea) {
                    $tplVpArea = $area; $tplVpHandle = [string]$e.handle
                    if ($g.PSObject.Properties.Name -contains 'center' -and $g.center) { $tplVpCenterX = [double]$g.center.x; $tplVpCenterY = [double]$g.center.y }
                    $tplVpHeight = $h
                }
            }
        }
        $keep = @($sheetHandle, $tplVpHandle)
        $allHandles = @($tvps.entities | ForEach-Object { [string]$_.handle })
        $tplExtraVpHandles = @($allHandles | Where-Object { $_ -notin $keep })
    }
}

# --- model-space geometry (faithful rebuild) --------------------------------------
# Like gen-scd.ps1, carry every line and text across so the generated sheet matches the working
# drawing. A TMD is a drawn table (lines + text), not graphical terminal symbols, so there is no
# circle->block substitution here (see the build 0.020 note).
$ents = Invoke-CliSteps -Cli $cli -Drawing $BomDrawing -Steps @('entities {"limit":5000}')
if ($null -eq $ents) { throw 'could not read the TMD model entities' }
function JNum { param($v) return ([double]$v).ToString([System.Globalization.CultureInfo]::InvariantCulture) }

# M4-C16: the drawn content's bounding box, so the content viewport can be framed on it.
$minX = [double]::MaxValue; $minY = [double]::MaxValue; $maxX = [double]::MinValue; $maxY = [double]::MinValue
function Track-XY { param($x, $y) if ($null -ne $x -and $null -ne $y) { $x = [double]$x; $y = [double]$y; if ($x -lt $script:minX) { $script:minX = $x }; if ($x -gt $script:maxX) { $script:maxX = $x }; if ($y -lt $script:minY) { $script:minY = $y }; if ($y -gt $script:maxY) { $script:maxY = $y } } }
foreach ($e in $ents.entities) {
    $g = $e.geometry
    # Line geometry carries its endpoints as `a` and `b` (not start/end); Circle as `center`;
    # MText/Text/Insert as `insert`.
    if ($g.PSObject.Properties.Name -contains 'a' -and $g.a) { Track-XY $g.a.x $g.a.y }
    if ($g.PSObject.Properties.Name -contains 'b' -and $g.b) { Track-XY $g.b.x $g.b.y }
    if ($g.PSObject.Properties.Name -contains 'center' -and $g.center) { Track-XY $g.center.x $g.center.y }
    if ($g.PSObject.Properties.Name -contains 'insert' -and $g.insert) { Track-XY $g.insert.x $g.insert.y }
}
$hasExtents = ($minX -lt $maxX -and $minY -lt $maxY)

$lines = New-Object System.Collections.Generic.List[string]
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
# cadcraft draws on the CURRENT layer (a per-command "layer" param is ignored), so switch the
# current layer before each group of same-layer entities or everything lands on "Viewport".
$curLayer = ''
function Emit-Layer {
    param([string]$Name)
    if ($Name -and $Name -ne $curLayer) {
        $script:lines.Add('layer.current {"name":' + (ConvertTo-JsonStringValue -Value $Name) + '}')
        $script:curLayer = $Name
    }
}
Emit-Layer 'Preliminary Not For Construction'
$lines.Add('mtext {"at":[768,72],"text":"PRELIMINARY","height":4,"style":"Romans"}')
$lines.Add('mtext {"at":[753,66],"text":"NOT FOR CONSTRUCTION","height":4,"style":"Romans"}')

$carried = 0
foreach ($e in $ents.entities) {
    $g = $e.geometry
    Emit-Layer ([string]$e.layer)
    switch ($e.type) {
        'Line' {
            if ($g.PSObject.Properties.Name -contains 'a' -and $g.PSObject.Properties.Name -contains 'b') {
                $lines.Add('line {"points":[[' + (JNum $g.a.x) + ',' + (JNum $g.a.y) + '],[' + (JNum $g.b.x) + ',' + (JNum $g.b.y) + ']],"layer":' + (ConvertTo-JsonStringValue -Value $e.layer) + '}')
                $carried++
            }
        }
        'MText' {
            if ($g.PSObject.Properties.Name -contains 'insert') {
                $lines.Add('mtext {"at":[' + (JNum $g.insert.x) + ',' + (JNum $g.insert.y) + '],"text":' + (ConvertTo-JsonStringValue -Value $g.contents) + ',"height":' + (JNum $g.height) + ',"layer":' + (ConvertTo-JsonStringValue -Value $e.layer) + '}')
                $carried++
            }
        }
        'Circle' {
            if ($g.PSObject.Properties.Name -contains 'center') {
                $lines.Add('circle {"center":[' + (JNum $g.center.x) + ',' + (JNum $g.center.y) + '],"radius":' + (JNum $g.radius) + ',"layer":' + (ConvertTo-JsonStringValue -Value $e.layer) + '}')
                $carried++
            }
        }
    }
}

$outDwg = Join-Path $OutDir $name
# M4-C16/C17: switch to the layout, erase the extra viewports (duplicate sheet + empty detail), then
# frame the content viewport on the drawn content's extents (see gen-scd.ps1 for the note).
if ($tplLayout) {
    $lines.Add('layout.set {"name":' + (ConvertTo-JsonStringValue -Value $tplLayout) + '}')
}
if ($tplExtraVpHandles.Count -gt 0) {
    $hjson = ($tplExtraVpHandles | ForEach-Object { ConvertTo-JsonStringValue -Value $_ }) -join ','
    $lines.Add('erase {"handles":[' + $hjson + ']}')
}
if ($tplVpHandle -and $hasExtents) {
    $cx = ($minX + $maxX) / 2.0
    $cy = ($minY + $maxY) / 2.0
    $cw = $maxX - $minX
    $ch = $maxY - $minY
    # M4-C18: frame the content window as the working drawings do (view = window centre, viewHeight =
    # window height); fall back to content-centred framing only if the content doesn't fit that view.
    $aspect = if ($tplVpHeight -gt 0) { $tplVpArea / ($tplVpHeight * $tplVpHeight) } else { 1.55 }
    $shownW = $tplVpHeight * $aspect
    $fitsInWindow = ([Math]::Abs($cx - $tplVpCenterX) -le ($shownW / 2.0)) -and ([Math]::Abs($cy - $tplVpCenterY) -le ($tplVpHeight / 2.0)) -and ($cw -le $shownW) -and ($ch -le $tplVpHeight)
    if ($fitsInWindow) {
        $lines.Add('viewport.set {"handle":' + (ConvertTo-JsonStringValue -Value $tplVpHandle) + ',"locked":false,"center":[' + (JNum $tplVpCenterX) + ',' + (JNum $tplVpCenterY) + '],"viewHeight":' + (JNum $tplVpHeight) + '}')
    } else {
        $vh = [Math]::Max($ch, $cw / $aspect) * 1.1
        if ($vh -lt 1.0) { $vh = 100.0 }
        $lines.Add('viewport.set {"handle":' + (ConvertTo-JsonStringValue -Value $tplVpHandle) + ',"locked":false,"center":[' + (JNum $cx) + ',' + (JNum $cy) + '],"viewHeight":' + (JNum $vh) + '}')
    }
}
# M4-C14 + M5 lineweights: plot monochrome with entity lineweights honoured, like the Reference
# (see gen-scd.ps1 for the full note).
if ($tplLayout) {
    $lines.Add('pagesetup {"layout":' + (ConvertTo-JsonStringValue -Value $tplLayout) + ',"plotStyleTable":"monochrome.ctb","lineweights":true}')
}

$lines.Add('saveas {"path":' + (ConvertTo-JsonStringValue -Value $outDwg) + ',"version":2018}')

$scrPath = Join-Path $SheetsDir (($name -replace '\.dwg$', '') + '.scr')
[System.IO.File]::WriteAllLines($scrPath, $lines, (New-Object System.Text.ASCIIEncoding))
Write-Host "wrote $scrPath ($($lines.Count) commands, $carried model entities carried)"

# --- run it ----------------------------------------------------------------------
if (Test-Path -LiteralPath $outDwg) { Remove-Item -LiteralPath $outDwg -Force }
$bat = [System.IO.Path]::GetTempFileName() + '.cmd'
$runLine = '"' + $cli + '" run "' + $Template + '" --script-file "' + $scrPath + '"'
[System.IO.File]::WriteAllText($bat, "@echo off`r`n$runLine`r`n", (New-Object System.Text.ASCIIEncoding))
$pi = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', (Get-ArgumentForNative -Value $bat)) -NoNewWindow -PassThru
if (-not $pi.WaitForExit(300000)) { try { $pi.Kill() } catch { } }
Remove-Item -LiteralPath $bat -Force -ErrorAction SilentlyContinue

if (-not (Test-Path -LiteralPath $outDwg)) { Write-Error 'generated sheet was not written'; exit 1 }
Write-Host "generated $outDwg ($((Get-Item -LiteralPath $outDwg).Length) bytes)"
Write-Host "PASS M4 (TMD sheet generated by cadcraft): $name"
exit 0
