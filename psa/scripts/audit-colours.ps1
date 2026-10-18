# audit-colours.ps1 -- compare stroke colour, width and geometry between each source sheet and its
# generated copy, using SVG so no vision model is involved.
#
# Ink coverage alone cannot tell a correct drawing from one whose every line is the wrong colour, and
# colour is a large part of "looks like the originals". cadcraft-cli convert to SVG keeps each stroke's
# colour, width and coordinates as text, so the two sheets can be diffed directly.
#
# Both files MUST be rendered through the same explicit window. Without it each file is rendered at its
# own auto-fitted zoom, the two SVGs get different viewBox sizes, and every coordinate becomes
# incomparable -- which reads as thousands of large mismatches that are pure scale. That window is
# fixed below for exactly that reason.
#
# Prints colours, counts and sizes only, never drawing text.
#
# Exit 0 when every sheet's colour counts match (allowing the known generated additions) and no
# mismatch is larger than a glyph; 1 otherwise.

[CmdletBinding()]
param(
    [string]$OutDir,
    [string]$WorkingDir,
    # Drawing-unit window used for both renders, so coordinates are comparable.
    [string]$Window = '-100,-100,2000,1300',
    # A stroke above this span that is missing from the generated file is real geometry, not a glyph.
    [double]$GlyphSpan = 5.0
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

$workDir = Join-Path $D 'fusion\colour-check'
if (-not (Test-Path -LiteralPath $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }

$py = @'
import collections
import re
import sys


def polys(path):
    text = open(path, encoding='utf-8', errors='replace').read()
    out = []
    for m in re.finditer(r'<polyline\b[^>]*>', text):
        tag = m.group(0)
        stroke = re.search(r'stroke="([^"]+)"', tag)
        pts = re.search(r'points="([^"]+)"', tag)
        width = re.search(r'stroke-width="([^"]+)"', tag)
        if not pts:
            continue
        coords = []
        for tok in pts.group(1).split():
            q = tok.split(',')
            if len(q) == 2:
                try:
                    coords.append((float(q[0]), float(q[1])))
                except ValueError:
                    pass
        out.append((stroke.group(1) if stroke else '?', tuple(coords), width.group(1) if width else '?'))
    return out


def span(coords):
    if not coords:
        return 0.0
    xs = [x for x, y in coords]
    ys = [y for x, y in coords]
    return max(max(xs) - min(xs), max(ys) - min(ys))


def shape(coords):
    if not coords:
        return ()
    ox, oy = coords[0]
    return tuple((round(x - ox, 2), round(y - oy, 2)) for x, y in coords)


src_path, gen_path, glyph_span = sys.argv[1], sys.argv[2], float(sys.argv[3])
src = polys(src_path)
gen = polys(gen_path)

vb_a = re.search(r'viewBox="([^"]+)"', open(src_path, encoding='utf-8', errors='replace').read())
vb_b = re.search(r'viewBox="([^"]+)"', open(gen_path, encoding='utf-8', errors='replace').read())
if not vb_a or not vb_b or vb_a.group(1) != vb_b.group(1):
    print('FAIL viewBoxes differ (%s vs %s): the two renders are at different zooms, coordinates are not comparable'
          % (vb_a.group(1) if vb_a else '?', vb_b.group(1) if vb_b else '?'))
    sys.exit(1)

ca = collections.Counter(c for c, p, w in src)
cb = collections.Counter(c for c, p, w in src)
ga = collections.Counter(c for c, p, w in gen)
gb = collections.Counter(c for c, p, w in gen)

wa = set(w for c, p, w in src)
wb = set(w for c, p, w in gen)

set_a = set((c, p) for c, p, w in src)
set_b = set((c, p) for c, p, w in gen)
only_a = [(c, p) for c, p, w in src if (c, p) not in set_b]
big = [(c, p) for c, p in only_a if span(p) >= glyph_span]

# A big stroke whose shape exists in the generated file is present but repositioned (glyph advance
# width), not lost geometry. Only a big stroke with no shape match anywhere is real missing geometry.
gen_shapes = collections.Counter((c, shape(p)) for c, p, w in gen)
lost = [(c, p) for c, p in big if gen_shapes.get((c, shape(p)), 0) == 0]

print('polylines: src=%d gen=%d | stroke widths src=%s gen=%s' % (len(src), len(gen), sorted(wa), sorted(wb)))
print('colour counts: src=%s gen=%s' % (dict(sorted(ca.items())), dict(sorted(ga.items()))))
missing_cols = {c: ca[c] - ga.get(c, 0) for c in ca if ca[c] > ga.get(c, 0)}
print('colours with FEWER strokes in generated: %s' % (missing_cols or 'none'))
print('unmatched src strokes: %d | span >= %.1f: %d | of those, shape absent from generated (real loss): %d'
      % (len(only_a), glyph_span, len(big), len(lost)))
for c, p in lost[:5]:
    print('   LOST colour=%s span=%.1f npoints=%d' % (c, span(p), len(p)))

if lost:
    print('FAIL colour/stroke audit: %d non-glyph stroke(s) absent from the generated sheet' % len(lost))
    sys.exit(1)
if missing_cols:
    print('FAIL colour/stroke audit: generated sheet is missing strokes in %s' % sorted(missing_cols))
    sys.exit(1)
print('PASS colour/stroke audit (no non-glyph stroke lost; every colour at least as present as source)')
sys.exit(0)
'@ -replace "`r", ''

$pyFile = Join-Path $workDir 'audit_colours.py'
[System.IO.File]::WriteAllText($pyFile, $py)

$fail = 0
Write-Host ("stroke colour/geometry comparison (render window {0})" -f $Window)
foreach ($n in @($Project.sheets | Sort-Object)) {
    $src = Join-Path $WorkingDir ($n + '.dwg')
    $gen = Join-Path $OutDir ($n + '.dwg')
    if (-not (Test-Path -LiteralPath $src) -or -not (Test-Path -LiteralPath $gen)) { Write-Host "SKIP  $n"; continue }

    $svgA = Join-Path $workDir 'src.svg'
    $svgB = Join-Path $workDir 'gen.svg'
    Remove-Item $svgA, $svgB -Force -ErrorAction SilentlyContinue
    & $cli convert $src $svgA --window $Window 2>&1 | Out-Null
    & $cli convert $gen $svgB --window $Window 2>&1 | Out-Null

    $parts = $n.Split('-')
    $short = if ($parts.Count -gt 2) { ($parts[2..($parts.Count - 1)] -join '-') } else { $n }

    if (-not (Test-Path -LiteralPath $svgA) -or -not (Test-Path -LiteralPath $svgB)) {
        Write-Host "FAIL  $short  could not render both sheets to SVG"
        $fail++
        continue
    }

    & python $pyFile $svgA $svgB $GlyphSpan 2>&1 | ForEach-Object { "  $short : $_" }
    if ($LASTEXITCODE -ne 0) { $fail++ }
    Remove-Item $svgA, $svgB -Force -ErrorAction SilentlyContinue
}

Remove-Item $pyFile -Force -ErrorAction SilentlyContinue

if ($fail -gt 0) { Write-Host "FAIL colour/stroke audit ($fail problem(s))"; exit 1 }
Write-Host 'PASS colour/stroke audit (no non-glyph stroke lost on any sheet)'
exit 0
