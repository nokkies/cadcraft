# gen-bom.ps1 -- cadcraft card M4-C2
#
# Builds the bill-of-materials sheet with cadcraft (not the C# generator). It reads the item
# rows from the existing BOM drawing (so the data is the current BOM, not a copy), writes a
# cadcraft script to $D\fusion\sheets\bom.scr, and runs it against the template to produce
# $D\fusion\out\<bom sheet>.dwg (the -IC-GAD-002 sheet from $Project.sheets).
#
# The script it emits follows psa\scripts\sheets\bom.scr.example: insert the title block with
# attributes, draw the table with line + mtext, saveas. The row data is read from the current
# BOM so the generated sheet matches the working drawing (until the BOM is itself generated, at
# which point the data source moves upstream).
#
# Writes only inside $D\fusion.

[CmdletBinding()]
param(
    [string]$Template,
    [string]$BomDrawing,
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
    throw 'PSA_DRAWINGS is not set to an existing folder. Ask Reinach for it (see psa/PLAN.md).'
}

function Resolve-CadcraftCli {
    $cmd = Get-Command 'cadcraft-cli' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $exe = 'C:\Users\ReinachvanNieuwenhui\src\cadcraft\target\release\cadcraft-cli.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    throw 'cadcraft-cli not found. Run cards M0-C2 and M0-C3.'
}

function Get-ArgumentForNative {
    param([string]$Value)
    return '"' + $Value.Replace('"', '""') + '"'
}

# Run one --cmd step against a drawing and return parsed JSON.
function Invoke-CliStep {
    param([string]$Cli, [string]$Drawing, [string]$Step)
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    $bat = [System.IO.Path]::GetTempFileName() + '.cmd'
    try {
        $line = '"' + $Cli + '" run "' + $Drawing + '" --cmd "' + $Step.Replace('"', '\"') + '"'
        [System.IO.File]::WriteAllText($bat, "@echo off`r`n$line`r`n", (New-Object System.Text.ASCIIEncoding))
        $pi = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', (Get-ArgumentForNative -Value $bat)) `
                -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        if (-not $pi.WaitForExit(120000)) { try { $pi.Kill() } catch { }; return $null }
        if ($pi.ExitCode -ne 0) { return $null }
        try { return (([System.IO.File]::ReadAllText($tmpOut)) | ConvertFrom-Json) } catch { return $null }
    } catch { return $null } finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr, $bat -Force -ErrorAction SilentlyContinue
    }
}

# JSON-escape a string value (backslash and double quote) for embedding in a command's JSON.
function ConvertTo-JsonStringValue {
    param([string]$Value)
    $esc = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $esc + '"'
}

# Run a sequence of --cmd steps in ONE invocation and return the LAST step's parsed JSON.
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
        # The CLI prints one JSON object (or array, e.g. layout.list) per step; the last line is the result.
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
$bomSheet = @($Project.sheets | Where-Object { $_ -match '-IC-GAD-002' })[0]
if ([string]::IsNullOrWhiteSpace($Template)) { $Template = Join-Path $D ($Project.template -replace '/', '\') }
if ([string]::IsNullOrWhiteSpace($BomDrawing)) { $BomDrawing = Join-Path $D ($Project.workingDir + '\' + $bomSheet + '.dwg') }
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $D 'fusion\out' }
if ([string]::IsNullOrWhiteSpace($SheetsDir)) { $SheetsDir = Join-Path $D 'fusion\sheets' }

if (-not (Test-Path -LiteralPath $Template)) { throw "template not found: $Template" }
if (-not (Test-Path -LiteralPath $BomDrawing)) { throw "BOM drawing not found: $BomDrawing" }
foreach ($d in @($OutDir, $SheetsDir)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

$cli = Resolve-CadcraftCli

# --- read the title-block attributes to carry them onto the generated sheet --------
# The title block lives in the paper-space layout, so read it after layout.set (the same lesson
# as card M2-C1: `texts` reads the current space, and a fresh open is model space).
$tbAttribs = @{}
# Find the BOM's paper-space layout name. Prefer the cached info JSON; if it is not there (the
# path did not flatten to the cache name), ask the CLI directly.
$bomRel = ($BomDrawing -replace [regex]::Escape($D + '\'), '') -replace '\\', '__' -replace '\.dwg$', ''
$bomInfo = Join-Path (Join-Path $D 'fusion\info') ($bomRel + '.dwg.json')
$tbLayout = ''
if (Test-Path -LiteralPath $bomInfo) {
    $lay = @( ((Get-Content -LiteralPath $bomInfo -Raw | ConvertFrom-Json).layouts | ForEach-Object { [string]$_ }) | Where-Object { $_ -ne 'Model' } )
    if ($lay.Count -gt 0) { $tbLayout = $lay[0] }
}
if ([string]::IsNullOrWhiteSpace($tbLayout)) {
    $ll = Invoke-CliStep -Cli $cli -Drawing $BomDrawing -Step 'layout.list {}'
    if ($null -ne $ll) {
        # layout.list returns an array of {name, ...} objects.
        $lay = @($ll | ForEach-Object { [string]$_.name } | Where-Object { $_ -and $_ -ne 'Model' })
        if ($lay.Count -gt 0) { $tbLayout = $lay[0] }
    }
}
if (-not [string]::IsNullOrWhiteSpace($tbLayout)) {
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
# Fall back to model-space tags if the layout read found none (a drawing that keeps its title
# block in model space).
if ($tbAttribs.Count -eq 0) {
    $tbModel = Invoke-CliSteps -Cli $cli -Drawing $BomDrawing -Steps @('texts {"limit":1000}')
    if ($null -ne $tbModel) {
        foreach ($t in $tbModel.texts) {
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
# other viewport (see gen-scd.ps1 for the note). Identify by role, never by handle.
$tplVpHandle = ''
$tplVpArea = -1.0
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
                if ($area -gt $tplVpArea) { $tplVpArea = $area; $tplVpHandle = [string]$e.handle }
            }
        }
        $keep = @($sheetHandle, $tplVpHandle)
        $allHandles = @($tvps.entities | ForEach-Object { [string]$_.handle })
        $tplExtraVpHandles = @($allHandles | Where-Object { $_ -notin $keep })
    }
}

# --- model-space geometry (faithful rebuild) --------------------------------------
# Like gen-tmd.ps1 and gen-scd.ps1, carry every model line and text across so the generated sheet
# matches the working drawing's exact table geometry. The whole BOM (frame, column rules, every
# cell) is drawn on the TITLEBLOCK layer in model space; re-emitting it on a fresh grid lost the
# source's 32 table lines (build 0.034 fixes that). The title block and border are inserted with
# the attributes read from the paper-space layout.
$ents = Invoke-CliSteps -Cli $cli -Drawing $BomDrawing -Steps @('entities {"limit":5000}')
if ($null -eq $ents) { throw 'could not read the BOM model entities' }
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

$outDwg = Join-Path $OutDir ($bomSheet + '.dwg')
# M4-C14 + M5 lineweights: plot monochrome with entity lineweights honoured, like the Reference
# (see gen-scd.ps1 for the full note).
if ($tplLayout) {
    $lines.Add('pagesetup {"layout":' + (ConvertTo-JsonStringValue -Value $tplLayout) + ',"plotStyleTable":"monochrome.ctb","lineweights":true}')
}

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
    $aspect = 1.55
    $vh = [Math]::Max($ch, $cw / $aspect) * 1.1
    if ($vh -lt 1.0) { $vh = 100.0 }
    $lines.Add('viewport.set {"handle":' + (ConvertTo-JsonStringValue -Value $tplVpHandle) + ',"locked":false,"center":[' + (JNum $cx) + ',' + (JNum $cy) + '],"viewHeight":' + (JNum $vh) + '}')
}

$lines.Add('saveas {"path":' + (ConvertTo-JsonStringValue -Value $outDwg) + ',"version":2018}')

$scrPath = Join-Path $SheetsDir 'bom.scr'
[System.IO.File]::WriteAllLines($scrPath, $lines, (New-Object System.Text.ASCIIEncoding))
Write-Host "wrote $scrPath ($($lines.Count) commands, $carried model entities carried)"

# --- run it ------------------------------------------------------------------------
if (Test-Path -LiteralPath $outDwg) { Remove-Item -LiteralPath $outDwg -Force }
$bat = [System.IO.Path]::GetTempFileName() + '.cmd'
$runLine = '"' + $cli + '" run "' + $Template + '" --script-file "' + $scrPath + '"'
[System.IO.File]::WriteAllText($bat, "@echo off`r`n$runLine`r`n", (New-Object System.Text.ASCIIEncoding))
$pi = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', (Get-ArgumentForNative -Value $bat)) -NoNewWindow -PassThru
if (-not $pi.WaitForExit(300000)) { try { $pi.Kill() } catch { } }
Remove-Item -LiteralPath $bat -Force -ErrorAction SilentlyContinue

if (-not (Test-Path -LiteralPath $outDwg)) { Write-Error 'generated sheet was not written'; exit 1 }
Write-Host "generated $outDwg ($((Get-Item -LiteralPath $outDwg).Length) bytes)"
Write-Host 'PASS M4-C2 (BOM sheet generated by cadcraft)'
exit 0
