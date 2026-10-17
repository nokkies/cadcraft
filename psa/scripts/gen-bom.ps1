# gen-bom.ps1 -- cadcraft card M4-C2
#
# Builds the bill-of-materials sheet with cadcraft (not the C# generator). It reads the item
# rows from the existing BOM drawing (so the data is the current BOM, not a copy), writes a
# cadcraft script to $D\fusion\sheets\bom.scr, and runs it against the template to produce
# $D\fusion\out\NNNN-IC-GAD-002_A.dwg.
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
        # The CLI prints one JSON object per step; the last line is the texts result.
        $text = [System.IO.File]::ReadAllText($tmpOut)
        $jsonLines = @($text -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') })
        if ($jsonLines.Count -eq 0) { return $null }
        try { return ($jsonLines[-1] | ConvertFrom-Json) } catch { return $null }
    } catch { return $null } finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr, $bat -Force -ErrorAction SilentlyContinue
    }
}

$D = Get-PSADrawingsRoot
if ([string]::IsNullOrWhiteSpace($Template)) { $Template = Join-Path $D 'Template\NNNN-TEMPLATE_A.dwg' }
if ([string]::IsNullOrWhiteSpace($BomDrawing)) { $BomDrawing = Join-Path $D '3. Working\NNNN-IC-GAD-002_A.dwg' }
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

# --- model-space geometry (faithful rebuild) --------------------------------------
# Like gen-tmd.ps1 and gen-scd.ps1, carry every model line and text across so the generated sheet
# matches the working drawing's exact table geometry. The whole BOM (frame, column rules, every
# cell) is drawn on the TITLEBLOCK layer in model space; re-emitting it on a fresh grid lost the
# source's 32 table lines (build 0.034 fixes that). The title block and border are inserted with
# the attributes read from the paper-space layout.
$ents = Invoke-CliSteps -Cli $cli -Drawing $BomDrawing -Steps @('entities {"limit":5000}')
if ($null -eq $ents) { throw 'could not read the BOM model entities' }
function JNum { param($v) return ([double]$v).ToString([System.Globalization.CultureInfo]::InvariantCulture) }

$lines = New-Object System.Collections.Generic.List[string]
$attribJson = ($tbAttribs.Keys | Sort-Object | ForEach-Object {
    (ConvertTo-JsonStringValue -Value $_) + ':' + (ConvertTo-JsonStringValue -Value $tbAttribs[$_])
}) -join ','
$lines.Add('insert {"name":"A1 TITLE TEXT","at":[0,0],"attribs":{' + $attribJson + '}}')
$lines.Add('insert {"name":"A1 BORDER","at":[0,0]}')
$lines.Add('mtext {"at":[768,72],"text":"PRELIMINARY","height":4,"style":"Romans","layer":"Preliminary Not For Construction"}')
$lines.Add('mtext {"at":[753,66],"text":"NOT FOR CONSTRUCTION","height":4,"style":"Romans","layer":"Preliminary Not For Construction"}')

$carried = 0
foreach ($e in $ents.entities) {
    $g = $e.geometry
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

$outDwg = Join-Path $OutDir 'NNNN-IC-GAD-002_A.dwg'
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
