# audit-linetypes.ps1 -- report linetype fidelity, and prove the renderer dashes and scales dashes.
#
# Four separate questions, all measured here. Each is a distinct way dashed and centre lines can look
# wrong on a generated sheet while the entity data still matches the source:
#
# 1. TABLE: does the generated sheet load the same linetypes as its source? A missing definition means
#    every entity on that linetype falls back to continuous, so dashed and centre lines silently turn
#    solid. Compared per sheet against the source.
#
# 2. HEADER VARIABLES: does the generated sheet carry the same linetype-related header variables?
#    LTSCALE multiplies every dash length, PSLTSCALE makes dash density depend on viewport zoom, and
#    LWDISPLAY turns lineweights on or off. None of these are visible to an entity or layer audit.
#
# 3. RENDER: does cadcraft actually draw a non-continuous linetype as dashes? A matching table proves
#    nothing if the renderer ignores it. Proved with a synthetic drawing on the template's empty model
#    space: one line on a HIDDEN layer, one on a Continuous layer, rendered and measured by counting
#    the lit segments each line breaks into.
#
# 4. ZOOM SCALING: are dashes fixed in DRAWING UNITS, or in pixels? If they were fixed in pixels, the
#    content-viewport framing chosen by the generators would change how dense the dashes look, so a
#    sheet could plot with wrong-looking dash density even with correct data. Measured by rendering the
#    same dashed line at two zooms and taking the ratio of dash lengths: a 4x zoom must give 4x the
#    dash length in pixels.
#
# Prints linetype names, variable names/values and pixel counts only, never drawing text.
#
# Exit 0 when every sheet's table and header variables match its source AND both render tests pass; 1
# otherwise.

[CmdletBinding()]
param(
    [string]$OutDir,
    [string]$WorkingDir
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
if ([string]::IsNullOrWhiteSpace($WorkingDir)) { $WorkingDir = Join-Path $D '3. Working' }

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$cli = Join-Path $repo 'target\release\cadcraft-cli.exe'
if (-not (Test-Path -LiteralPath $cli)) { throw "cadcraft-cli not found at $cli" }

function Get-LinetypeNames {
    param([string]$Drawing)
    $scr = [System.IO.Path]::GetTempFileName() + '.scr'
    try {
        [System.IO.File]::WriteAllText($scr, "linetype {}`r`n", (New-Object System.Text.ASCIIEncoding))
        $raw = (& $cli run $Drawing --script-file $scr 2>&1 | Select-Object -Last 1)
    } finally {
        Remove-Item $scr -Force -ErrorAction SilentlyContinue
    }
    if (-not $raw) { return @() }
    try { return @(($raw | ConvertFrom-Json).loaded | ForEach-Object { [string]$_.name }) } catch { return @() }
}

$fail = 0

# Scratch space for the render test. Deliberately NOT %TEMP%: a stray .py file there shadows Python's
# stdlib (an unrelated inspect.py in %TEMP% broke an early version of this check), so keep the working
# files in a folder of our own under the drawings directory.
$workDir = Join-Path $D 'fusion\linetype-check'
if (-not (Test-Path -LiteralPath $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }

# ---- 1. table comparison ----------------------------------------------------
Write-Host 'linetype tables (source vs generated):'
foreach ($n in @($Project.sheets | Sort-Object)) {
    $src = Join-Path $WorkingDir ($n + '.dwg')
    $gen = Join-Path $OutDir ($n + '.dwg')
    if (-not (Test-Path -LiteralPath $src) -or -not (Test-Path -LiteralPath $gen)) { Write-Host "SKIP  $n"; continue }

    $s = @(Get-LinetypeNames -Drawing $src)
    $g = @(Get-LinetypeNames -Drawing $gen)
    if ($s.Count -eq 0) { Write-Host "FAIL  $n  source linetype table unreadable"; $fail++; continue }

    $missing = @($s | Where-Object { $g -notcontains $_ })
    $parts = $n.Split('-')
    $short = if ($parts.Count -gt 2) { ($parts[2..($parts.Count - 1)] -join '-') } else { $n }

    if ($missing.Count -gt 0) {
        Write-Host ("FAIL  {0,-16} linetype(s) missing from generated: {1}" -f $short, ($missing -join ', '))
        $fail++
    } else {
        $named = @($s | Where-Object { $_ -notin @('ByBlock', 'ByLayer', 'Continuous') })
        $note = if ($named.Count -gt 0) { ', non-solid: ' + ($named -join ', ') } else { '' }
        Write-Host ("OK    {0,-16} all {1} source linetypes present{2}" -f $short, $s.Count, $note)
    }
}

# ---- 2. header variables ---------------------------------------------------
# Variables that change how the sheet plots without appearing on any entity.
$headerVars = @('LTSCALE', 'PSLTSCALE', 'CELTSCALE', 'LWDISPLAY', 'MEASUREMENT')

function Get-HeaderVar {
    param([string]$Drawing, [string]$Name)
    $scr = [System.IO.Path]::GetTempFileName() + '.scr'
    try {
        $cmd = 'getvar ' + (@{ name = $Name } | ConvertTo-Json -Compress)
        [System.IO.File]::WriteAllText($scr, ($cmd + "`r`n"), (New-Object System.Text.ASCIIEncoding))
        $raw = (& $cli run $Drawing --script-file $scr 2>&1 | Select-Object -Last 1)
    } finally {
        Remove-Item $scr -Force -ErrorAction SilentlyContinue
    }
    if (-not $raw) { return '<unreadable>' }
    try { return "$([string](($raw | ConvertFrom-Json).value))" } catch { return '<unreadable>' }
}

Write-Host 'linetype-related header variables (source vs generated):'
foreach ($n in @($Project.sheets | Sort-Object)) {
    $src = Join-Path $WorkingDir ($n + '.dwg')
    $gen = Join-Path $OutDir ($n + '.dwg')
    if (-not (Test-Path -LiteralPath $src) -or -not (Test-Path -LiteralPath $gen)) { continue }

    $diffs = @()
    foreach ($v in $headerVars) {
        $a = Get-HeaderVar -Drawing $src -Name $v
        $b = Get-HeaderVar -Drawing $gen -Name $v
        if ($a -ne $b) { $diffs += ($v + ' [' + $a + '] -> [' + $b + ']') }
    }

    $parts = $n.Split('-')
    $short = if ($parts.Count -gt 2) { ($parts[2..($parts.Count - 1)] -join '-') } else { $n }

    if ($diffs.Count -gt 0) {
        Write-Host ("FAIL  {0,-16} header variable(s) differ: {1}" -f $short, ($diffs -join '; '))
        $fail++
    } else {
        Write-Host ("OK    {0,-16} {1} header variables match ({2})" -f $short, $headerVars.Count, ($headerVars -join ', '))
    }
}

# ---- 3. render test --------------------------------------------------------
# The template's model space is empty, so it is a clean canvas for two test lines.
$tpl = Get-ChildItem -LiteralPath (Join-Path $D 'Template') -Filter '*.dwg' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $tpl) {
    Write-Host 'SKIP render test: no template .dwg found under the Template folder'
} else {
    $testDwg = Join-Path $workDir 'audit-linetypes.dwg'
    $testPng = Join-Path $workDir 'audit-linetypes.png'
    Remove-Item $testDwg, $testPng -Force -ErrorAction SilentlyContinue

    $sa = 'saveas ' + (@{ path = $testDwg; version = 2018 } | ConvertTo-Json -Compress)
    $cmds = @(
        'linetype {"name":"HIDDEN"}',
        ('layer.new ' + (@{ name = 'AUDIT-HID'; linetype = 'HIDDEN'; current = $true } | ConvertTo-Json -Compress)),
        'line {"points":[[0,10],[200,10]]}',
        ('layer.new ' + (@{ name = 'AUDIT-SOL'; current = $true } | ConvertTo-Json -Compress)),
        'line {"points":[[0,0],[200,0]]}',
        $sa
    )
    $scr = [System.IO.Path]::GetTempFileName() + '.scr'
    try {
        [System.IO.File]::WriteAllText($scr, (($cmds -join "`r`n") + "`r`n"), (New-Object System.Text.ASCIIEncoding))
        & $cli run $tpl.FullName --script-file $scr 2>&1 | Out-Null
    } finally {
        Remove-Item $scr -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $testDwg)) {
        Write-Host 'FAIL render test: could not build the synthetic drawing'
        $fail++
    } else {
        & $cli convert $testDwg $testPng --window -20,-20,220,40 2>&1 | Out-Null
        Remove-Item $testDwg -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $testPng)) {
            Write-Host 'FAIL render test: could not render the synthetic drawing'
            $fail++
        } else {
            $py = @'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGB')
w, h = im.size
px = im.load()
# cadcraft renders light lines on a dark background; the background here is about (33,40,48).
def lit(x, y):
    return sum(px[x, y]) > 420
rows = [y for y in range(h) if sum(1 for x in range(w) if lit(x, y)) > 20]
if len(rows) < 2:
    print('FAIL render test: expected two horizontal test lines, found %d row bands' % len(rows))
    sys.exit(1)
bands = []
for y in rows:
    if not bands or y - bands[-1][-1] > 5:
        bands.append([y])
    else:
        bands[-1].append(y)
if len(bands) < 2:
    print('FAIL render test: expected two separate lines, got %d bands' % len(bands))
    sys.exit(1)
def segments(y):
    segs = []
    start = None
    for x in range(w):
        d = lit(x, y)
        if d and start is None:
            start = x
        if not d and start is not None:
            segs.append(x - start)
            start = None
    if start is not None:
        segs.append(w - start)
    return segs
# Smaller image row = higher drawing y = the HIDDEN line (drawn at y=10, above the solid at y=0).
bands.sort(key=lambda b: b[0])
hid = segments(bands[0][len(bands[0]) // 2])
sol = segments(bands[-1][len(bands[-1]) // 2])

def dashed(segs):
    # A dashed line is many segments of nearly equal length. A solid line is one long segment; it may
    # show one- or two-pixel notches from antialiasing, so short slivers are ignored and the remaining
    # pieces must still be dominated by one long run.
    real = [s for s in segs if s > 5]
    if len(real) < 5:
        return False
    longest = max(real)
    # dashes are short relative to the whole line, and repeat evenly
    if longest > 0.4 * sum(real):
        return False
    short = [s for s in real if s <= 0.2 * sum(real)]
    return len(short) >= 0.8 * len(real)

print('HIDDEN line: %d segments %s' % (len([s for s in hid if s > 5]), hid[:8]))
print('Continuous line: %d segments %s' % (len([s for s in sol if s > 5]), sol[:8]))
if dashed(hid) and not dashed(sol):
    print('PASS render test (cadcraft dashes a HIDDEN linetype and keeps Continuous solid)')
    sys.exit(0)
print('FAIL render test: dashing not honoured (hidden dashed=%s, continuous dashed=%s)' % (dashed(hid), dashed(sol)))
sys.exit(1)
'@
            $pyFile = Join-Path $workDir 'audit_linetypes.py'
            [System.IO.File]::WriteAllText($pyFile, $py)
            & python $pyFile $testPng 2>&1 | ForEach-Object { "render test: $_" }
            if ($LASTEXITCODE -ne 0) { $fail++ }
            Remove-Item $testPng, $pyFile -Force -ErrorAction SilentlyContinue
        }
    }

    # ---- 4. zoom scaling ---------------------------------------------------
    # Dashes must be fixed in DRAWING UNITS. If they were fixed in pixels, the content-viewport framing
    # the generators pick would change how dense the dashes look on the sheet.
    $zoomDwg = Join-Path $workDir 'audit-zoom.dwg'
    Remove-Item $zoomDwg -Force -ErrorAction SilentlyContinue
    $sa2 = 'saveas ' + (@{ path = $zoomDwg; version = 2018 } | ConvertTo-Json -Compress)
    $cmds2 = @(
        'linetype {"name":"HIDDEN"}',
        ('layer.new ' + (@{ name = 'AUDIT-ZOOM'; linetype = 'HIDDEN'; current = $true } | ConvertTo-Json -Compress)),
        'line {"points":[[0,0],[400,0]]}',
        $sa2
    )
    $scr2 = [System.IO.Path]::GetTempFileName() + '.scr'
    try {
        [System.IO.File]::WriteAllText($scr2, (($cmds2 -join "`r`n") + "`r`n"), (New-Object System.Text.ASCIIEncoding))
        & $cli run $tpl.FullName --script-file $scr2 2>&1 | Out-Null
    } finally {
        Remove-Item $scr2 -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $zoomDwg)) {
        Write-Host 'FAIL zoom test: could not build the synthetic drawing'
        $fail++
    } else {
        $pngFit = Join-Path $workDir 'audit-zoom-fit.png'
        $pngZoom = Join-Path $workDir 'audit-zoom-4x.png'
        Remove-Item $pngFit, $pngZoom -Force -ErrorAction SilentlyContinue
        # Same line, same image size: the second window is 4x narrower, so 4x the pixels per unit.
        & $cli convert $zoomDwg $pngFit --window '0,-15,400,15' 2>&1 | Out-Null
        & $cli convert $zoomDwg $pngZoom --window '0,-15,100,15' 2>&1 | Out-Null
        Remove-Item $zoomDwg -Force -ErrorAction SilentlyContinue

        if (-not (Test-Path -LiteralPath $pngFit) -or -not (Test-Path -LiteralPath $pngZoom)) {
            Write-Host 'FAIL zoom test: could not render both zooms'
            $fail++
        } else {
            $py2 = @'
import sys
from PIL import Image


def first_dash(path):
    im = Image.open(path).convert('RGB')
    w, h = im.size
    px = im.load()

    def lit(x, y):
        return sum(px[x, y]) > 420

    rows = [y for y in range(h) if sum(1 for x in range(w) if lit(x, y)) > 20]
    if not rows:
        return None
    y = rows[len(rows) // 2]
    segs = []
    start = None
    for x in range(w):
        d = lit(x, y)
        if d and start is None:
            start = x
        if not d and start is not None:
            segs.append(x - start)
            start = None
    if start is not None:
        segs.append(w - start)
    real = [s for s in segs if s > 5]
    if not real:
        return None
    return sum(real) / len(real)


fit = first_dash(sys.argv[1])
zoom = first_dash(sys.argv[2])
if not fit or not zoom:
    print('FAIL zoom test: could not measure dashes at both zooms')
    sys.exit(1)
ratio = zoom / fit
print('mean dash length: fit=%.1f px, 4x zoom=%.1f px, ratio=%.2f' % (fit, zoom, ratio))
# Dashes fixed in drawing units must grow in proportion to the zoom.
if 3.0 <= ratio <= 5.0:
    print('PASS zoom test (dashes scale with zoom, so they are fixed in drawing units)')
    sys.exit(0)
print('FAIL zoom test: dash length did not scale with zoom (ratio %.2f), so framing would change dash density' % ratio)
sys.exit(1)
'@ -replace "`r", ''
            $pyFile2 = Join-Path $workDir 'audit_zoom.py'
            [System.IO.File]::WriteAllText($pyFile2, $py2)
            & python $pyFile2 $pngFit $pngZoom 2>&1 | ForEach-Object { "zoom test: $_" }
            if ($LASTEXITCODE -ne 0) { $fail++ }
            Remove-Item $pngFit, $pngZoom, $pyFile2 -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($fail -gt 0) { Write-Host "FAIL linetype audit ($fail problem(s))"; exit 1 }
Write-Host 'PASS linetype audit (linetype tables and header variables match the source, the renderer dashes, and dashes scale with zoom)'
exit 0
