# check-textheights.ps1 -- M4-C22: every text on a generated sheet must be the size it is on its source.
#
# Why this exists when audit-textstyles and audit-blocks already pass.
#
# audit-textstyles compares the text STYLE table (font, bigFont, height, widthFactor). audit-blocks
# compares block definitions, reference scales and attribute VALUES. Both were green on GAD-001 while its
# balloon tags rendered at 15.0mm against a source at 2.5mm -- a 6x error on 25 entities. Neither audit is
# wrong; they never look at the thing that broke. The style height was 0.0 on both sides (the style carries
# no default), the block scale was 6.0 on both sides, and the attribute VALUES matched. The height that
# renders lives on the attribute's own text properties, which sits in the seam between the two audits.
#
# Resolved, and the seam lesson stands. The 2.5-vs-15.0 gap was a bug in the C# generator that made the
# source sheets: it stored an inserted attribute at the block's raw height instead of the scaled height.
# Claude fixed that generator and regenerated the sources (psa/REVIEW-0.125.md section 3); the source now
# carries 15.0 like the generated sheet, so GAD-001 passes this check with no exception. The seam the check
# covers is still real -- an attribute's rendered height is not in the style table or the block table -- so
# the check stays.
#
# That is a general shape of gap: two checks that each cover a layer of a structure, and the value that
# matters lives in the seam between them. The fix is not to tighten either audit but to measure the rendered
# quantity directly.
#
# WHERE THE HEIGHT LIVES, because getting this wrong makes the check silently vacuous. An attribute under an
# INSERT is { tag, props, text: { height, insert, style, value, widthFactor, ... } }. Reading `height` off
# the attribute itself returns null on every entity, and a first revision of this check did exactly that:
# it compared zero attributes on all twelve sheets and printed twelve PASS lines. So this script reports how
# many attributes it actually compared, and fails if a sheet has none -- a null-field regression cannot hide
# behind a green line.
#
# Prints heights, styles and coordinates only. Never text content.

param(
    [string]$OutDir
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

$pyExe = 'C:\Python314\python.exe'
if (-not (Test-Path -LiteralPath $pyExe)) { throw "python not found at $pyExe" }

# The comparison, as Python. Written once, at top level, and written out to the temp dir -- an earlier
# revision kept two copies (one in a variable that was never used) which could and did drift.
$pyCode = @'
import json, sys


def texts(payload):
    """(effective_height, kind, x, y) for every text on the sheet.

    Effective height for an attribute is its own text height: the enclosing INSERT scale is already folded
    in by the reader, so multiplying again would double-count it. That is worth stating because it is the
    opposite of what one would assume, and it is what makes the GAD-001 balloon read 15.0 rather than 2.5.
    """
    out = []
    for e in payload.get("entities", []):
        g = e.get("geometry") or {}
        t = (e.get("type") or "").lower()
        if t in ("text", "mtext"):
            h = e.get("height") or g.get("height") or 0.0
            ins = g.get("insert") or e.get("insert") or {}
            out.append((round(float(h), 3), "TEXT", round(float(ins.get("x") or 0.0), 1), round(float(ins.get("y") or 0.0), 1)))
        elif t in ("insert", "block reference"):
            for a in (g.get("attribs") or []):
                tp = a.get("text") or {}
                ah = tp.get("height")
                if ah is None:
                    continue
                ins = tp.get("insert") or g.get("insert") or {}
                out.append((round(float(ah), 3), "ATTRIB", round(float(ins.get("x") or 0.0), 1), round(float(ins.get("y") or 0.0), 1)))
    return out


src = texts(json.load(open(sys.argv[1], encoding="utf-8")))
gen = texts(json.load(open(sys.argv[2], encoding="utf-8")))

# Pairing by position is right for plain Text and WRONG for attributes, and the first revision of this check
# paired by position for both. It passed all twelve sheets while GAD-001's balloons were 2.5mm in the source
# and 15.0mm in the generated sheet -- the exact defect the check was written for. The reason it missed it:
# reading attributes off a SOURCE sheet yields one entry per block DEFINITION (an ATTRIB record inside the
# BLOCK TABLE, at the definition's own origin), while reading a GENERATED sheet yields one entry per
# INSTANCE. 25 instances cannot share a position with 1 definition, so every balloon fell outside the
# "shared positions" set and nothing was compared.
#
# So attributes are compared as a height MULTISET, not by position. That is the right granularity anyway:
# what matters is that the sheet draws its tags at the sizes the source draws its tags at, and a per-tag
# pairing across two different representations would be inventing a correspondence that is not there.
# Plain text keeps position-keying, where both sides genuinely are instances.
def heights(rows, kind):
    d = {}
    for h, k, x, y in rows:
        if k != kind:
            continue
        d[h] = d.get(h, 0) + 1
    return d


sh, gh = heights(src, "ATTRIB"), heights(gen, "ATTRIB")
attrib_bad = []
for h in sorted(set(sh) | set(gh)):
    if sh.get(h, 0) != gh.get(h, 0):
        attrib_bad.append([h, sh.get(h, 0), gh.get(h, 0)])

pos_s = {}
for h, k, x, y in src:
    if k == "TEXT":
        pos_s.setdefault((x, y), []).append(h)
pos_g = {}
for h, k, x, y in gen:
    if k == "TEXT":
        pos_g.setdefault((x, y), []).append(h)

shared = sorted(set(pos_s) & set(pos_g))
bad = []
for k in shared:
    a = sorted(pos_s[k])
    b = sorted(pos_g[k])
    if a != b:
        bad.append([k[0], k[1], a[:4], b[:4]])

n_attrib = sum(1 for h, k, x, y in gen if k == "ATTRIB")
n_src_attrib = sum(1 for h, k, x, y in src if k == "ATTRIB")

print(json.dumps({
    "src_texts": len(src),
    "gen_texts": len(gen),
    "gen_attribs": n_attrib,
    "src_attribs": n_src_attrib,
    "shared_positions": len(shared),
    "text_mismatch_count": len(bad),
    "text_height_mismatches": bad[:12],
    "attrib_mismatch_count": len(attrib_bad),
    "attrib_height_mismatches": attrib_bad[:12],
}))
'@

$tmp = $null
$failCount = 0
try {
    # Under the project dir: %TEMP% has an 8.3 short form when the user name exceeds eight characters and
    # Python then fails to import site-packages, which surfaces as an unrelated-looking error.
    $tmp = Join-Path $D ('fusion\colour-check\txth-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $pyFile = Join-Path $tmp 'cmp.py'
    [System.IO.File]::WriteAllText($pyFile, $pyCode)
    $sp = Join-Path $tmp 'src.json'
    $gp = Join-Path $tmp 'gen.json'

    function Merge-Json($a, $b) {
        # One payload from two entity lists (model space and paper space).
        if (-not $a) { $a = '{"entities":[]}' }
        if (-not $b) { $b = '{"entities":[]}' }
        $ja = $a | ConvertFrom-Json
        $jb = $b | ConvertFrom-Json
        $all = @()
        if ($ja.PSObject.Properties.Name -contains 'entities') { $all += @($ja.entities) }
        if ($jb.PSObject.Properties.Name -contains 'entities') { $all += @($jb.entities) }
        return (@{ entities = $all } | ConvertTo-Json -Depth 14 -Compress)
    }

    # Wrapped in @(): with one sheet the pipeline returns a bare FileInfo and StrictMode rejects .Count.
    $dwgs = @(Get-ChildItem -LiteralPath $OutDir -Filter '*.dwg' | Sort-Object Name)
    if ($dwgs.Count -eq 0) { throw "no sheets in $OutDir" }

    foreach ($dwg in $dwgs) {
        $f = $dwg.FullName
        $n = $dwg.BaseName
        $srcPath = Join-Path $D ($Project.workingDir + '\' + $n + '.dwg')
        if (-not (Test-Path -LiteralPath $srcPath)) { Write-Host "SKIP $($dwg.Name) (no source sheet)"; continue }

        $srcModel = (pwsh -NoProfile -File $runStep $srcPath 'entities {"limit":20000}' | Select-Object -Last 1)
        $genModel = (pwsh -NoProfile -File $runStep $f 'entities {"limit":20000}' | Select-Object -Last 1)
        if (-not $srcModel -or -not $genModel) { Write-Host "FAIL $($dwg.Name) could not read model space"; $failCount++; continue }

        # Each side uses its OWN layout name: source sheets name the layout after the sheet, generated ones
        # use Layout1. Applying one file's name to the other reads the wrong space.
        $srcLay = @(([regex]::Matches((pwsh -NoProfile -File $runStep $srcPath 'layout.list {}' | Select-Object -Last 1), '"name":"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }) | Where-Object { $_ -ne 'Model' })
        $genLay = @(([regex]::Matches((pwsh -NoProfile -File $runStep $f 'layout.list {}' | Select-Object -Last 1), '"name":"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }) | Where-Object { $_ -ne 'Model' })
        $srcPaper = ''
        $genPaper = ''
        if (@($srcLay).Count) { $srcPaper = (pwsh -NoProfile -File $runStep $srcPath ('layout.set ' + (@{ name = $srcLay[0] } | ConvertTo-Json -Compress)) 'entities {"limit":20000}' | Select-Object -Last 1) }
        if (@($genLay).Count) { $genPaper = (pwsh -NoProfile -File $runStep $f ('layout.set ' + (@{ name = $genLay[0] } | ConvertTo-Json -Compress)) 'entities {"limit":20000}' | Select-Object -Last 1) }

        [System.IO.File]::WriteAllText($sp, (Merge-Json $srcModel $srcPaper))
        [System.IO.File]::WriteAllText($gp, (Merge-Json $genModel $genPaper))

        $lines = @(& $pyExe $pyFile $sp $gp 2>&1 | ForEach-Object { [string]$_ })
        $json = $lines | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1
        if (-not $json) { Write-Host "FAIL $($dwg.Name) could not compare ($($lines | Select-Object -First 1))"; $failCount++; continue }
        $o = $json | ConvertFrom-Json

        # A sheet with attributes whose comparison sees none is a broken comparison, not a passing sheet.
        if ([int]$o.gen_attribs -eq 0 -and [int]$o.gen_texts -gt 0) {
            Write-Host "FAIL $($dwg.Name) (comparison saw 0 attribute heights; the height field moved or the reader changed)"
            $failCount++
            continue
        }
        $bad = @()
        if ([int]$o.attrib_mismatch_count -gt 0) {
            foreach ($m in @($o.attrib_height_mismatches)) { $bad += "attribute height $($m[0]): source has $($m[1]), generated has $($m[2])" }
        }
        if ([int]$o.text_mismatch_count -gt 0) {
            foreach ($m in @($o.text_height_mismatches)) { $bad += "text at $($m[0]),$($m[1]) src=$($m[2] -join '/') gen=$($m[3] -join '/')" }
        }
        if ($bad.Count -gt 0) {
            Write-Host "FAIL $($dwg.Name) ($($bad -join ' | '))"
            $failCount++
            continue
        }
        Write-Host "PASS $($dwg.Name) ($([int]$o.gen_texts) texts, $([int]$o.gen_attribs) attributes; heights match the source)"
    }
}
finally {
    if ($tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failCount -gt 0) {
    Write-Host "FAIL M4-C22 ($failCount sheet(s) where text renders at a height its source does not)"
    exit 1
}
Write-Host 'PASS M4-C22 (every text on every generated sheet is the size it is on its source)'
exit 0
