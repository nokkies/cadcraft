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
#
# What the heuristic can and cannot see, since a passing proxy invites over-trust.
#
# It CAN see: nothing being drawn at all. That is the defect it was written for and it is the right shape
# for a byte count -- an empty sheet is the template's border and title block and nothing else, so its plot
# sits near the baseline. check-f5, on the same plot path, was proven to bite: two different sheet names
# given identical content came back "identical plot to ..." and exited 1.
#
# It CANNOT see: content that is drawn but wrong. Two specific blind spots, both measured rather than
# assumed. (a) Placement -- a sheet framed off-screen, scaled to a speck, or duplicated still carries well
# over baseline+5000 bytes, because byte size is indifferent to where the ink is. (b) Partial emptiness --
# freezing six content layers inside the content viewport (0, 1T, 3C, 3T, 25C and the stamp layer) on
# SCD-001 still plotted 53,308 bytes against 63,557 unfrozen, comfortably above baseline+5000, and
# check-f2 PASSED it. That is a sheet that lost roughly a fifth of its plotted bytes and about 40% of its
# ink items (9,018 against 15,274).
#
# (b) is a real coverage gap, not a documentation footnote, and it is not covered by the neighbours either.
# The same frozen sheet was run against every check that could plausibly see it: check-f2 PASS, check-f5
# PASS, check-f6 PASS, check-detail PASS (detail window 94% of ink against a source at 71%, a 32% drift
# inside the 35% tolerance), check-textheights PASS. Only check-f7 caught it, and by entity count rather
# than by appearance. So a sheet can lose a large fraction of its drawing and the plot-side checks let it
# through, because each measures a quantity that freezing layers happens not to move much: bytes, hashes,
# viewport framing, a ratio inside a generous band, text sizes.
#
# What would close it is a whole-sheet ink comparison against the source, the same shape as check-detail but
# over the entire page rather than the detail window -- check-detail already computes both numbers, so the
# data is there. It is deliberately not added here: check-detail's own first version was rejected at build
# 0.109 for asserting a threshold nobody had measured against the reference, and a whole-sheet tolerance
# would need the same measurement before it can be written down. Recorded as the next thing to do, with the
# frozen sheet as its negative test.

[CmdletBinding()]
param(
    [string]$OutDir,
    # A generated plot must exceed the empty baseline by at least this many bytes to count as content.
    [int]$MinContentBytes = 5000,
    [string]$FontAlt = 'arial.ttf'   # SHX text substitution for the plotted PDFs (see export-pdf.ps1)
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($FontAlt)) {
    Remove-Item Env:\CADCRAFT_FONTALT -ErrorAction SilentlyContinue
} else {
    $env:CADCRAFT_FONTALT = $FontAlt
}

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

# Wrapped in @(): with ONE sheet in the directory the pipeline returns a bare FileInfo, and StrictMode 3.0
# rejects .Count on it. check-f2 had never been run against a single-sheet directory before build 0.115, so
# this sat latent -- it only ever ran through gen-all, on all twelve.
$sheets = @(Get-ChildItem -LiteralPath $OutDir -Filter '*.dwg' | Sort-Object Name)
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
