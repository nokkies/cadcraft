# check-ink.ps1 -- card M4-C14: the generated plots are monochrome like the Reference.
#
# The Reference issued PDFs are monochrome: measured on an issued Reference termination sheet the
# ink is true black (0,0,0) and only 0.05% of sampled pixels carry any hue (anti-aliasing). cadcraft
# plotted the layer colours because the template's page setup names PSA.ctb, a colour-dependent
# table cadcraft does not carry. The generators now set each sheet's plot style to cadcraft's builtin
# monochrome.ctb, so the plot is black-on-white like the Reference.
#
# This check exports each generated sheet's layout, renders the first page, and measures the
# fraction of pixels whose channels differ (a coloured pixel: max(r,g,b) - min(r,g,b) > 40). It
# FAILs if that fraction is above the Reference's own band (0.05%) plus a margin. A sheet that
# plots nothing is caught here too (its content fraction is checked).
#
# Exit 0 when every generated plot is monochrome and non-empty, 1 otherwise.

[CmdletBinding()]
param(
    [string]$OutDir,
    [double]$MaxColouredPct = 0.5,   # Reference measures 0.04-0.06%; allow an order of magnitude of margin
    [double]$MinInkPct = 0.05,       # floor that catches a truly-empty frame (~0%); the Reference's own
                                     # sparse cover sheet measures 0.66% ink, so this is only an empty guard
    [string]$FontAlt = 'arial.ttf'   # SHX text substitution for the rendered PDFs (see export-pdf.ps1)
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($FontAlt)) {
    Remove-Item Env:\CADCRAFT_FONTALT -ErrorAction SilentlyContinue
} else {
    $env:CADCRAFT_FONTALT = $FontAlt
}

function Get-PSADrawingsRoot {
    foreach ($scope in 'Process', 'User', 'Machine') {
        $v = [Environment]::GetEnvironmentVariable('PSA_DRAWINGS', $scope)
        if (-not [string]::IsNullOrWhiteSpace($v) -and (Test-Path -LiteralPath $v)) { return $v.TrimEnd('\') }
    }
    throw 'PSA_DRAWINGS is not set to an existing folder.'
}
function Get-ArgumentForNative { param([string]$Value) return '"' + $Value.Replace('"', '""') + '"' }

$D = Get-PSADrawingsRoot
. (Join-Path $PSScriptRoot 'project.ps1')
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $D 'fusion\out' }
if (-not (Test-Path -LiteralPath $OutDir)) { throw "out dir not found: $OutDir" }

function Resolve-CadcraftCli {
    $cmd = Get-Command 'cadcraft-cli' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $exe = 'C:\Users\ReinachvanNieuwenhui\src\cadcraft\target\release\cadcraft-cli.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    throw 'cadcraft-cli not found.'
}
$cli = Resolve-CadcraftCli

# Scratch dir for the rendered PNGs (outside the repo, never committed).
$tmp = Join-Path $D 'fusion\ink-check'
if (-not (Test-Path -LiteralPath $tmp)) { New-Item -ItemType Directory -Path $tmp -Force | Out-Null }

function Get-FirstLayout {
    param([string]$Drawing)
    $scr = [System.IO.Path]::GetTempFileName() + '.scr'
    [System.IO.File]::WriteAllText($scr, "layout.list {}`n", (New-Object System.Text.ASCIIEncoding))
    $outFile = [System.IO.Path]::GetTempFileName()
    $bat = [System.IO.Path]::GetTempFileName() + '.cmd'
    $line = '"' + $cli + '" run "' + $Drawing + '" --script-file "' + $scr + '"'
    [System.IO.File]::WriteAllText($bat, "@echo off`r`n$line`r`n", (New-Object System.Text.ASCIIEncoding))
    $pi = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', (Get-ArgumentForNative $bat)) -NoNewWindow -PassThru -RedirectStandardOutput $outFile
    if (-not $pi.WaitForExit(120000)) { try { $pi.Kill() } catch { } }
    $txt = ''
    if (Test-Path -LiteralPath $outFile) { $txt = [System.IO.File]::ReadAllText($outFile); Remove-Item $outFile -Force }
    Remove-Item $scr, $bat -Force -ErrorAction SilentlyContinue
    $lay = @([regex]::Matches($txt, '"name":"([^"]*)"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -and $_ -ne 'Model' }) | Select-Object -First 1
    if ($lay) { return $lay }
    return 'Layout1'
}

function Export-LayoutPdf {
    param([string]$Drawing, [string]$Layout, [string]$OutBase)
    $scr = [System.IO.Path]::GetTempFileName() + '.scr'
    $cmd = 'exportpdf {"path":' + ($OutBase | ConvertTo-Json) + ',"layouts":[' + ($Layout | ConvertTo-Json) + ']}'
    [System.IO.File]::WriteAllText($scr, $cmd + "`n", (New-Object System.Text.ASCIIEncoding))
    $bat = [System.IO.Path]::GetTempFileName() + '.cmd'
    $line = '"' + $cli + '" run "' + $Drawing + '" --script-file "' + $scr + '"'
    [System.IO.File]::WriteAllText($bat, "@echo off`r`n$line`r`n", (New-Object System.Text.ASCIIEncoding))
    $null = [System.IO.Path]::GetTempFileName()
    $outFile = [System.IO.Path]::GetTempFileName()
    $pi = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', (Get-ArgumentForNative $bat)) -NoNewWindow -PassThru -RedirectStandardOutput $outFile
    if (-not $pi.WaitForExit(120000)) { try { $pi.Kill() } catch { } }
    if (Test-Path -LiteralPath $outFile) { Remove-Item $outFile -Force }
    Remove-Item $scr, $bat -Force -ErrorAction SilentlyContinue
    $pdf = $OutBase + '.pdf'
    if (Test-Path -LiteralPath $OutBase) { Copy-Item -LiteralPath $OutBase -Destination $pdf -Force; Remove-Item -LiteralPath $OutBase -Force }
    if (Test-Path -LiteralPath $pdf) { return $pdf }
    return $null
}

# Python one-liner that renders a PDF page and prints "coloured_pct ink_pct".
$pyScript = @'
import fitz, sys
d = fitz.open(sys.argv[1]); pix = d[0].get_pixmap(matrix=fitz.Matrix(2,2))
s = pix.samples; w = pix.width; h = pix.height; n = pix.n
step = 3
tot = 0; coloured = 0; ink = 0
for y in range(0, h, step):
    row = y*w*n
    for x in range(0, w, step):
        i = row + x*n
        r = s[i]; g = s[i+1]; b = s[i+2]
        tot += 1
        if max(r,g,b) - min(r,g,b) > 40: coloured += 1
        if (r+g+b)//3 < 200: ink += 1
if tot == 0:
    print("0 0"); sys.exit(0)
print("%.4f %.4f" % (100.0*coloured/tot, 100.0*ink/tot))
'@
$pyFile = Join-Path $tmp 'measure_ink.py'
[System.IO.File]::WriteAllText($pyFile, $pyScript, (New-Object System.Text.ASCIIEncoding))

$sheets = Get-ChildItem -LiteralPath $OutDir -Filter '*.dwg' | Sort-Object Name
if ($sheets.Count -eq 0) { throw "no sheets in $OutDir" }

$failCount = 0
foreach ($dwg in $sheets) {
    $lay = Get-FirstLayout $dwg.FullName
    $pdf = Export-LayoutPdf -Drawing $dwg.FullName -Layout $lay -OutBase (Join-Path $tmp $dwg.BaseName)
    if (-not $pdf) { Write-Host ("FAIL  {0}  (no PDF produced)" -f $dwg.Name); $failCount++; continue }
    $out = (& python $pyFile $pdf 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $out) { Write-Host ("FAIL  {0}  (python measure failed: {1})" -f $dwg.Name, $out); $failCount++; continue }
    $parts = $out -split '\s+'
    $colPct = [double]$parts[0]
    $inkPct = [double]$parts[1]
    $why = @()
    if ($colPct -gt $MaxColouredPct) { $why += ("{0}% coloured (Reference band {1}%)" -f $colPct, $MaxColouredPct) }
    if ($inkPct -lt $MinInkPct) { $why += ("only {0}% ink (near-empty plot)" -f $inkPct) }
    if ($why.Count -eq 0) {
        Write-Host ("PASS  {0}  ({1}% coloured, {2}% ink -- monochrome, non-empty)" -f $dwg.Name, $colPct, $inkPct)
    } else {
        Write-Host ("FAIL  {0}  ({1})" -f $dwg.Name, ($why -join '; '))
        $failCount++
    }
}

if ($failCount -eq 0) {
    Write-Host ("PASS M4-C14 (all {0} generated plots are monochrome like the Reference and non-empty)" -f $sheets.Count)
    exit 0
} else {
    Write-Host ("FAIL M4-C14 ({0} sheet(s) not monochrome or empty)" -f $failCount)
    exit 1
}
