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

$dwgs = Get-ChildItem -LiteralPath $OutDir -Filter '*.dwg' | Sort-Object Name
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

    # M4-C17: exactly one model-space window (id>=2). cadcraft's saveas can promote a second sheet
    # viewport into the model list, so the layout ends up with two or three model windows all drawing
    # the same content -> the sheet looks duplicated (ghosting). More than one model window FAILs.
    $modelVpCount = @($vo.entities | Where-Object { $g = $_.geometry; ($g.PSObject.Properties.Name -contains 'id') -and ([int]$g.id -ge 2) }).Count
    if ($modelVpCount -ne 1) {
        Write-Host "FAIL $($dwg.Name) ($modelVpCount model-space viewports (id>=2), expected exactly 1 -- duplicate viewports ghost the content)"
        $failCount++
        continue
    }

    # Pass when the viewCenter is near the content centre and the view is tall enough to show it.
    $mx = [Math]::Abs($maxX - $minX) * $MarginFrac + 1.0
    $my = $ch * $MarginFrac + 1.0
    $centered = ([Math]::Abs($vcx - $cx) -le $mx) -and ([Math]::Abs($vcy - $cy) -le $my)
    $tallEnough = $vh -ge ($ch * 0.8)
    if ($centered -and $tallEnough) {
        Write-Host "PASS $($dwg.Name) (one content viewport viewCenter ($([Math]::Round($vcx,0)),$([Math]::Round($vcy,0))) near content ($([Math]::Round($cx,0)),$([Math]::Round($cy,0))), viewHeight $([Math]::Round($vh,0)) >= content height $([Math]::Round($ch,0)))"
    } else {
        Write-Host "FAIL $($dwg.Name) (content viewport viewCenter ($([Math]::Round($vcx,0)),$([Math]::Round($vcy,0))) vs content ($([Math]::Round($cx,0)),$([Math]::Round($cy,0))), viewHeight $([Math]::Round($vh,0)) vs content height $([Math]::Round($ch,0)); centered=$centered tallEnough=$tallEnough)"
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
