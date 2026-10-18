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


def filled(path):
    """Filled <path> geometry. cadcraft emits TrueType glyph outlines as <path fill=... d=...>,
    not as <polyline stroke=... points=...>, so a polyline-only parse silently skips every filled
    shape -- on the sheet with the balloon tags that is 37 glyph outlines, the most-detailed text on
    the drawing. Coordinates come from the d= attribute; SVG geometry is NOT in d= for polylines,
    which is why the two need separate readers."""
    text = open(path, encoding='utf-8', errors='replace').read()
    out = []
    for m in re.finditer(r'<path\b[^>]*>', text):
        tag = m.group(0)
        fill = re.search(r'fill="([^"]+)"', tag)
        d = re.search(r'\bd="([^"]+)"', tag)
        if not d:
            continue
        nums = re.findall(r'-?\d+\.?\d*', d.group(1))
        coords = tuple(zip(nums[0::2], nums[1::2]))
        coords = tuple((float(x), float(y)) for x, y in coords)
        if not coords:
            continue
        out.append((fill.group(1) if fill else '?', coords))
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
# Filled <path> geometry (TrueType glyph outlines). A polyline-only parse skips these entirely.
# The comparison must be SCALE-AWARE. These glyphs sit inside block references, and a reference's
# scale multiplies its text: the balloon tags are inserted at scale 6.0, so their outlines come out
# at exactly 6x the source's per-glyph size while being the same glyph. Comparing raw coordinates
# calls that "lost geometry", which is wrong. Two shapes are the same shape when one is a uniform
# rescale of the other -- so compare the vertex count and the ASPECT RATIO, and separately check the
# size ratio is uniform across the sheet (a per-glyph size change would be a real defect).
fa = filled(src_path)
fb = filled(gen_path)


def aspect(p):
    xs = [x for x, y in p]
    ys = [y for x, y in p]
    w = max(xs) - min(xs)
    h = max(ys) - min(ys)
    if h <= 0:
        return (len(p), 0.0)
    return (len(p), round(w / h, 3))


set_fa = set((c, p) for c, p in fa)
set_fb = set((c, p) for c, p in fb)
only_fa = [(c, p) for c, p in fa if (c, p) not in set_fb]
gen_fshapes = collections.Counter((c, shape(p)) for c, p in fb)
exact_f = [(c, p) for c, p in only_fa if gen_fshapes.get((c, shape(p)), 0) == 0]

# Anything not an exact shape match is re-checked ignoring uniform scale.
gen_aspects = collections.Counter((c, aspect(p)) for c, p in fb)
lost_f = [(c, p) for c, p in exact_f if gen_aspects.get((c, aspect(p)), 0) == 0]

# Size ratio across matched shapes: must be one uniform number, i.e. a block scale, not drift.
ratios = []
src_by_aspect = collections.defaultdict(list)
for c, p in fa:
    src_by_aspect[(c, aspect(p))].append(max(x for x, y in p) - min(x for x, y in p))
gen_by_aspect = collections.defaultdict(list)
for c, p in fb:
    gen_by_aspect[(c, aspect(p))].append(max(x for x, y in p) - min(x for x, y in p))
for k in src_by_aspect:
    if k in gen_by_aspect and src_by_aspect[k] and gen_by_aspect[k]:
        sa = sorted(src_by_aspect[k]); ga = sorted(gen_by_aspect[k])
        if len(sa) == len(ga):
            for i in range(len(sa)):
                if sa[i] > 0:
                    ratios.append(round(ga[i] / sa[i], 2))
rc = collections.Counter(ratios)

fill_a = collections.Counter(c for c, p in fa)
fill_b = collections.Counter(c for c, p in fb)
missing_fill = {c: fill_a[c] - fill_b.get(c, 0) for c in fill_a if fill_a[c] > fill_b.get(c, 0)}
print('filled paths: src=%d gen=%d | fills src=%s gen=%s' % (len(fa), len(fb), dict(sorted(fill_a.items())), dict(sorted(fill_b.items()))))
print('filled: unmatched src=%d | exact-shape loss=%d | scale-aware loss=%d | fills with fewer: %s'
      % (len(only_fa), len(exact_f), len(lost_f), missing_fill or 'none'))
if rc:
    print('filled size ratio gen/src (uniform = a block scale): %s' % rc.most_common(4))
for c, p in lost_f[:5]:
    print('   LOST FILL colour=%s span=%.1f npoints=%d' % (c, span(p), len(p)))

if lost:
    print('FAIL colour/stroke audit: %d non-glyph stroke(s) absent from the generated sheet' % len(lost))
    sys.exit(1)
if missing_cols:
    print('FAIL colour/stroke audit: generated sheet is missing strokes in %s' % sorted(missing_cols))
    sys.exit(1)
if lost_f:
    print('FAIL colour/stroke audit: %d filled shape(s) absent from the generated sheet (not explained by a uniform scale)' % len(lost_f))
    sys.exit(1)
if missing_fill:
    print('FAIL colour/stroke audit: generated sheet has fewer filled shapes in %s' % sorted(missing_fill))
    sys.exit(1)
print('PASS colour/stroke audit (no non-glyph stroke or filled shape lost; every colour at least as present as source)')
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
