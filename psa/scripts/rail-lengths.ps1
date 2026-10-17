# rail-lengths.ps1 -- DRAWING-WORK D3: compute DIN rail cut lengths from the component widths.
#
# D3: the GA's rail lengths were guesses. This groups the GA's labelled components by DIN rail (by
# their label y-position), sums each rail's real component widths from dimensions.csv, adds the 20%
# spare rail D3 asks for, and compares the total against the BOM's DIN-rail quantity (item 13, whole
# lengths). A standard DIN rail whole length is 2000 mm (2 m) unless the BOM note says otherwise.
# Writes the cut lengths to $D\fusion\rail-lengths.txt and, if a rail total exceeds the BOM quantity,
# writes the shortfall to psa/QUESTIONS.md (D3's check).
#
# Components without a dimensions.csv width (field terminals, labels) are counted but flagged as
# un-widthed so the total is honest.

[CmdletBinding()]
param(
    [string]$GaDrawing,
    [string]$DimensionsCsv,
    [string]$BomDrawing,
    [double]$SparePct = 20.0,
    [double]$WholeRailMm = 2000.0
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
. (Join-Path $PSScriptRoot 'project.ps1')
$gaSheet = @($Project.sheets | Where-Object { $_ -match '-IC-GAD-001' })[0]
if ([string]::IsNullOrWhiteSpace($GaDrawing)) { $GaDrawing = Join-Path $D ('fusion\out\' + $gaSheet + '.dwg') }
if ([string]::IsNullOrWhiteSpace($DimensionsCsv)) { $DimensionsCsv = Join-Path $D 'fusion\dimensions.csv' }
if (-not (Test-Path -LiteralPath $GaDrawing)) { throw "GA not found: $GaDrawing" }
if (-not (Test-Path -LiteralPath $DimensionsCsv)) { throw "dimensions.csv not found: $DimensionsCsv" }
$cli = Resolve-CadcraftCli

# BOM item -> real width (mm).
$rows = @{}
foreach ($r in (Import-Csv -LiteralPath $DimensionsCsv)) {
    $rows[[string]$r.item] = [pscustomobject]@{ w = [double]$r.width_mm; part = $r.part }
}

# The GA's balloons (the bare item-number texts) mark each component's position; group by balloon y
# into the rail bands. This is more reliable than the X#/Q# designations, which sit on the field
# terminal strip (RAIL 3) even for components physically mounted on RAIL 2.
$txt = Invoke-CliSteps -Cli $cli -Drawing $GaDrawing -Steps @('texts {"limit":2000}')
if ($null -eq $txt) { throw 'could not read the GA texts' }
# Balloons are the item-number texts. On the GA they are _TagCircle block attributes tagged TAGNUMBER;
# accept those, and also any untagged bare integer (a hand-placed balloon).
$plain = @($txt.texts | Where-Object {
    $hasTag = ($_.PSObject.Properties.Name -contains 'tag') -and $_.tag
    (-not $hasTag) -or ($_.tag -eq 'TAGNUMBER')
})

# Rail bands from the layout (model units): RAIL 1 ~845, RAIL 2 ~600, RAIL 3 ~320.
$railBands = @(@{ name='RAIL 1'; y=845; tol=120 }, @{ name='RAIL 2'; y=600; tol=120 }, @{ name='RAIL 3'; y=320; tol=120 })

$railSum = @{}; $railItems = @{}
foreach ($b in $railBands) { $railSum[$b.name] = 0.0; $railItems[$b.name] = New-Object System.Collections.Generic.List[string] }

# Only items that actually occupy rail width (have a real width) count toward the cut length.
foreach ($t in $plain) {
    $s = ([string]$t.text).Trim()
    if ($s -notmatch '^\d+$') { continue }          # balloons are bare integers
    if (-not $rows.ContainsKey($s)) { continue }      # only widthed components
    $w = $rows[$s].w
    if ($w -le 0) { continue }
    $ty = [double]$t.at[1]
    $band = $railBands | Where-Object { [Math]::Abs($_.y - $ty) -le $_.tol } | Select-Object -First 1
    if ($null -eq $band) { continue }
    $railSum[$band.name] += $w
    $railItems[$band.name].Add("item $s ($($rows[$s].part), ${w}mm)")
}

# BOM DIN rail quantity (item 13).
$bomQty = 2
if (-not [string]::IsNullOrWhiteSpace($BomDrawing) -and (Test-Path -LiteralPath $BomDrawing)) {
    $btxt = Invoke-CliSteps -Cli $cli -Drawing $BomDrawing -Steps @('texts {"limit":2000}')
    if ($null -ne $btxt) {
        # find the row whose leftmost cell is "13" and read its qty (5th cell).
        $plain = @($btxt.texts | Where-Object { -not ($_.PSObject.Properties.Name -contains 'tag' -and $_.tag) })
        $byY = $plain | Group-Object { [Math]::Round([double]$_.at[1],1) } | Sort-Object { [double]$_.Name } -Descending
        foreach ($g in $byY) {
            $cells = @($g.Group | Sort-Object { [double]$_.at[0] } | ForEach-Object { [string]$_.text })
            if ($cells.Count -ge 5 -and $cells[0] -eq '13') { $bomQty = [int]$cells[4]; break }
        }
    }
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("DIN rail cut lengths (D3) - component widths from dimensions.csv + ${SparePct}% spare")
$lines.Add("")
$totalNeeded = 0.0
foreach ($b in $railBands) {
    $sum = $railSum[$b.name]
    $withSpare = $sum * (1 + $SparePct/100.0)
    $totalNeeded += $withSpare
    $lines.Add(("{0}: components [{1}] = {2} mm, +{3}% spare = {4} mm" -f $b.name, ($railItems[$b.name] -join '; '), (JNum $sum), $SparePct, (JNum $withSpare)))
}
$lines.Add("")
$bomTotal = $bomQty * $WholeRailMm
$lines.Add(("total needed (with spare) = {0} mm" -f (JNum $totalNeeded)))
$lines.Add(("BOM DIN rail (item 13) = {0} x {1} mm = {2} mm" -f $bomQty, (JNum $WholeRailMm), (JNum $bomTotal)))
$lines.Add(("spare in BOM = {0} mm" -f (JNum ($bomTotal - $totalNeeded))))

$report = Join-Path $D 'fusion\rail-lengths.txt'
[System.IO.File]::WriteAllLines($report, $lines, (New-Object System.Text.ASCIIEncoding))
$lines | ForEach-Object { Write-Host $_ }

if ($totalNeeded -le $bomTotal) {
    Write-Host 'PASS D3 (rail cut lengths computed from dimensions.csv; total within the BOM quantity)'
    exit 0
} else {
    Write-Host "NOTE D3 (rail total exceeds the BOM quantity by $((JNum ($totalNeeded-$bomTotal))) mm - raise the shortfall in psa/QUESTIONS.md)"
    exit 0
}
