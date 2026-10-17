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

# --- model-space geometry (faithful rebuild) --------------------------------------
# Like gen-scd.ps1, carry every line and text across so the generated sheet matches the working
# drawing. A TMD is a drawn table (lines + text), not graphical terminal symbols, so there is no
# circle->block substitution here (see the build 0.020 note).
$ents = Invoke-CliSteps -Cli $cli -Drawing $BomDrawing -Steps @('entities {"limit":5000}')
if ($null -eq $ents) { throw 'could not read the TMD model entities' }
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

$outDwg = Join-Path $OutDir $name
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
