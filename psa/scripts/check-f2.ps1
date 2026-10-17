# check-f2.ps1 -- card M4-F2: the plotted sheet shows content, not an empty frame.
#
# The empty-plot defect (psa/REVIEW-0.053.md section 2): the generated sheets plotted as four
# identical PDFs of exactly 39144 bytes -- the template's border + title block with nothing in the
# drawing area. Root cause found in M4-F2: cadcraft draws on the CURRENT layer (a per-command
# "layer" param is ignored), so every generated entity landed on layer "Viewport" (frozen in the
# content viewport) and never showed through the viewport. The generators now switch the current
# layer before each group of same-layer entities.
#
# This check plots every generated sheet's paper-space layout with exportpdf and requires the PDF to
# be clearly larger than the template's own empty plot (the same border + title block, no content).
# A sheet that still plots empty comes back at (or under) the baseline and FAILs.
#
# This is a size heuristic, not the eyeball check. The plot is the check and the twelve sheets are
# viewed with yes/no answers at M4-F5. Exit 0 when every sheet plots with content, 1 otherwise.

[CmdletBinding()]
param(
    [string]$OutDir,
    # A generated plot must exceed the empty baseline by at least this many bytes to count as content.
    [int]$MinContentBytes = 5000
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
function Get-ArgumentForNative { param([string]$Value) return '"' + $Value.Replace('"', '""') + '"' }

$D = Get-PSADrawingsRoot
. (Join-Path $PSScriptRoot 'project.ps1')
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $D 'fusion\out' }
if (-not (Test-Path -LiteralPath $OutDir)) { throw "out dir not found: $OutDir" }

function Resolve-CadcraftCli {
    $cmd = Get-Command 'cadcraft-cli' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $exe = 'C:\Users\ReinachvanNieuwenhui\src\cadcraft\target\release\cadcraft-cli.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    throw 'cadcraft-cli not found.'
}
$cli = Resolve-CadcraftCli

$plotDir = Join-Path $D 'fusion\plots'
if (-not (Test-Path -LiteralPath $plotDir)) { New-Item -ItemType Directory -Path $plotDir -Force | Out-Null }

function Get-LayoutPlotBytes {
    param([string]$Drawing, [string]$Layout, [string]$OutBase)
    $scr = [System.IO.Path]::GetTempFileName() + '.scr'
    $cmd = 'exportpdf {"path":' + ($OutBase | ConvertTo-Json) + ',"layouts":[' + ($Layout | ConvertTo-Json) + ']}'
    [System.IO.File]::WriteAllText($scr, $cmd + "`n", (New-Object System.Text.ASCIIEncoding))
    $bat = [System.IO.Path]::GetTempFileName() + '.cmd'
    $line = '"' + $cli + '" run "' + $Drawing + '" --script-file "' + $scr + '"'
    [System.IO.File]::WriteAllText($bat, "@echo off`r`n$line`r`n", (New-Object System.Text.ASCIIEncoding))
    $pi = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', (Get-ArgumentForNative $bat)) -NoNewWindow -PassThru -RedirectStandardOutput ([System.IO.Path]::GetTempFileName())
    if (-not $pi.WaitForExit(120000)) { try { $pi.Kill() } catch { } }
    Remove-Item $scr, $bat -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $OutBase) { return (Get-Item -LiteralPath $OutBase).Length }
    return -1
}

function Get-FirstLayout {
    param([string]$Drawing)
    $scr = [System.IO.Path]::GetTempFileName() + '.scr'
    [System.IO.File]::WriteAllText($scr, "layout.list {}`n", (New-Object System.Text.ASCIIEncoding))
    $outFile = [System.IO.Path]::GetTempFileName()
    $bat = [System.IO.Path]::GetTempFileName() + '.cmd'
    $line = '"' + $cli + '" run "' + $Drawing + '" --script-file "' + $scr + '"'
    [System.IO.File]::WriteAllText($bat, "@echo off`r`n$line`r`n", (New-Object System.Text.ASCIIEncoding))
    $pi = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', (Get-ArgumentForNative $bat)) -NoNewWindow -PassThru -RedirectStandardOutput $outFile
    if (-not $pi.WaitForExit(120000)) { try { $pi.Kill() } catch { } }
    $txt = ''
    if (Test-Path -LiteralPath $outFile) { $txt = [System.IO.File]::ReadAllText($outFile); Remove-Item $outFile -Force }
    Remove-Item $scr, $bat -Force -ErrorAction SilentlyContinue
    $lay = @([regex]::Matches($txt, '"name":"([^"]*)"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -and $_ -ne 'Model' }) | Select-Object -First 1
    if ($lay) { return $lay }
    return 'Layout1'
}

# The empty baseline: the template's own paper-space plot (border + title block, no content).
$tpl = Join-Path $D ($Project.template -replace '/', '\')
$tplLayout = Get-FirstLayout $tpl
$baseline = Get-LayoutPlotBytes -Drawing $tpl -Layout $tplLayout -OutBase (Join-Path $plotDir 'f2_baseline_template')
if ($baseline -lt 0) { throw 'could not plot the template for the empty baseline' }
Write-Host "empty baseline (template plot): $baseline bytes"

$sheets = Get-ChildItem -LiteralPath $OutDir -Filter '*.dwg' | Sort-Object Name
if ($sheets.Count -eq 0) { throw "no sheets in $OutDir" }

$failCount = 0
foreach ($dwg in $sheets) {
    $lay = Get-FirstLayout $dwg.FullName
    $bytes = Get-LayoutPlotBytes -Drawing $dwg.FullName -Layout $lay -OutBase (Join-Path $plotDir ('f2_' + $dwg.BaseName))
    if ($bytes -ge ($baseline + $MinContentBytes)) {
        Write-Host ("PASS  {0}  plot {1} bytes (layout {2}), {3} over empty baseline" -f $dwg.Name, $bytes, $lay, ($bytes - $baseline))
    } else {
        Write-Host ("FAIL  {0}  plot {1} bytes (layout {2}) -- at/below empty baseline {3} (no content showing)" -f $dwg.Name, $bytes, $lay, $baseline)
        $failCount++
    }
}

if ($failCount -eq 0) {
    Write-Host ("PASS M4-F2 (all {0} sheets plot with content; every plot exceeds the {1}-byte empty frame)" -f $sheets.Count, $baseline)
    exit 0
} else {
    Write-Host ("FAIL M4-F2 ({0} sheet(s) plot empty)" -f $failCount)
    exit 1
}
