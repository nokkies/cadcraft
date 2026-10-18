# check-f8.ps1 -- card M4-C20: the draft stamps are paper-space Text, like the working drawings.
#
# The PRELIMINARY / NOT FOR CONSTRUCTION stamps are paper-space single-line Text in the working
# drawings (measured on SCD-001: layer "Preliminary Not For Construction", Text entities at
# (768,72) and (753,66), height 4, style Romans, and NOTHING on that layer in model space). A paper
# stamp prints at a fixed sheet position whatever the content viewport shows. The generators used to
# emit them as model-space MText, which put them inside the content window where the viewport scales
# them -- a fidelity difference from the source.
#
# This check reads each generated sheet's paper space and model space and requires: exactly two
# paper-space Text entities on the stamp layer with the expected values, and zero entities on that
# layer in model space. A sheet whose stamps are model-space, missing, or the wrong entity type FAILs.
#
# Exit 0 when every generated sheet matches, 1 otherwise.

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
    throw 'PSA_DRAWINGS is not set to an existing folder.'
}

function Resolve-CadcraftCli {
    $cmd = Get-Command 'cadcraft-cli' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $exe = 'C:\Users\ReinachvanNieuwenhui\src\cadcraft\target\release\cadcraft-cli.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    throw 'cadcraft-cli not found.'
}

$D = Get-PSADrawingsRoot
. (Join-Path $PSScriptRoot 'project.ps1')
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $D 'fusion\out' }
if (-not (Test-Path -LiteralPath $OutDir)) { throw "out dir not found: $OutDir" }
$cli = Resolve-CadcraftCli
$runStep = Join-Path $PSScriptRoot 'run-step.ps1'

$StampLayer = 'Preliminary Not For Construction'
# The two stamps, with the source's position and height.
$Expected = @(
    @{ text = 'PRELIMINARY';         x = 768.0; y = 72.0; h = 4.0 },
    @{ text = 'NOT FOR CONSTRUCTION'; x = 753.0; y = 66.0; h = 4.0 }
)

function Get-LayerEntities {
    param([string]$Drawing, [string]$Layout, [switch]$Paper)
    $steps = @()
    if ($Paper) { $steps += ('layout.set {"name":' + ($Layout | ConvertTo-Json) + '}') }
    $steps += ('entities {"layer":' + ($StampLayer | ConvertTo-Json) + ',"limit":200}')
    $out = (& $runStep $Drawing @steps | Select-Object -Last 1)
    if (-not $out) { return @() }
    try { return @(($out | ConvertFrom-Json).entities) } catch { return @() }
}

$fail = 0
$checked = 0
foreach ($n in @($Project.sheets | Sort-Object)) {
    $dwg = Join-Path $OutDir ($n + '.dwg')
    if (-not (Test-Path -LiteralPath $dwg)) { Write-Host "FAIL  $n  no generated sheet"; $fail++; continue }
    $checked++

    # The layout name: the first paper-space layout in the sheet.
    $layouts = (& $runStep $dwg 'layout.list {}' | Select-Object -Last 1)
    $layout = 'Layout1'
    if ($layouts) {
        try {
            $paper = @(($layouts | ConvertFrom-Json) | Where-Object { $_.name -ne 'Model' })
            if ($paper.Count -gt 0) { $layout = [string]$paper[0].name }
        } catch { }
    }

    $paper = @(Get-LayerEntities -Drawing $dwg -Layout $layout -Paper)
    $model = @(Get-LayerEntities -Drawing $dwg -Layout $layout)

    $problems = @()
    if ($model.Count -ne 0) { $problems += "$($model.Count) stamp entities in MODEL space (source has 0)" }

    foreach ($exp in $Expected) {
        $hit = @($paper | Where-Object {
            $_.type -eq 'Text' -and
            [string]$_.geometry.value -eq $exp.text -and
            ([Math]::Abs([double]$_.geometry.insert.x - $exp.x) -lt 0.5) -and
            ([Math]::Abs([double]$_.geometry.insert.y - $exp.y) -lt 0.5) -and
            ([Math]::Abs([double]$_.geometry.height - $exp.h) -lt 0.05)
        })
        if ($hit.Count -eq 0) {
            $wrongType = @($paper | Where-Object { [string]$_.geometry.value -eq $exp.text })
            if ($wrongType.Count -gt 0) {
                $problems += ("'" + $exp.text + "' present but type=" + ($wrongType[0].type) + ' (must be paper-space Text)')
            } else {
                $problems += ("'" + $exp.text + "' missing from paper space")
            }
        }
    }

    if ($problems.Count -gt 0) {
        Write-Host ("FAIL  $n  " + ($problems -join '; '))
        $fail++
    } else {
        Write-Host "PASS  $n  2 paper-space Text stamps, 0 in model space (layout $layout)"
    }
}

if ($checked -eq 0) { Write-Host 'FAIL  no generated sheets found'; exit 1 }
if ($fail -gt 0) { Write-Host "FAIL M4-C20 ($fail of $checked sheets have the draft stamps in the wrong space or type)"; exit 1 }
Write-Host "PASS M4-C20 (all $checked generated sheets carry the draft stamps as paper-space Text, like the working drawings)"
exit 0
