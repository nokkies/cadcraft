# check-sheetink.ps1 -- card M4-C23: a generated sheet plots the same amount of drawing as its source.
#
# Why this exists. Build 0.115 measured a hole: freeze six content layers inside a generated sheet's content
# viewport and roughly 40% of the drawing stops plotting (9,018 ink items against 15,274), and check-f2,
# check-f5, check-f6 and check-textheights ALL pass it. Each of those measures a quantity that
# losing content happens not to move much -- PDF bytes, hashes, viewport framing, one ratio inside a generous
# band, text sizes. Only check-f7 noticed, by entity count, which is a data check and says nothing about what
# reaches the page. check-f2's header records this as the gap and names the fix as a whole-sheet ink
# comparison; this is that check.
#
# What it measures. Both sheets are plotted through cadcraft's own exportpdf -- source and generated, each
# read through ITS OWN paper-space layout name, because the working drawings name their layout after the
# sheet while the generated ones use Layout1. Then every vector path item on the plotted page is counted.
# The generated count must sit inside a tolerance band around the source count.
#
# The tolerance, measured rather than invented. Build 0.109 rejected check-detail's first version for
# asserting a threshold nobody had checked against the reference, so this one is calibrated on the real set
# before being written down. Whole-sheet ink ratio, generated over source, all twelve sheets, after the
# orphan-viewport and viewport-framing fixes (builds 0.126/0.127): every sheet is exactly 1.0000. There is
# no outlier. The default tolerance is +/-10%, generous enough to absorb the annotations the generators add
# and tight enough that a sheet losing a frozen-viewport's worth of ink fails.
#
# A note on history: this band was originally calibrated with GAD-001 sitting at 2.0087, blamed on a
# "TrueType balloon defect" (psa/pr/true-type-attribute-scale.md). That was wrong twice over -- the oversized
# balloon text was a source-data trait (withdrawn at build 0.123), and the 2.0087 itself was the general
# arrangement's viewport being framed too tight (fixed at build 0.127, M4-G2). With the fixed sources and the
# correct framing, GAD-001 plots at 1.0000 like every other sheet, so there is no known defect to hold a band
# open for.
#
# THE MEASUREMENT ROUTE IS PART OF THE MEASUREMENT, and this is the reason for the FontAlt parameter. The
# count depends on how text is rasterised: with CADCRAFT_FONTALT=arial.ttf, SCD-001's source plots 832 path
# items; without it, the same sheet plots 15,300. Eighteen times. That is not noise -- with the substitution
# cadcraft emits text as TrueType glyph outlines (embedded fonts, counted as few paths) and without it it
# emits its own stroke font (every glyph as line segments). Both sides of a comparison must therefore be
# plotted with the SAME substitution setting, which this script enforces by setting it once, before any plot.
# The first version of this check was calibrated at 1.0000..1.0764 with FONTALT unset and then run with it
# set, which is why it reported GAD-001 at 2.0087 against a band that had never been measured that way.
# Ratios are stable within a setting (1.0 on eleven sheets under FONTALT, 1.0 on seven under none), so the
# check is sound as long as one setting is used throughout -- which is what the parameter guarantees.
#
# Asymmetric on purpose. Losing ink is the failure this check was written for. Gaining ink is a different
# defect (duplication, or the text-scale bug) and check-f6 and check-textheights cover it; a sheet that gains
# more than the tolerance is still reported, but the band is generous upward because the generators are
# known to add annotations.
#
# Exit 0 when every generated sheet plots within the band of its source, 1 otherwise.

[CmdletBinding()]
param(
    [string]$OutDir,
    # How far the generated sheet's plotted ink may sit from its source's, as a fraction of the source.
    # Calibrated above; measured against the reference rather than chosen to separate one case.
    [double]$Tolerance = 0.10,
    [string]$FontAlt = 'arial.ttf'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-PSADrawingsRoot {
    foreach ($scope in 'Process', 'User', 'Machine') {
        $v = [Environment]::GetEnvironmentVariable('PSA_DRAWINGS', $scope)
        if (-not [string]::IsNullOrWhiteSpace($v) -and (Test-Path -LiteralPath $v)) { return $v.TrimEnd('\') }
    }
    throw 'PSA_DRAWINGS is not set to an existing folder'
}

$D = Get-PSADrawingsRoot
. (Join-Path $PSScriptRoot 'project.ps1')
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $D 'fusion\out' }
if (-not (Test-Path -LiteralPath $OutDir)) { throw "out dir not found: $OutDir" }

$script:pythonExe = $null
function Resolve-Python {
    # Skip the WindowsApps stub: it is an app-execution alias, not a real interpreter, and running it
    # produces nothing useful. Falls back to the known-good install.
    $c = Get-Command python -ErrorAction SilentlyContinue
    if ($c -and $c.Source -notmatch 'WindowsApps' -and (Test-Path -LiteralPath $c.Source)) { $script:pythonExe = $c.Source; return }
    foreach ($p in 'C:\Python314\python.exe', 'C:\Python312\python.exe') {
        if (Test-Path -LiteralPath $p) { $script:pythonExe = $p; return }
    }
    throw 'no usable python interpreter found'
}
Resolve-Python

$cli = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'target\release\cadcraft-cli.exe'
if (-not (Test-Path -LiteralPath $cli)) { $c = Get-Command cadcraft-cli -ErrorAction SilentlyContinue; if ($c) { $cli = $c.Source } }
if (-not (Test-Path -LiteralPath $cli)) { throw "cadcraft-cli not found at $cli" }
$runStep = Join-Path $PSScriptRoot 'run-step.ps1'

if ([string]::IsNullOrWhiteSpace($FontAlt)) { Remove-Item Env:\CADCRAFT_FONTALT -ErrorAction SilentlyContinue }
else { $env:CADCRAFT_FONTALT = $FontAlt }

# Scratch lives under the project dir, never %TEMP%: the 8.3 short form of %TEMP% breaks python's
# site-packages import.
$tmp = Join-Path $D ('fusion\colour-check\shink-' + [Guid]::NewGuid().ToString('N'))
$script:pyFile = $null
try {
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    $py = @'
import fitz, os, sys, json

def items(path):
    if not os.path.exists(path):
        return -1
    d = fitz.open(path)
    n = 0
    for dr in d[0].get_drawings():
        n += len(dr.get("items", []))
    d.close()
    return n

rows = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    name, sp, gp = line.split("|")
    s = items(sp)
    g = items(gp)
    rows.append({"name": name, "src": s, "gen": g,
                 "ratio": (round(g / s, 4) if s > 0 else None)})
print(json.dumps(rows))
'@
    $script:pyFile = Join-Path $tmp 'sheetink.py'
    [System.IO.File]::WriteAllText($script:pyFile, $py, (New-Object System.Text.ASCIIEncoding))

    # Wrapped in @(): one sheet in the directory yields a bare FileInfo and StrictMode rejects .Count.
    $genSheets = @(Get-ChildItem -LiteralPath $OutDir -Filter '*.dwg' | Sort-Object Name)
    if ($genSheets.Count -eq 0) { throw "no sheets in $OutDir" }

    $pairs = @()
    foreach ($g in $genSheets) {
        $n = $g.BaseName
        $srcPath = Join-Path $D ($Project.workingDir + '\' + $n + '.dwg')
        if (-not (Test-Path -LiteralPath $srcPath)) { Write-Host "FAIL $n (no source sheet to compare against)"; continue }

        # Each side through its OWN layout name -- the source names it after the sheet, the generated uses Layout1.
        $srcLayouts = @(([regex]::Matches((& pwsh -NoProfile -File $runStep $srcPath 'layout.list {}' | Select-Object -Last 1), '"name":"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }) | Where-Object { $_ -ne 'Model' })
        if ($srcLayouts.Count -eq 0) { Write-Host "FAIL $n (source sheet has no paper-space layout)"; continue }

        $bSrc = Join-Path $tmp ('s_' + $n)
        $bGen = Join-Path $tmp ('g_' + $n)
        Remove-Item $bSrc, $bGen -Force -ErrorAction SilentlyContinue

        # exportpdf takes `layouts` (an array) and a path with NO extension appended. Both sides go through
        # run-step.ps1, the same path every other plot check uses: an inline script-file built here produced
        # plots with roughly a fifteenth of the ink, so the two sides must be plotted identically or the
        # ratio measures the plotting route rather than the drawing.
        $null = (& pwsh -NoProfile -File $runStep $srcPath ('layout.set ' + (@{ name = $srcLayouts[0] } | ConvertTo-Json -Compress)) ('exportpdf {"path":' + ($bSrc | ConvertTo-Json) + ',"layouts":[' + ($srcLayouts[0] | ConvertTo-Json) + ']}') 2>&1 | Out-String)
        $null = (& pwsh -NoProfile -File $runStep $g.FullName 'layout.set {"name":"Layout1"}' ('exportpdf {"path":' + ($bGen | ConvertTo-Json) + ',"layouts":[' + ('Layout1' | ConvertTo-Json) + ']}') 2>&1 | Out-String)

        if (-not (Test-Path -LiteralPath $bSrc) -or -not (Test-Path -LiteralPath $bGen)) {
            Write-Host "FAIL $n (could not plot one of the two sheets)"
            continue
        }
        $pairs += ($n + '|' + $bSrc + '|' + $bGen)
    }

    if ($pairs.Count -eq 0) { Write-Host 'FAIL M4-C23 (no sheet pair could be plotted)'; exit 1 }

    $raw = ($pairs | & $script:pythonExe $script:pyFile 2>&1 | ForEach-Object { "$_" })
    $jsonLine = @($raw | Where-Object { $_ -match '^\s*\[' } | Select-Object -Last 1)
    if ($jsonLine.Count -eq 0) {
        Write-Host 'FAIL M4-C23 (the ink counter returned no result)'
        ($raw | Select-Object -First 3) | ForEach-Object { Write-Host ("  " + $_) }
        exit 1
    }
    $rows = @($jsonLine[0] | ConvertFrom-Json)

    $bad = 0
    $worst = 0.0
    foreach ($r in $rows) {
        if ($r.src -le 0 -or $null -eq $r.ratio) { Write-Host ("FAIL {0} (source plotted no ink; nothing to compare)" -f $r.name); $bad++; continue }
        $drift = [Math]::Abs([double]$r.ratio - 1.0)
        if ($drift -gt [Math]::Abs($worst)) { $worst = $drift }
        if ($drift -gt $Tolerance) {
            $dir = if ([double]$r.ratio -lt 1.0) { 'missing drawing' } else { 'extra drawing' }
            Write-Host ("FAIL {0} (plots {1} ink items against a source {2}: {3}x, {4})" -f $r.name, $r.gen, $r.src, $r.ratio, $dir)
            $bad++
        } else {
            Write-Host ("PASS {0} (plots {1} ink items against a source {2}: {3}x)" -f $r.name, $r.gen, $r.src, $r.ratio)
        }
    }

    # Anti-vacuity: a comparison that saw no ink is not a pass. This is the shape that produced two vacuous
    # PASS lines in build 0.112, so it is checked rather than assumed.
    $withInk = @($rows | Where-Object { $_.src -gt 0 })
    if ($withInk.Count -eq 0) { Write-Host 'FAIL M4-C23 (compared zero sheets: no source produced any ink)'; exit 1 }

    if ($bad -gt 0) { Write-Host ("FAIL M4-C23 ({0} sheet(s) plotting a different amount of drawing than their source; worst drift {1:P0})" -f $bad, $worst); exit 1 }
    Write-Host ("PASS M4-C23 (all {0} sheets plot within {1:P0} of their source's ink; worst drift {2:P1})" -f $rows.Count, $Tolerance, $worst)
    exit 0
} finally {
    foreach ($s in (Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter '*.scr' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-15) })) {
        Remove-Item $s.FullName -Force -ErrorAction SilentlyContinue
    }
    if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
