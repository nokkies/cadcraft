# audit-sheet-space.ps1 -- report entity fidelity of every generated sheet against its source, in
# both paper space and model space.
#
# This is a report, not a gate (gen-all's check-f7/check-f8 are the gates). It exists because the
# draft-stamp defect (card M4-C20, build 0.079) was found only by comparing paper space entity by
# entity -- the model-space checks could not see it, since a stamp in the wrong space is invisible to
# a model-space count. Run it after changing anything that touches sheet space.
#
# For each generated sheet it compares, in the sheet's paper-space layout and in model space:
#   - entity-type counts (source vs generated)
#   - for model-space texts, how many the generator adds and how many are missing (reported by layer
#     only, never by text, so the output is safe to commit under the two-folder rule)
#
# Expected differences, all reported as EXPECTED rather than defects:
#   - paper Viewport 4->2: the source template carries four viewports, two of which are template
#     furniture that shows nothing (measured: the duplicate sheet window 41D1 at id=1, and the detail
#     window 41D5 at viewHeight 3188 -- zoomed out to nothing). The generators erase those two because
#     cadcraft's saveas renumbers ids and promotes 41D1 into the model-window list, which drew the
#     content two or three times (the "duplicated" look Reinach reported).
#   - model MText additions on the annotation layers: the generators add the D4 terminal-number labels
#     (a "Tn" beside each I/O channel name, card DRAWING-WORK D4) and the D3 DIN-rail note. Additions
#     are allowed; MISSING source texts are not.
#
# Exit 0 when every sheet matches apart from the expected differences; 1 when a source text is missing
# or an unexpected count differs, so it can be used as a gate if wanted.

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

function Get-ModelEntities {
    param([string]$Drawing)
    $ents = (& $runStep $Drawing 'entities {"limit":30000}' | Select-Object -Last 1)
    if (-not $ents) { return @() }
    try { return @(($ents | ConvertFrom-Json).entities) } catch { return @() }
}

function Get-TypeCounts {
    param($Ents)
    $m = @{}
    foreach ($e in $Ents) { if ($m.ContainsKey($e.type)) { $m[$e.type]++ } else { $m[$e.type] = 1 } }
    return $m
}

# Text multiset keyed by layer+content, so a difference can be reported by layer without printing text.
function Get-TextKeyMap {
    param($Ents)
    $m = @{}
    foreach ($e in $Ents) {
        if ($e.type -ne 'MText' -and $e.type -ne 'Text') { continue }
        $val = ''
        if ($e.geometry.PSObject.Properties.Name -contains 'contents') { $val = [string]$e.geometry.contents }
        elseif ($e.geometry.PSObject.Properties.Name -contains 'value') { $val = [string]$e.geometry.value }
        $key = [string]$e.layer + '|' + $val
        if ($m.ContainsKey($key)) { $m[$key]++ } else { $m[$key] = 1 }
    }
    return $m
}

$fail = 0
foreach ($n in @($Project.sheets | Sort-Object)) {
    $src = Join-Path $WorkingDir ($n + '.dwg')
    $gen = Join-Path $OutDir ($n + '.dwg')
    if (-not (Test-Path -LiteralPath $src)) { Write-Host "SKIP  $n  no source sheet"; continue }
    if (-not (Test-Path -LiteralPath $gen)) { Write-Host "FAIL  $n  no generated sheet"; $fail++; continue }

    $sPaper = @(Get-PaperEntities -Drawing $src)
    $gPaper = @(Get-PaperEntities -Drawing $gen)
    $sModel = @(Get-ModelEntities -Drawing $src)
    $gModel = @(Get-ModelEntities -Drawing $gen)

    $unexpected = @()

    # --- paper space counts ---
    $sp = Get-TypeCounts -Ents $sPaper
    $gp = Get-TypeCounts -Ents $gPaper
    foreach ($t in @($sp.Keys + $gp.Keys | Sort-Object -Unique)) {
        $a = 0; $b = 0
        if ($sp.ContainsKey($t)) { $a = $sp[$t] }
        if ($gp.ContainsKey($t)) { $b = $gp[$t] }
        if ($a -ne $b) {
            if ($t -eq 'Viewport' -and $a -eq 4 -and $b -eq 2) { continue }   # expected (see header)
            $unexpected += ('paper ' + $t + ' ' + $a + '->' + $b)
        }
    }

    # --- model space counts (MText/Text handled by the text diff below) ---
    $sm = Get-TypeCounts -Ents $sModel
    $gm = Get-TypeCounts -Ents $gModel
    foreach ($t in @($sm.Keys + $gm.Keys | Sort-Object -Unique)) {
        $a = 0; $b = 0
        if ($sm.ContainsKey($t)) { $a = $sm[$t] }
        if ($gm.ContainsKey($t)) { $b = $gm[$t] }
        if ($a -ne $b -and $t -ne 'MText' -and $t -ne 'Text') { $unexpected += ('model ' + $t + ' ' + $a + '->' + $b) }
    }

    # --- model space texts: additions allowed (D4/D3 annotations); missing source texts are a defect ---
    $st = Get-TextKeyMap -Ents $sModel
    $gt = Get-TextKeyMap -Ents $gModel
    $missing = 0
    $missingLayers = @{}
    foreach ($k in $st.Keys) {
        $b = 0; if ($gt.ContainsKey($k)) { $b = $gt[$k] }
        $d = $st[$k] - $b
        if ($d -gt 0) {
            $missing += $d
            $lay = $k.Split('|')[0]
            if ($missingLayers.ContainsKey($lay)) { $missingLayers[$lay] += $d } else { $missingLayers[$lay] = $d }
        }
    }
    $added = 0
    foreach ($k in $gt.Keys) {
        $a = 0; if ($st.ContainsKey($k)) { $a = $st[$k] }
        $d = $gt[$k] - $a
        if ($d -gt 0) { $added += $d }
    }
    if ($missing -gt 0) {
        $mp = @()
        foreach ($lay in ($missingLayers.Keys | Sort-Object)) { $mp += ($lay + ':-' + $missingLayers[$lay]) }
        $unexpected += ('model texts MISSING from generated (' + $missing + ') ' + ($mp -join ' '))
    }

    # Short label: drop the leading "<project>-<discipline>-" prefix without naming it here.
    $parts = $n.Split('-')
    $short = if ($parts.Count -gt 2) { ($parts[2..($parts.Count - 1)] -join '-') } else { $n }

    if ($unexpected.Count -gt 0) {
        Write-Host ("FAIL  {0,-16} {1}" -f $short, ($unexpected -join '; '))
        $fail++
    } else {
        $notes = @()
        if ($sp.ContainsKey('Viewport') -and $gp.ContainsKey('Viewport') -and $sp['Viewport'] -eq 4 -and $gp['Viewport'] -eq 2) { $notes += 'Viewport 4->2 expected' }
        if ($added -gt 0) { $notes += ([string]$added + ' annotation texts added (D4/D3)') }
        $noteStr = ''
        if ($notes.Count -gt 0) { $noteStr = ' (' + ($notes -join ', ') + ')' }
        Write-Host ("OK    {0,-16} matches source: paper {1}, model {2} entities, 0 source texts missing{3}" -f $short, $gPaper.Count, $gModel.Count, $noteStr)
    }
}

if ($fail -gt 0) { Write-Host "FAIL sheet-space audit ($fail sheet(s) differ beyond the expected differences)"; exit 1 }
Write-Host 'PASS sheet-space audit (every generated sheet matches its source in paper and model space, apart from the erased template viewports and the intentional annotations)'
exit 0
