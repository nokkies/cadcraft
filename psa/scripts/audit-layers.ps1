# audit-layers.ps1 -- report layer-table fidelity of every generated sheet against its source.
#
# A report, not a gate. It exists because a layer can hide content without any entity count changing:
# if a layer is off, frozen, set not-to-plot, or frozen-in-new-viewport in the generated sheet but not
# in the source, everything on it silently disappears from the plot while every entity count still
# matches. Entity-level audits cannot see that. Run it after changing anything that touches layers.
#
# For each sheet it compares, for every layer the source defines:
#   - the layer exists in the generated sheet
#   - on, frozen, plot, newVpFreeze, locked            (visibility and plotting)
#   - color, colorRgb, linetype, lineweight, plotStyle, transparency   (how it prints)
#
# It prints only layer names and property names, never drawing text, so its output is safe to commit
# under the two-folder rule.
#
# Exit 0 when every source layer is present in the generated sheet with matching properties; 1
# otherwise, so it can be promoted to a gate.

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

$cli = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'target\release\cadcraft-cli.exe'
if (-not (Test-Path -LiteralPath $cli)) { throw "cadcraft-cli not found at $cli" }

function Get-LayerTable {
    param([string]$Drawing)
    $scr = [System.IO.Path]::GetTempFileName() + '.scr'
    try {
        [System.IO.File]::WriteAllText($scr, "layer {}`r`n", (New-Object System.Text.ASCIIEncoding))
        $raw = (& $cli run $Drawing --script-file $scr 2>&1 | Select-Object -Last 1)
    } finally {
        Remove-Item $scr -Force -ErrorAction SilentlyContinue
    }
    if (-not $raw) { return @() }
    try { return @(($raw | ConvertFrom-Json).layers) } catch { return @() }
}

# Properties that change what the sheet looks like when plotted.
$props = @('on', 'frozen', 'plot', 'newVpFreeze', 'locked', 'color', 'colorRgb', 'linetype', 'lineweight', 'plotStyle', 'transparency')

$fail = 0
foreach ($n in @($Project.sheets | Sort-Object)) {
    $src = Join-Path $WorkingDir ($n + '.dwg')
    $gen = Join-Path $OutDir ($n + '.dwg')
    if (-not (Test-Path -LiteralPath $src)) { Write-Host "SKIP  $n  no source sheet"; continue }
    if (-not (Test-Path -LiteralPath $gen)) { Write-Host "FAIL  $n  no generated sheet"; $fail++; continue }

    $sl = @(Get-LayerTable -Drawing $src)
    $gl = @(Get-LayerTable -Drawing $gen)
    if ($sl.Count -eq 0) { Write-Host "FAIL  $n  source layer table unreadable"; $fail++; continue }

    $gm = @{}
    foreach ($l in $gl) { $gm[[string]$l.name] = $l }

    $problems = @()
    foreach ($l in $sl) {
        $nm = [string]$l.name
        if (-not $gm.ContainsKey($nm)) { $problems += ($nm + ': layer missing from generated sheet'); continue }
        $o = $gm[$nm]
        foreach ($p in $props) {
            $a = ''; $b = ''
            if ($l.PSObject.Properties.Name -contains $p) { $a = [string]$l.$p }
            if ($o.PSObject.Properties.Name -contains $p) { $b = [string]$o.$p }
            if ($a -ne $b) { $problems += ($nm + '.' + $p + ' [' + $a + '] -> [' + $b + ']') }
        }
    }

    $parts = $n.Split('-')
    $short = if ($parts.Count -gt 2) { ($parts[2..($parts.Count - 1)] -join '-') } else { $n }

    if ($problems.Count -gt 0) {
        Write-Host ("FAIL  {0,-16} {1} layer difference(s): {2}" -f $short, $problems.Count, (($problems | Select-Object -First 8) -join '; '))
        $fail++
    } else {
        Write-Host ("OK    {0,-16} all {1} source layers present with matching visibility and plot properties" -f $short, $sl.Count)
    }
}

if ($fail -gt 0) { Write-Host "FAIL layer audit ($fail sheet(s) differ)"; exit 1 }
Write-Host 'PASS layer audit (every source layer is present in the generated sheet with matching visibility and plot properties)'
exit 0
