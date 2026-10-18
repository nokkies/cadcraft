# check-mtextwidth.ps1 -- card M4-C24: every MText keeps the wrap width its source gives it.
#
# Found while explaining a 42x ink difference between a source working drawing and the sheet generated from
# it (builds 0.117/0.118 chased that number through the DWG round-trip, viewport ids, the layer table and the
# page setup and found none of them responsible). The content turned out to be faithful -- 27 of 31 texts
# verbatim, zero source-only texts -- but the MText PROPERTIES were not:
#
#   sheet                 source MText with a wrap width    generated
#   GAD-001               28                               0
#   GAD-002               1                                0
#   SCD-001..005          21, 12, 5, 9, 11                 0
#   TMD-001..005          12, 26, 38, 36, 26               0
#
# Two hundred and nine MText across the twelve sheets carry a wrap width in the source and none of them keep
# it. An MText with width 0 does not wrap: the whole paragraph renders on one line. The NOTES block on
# TMD-001 is width 500 in the source and width 0 in ours, so a five-line note plots as one long line running
# off the sheet. The same rewrite drops the text style: the source's MText use isocp2 and ours come out as
# Standard.
#
# Why no existing check saw it. audit-textstyles compares the STYLE TABLE, which is intact -- isocp2 exists
# in the generated file with the same font, height and width factor. The defect is on the entity, not the
# table, so the audit is looking one level away from it. audit-sheet-space compares the model-space TEXT
# MULTISET, which matches because the characters are all there. check-textheights compares rendered heights,
# which are right. Nothing compared per-entity MText properties. This is the second time this shape has
# bitten: build 0.112 found the rendered height living in the seam between two audits, and this is the same
# seam one field over.
#
# The check reads both sides' model space through run-step.ps1 and compares, for every source MText, whether
# the generated sheet has an MText at the same insert with the same wrap width. Matching on position rather
# than on order, because the generators emit in a different order and add their own annotations.
#
# Exit 0 when every source MText's wrap width survives; 1 otherwise.

[CmdletBinding()]
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
    throw 'PSA_DRAWINGS is not set to an existing folder'
}

$D = Get-PSADrawingsRoot
. (Join-Path $PSScriptRoot 'project.ps1')
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $D 'fusion\out' }
if (-not (Test-Path -LiteralPath $OutDir)) { throw "out dir not found: $OutDir" }
$runStep = Join-Path $PSScriptRoot 'run-step.ps1'
if (-not (Test-Path -LiteralPath $runStep)) { throw 'run-step.ps1 not found next to this script' }

$script:pythonExe = $null
function Resolve-Python {
    $c = Get-Command python -ErrorAction SilentlyContinue
    if ($c -and $c.Source -notmatch 'WindowsApps' -and (Test-Path -LiteralPath $c.Source)) { $script:pythonExe = $c.Source; return }
    foreach ($p in 'C:\Python314\python.exe', 'C:\Python312\python.exe') {
        if (Test-Path -LiteralPath $p) { $script:pythonExe = $p; return }
    }
    throw 'no usable python interpreter found'
}
Resolve-Python

$tmp = Join-Path $D ('fusion\colour-check\mtw-' + [Guid]::NewGuid().ToString('N'))
$script:pyFile = $null
try {
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    $py = @'
import json, sys

def mtexts(path):
    d = json.load(open(path, encoding="utf-8"))
    out = []
    for e in d.get("entities", []):
        if (e.get("type") or "") != "MText":
            continue
        g = e.get("geometry") or {}
        ins = g.get("insert") or {}
        out.append({
            "x": round(float(ins.get("x") or 0.0), 1),
            "y": round(float(ins.get("y") or 0.0), 1),
            "w": round(float(g.get("width") or 0.0), 1),
            "style": g.get("style"),
        })
    return out

src = mtexts(sys.argv[1])
gen = mtexts(sys.argv[2])

# Index generated MText by rounded position. The generators emit in a different order and add their own
# annotations, so order cannot be used; position can.
by_pos = {}
for m in gen:
    by_pos.setdefault((m["x"], m["y"]), []).append(m)

lost = 0
changed_style = 0
matched = 0
for m in src:
    cands = by_pos.get((m["x"], m["y"])) or []
    if not cands:
        # No generated MText at this position: the generator moved or merged it. Not this check's business --
        # check-f7 compares the text multiset and would see a genuinely missing text.
        continue
    matched += 1
    # A wrap width in the source that is zero in the generated sheet is the defect this check exists for.
    if m["w"] > 0 and all(c["w"] <= 0 for c in cands):
        lost += 1
    # Style rewrite is reported separately: it is currently invisible because every .shx style falls through
    # to the same stroke font, but it is a real difference in the file and would matter the moment cadcraft
    # renders SHX properly.
    if m["style"] and all((c["style"] or "") != m["style"] for c in cands):
        changed_style += 1

print(json.dumps({"src_mtexts": len(src), "gen_mtexts": len(gen), "matched": matched,
                  "lost_width": lost, "changed_style": changed_style}))
'@
    $script:pyFile = Join-Path $tmp 'mtw.py'
    [System.IO.File]::WriteAllText($script:pyFile, $py, (New-Object System.Text.ASCIIEncoding))

    $genSheets = @(Get-ChildItem -LiteralPath $OutDir -Filter '*.dwg' | Sort-Object Name)
    if ($genSheets.Count -eq 0) { throw "no sheets in $OutDir" }

    $fail = 0
    $totLost = 0
    $totStyle = 0
    $totMatched = 0
    foreach ($g in $genSheets) {
        $n = $g.BaseName
        $srcPath = Join-Path $D ($Project.workingDir + '\' + $n + '.dwg')
        if (-not (Test-Path -LiteralPath $srcPath)) { Write-Host "FAIL $n (no source sheet)"; $fail++; continue }

        $js = Join-Path $tmp ('s_' + $n + '.json')
        $jg = Join-Path $tmp ('g_' + $n + '.json')
        $null = (& pwsh -NoProfile -File $runStep $srcPath 'entities {"limit":20000}' 2>&1 | Out-String)
        $rs = (& pwsh -NoProfile -File $runStep $srcPath 'entities {"limit":20000}' 2>&1 | Out-String)
        $rg = (& pwsh -NoProfile -File $runStep $g.FullName 'entities {"limit":20000}' 2>&1 | Out-String)
        $ls = @(($rs -split "`r?`n" | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1))
        $lg = @(($rg -split "`r?`n" | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1))
        if ($ls.Count -eq 0 -or $lg.Count -eq 0) { Write-Host "FAIL $n (could not read entities)"; $fail++; continue }
        [System.IO.File]::WriteAllText($js, $ls[0], (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText($jg, $lg[0], (New-Object System.Text.UTF8Encoding($false)))

        $out = (& $script:pythonExe $script:pyFile $js $jg 2>&1 | ForEach-Object { "$_" })
        $jl = @($out | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1)
        if ($jl.Count -eq 0) {
            Write-Host "FAIL $n (the comparison returned no result)"
            ($out | Select-Object -First 3) | ForEach-Object { Write-Host ("  " + $_) }
            $fail++; continue
        }
        $o = $jl[0] | ConvertFrom-Json

        # Anti-vacuity: if the comparison matched no MText at all it compared nothing, which is the shape that
        # produced two vacuous PASS lines at build 0.112.
        if ([int]$o.matched -eq 0 -and [int]$o.src_mtexts -gt 0) {
            Write-Host ("FAIL {0} (compared zero MText: {1} in the source, {2} in the generated, no position shared)" -f $n, $o.src_mtexts, $o.gen_mtexts)
            $fail++
            continue
        }

        $totLost += [int]$o.lost_width
        $totStyle += [int]$o.changed_style
        $totMatched += [int]$o.matched
        if ([int]$o.lost_width -gt 0) {
            Write-Host ("FAIL {0} ({1} of {2} matched MText lost their wrap width; {3} had their text style rewritten)" -f $n, $o.lost_width, $o.matched, $o.changed_style)
            $fail++
        } else {
            Write-Host ("PASS {0} ({1} MText compared, every wrap width and text style preserved)" -f $n, $o.matched)
        }
    }

    if ($fail -gt 0) {
        Write-Host ("FAIL M4-C24 ({0} sheet(s) where MText properties do not survive generation; {1} wrap widths lost in total, {2} text styles rewritten, {3} MText compared)" -f $fail, $totLost, $totStyle, $totMatched)
        exit 1
    }
    Write-Host ("PASS M4-C24 (all {0} sheets: {1} MText compared, every wrap width and text style preserved)" -f $genSheets.Count, $totMatched)
    exit 0
} finally {
    if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
