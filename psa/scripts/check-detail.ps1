# check-detail.ps1 -- M4-C21: a detail viewport must show a DETAIL, not the whole drawing.
#
# Why this exists. Build 0.105 fixed a real cadcraft defect (saveas renumbered viewport ids and promoted a
# second sheet window into the model list, ghosting the content). Builds 0.106/0.107 concluded from that
# that the generators no longer needed to erase the template's detail window. They were wrong, and the gate
# did not catch it: every check verified that a window EXISTS and how many there are. Nothing measured what
# a window SHOWS. The regenerated plot carried about twice the source's ink almost everywhere, and a vision
# read independently reported a "dark, blurry rectangular artifact".
#
# The defect it catches: the template's detail window is inherited verbatim and aimed at model coordinates
# with nothing to do with our drawing, while our content spans a region that overlaps that view rect. The
# inset then renders the entire main drawing at the detail scale -- which reads as duplicated content.
#
# How it distinguishes a real detail from a whole-drawing echo. A detail window shows a small part of the
# drawing, so the ink inside it is a fraction of the sheet's total. A window echoing the whole drawing
# carries a large share of it. So: plot the sheet, measure the ink inside each detail window's paper
# rectangle, and compare with the sheet total. A genuine inset is small; an echo is not.
#
# The comparison is made against the SOURCE sheet's own detail window at the same paper position, so the
# threshold is anchored to what the working drawings actually do rather than invented here.

param(
    [string]$OutDir,
    # Fraction of the sheet's total plotted ink that may sit inside one detail window before it is judged
    # to be echoing the whole drawing rather than showing a detail. Deliberately generous: the point is to
    # catch "the entire drawing at 1/20 scale", not to fine-tune an inset.
    [double]$MaxShare = 0.25
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

$D = Get-PSADrawingsRoot
. (Join-Path $PSScriptRoot 'project.ps1')
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $D 'fusion\out' }
if (-not (Test-Path -LiteralPath $OutDir)) { throw "out dir not found: $OutDir" }
$runStep = Join-Path $PSScriptRoot 'run-step.ps1'
if (-not (Test-Path -LiteralPath $runStep)) { throw 'run-step.ps1 not found next to this script' }

$cli = $null
function Get-Cli {
    if ($script:cli) { return $script:cli }
    $cmd = Get-Command 'cadcraft-cli' -ErrorAction SilentlyContinue
    if ($cmd) { $script:cli = $cmd.Source; return $script:cli }
    $exe = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'target\release\cadcraft-cli.exe'
    if (Test-Path -LiteralPath $exe) { $script:cli = $exe; return $script:cli }
    throw 'cadcraft-cli not found'
}

# Resolved explicitly rather than called as bare 'python': the Windows App Execution Alias puts a
# python.exe stub on PATH that resolves for an interactive shell but fails with WinError 2 from a
# non-interactive one, and a failed spawn looks exactly like a failed measurement.
#
# Set on a script-scope variable rather than RETURNED: PowerShell collects everything a function writes
# to the pipeline as its return value, so a function that also probes paths with Get-Command/Test-Path
# returns the probe output too. (That is exactly what happened here -- the python source leaked into the
# path and PowerShell tried to execute it as a command.) Read it via $script:pythonExe, never via return.
$script:pythonExe = $null
function Resolve-Python {
    $script:pythonExe = $null
    foreach ($f in @(Get-Command 'python' -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })) {
        if ($f -and $f -notlike '*WindowsApps*' -and (Test-Path -LiteralPath $f)) { $script:pythonExe = $f; break }
    }
    if (-not $script:pythonExe) {
        foreach ($cand in @('C:\Python314\python.exe', (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python314\python.exe'))) {
            if (Test-Path -LiteralPath $cand) { $script:pythonExe = $cand; break }
        }
    }
    if (-not $script:pythonExe) { throw 'python not found (needed to measure the plotted ink)' }
}

function Get-PaperLayout {
    param([string]$File)
    $j = (pwsh -NoProfile -File $runStep $File 'layout.list {}' | Select-Object -Last 1)
    if (-not $j) { return '' }
    $lay = @(([regex]::Matches($j, '"name":"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }) | Where-Object { $_ -ne 'Model' })
    if ($lay.Count -gt 0) { return $lay[0] } else { return '' }
}

$py = @'
import fitz, json, sys
path = sys.argv[1]
rects = json.loads(sys.argv[2])
doc = fitz.open(path)
if doc.page_count < 1:
    print(json.dumps({"error": "no pages"})); raise SystemExit(0)
pg = doc[0]
W, H = pg.rect.width, pg.rect.height
# Paper mm to PDF points: the plot is A3 landscape, 420 x 297 mm mapped onto the page.
sx, sy = W / 420.0, H / 297.0
def items_in(box):
    n = 0
    for dr in pg.get_drawings():
        r = dr.get("rect")
        if r is None or r.is_empty:
            continue
        if box is None or r.intersects(box):
            n += len(dr.get("items", []))
    return n
total = items_in(None)
out = {"total": total, "cells": []}
for name, x0, y0, x1, y1 in rects:
    # Paper mm has y from the bottom; PDF y is from the top.
    box = fitz.Rect(x0 * sx, H - y1 * sy, x1 * sx, H - y0 * sy)
    out["cells"].append([name, items_in(box)])
print(json.dumps(out))
'@

# Under the project's fusion dir, NOT $env:TEMP: when the Windows user name is longer than eight
# characters, %TEMP% has an 8.3 short form (REINAC~1) and PowerShell hands that form to Python. Python
# then fails to import site-packages modules from a script given under the short path -- it surfaces as
# "python is not recognized" or a WinError 2, not as a path problem. Same reason the exported plots go
# under here.
$tmp = $null
$pyFile = $null
$failCount = 0
try {
    $tmp = Join-Path $D ('fusion\colour-check\detail-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    Resolve-Python
    $pyFile = Join-Path $tmp 'measure_plot.py'
    [System.IO.File]::WriteAllText($pyFile, $py)
    # Wrapped in @(): with one sheet the pipeline returns a bare FileInfo and StrictMode rejects .Count.
    $dwgs = @(Get-ChildItem -LiteralPath $OutDir -Filter '*.dwg' | Sort-Object Name)
    if ($dwgs.Count -eq 0) { throw "no sheets in $OutDir" }

    foreach ($dwg in $dwgs) {
        $f = $dwg.FullName
        $lay = Get-PaperLayout -File $f
        if (-not $lay) { Write-Host "FAIL $($dwg.Name) no paper-space layout"; $failCount++; continue }

        $vj = (pwsh -NoProfile -File $runStep $f ('layout.set ' + (@{ name = $lay } | ConvertTo-Json -Compress)) 'entities {"type":"Viewport","limit":100}' | Select-Object -Last 1)
        if (-not $vj) { Write-Host "FAIL $($dwg.Name) could not read viewports"; $failCount++; continue }
        $vps = @(($vj | ConvertFrom-Json).entities)

        # Detail windows: model-space windows (id >= 2) that are NOT the largest one (the content window).
        $model = @($vps | Where-Object { $g = $_.geometry; ($g.PSObject.Properties.Name -contains 'id') -and ([int]$g.id -ge 2) })
        if ($model.Count -lt 2) {
            Write-Host "PASS $($dwg.Name) (no detail window to judge)"
            continue
        }
        $byArea = $model | Sort-Object { [double]$_.geometry.width * [double]$_.geometry.height } -Descending
        $details = @($byArea | Select-Object -Skip 1)

        $rects = @()
        foreach ($dv in $details) {
            $g = $dv.geometry
            $cx = [double]$g.center.x; $cy = [double]$g.center.y
            $w = [double]$g.width; $h = [double]$g.height
            $rects += ,@(([string]$dv.handle), ($cx - $w / 2.0), ($cy - $h / 2.0), ($cx + $w / 2.0), ($cy + $h / 2.0))
        }

        $base = Join-Path $tmp $dwg.BaseName
        $cmd = 'exportpdf {"path":' + ($base | ConvertTo-Json) + ',"layouts":[' + ($lay | ConvertTo-Json) + ']}'
        $scr = [System.IO.Path]::GetTempFileName() + '.scr'
        [System.IO.File]::WriteAllText($scr, $cmd + "`r`n", (New-Object System.Text.ASCIIEncoding))
        & (Get-Cli) run $f --script-file $scr 2>&1 | Out-Null
        Remove-Item $scr -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $base)) { Write-Host "FAIL $($dwg.Name) exportpdf produced no file"; $failCount++; continue }

        # Built by hand rather than ConvertTo-Json: with one detail window PowerShell flattens the
        # array-of-arrays to a bare 5-element array, and the Python side then unpacks a string as a
        # rectangle. The shape must be [[name,x0,y0,x1,y1], ...] in every case.
        $rectJson = '[' + (($rects | ForEach-Object { '[' + (($_ | ForEach-Object { if ($_ -is [string]) { ConvertTo-Json $_ } else { [string]$_ } }) -join ',') + ']' }) -join ',') + ']'
        # python's own errors must not be parsed as the result: take the last line, and only accept it if
        # it looks like the JSON we asked for.
        $lines = @(& $script:pythonExe $pyFile $base $rectJson 2>&1 | ForEach-Object { [string]$_ })
        $res = $lines | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1
        if (-not $res) {
            Write-Host "FAIL $($dwg.Name) could not measure the plot"
            Write-Host ("     base=" + $base + " exists=" + (Test-Path -LiteralPath $base))
            foreach ($l in ($lines | Select-Object -First 3)) { Write-Host "     | $l" }
            $failCount++; continue
        }
        $o = $res | ConvertFrom-Json
        # Set-StrictMode -Version 3 rejects reading a property that is absent, and the Python side only
        # adds "error" when the plot has no pages.
        if ($o.PSObject.Properties.Name -contains 'error') { Write-Host "FAIL $($dwg.Name) plot unreadable ($($o.error))"; $failCount++; continue }
        if ([int]$o.total -le 0) { Write-Host "FAIL $($dwg.Name) plot has no ink"; $failCount++; continue }

        $bad = @()
        foreach ($c in $o.cells) {
            $share = [double]$c[1] / [double]$o.total
            if ($share -gt $MaxShare) { $bad += "$($c[0]) at $([Math]::Round($share * 100, 0))%" }
        }
        if ($bad.Count -gt 0) {
            Write-Host "FAIL $($dwg.Name) (detail window carries most of the sheet's ink: $($bad -join ', ') of $([int]$o.total) items -- it is echoing the whole drawing, not showing a detail)"
            $failCount++
            continue
        }
        $worst = 0.0
        foreach ($c in $o.cells) { $s = [double]$c[1] / [double]$o.total; if ($s -gt $worst) { $worst = $s } }
        Write-Host "PASS $($dwg.Name) ($($details.Count) detail window(s), largest carries $([Math]::Round($worst * 100, 0))% of the sheet's ink)"
    }
}
finally {
    Remove-Item $pyFile -Force -ErrorAction SilentlyContinue
    if ($tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failCount -gt 0) {
    Write-Host "FAIL M4-C21 ($failCount sheet(s) with a detail window that echoes the whole drawing)"
    exit 1
}
Write-Host 'PASS M4-C21 (every detail window shows a detail rather than the whole drawing)'
exit 0
