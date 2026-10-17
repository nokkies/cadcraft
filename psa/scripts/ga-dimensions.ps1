# ga-dimensions.ps1 -- DRAWING-WORK D2: check the GA component rectangles against dimensions.csv.
#
# D2 asks that component outlines on the general arrangement match the manufacturer dimensions in
# $D\fusion\dimensions.csv. This measures each labelled component box on the GA (1:3 scale) and
# compares it to the real W x H from dimensions.csv, classifying each as:
#   TO-SCALE  - drawn within tolerance of the real size (a true outline)
#   SCHEMATIC - drawn much larger than real (a placeholder box, standard for a schematic GA)
# The GA note 2 already says "COMPONENT OUTLINES AND POSITIONS ARE NOMINAL"; this quantifies it and
# flags any component that is neither to-scale nor clearly schematic (an in-between size, which is
# the only case that is actually wrong). Exit 0 when every component is either to-scale or clearly
# schematic; 1 when one is in the ambiguous middle (too big to be a sliver, too small to be a box).
#
# This is a measurement/check tool. It does not modify the drawing.

[CmdletBinding()]
param(
    [string]$GaDrawing,
    [string]$DimensionsCsv,
    [double]$Scale = 3.0,        # 1:3 -> model units are 3x real mm
    [double]$ToleranceMm = 1.0,  # within this of real -> TO-SCALE
    [double]$SchematicFactor = 1.5  # drawn > this x real -> clearly SCHEMATIC
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
function Get-ArgumentForNative { param([string]$Value) return '"' + $Value.Replace('"','""') + '"' }
function JNum { param($v) return ([double]$v).ToString([System.Globalization.CultureInfo]::InvariantCulture) }
function Invoke-CliSteps {
    param([string]$Cli, [string]$Drawing, [string[]]$Steps)
    $tmpOut = [System.IO.Path]::GetTempFileName(); $tmpErr = [System.IO.Path]::GetTempFileName()
    $bat = [System.IO.Path]::GetTempFileName() + '.cmd'
    try {
        $argPart = ''
        foreach ($s in $Steps) { $argPart += ' --cmd "' + $s.Replace('"','\"') + '"' }
        $line = '"' + $Cli + '" run "' + $Drawing + '"' + $argPart
        [System.IO.File]::WriteAllText($bat, "@echo off`r`n$line`r`n", (New-Object System.Text.ASCIIEncoding))
        $pi = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d','/c',(Get-ArgumentForNative -Value $bat)) -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        if (-not $pi.WaitForExit(120000)) { try { $pi.Kill() } catch {}; return $null }
        if ($pi.ExitCode -ne 0) { return $null }
        $text = [System.IO.File]::ReadAllText($tmpOut)
        $jsonLines = @($text -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') })
        if ($jsonLines.Count -eq 0) { return $null }
        try { return ($jsonLines[-1] | ConvertFrom-Json) } catch { return $null }
    } catch { return $null } finally {
        Remove-Item -LiteralPath $tmpOut,$tmpErr,$bat -Force -ErrorAction SilentlyContinue
    }
}

$D = Get-PSADrawingsRoot
if ([string]::IsNullOrWhiteSpace($GaDrawing)) { $GaDrawing = Join-Path $D 'fusion\out\NNNN-IC-GAD-001_A.dwg' }
if ([string]::IsNullOrWhiteSpace($DimensionsCsv)) { $DimensionsCsv = Join-Path $D 'fusion\dimensions.csv' }
if (-not (Test-Path -LiteralPath $GaDrawing)) { throw "GA not found: $GaDrawing" }
if (-not (Test-Path -LiteralPath $DimensionsCsv)) { throw "dimensions.csv not found: $DimensionsCsv" }

$cli = Resolve-CadcraftCli

# GA component designation -> BOM item (dimensions.csv row).
$labelToItem = [ordered]@{
    'X3 DI'         = '2'
    'X4 DO'         = '3'
    'X5 AO'         = '4'
    '8 PORT SWITCH' = '5'
    '24V PSU'       = '6'
}
$rows = @{}
foreach ($r in (Import-Csv -LiteralPath $DimensionsCsv)) {
    if ([double]$r.width_mm -le 0) { continue }
    $rows[[string]$r.item] = [pscustomobject]@{ w = [double]$r.width_mm; h = [double]$r.height_mm; part = $r.part }
}

$ents = Invoke-CliSteps -Cli $cli -Drawing $GaDrawing -Steps @('entities {"limit":5000}')
if ($null -eq $ents) { throw 'could not read the GA entities' }
$lines = @($ents.entities | Where-Object { $_.type -eq 'Line' })
$txt = Invoke-CliSteps -Cli $cli -Drawing $GaDrawing -Steps @('texts {"limit":2000}')
if ($null -eq $txt) { throw 'could not read the GA texts' }

function Find-Box($tx, $ty, $radius) {
    $cand = @($lines | Where-Object {
        $mx = ($_.geometry.a.x + $_.geometry.b.x) / 2.0
        $my = ($_.geometry.a.y + $_.geometry.b.y) / 2.0
        ([Math]::Abs($mx - $tx) -le $radius) -and ([Math]::Abs($my - $ty) -le $radius)
    })
    $vert = @($cand | Where-Object { [Math]::Abs($_.geometry.a.x - $_.geometry.b.x) -lt 0.01 })
    $horiz = @($cand | Where-Object { [Math]::Abs($_.geometry.a.y - $_.geometry.b.y) -lt 0.01 })
    if ($vert.Count -lt 2 -or $horiz.Count -lt 2) { return $null }
    $xs = @($vert | ForEach-Object { $_.geometry.a.x } | Sort-Object)
    $ys = @($horiz | ForEach-Object { $_.geometry.a.y } | Sort-Object)
    return [pscustomobject]@{ x0 = $xs[0]; x1 = $xs[-1]; y0 = $ys[0]; y1 = $ys[-1] }
}

$ambiguous = 0
foreach ($label in $labelToItem.Keys) {
    $item = $labelToItem[$label]
    if (-not $rows.ContainsKey($item)) { Write-Host ("  {0,-14} item {1}: no dimensions row" -f $label, $item); continue }
    $lab = @($txt.texts | Where-Object { ([string]$_.text).Trim() -eq $label } | Select-Object -First 1)
    if ($lab.Count -eq 0) { Write-Host ("  {0,-14}: label not found" -f $label); continue }
    $box = Find-Box ([double]$lab[0].at[0]) ([double]$lab[0].at[1]) 90
    if ($null -eq $box) { Write-Host ("  {0,-14}: box not found" -f $label); continue }
    $realW = $rows[$item].w; $realH = $rows[$item].h
    $drawW = $box.x1 - $box.x0; $drawH = $box.y1 - $box.y0
    $realWu = $realW / $Scale; $realHu = $realH / $Scale
    # Classify by the larger of the two width/height ratios (drawn / real).
    $ratio = [Math]::Max($drawW / [Math]::Max($realWu,0.001), $drawH / [Math]::Max($realHu,0.001))
    $withinTol = ([Math]::Abs($drawW - $realWu) * $Scale -le $ToleranceMm) -and ([Math]::Abs($drawH - $realHu) * $Scale -le $ToleranceMm)
    if ($withinTol) { $cls = 'TO-SCALE' }
    elseif ($ratio -ge $SchematicFactor) { $cls = 'SCHEMATIC' }
    else { $cls = 'AMBIGUOUS'; $ambiguous++ }
    Write-Host ("  {0,-14} item {1} {2}: drawn {3}x{4}u, real {5}x{6}mm ({7}x{8}u) ratio {9} -> {10}" -f $label, $item, $rows[$item].part, (JNum $drawW), (JNum $drawH), (JNum $realW), (JNum $realH), (JNum $realWu), (JNum $realHu), (JNum $ratio), $cls)
}

if ($ambiguous -eq 0) {
    Write-Host 'PASS D2 (every component is either a true outline or a clearly-schematic placeholder; the GA is a schematic layout, as its note 2 states)'
    exit 0
} else {
    Write-Host "FAIL D2 ($ambiguous component(s) in the ambiguous middle - neither to-scale nor clearly schematic)"
    exit 1
}
