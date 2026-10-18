# audit-textstyles.ps1 -- report text-style fidelity between each source sheet and its generated copy.
#
# A text style carries the font, the default height and the WIDTH FACTOR. If any of the three is lost,
# every string in that style changes shape or spacing on the sheet -- and no entity-level check sees it,
# because the entities themselves are unchanged. The width factor matters most: the source's Romans style
# uses 0.9, so losing it makes all that text about ten percent too wide.
#
# Prints style names, font file names and numbers only, never drawing text.
#
# Exit 0 when every style the source defines exists in the generated sheet with the same font, bigFont,
# height and widthFactor; 1 otherwise.

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

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$cli = Join-Path $repo 'target\release\cadcraft-cli.exe'
if (-not (Test-Path -LiteralPath $cli)) { throw "cadcraft-cli not found at $cli" }

function Get-TextStyles {
    param([string]$Drawing)
    $scr = [System.IO.Path]::GetTempFileName() + '.scr'
    try {
        [System.IO.File]::WriteAllText($scr, "style.list {}`r`n", (New-Object System.Text.ASCIIEncoding))
        $raw = (& $cli run $Drawing --script-file $scr 2>&1 | Select-Object -Last 1)
    } finally {
        Remove-Item $scr -Force -ErrorAction SilentlyContinue
    }
    if (-not $raw) { return @() }
    try { return @(($raw | ConvertFrom-Json).styles) } catch { return @() }
}

# The three fields that change how text looks. 'trueType' is deliberately excluded: it is derived from
# the font name, so comparing font already covers it.
$fields = @('font', 'bigFont', 'height', 'widthFactor')

$fail = 0
$totalChecked = 0
Write-Host 'text styles (source vs generated):'
foreach ($n in @($Project.sheets | Sort-Object)) {
    $src = Join-Path $WorkingDir ($n + '.dwg')
    $gen = Join-Path $OutDir ($n + '.dwg')
    if (-not (Test-Path -LiteralPath $src) -or -not (Test-Path -LiteralPath $gen)) { Write-Host "SKIP  $n"; continue }

    $s = @(Get-TextStyles -Drawing $src)
    $g = @(Get-TextStyles -Drawing $gen)
    if ($s.Count -eq 0) { Write-Host "FAIL  $n  source style table unreadable"; $fail++; continue }

    $parts = $n.Split('-')
    $short = if ($parts.Count -gt 2) { ($parts[2..($parts.Count - 1)] -join '-') } else { $n }

    $problems = @()
    foreach ($st in $s) {
        $name = [string]$st.name
        $m = $g | Where-Object { [string]$_.name -eq $name }
        if (-not $m) { $problems += ("style '$name' missing from generated"); continue }
        $totalChecked++
        foreach ($f in $fields) {
            $a = "$([string]$st.$f)"
            $b = "$([string]$m.$f)"
            if ($a -ne $b) { $problems += ("$name.$f [$a] -> [$b]") }
        }
    }

    if ($problems.Count -gt 0) {
        Write-Host ("FAIL  {0,-16} {1}" -f $short, ($problems -join '; '))
        $fail++
    } else {
        # Report the width factors, since that is the field most likely to be silently lost.
        $factors = @($s | Where-Object { [double]$_.widthFactor -ne 1.0 } | ForEach-Object { "$($_.name)=$($_.widthFactor)" })
        $note = if ($factors.Count -gt 0) { ', width factors != 1: ' + ($factors -join ', ') } else { '' }
        Write-Host ("OK    {0,-16} all {1} styles match on {2}{3}" -f $short, $s.Count, ($fields -join '/'), $note)
    }
}

if ($fail -gt 0) { Write-Host "FAIL text-style audit ($fail problem(s))"; exit 1 }
Write-Host "PASS text-style audit ($totalChecked style records match on font, bigFont, height and widthFactor)"
exit 0
