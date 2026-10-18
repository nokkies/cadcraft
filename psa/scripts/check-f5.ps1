# check-f5.ps1 -- card M4-F5, part 1: the twelve generated plots are distinct real plots.
#
# The empty-plot failure (psa/REVIEW-0.053.md section 2): five builds reported PASS on sheets that
# plotted empty, and the review found four generated PDFs of EXACTLY 39144 bytes each -- the same
# empty frame. A set of identical (or empty) PDFs is the signature of that bug.
#
# This check exports every generated sheet's paper-space layout with exportpdf, then:
#   1. computes the SHA-256 of each PDF;
#   2. requires all twelve hashes to be distinct from each other;
#   3. requires each to differ from the template's own plot (the empty frame) and to be larger than
#      it (so no sheet is the empty frame).
# A duplicate hash, or a sheet whose plot equals the empty template plot, FAILs.
#
# This is the machine half of "the plot is the check". The human half -- viewing each plot and
# answering the three M1-C4 questions -- is recorded in $D\fusion\render-review-generated.md.
# Exit 0 when all twelve plots are distinct and non-empty, 1 otherwise.

[CmdletBinding()]
param(
    [string]$OutDir,
    [int]$MinContentBytes = 5000,
    [string]$FontAlt = 'arial.ttf'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# SHX text substitution for the plotted PDFs (see export-pdf.ps1's header note). The PSA text
# styles name isocp.shx, which cadcraft cannot parse, so without this every text falls back to the
# built-in stroke font. cadcraft's FONTALT (CADCRAFT_FONTALT) renders an unfindable font (an SHX
# file) in the named face instead; setting it here makes the review PDFs render SHX text in a real
# TrueType face. It changes only the render, never the DWG data. Pass -FontAlt '' for the stroke font.
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

$plotDir = Join-Path $D 'fusion\pdf'
if (-not (Test-Path -LiteralPath $plotDir)) { New-Item -ItemType Directory -Path $plotDir -Force | Out-Null }

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
    $pi = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', (Get-ArgumentForNative $bat)) -NoNewWindow -PassThru -RedirectStandardOutput ([System.IO.Path]::GetTempFileName())
    if (-not $pi.WaitForExit(120000)) { try { $pi.Kill() } catch { } }
    Remove-Item $scr, $bat -Force -ErrorAction SilentlyContinue
    # exportpdf writes the file at OutBase with no extension; give it .pdf so it is usable.
    $pdf = $OutBase + '.pdf'
    if (Test-Path -LiteralPath $OutBase) { Copy-Item -LiteralPath $OutBase -Destination $pdf -Force; Remove-Item -LiteralPath $OutBase -Force }
    if (Test-Path -LiteralPath $pdf) { return $pdf }
    return $null
}

# The template's own plot = the empty frame reference.
$tpl = Join-Path $D ($Project.template -replace '/', '\')
$tplLayout = Get-FirstLayout $tpl
$tplPdf = Export-LayoutPdf -Drawing $tpl -Layout $tplLayout -OutBase (Join-Path $plotDir 'template')
if (-not $tplPdf) { throw 'could not plot the template' }
$tplHash = (Get-FileHash -LiteralPath $tplPdf -Algorithm SHA256).Hash
$tplBytes = (Get-Item -LiteralPath $tplPdf).Length
Write-Host "template plot (empty frame): $tplBytes bytes, sha256 $($tplHash.Substring(0,12))..."

$sheets = Get-ChildItem -LiteralPath $OutDir -Filter '*.dwg' | Sort-Object Name
if ($sheets.Count -eq 0) { throw "no sheets in $OutDir" }

$hashes = @{}
$failCount = 0
foreach ($dwg in $sheets) {
    $lay = Get-FirstLayout $dwg.FullName
    $pdf = Export-LayoutPdf -Drawing $dwg.FullName -Layout $lay -OutBase (Join-Path $plotDir $dwg.BaseName)
    if (-not $pdf) { Write-Host ("FAIL  {0}  (no PDF produced)" -f $dwg.Name); $failCount++; continue }
    $bytes = (Get-Item -LiteralPath $pdf).Length
    $h = (Get-FileHash -LiteralPath $pdf -Algorithm SHA256).Hash
    $why = @()
    if ($h -eq $tplHash) { $why += 'plot equals the empty template frame' }
    if ($bytes -lt ($tplBytes + $MinContentBytes)) { $why += "plot $bytes bytes is at/below empty frame $tplBytes" }
    if ($hashes.ContainsKey($h)) { $why += "identical plot to $($hashes[$h])" }
    else { $hashes[$h] = $dwg.Name }
    if ($why.Count -eq 0) {
        Write-Host ("PASS  {0}  plot {1} bytes, sha256 {2}... (distinct, non-empty)" -f $dwg.Name, $bytes, $h.Substring(0,12))
    } else {
        Write-Host ("FAIL  {0}  ({1})" -f $dwg.Name, ($why -join '; '))
        $failCount++
    }
}

if ($failCount -eq 0) {
    Write-Host ("PASS M4-F5 plots (all {0} generated plots distinct from each other and from the empty template frame)" -f $sheets.Count)
    exit 0
} else {
    Write-Host ("FAIL M4-F5 ({0} sheet(s) with duplicate or empty plots)" -f $failCount)
    exit 1
}
