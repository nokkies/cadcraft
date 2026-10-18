# check-f6.ps1 -- card M4-C16: each generated sheet's content viewport frames its content.
#
# The defect (found by Reinach opening the DWG): the template's content viewport (the model-space
# window with the largest paper window) was authored over an EMPTY template model space, so its
# stored view pointed at empty space (measured on the template: viewCenter (-350,571), viewHeight
# 524). A generated sheet therefore plotted with the border and title block (paper space, always
# drawn) but NO content -- the content viewport looked where the content is not. gen-scd.ps1 now
# reframes that viewport on the drawn content's extents (M4-C16).
#
# This check guards it: for each generated sheet, compute the model content's bounding box, find the
# content viewport (id>=2, largest paper window), and require its viewCenter to lie inside the
# content box (with a margin) and its viewHeight to be at least the content height (so the content
# is framed, not pointed away). A viewport still pointing at the empty-template location FAILs.
#
# Exit 0 when every generated sheet's content viewport frames its content, 1 otherwise.

[CmdletBinding()]
param(
    [string]$OutDir,
    # Fraction of the content box the viewCenter may sit outside and still pass (generous margin).
    [double]$MarginFrac = 0.5
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

# Wrapped in @(): with a single sheet, Get-ChildItem | Sort-Object returns a bare FileInfo, and
# Set-StrictMode -Version 3 rejects .Count on it. That made this check impossible to run against a
# one-sheet directory, which is how a negative test has to be driven -- found when trying to prove the
# duplicate-viewport rule bites.
$dwgs = @(Get-ChildItem -LiteralPath $OutDir -Filter '*.dwg' | Sort-Object Name)
if ($dwgs.Count -eq 0) { throw "no sheets in $OutDir" }

function Get-FirstLayout { param([string]$File)
    $j = (pwsh -NoProfile -File $runStep $File 'layout.list {}' | Select-Object -Last 1)
    if (-not $j) { return '' }
    $lay = @(([regex]::Matches($j, '"name":"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }) | Where-Object { $_ -ne 'Model' })
    if ($lay.Count -gt 0) { return $lay[0] } else { return '' }
}

$failCount = 0
foreach ($dwg in $dwgs) {
    $f = $dwg.FullName
    $lay = Get-FirstLayout -File $f
    if (-not $lay) { Write-Host "FAIL $($dwg.Name) no paper-space layout"; $failCount++; continue }

    # Model content bounding box.
    $ej = (pwsh -NoProfile -File $runStep $f 'entities {"limit":10000}' | Select-Object -Last 1)
    if (-not $ej) { Write-Host "FAIL $($dwg.Name) could not read entities"; $failCount++; continue }
    $eo = $ej | ConvertFrom-Json
    $xs = @(); $ys = @()
    foreach ($e in $eo.entities) {
        $g = $e.geometry
        # Line endpoints are `a`/`b` (not start/end); Circle `center`; text/insert `insert`.
        if ($g.PSObject.Properties.Name -contains 'a' -and $g.a) { $xs += [double]$g.a.x; $ys += [double]$g.a.y }
        if ($g.PSObject.Properties.Name -contains 'b' -and $g.b) { $xs += [double]$g.b.x; $ys += [double]$g.b.y }
        if ($g.PSObject.Properties.Name -contains 'center' -and $g.center) { $xs += [double]$g.center.x; $ys += [double]$g.center.y }
        if ($g.PSObject.Properties.Name -contains 'insert' -and $g.insert) { $xs += [double]$g.insert.x; $ys += [double]$g.insert.y }
    }
    if ($xs.Count -eq 0) { Write-Host "FAIL $($dwg.Name) no model geometry to frame"; $failCount++; continue }
    $minX = ($xs | Measure-Object -Minimum).Minimum; $maxX = ($xs | Measure-Object -Maximum).Maximum
    $minY = ($ys | Measure-Object -Minimum).Minimum; $maxY = ($ys | Measure-Object -Maximum).Maximum
    $cx = ($minX + $maxX) / 2.0; $cy = ($minY + $maxY) / 2.0
    $ch = $maxY - $minY

    # Content viewport: id>=2, largest paper window.
    $vj = (pwsh -NoProfile -File $runStep $f ('layout.set {"name":' + ($lay | ConvertTo-Json) + '}') 'entities {"type":"Viewport","limit":100}' | Select-Object -Last 1)
    if (-not $vj) { Write-Host "FAIL $($dwg.Name) could not read viewports"; $failCount++; continue }
    $vo = $vj | ConvertFrom-Json
    $best = $null; $bestArea = -1.0
    foreach ($e in $vo.entities) {
        $g = $e.geometry
        $vid = -1; if ($g.PSObject.Properties.Name -contains 'id') { $vid = [int]$g.id }
        if ($vid -ge 2) {
            $w = 0.0; $h = 0.0
            if ($g.PSObject.Properties.Name -contains 'width') { $w = [double]$g.width }
            if ($g.PSObject.Properties.Name -contains 'height') { $h = [double]$g.height }
            if (($w * $h) -gt $bestArea) { $bestArea = $w * $h; $best = $g }
        }
    }
    if ($null -eq $best) { Write-Host "FAIL $($dwg.Name) no content viewport (id>=2)"; $failCount++; continue }
    $vcx = [double]$best.viewCenter.x; $vcy = [double]$best.viewCenter.y; $vh = [double]$best.viewHeight

    # M4-G1 (build 0.126): this used to require EXACTLY ONE model-space window (id>=2), written to pass the
    # generator's erase workaround rather than the target. The template's second model window (41D5) turned
    # out to be an orphan `*Paper_Space0` viewport no layout owned (psa/REVIEW-0.125.md section 1), and the
    # template was regenerated with the orphan emptied -- so a source sheet now has one content window, and
    # so does a generated one. What still matters, and what this asserts, is that no two model windows show
    # the SAME region: ghosting is duplication, not multiplicity. With one content window there is nothing to
    # duplicate, so this is a cheap guard against a future regression reintroducing a duplicated window.
    $modelVps = @(@($vo.entities | Where-Object { $g = $_.geometry; ($g.PSObject.Properties.Name -contains 'id') -and ([int]$g.id -ge 2) }))
    if ($modelVps.Count -lt 1) {
        Write-Host "FAIL $($dwg.Name) (no model-space window at all, nothing plots)"
        $failCount++
        continue
    }
    $dupe = $null
    for ($i = 0; $i -lt $modelVps.Count; $i++) {
        for ($j = $i + 1; $j -lt $modelVps.Count; $j++) {
            $a = $modelVps[$i].geometry; $b = $modelVps[$j].geometry
            $sameCentre = ([Math]::Abs([double]$a.viewCenter.x - [double]$b.viewCenter.x) -lt 1.0) -and
                          ([Math]::Abs([double]$a.viewCenter.y - [double]$b.viewCenter.y) -lt 1.0)
            $sameZoom = ([double]$a.viewHeight -gt 0) -and ([Math]::Abs([double]$a.viewHeight - [double]$b.viewHeight) / [double]$a.viewHeight -lt 0.02)
            if ($sameCentre -and $sameZoom) { $dupe = "$($modelVps[$i].handle)/$($modelVps[$j].handle)"; break }
        }
        if ($dupe) { break }
    }
    if ($dupe) {
        Write-Host "FAIL $($dwg.Name) (two model windows show the same region ($dupe) -- duplicate viewports ghost the content)"
        $failCount++
        continue
    }

    # Pass when the viewport's view rectangle contains the content box. The view shows a region of
    # height viewHeight and width viewHeight * (window width/height), centred on viewCenter. The
    # working drawings frame the window at its own centre (view = window centre, vh = window height),
    # so the check is "content inside the view", not "view centred on content".
    $winAspect = if ($best.PSObject.Properties.Name -contains 'width' -and [double]$best.height -gt 0) { [double]$best.width / [double]$best.height } else { 1.55 }
    $shownW = $vh * $winAspect
    $inX = ($minX -ge ($vcx - $shownW / 2.0 - 1.0)) -and ($maxX -le ($vcx + $shownW / 2.0 + 1.0))
    $inY = ($minY -ge ($vcy - $vh / 2.0 - 1.0)) -and ($maxY -le ($vcy + $vh / 2.0 + 1.0))
    if ($inX -and $inY) {
        Write-Host "PASS $($dwg.Name) (content X[$([Math]::Round($minX,0))..$([Math]::Round($maxX,0))] Y[$([Math]::Round($minY,0))..$([Math]::Round($maxY,0))] inside view X[$([Math]::Round($vcx-$shownW/2,0))..$([Math]::Round($vcx+$shownW/2,0))] Y[$([Math]::Round($vcy-$vh/2,0))..$([Math]::Round($vcy+$vh/2,0))])"
    } else {
        Write-Host "FAIL $($dwg.Name) (content X[$([Math]::Round($minX,0))..$([Math]::Round($maxX,0))] Y[$([Math]::Round($minY,0))..$([Math]::Round($maxY,0))] NOT inside view X[$([Math]::Round($vcx-$shownW/2,0))..$([Math]::Round($vcx+$shownW/2,0))] Y[$([Math]::Round($vcy-$vh/2,0))..$([Math]::Round($vcy+$vh/2,0))]; inX=$inX inY=$inY)"
        $failCount++
    }
}

if ($failCount -eq 0) {
    Write-Host 'PASS M4-C16 (every generated sheet content viewport frames its content)'
    exit 0
} else {
    Write-Host "FAIL M4-C16 ($failCount sheet(s) content viewport does not frame its content)"
    exit 1
}
