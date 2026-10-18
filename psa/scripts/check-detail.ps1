# check-detail.ps1 -- M4-C21: a sheet's detail window must plot like its SOURCE sheet's detail window.
#
# Why this exists, and why the first version of it was wrong.
#
# Builds 0.106/0.107 restored the template's detail window and the gate went green while the plots visibly
# changed. Every other check verified that a window EXISTS and how many there are; none looked at what one
# SHOWS. So this check was written to measure the ink inside each detail window.
#
# Its first threshold was invented here, and was WRONG. It failed a window carrying more than 25% of the
# sheet's ink, on the theory that a detail window showing most of the drawing must be echoing rather than
# detailing. Measured against the working drawings that premise is false: the source GAD sheet's own detail
# window carries 54% of its sheet's ink. The working drawings' "detail" window really does show the whole
# drawing at a small scale. A 25% threshold would FAIL THE REFERENCE SHEET ITSELF.
#
# So the rule is a COMPARISON, not a threshold: for each sheet, plot the source and the generated version,
# measure the ink inside the detail window's paper rectangle in both, and require the generated share to sit
# within a band of the source's. That is what "looks like the working drawings" means operationally, which
# is the standing goal -- rather than a number chosen inside this script.
#
# What it catches, in both directions:
#   - the 0.107 state (detail window inherited and aimed at template coordinates): generated shares measured
#     62% to 99.7% against a source at 54% -- the top of that range is well outside the band.
#   - the erase state (no detail window at all): generated share 0% against a source at 54% -- the bottom.
# Both are wrong, and a one-sided threshold catches only one of them.

param(
    [string]$OutDir,
    # How far the generated share may drift from the source's, as a fraction of the source's.
    [double]$Tolerance = 0.35
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

# Resolved into a script-scope variable rather than RETURNED. A PowerShell function collects everything it
# writes to the pipeline as its return value, so a resolver that probes paths with Get-Command/Test-Path
# returns the probe output too -- which here meant the python SOURCE came back as the executable path and
# PowerShell tried to run it as a command.
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
    if (-not $script:pythonExe) { throw 'python not found (needed to measure plotted ink)' }
}

function Get-PaperLayout {
    param([string]$File)
    $j = (pwsh -NoProfile -File $runStep $File 'layout.list {}' | Select-Object -Last 1)
    if (-not $j) { return '' }
    $lay = @(([regex]::Matches($j, '"name":"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }) | Where-Object { $_ -ne 'Model' })
    if ($lay.Count -gt 0) { return $lay[0] } else { return '' }
}

# The detail window is the smaller model-space window. Its paper rectangle is what gets plotted, so the
# rectangle is taken from the SOURCE sheet and applied to both plots: the same region of the sheet, ink
# counted the same way in each.
$py = @'
import fitz, json, sys
path = sys.argv[1]
x0, y0, x1, y1 = [float(v) for v in sys.argv[2].split(',')]
doc = fitz.open(path)
if doc.page_count < 1:
    print(json.dumps({"error": "no pages"})); raise SystemExit(0)
pg = doc[0]
W, H = pg.rect.width, pg.rect.height
sx, sy = W / 420.0, H / 297.0
total = 0
for dr in pg.get_drawings():
    total += len(dr.get("items", []))
box = fitz.Rect(x0 * sx, H - y1 * sy, x1 * sx, H - y0 * sy)
detail = 0
for dr in pg.get_drawings():
    r = dr.get("rect")
    if r is None or r.is_empty:
        continue
    if r.intersects(box):
        detail += len(dr.get("items", []))
print(json.dumps({"total": total, "detail": detail}))
'@

function Get-Ink {
    param([string]$Plot, [string]$RectCsv)
    # Both the .py and the plots live under the project dir, NOT %TEMP%: when the Windows user name exceeds
    # eight characters %TEMP% has an 8.3 short form (REINAC~1), PowerShell hands that to Python, and Python
    # then fails to import site-packages -- which surfaces as "python is not recognized" or a WinError 2
    # rather than as the path problem it is.
    $lines = @(& $script:pythonExe $script:pyFile $Plot $RectCsv 2>&1 | ForEach-Object { [string]$_ })
    $json = $lines | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1
    if (-not $json) { return $null }
    return ($json | ConvertFrom-Json)
}

$tmp = $null
$script:pyFile = $null
$failCount = 0
try {
    # Under the project dir, for the short-path reason noted on Get-Ink.
    $tmp = Join-Path $D ('fusion\colour-check\detail-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    Resolve-Python
    $script:pyFile = Join-Path $tmp 'measure_plot.py'
    [System.IO.File]::WriteAllText($script:pyFile, $py)

    # Wrapped in @(): with one sheet the pipeline returns a bare FileInfo and StrictMode rejects .Count.
    $dwgs = @(Get-ChildItem -LiteralPath $OutDir -Filter '*.dwg' | Sort-Object Name)
    if ($dwgs.Count -eq 0) { throw "no sheets in $OutDir" }

    foreach ($dwg in $dwgs) {
        $f = $dwg.FullName
        # Same source-sheet resolution as check-f7: the sheet names come from project.json, and the
        # working folder is named there rather than hard-coded.
        $n = $dwg.BaseName
        $srcPath = Join-Path $D ($Project.workingDir + '\' + $n + '.dwg')
        if (-not (Test-Path -LiteralPath $srcPath)) { Write-Host "SKIP $($dwg.Name) (no source sheet to compare with)"; continue }

        $srcLay = Get-PaperLayout -File $srcPath
        $genLay = Get-PaperLayout -File $f
        if (-not $srcLay -or -not $genLay) { Write-Host "FAIL $($dwg.Name) missing paper-space layout"; $failCount++; continue }

        # The source's detail window: the smaller of its model-space windows. Note the source names its
        # layout after the sheet while the generated sheet calls it Layout1, so each side is read with its
        # own layout name -- applying one file's name to the other is a mistake this repo has made before.
        $sj = (pwsh -NoProfile -File $runStep $srcPath ('layout.set ' + (@{ name = $srcLay } | ConvertTo-Json -Compress)) 'entities {"type":"Viewport","limit":100}' | Select-Object -Last 1)
        if (-not $sj) { Write-Host "FAIL $($dwg.Name) could not read the source viewports"; $failCount++; continue }
        $smodel = @((($sj | ConvertFrom-Json).entities) | Where-Object { $g = $_.geometry; ($g.PSObject.Properties.Name -contains 'id') -and ([int]$g.id -ge 2) })
        if ($smodel.Count -lt 2) { Write-Host "SKIP $($dwg.Name) (source has no detail window to compare with)"; continue }
        $dv = @($smodel | Sort-Object { [double]$_.geometry.width * [double]$_.geometry.height } -Descending)[-1]
        $g = $dv.geometry
        $cx = [double]$g.center.x; $cy = [double]$g.center.y
        $w = [double]$g.width; $h = [double]$g.height
        $rectCsv = "$($cx - $w / 2.0),$($cy - $h / 2.0),$($cx + $w / 2.0),$($cy + $h / 2.0)"

        $plotSrc = Join-Path $tmp ($dwg.BaseName + '_src')
        $plotGen = Join-Path $tmp ($dwg.BaseName + '_gen')
        foreach ($p in @(@($srcPath, $srcLay, $plotSrc), @($f, $genLay, $plotGen))) {
            $cmd = 'exportpdf {"path":' + ($p[2] | ConvertTo-Json) + ',"layouts":[' + ($p[1] | ConvertTo-Json) + ']}'
            $scr = [System.IO.Path]::GetTempFileName() + '.scr'
            [System.IO.File]::WriteAllText($scr, $cmd + "`r`n", (New-Object System.Text.ASCIIEncoding))
            & (Get-Cli) run $p[0] --script-file $scr 2>&1 | Out-Null
            Remove-Item $scr -Force -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path -LiteralPath $plotSrc) -or -not (Test-Path -LiteralPath $plotGen)) { Write-Host "FAIL $($dwg.Name) could not plot both sheets"; $failCount++; continue }

        $si = Get-Ink -Plot $plotSrc -RectCsv $rectCsv
        $gi = Get-Ink -Plot $plotGen -RectCsv $rectCsv
        if (-not $si -or -not $gi) { Write-Host "FAIL $($dwg.Name) could not measure the plots"; $failCount++; continue }
        if ([int]$si.total -le 0 -or [int]$gi.total -le 0) { Write-Host "FAIL $($dwg.Name) a plot has no ink"; $failCount++; continue }
        if ([int]$si.detail -le 0) { Write-Host "SKIP $($dwg.Name) (source detail window carries no ink to compare with)"; continue }

        $srcShare = [double]$si.detail / [double]$si.total
        $genShare = [double]$gi.detail / [double]$gi.total
        $drift = [Math]::Abs($genShare - $srcShare) / $srcShare
        if ($drift -gt $Tolerance) {
            $dir = 'extra'
            if ($genShare -lt $srcShare) { $dir = 'missing' }
            Write-Host "FAIL $($dwg.Name) (detail window carries $([Math]::Round($genShare * 100, 0))% of the sheet's ink, the source carries $([Math]::Round($srcShare * 100, 0))% -- $dir detail content)"
            $failCount++
            continue
        }
        Write-Host "PASS $($dwg.Name) (detail window $([Math]::Round($genShare * 100, 0))% of ink, source $([Math]::Round($srcShare * 100, 0))%, drift $([Math]::Round($drift * 100, 0))%)"
    }
}
finally {
    if ($script:pyFile) { Remove-Item $script:pyFile -Force -ErrorAction SilentlyContinue }
    if ($tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failCount -gt 0) {
    Write-Host "FAIL M4-C21 ($failCount sheet(s) whose detail window does not match its source)"
    exit 1
}
Write-Host 'PASS M4-C21 (every sheet plots its detail window like its source does)'
exit 0
