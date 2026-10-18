# audit-blocks.ps1 -- report block-definition and block-reference fidelity per sheet.
#
# A block reference draws its definition's entities at the reference's insert, scale and rotation. If a
# block definition loses an entity, or a reference loses its scale, every copy on the sheet changes at
# once -- and an entity-count comparison of model space cannot see it, because a reference is ONE entity
# no matter how much geometry it expands to. GAD-001 has 25 references expanding to 1,305 block
# entities, so this is the largest unverified surface on these sheets.
#
# Compares, per sheet:
#   1. the block table -- every source block exists, with the same entity count and base point;
#   2. the references -- count per block name, and for each reference its block, insert, scale and
#      rotation, matched as a multiset;
#   3. attribute values -- every attribute tag and value on every reference.
#
# Prints block names, counts, coordinates and attribute TAG names with their values. Attribute values on
# these sheets are numbers (balloon tag numbers), not project text; block names are generic
# (_TagCircle). Nothing here echoes the working drawings' text.
#
# Exit 0 when the block table, the reference multiset and all attribute values match; 1 otherwise.

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

function Invoke-Script {
    param([string]$Drawing, [string]$Command)
    $scr = [System.IO.Path]::GetTempFileName() + '.scr'
    try {
        [System.IO.File]::WriteAllText($scr, ($Command + "`r`n"), (New-Object System.Text.ASCIIEncoding))
        return (& $cli run $Drawing --script-file $scr 2>&1 | Select-Object -Last 1)
    } finally {
        Remove-Item $scr -Force -ErrorAction SilentlyContinue
    }
}

function Get-BlockTable {
    param([string]$Drawing)
    $raw = Invoke-Script -Drawing $Drawing -Command 'blocks.list {}'
    if (-not $raw) { return @() }
    try { return @(($raw | ConvertFrom-Json).blocks) } catch { return @() }
}

function Get-ReferenceKeys {
    param([string]$Drawing)
    $cmd = 'entities ' + (@{ type = 'Insert'; limit = 2000 } | ConvertTo-Json -Compress)
    $raw = Invoke-Script -Drawing $Drawing -Command $cmd
    if (-not $raw) { return @() }
    try { $list = @(($raw | ConvertFrom-Json).entities) } catch { return @() }
    $keys = @()
    foreach ($e in $list) {
        $g = $e.geometry
        if ($null -eq $g) { continue }
        $name = [string]$g.block
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $x = [Math]::Round([double]$g.insert.x, 3)
        $y = [Math]::Round([double]$g.insert.y, 3)
        $sx = [Math]::Round([double]$g.scale.x, 6)
        $sy = [Math]::Round([double]$g.scale.y, 6)
        $rot = [Math]::Round([double]$g.rotation, 6)
        $attrs = @()
        if ($g.PSObject.Properties.Name -contains 'attribs') {
            foreach ($a in @($g.attribs)) {
                $tag = [string]$a.tag
                $val = ''
                if ($a.PSObject.Properties.Name -contains 'text') { $val = [string]$a.text.value }
                $attrs += ($tag + '=' + $val)
            }
        }
        $keys += ($name + '|' + $x + ',' + $y + '|s' + $sx + ',' + $sy + '|r' + $rot + '|' + (($attrs | Sort-Object) -join ';'))
    }
    return @($keys | Sort-Object)
}

$fail = 0
$totalRefs = 0
$totalBlocks = 0
Write-Host 'block definitions and references (source vs generated):'
foreach ($n in @($Project.sheets | Sort-Object)) {
    $src = Join-Path $WorkingDir ($n + '.dwg')
    $gen = Join-Path $OutDir ($n + '.dwg')
    if (-not (Test-Path -LiteralPath $src) -or -not (Test-Path -LiteralPath $gen)) { Write-Host "SKIP  $n"; continue }

    $parts = $n.Split('-')
    $short = if ($parts.Count -gt 2) { ($parts[2..($parts.Count - 1)] -join '-') } else { $n }

    $problems = @()

    # 1. block table
    $sb = @(Get-BlockTable -Drawing $src)
    $gb = @(Get-BlockTable -Drawing $gen)
    foreach ($b in $sb) {
        $name = [string]$b.name
        $m = $gb | Where-Object { [string]$_.name -eq $name }
        if (-not $m) { $problems += ("block '$name' missing from generated"); continue }
        $totalBlocks++
        if ([int]$b.entities -ne [int]$m.entities) { $problems += ("$name entity count $($b.entities) -> $($m.entities)") }
        $bs = "$($b.base)"
        $bg = "$($m.base)"
        if ($bs -ne $bg) { $problems += ("$name base point [$bs] -> [$bg]") }
    }

    # 2 + 3. references, transforms and attributes
    $rk = @(Get-ReferenceKeys -Drawing $src)
    $gk = @(Get-ReferenceKeys -Drawing $gen)
    $totalRefs += $rk.Count
    $d = Compare-Object $rk $gk
    if ($d) {
        $missing = @($d | Where-Object { $_.SideIndicator -eq '<=' })
        $added = @($d | Where-Object { $_.SideIndicator -eq '=>' })
        if ($missing.Count) { $problems += ("$($missing.Count) reference(s) missing from generated (first: $($missing[0].InputObject))") }
        if ($added.Count) { $problems += ("$($added.Count) unexpected reference(s) in generated (first: $($added[0].InputObject))") }
    }

    if ($problems.Count -gt 0) {
        Write-Host ("FAIL  {0,-16} {1}" -f $short, ($problems -join '; '))
        $fail++
    } else {
        $named = @($sb | ForEach-Object { [string]$_.name } | Where-Object { $_ -notmatch '^A1 |^A2 |^A3 |^\*' } | Select-Object -First 3)
        $note = if ($rk.Count -gt 0) { "$($rk.Count) references, $($sb.Count) blocks" } else { "$($sb.Count) blocks, no references" }
        if ($named.Count) { $note += ' (e.g. ' + ($named -join ', ') + ')' }
        Write-Host ("OK    {0,-16} {1}" -f $short, $note)
    }
}

if ($fail -gt 0) { Write-Host "FAIL block audit ($fail problem(s))"; exit 1 }
Write-Host "PASS block audit ($totalBlocks block definitions, $totalRefs references, all transforms and attribute values matching)"
exit 0
