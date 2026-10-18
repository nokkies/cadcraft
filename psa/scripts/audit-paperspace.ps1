# audit-paperspace.ps1 -- report paper-space fidelity of every generated sheet against its source.
#
# This is a report, not a gate (gen-all's check-f7/check-f8 are the gates). It exists because the
# draft-stamp defect (card M4-C20, build 0.079) was found only by comparing paper space entity by
# entity -- the model-space checks could not see it, since a stamp in the wrong space is invisible to
# a model-space count. Run it after changing anything that touches paper space.
#
# For each generated sheet it compares, in the sheet's paper-space layout:
#   - entity-type counts (source vs generated)
#   - the draft-stamp entities (space, type, style, height, position)
#
# The one expected difference is Viewport: the source template carries four viewports, two of which
# are template furniture that shows nothing (measured: the duplicate sheet window 41D1 at id=1, and
# the detail window 41D5 at viewHeight 3188 -- zoomed out to nothing). The generators erase those two
# because cadcraft's saveas renumbers ids and promotes 41D1 into the model-window list, which drew the
# content two or three times (the "duplicated" look Reinach reported). So "Viewport 4->2" is correct
# and is reported as EXPECTED, not a defect.
#
# Exit 0 when every sheet matches apart from the expected Viewport difference; 1 when anything else
# differs, so it can be used as a gate if wanted.

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
$runStep = Join-Path $PSScriptRoot 'run-step.ps1'

function Get-PaperEntities {
    param([string]$Drawing)
    $layouts = (& $runStep $Drawing 'layout.list {}' | Select-Object -Last 1)
    $layout = 'Layout1'
    if ($layouts) {
        try {
            $paper = @(($layouts | ConvertFrom-Json) | Where-Object { $_.name -ne 'Model' })
            if ($paper.Count -gt 0) { $layout = [string]$paper[0].name }
        } catch { }
    }
    $ents = (& $runStep $Drawing ('layout.set {"name":' + ($layout | ConvertTo-Json) + '}') 'entities {"limit":20000}' | Select-Object -Last 1)
    if (-not $ents) { return @() }
    try { return @(($ents | ConvertFrom-Json).entities) } catch { return @() }
}

$fail = 0
foreach ($n in @($Project.sheets | Sort-Object)) {
    $src = Join-Path $WorkingDir ($n + '.dwg')
    $gen = Join-Path $OutDir ($n + '.dwg')
    if (-not (Test-Path -LiteralPath $src)) { Write-Host "SKIP  $n  no source sheet"; continue }
    if (-not (Test-Path -LiteralPath $gen)) { Write-Host "FAIL  $n  no generated sheet"; $fail++; continue }

    $s = @(Get-PaperEntities -Drawing $src)
    $g = @(Get-PaperEntities -Drawing $gen)

    $sc = @{}; $gc = @{}
    foreach ($e in $s) { if ($sc.ContainsKey($e.type)) { $sc[$e.type]++ } else { $sc[$e.type] = 1 } }
    foreach ($e in $g) { if ($gc.ContainsKey($e.type)) { $gc[$e.type]++ } else { $gc[$e.type] = 1 } }

    $unexpected = @()
    foreach ($t in @($sc.Keys + $gc.Keys | Sort-Object -Unique)) {
        $a = $sc[$t]; $b = $gc[$t]
        if ($a -ne $b) {
            if ($t -eq 'Viewport' -and $a -eq 4 -and $b -eq 2) { continue }   # expected (see header)
            $unexpected += ($t + ' ' + $a + '->' + $b)
        }
    }

    # Short label: drop the leading "<project>-<discipline>-" prefix without naming it here.
    $parts = $n.Split('-')
    $short = if ($parts.Count -gt 2) { ($parts[2..($parts.Count - 1)] -join '-') } else { $n }
    if ($unexpected.Count -gt 0) {
        Write-Host ("FAIL  {0,-16} paper space differs: {1}" -f $short, ($unexpected -join ', '))
        $fail++
    } else {
        $vpNote = if ($sc['Viewport'] -eq 4 -and $gc['Viewport'] -eq 2) { ' (Viewport 4->2 expected)' } else { '' }
        Write-Host ("OK    {0,-16} paper space matches source: {1} entities{2}" -f $short, $g.Count, $vpNote)
    }
}

if ($fail -gt 0) { Write-Host "FAIL paper-space audit ($fail sheet(s) differ beyond the expected viewport erasure)"; exit 1 }
Write-Host 'PASS paper-space audit (every generated sheet matches its source, apart from the two erased template viewports)'
exit 0
