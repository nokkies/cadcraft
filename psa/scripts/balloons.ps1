# balloons.ps1 -- cadcraft card M3 / DRAWING-WORK D6
#
# Every balloon number on the general arrangement (the _TagCircle inserts' TAGNUMBER attribute)
# must be an item number on the bill of materials, and every BOM item must appear at least once
# on the GA or be on the list of items that have no position (allowances, labels, cables).
#
# How the two sides are read:
#   * GA balloons: the TAGNUMBER attributes (the _TagCircle block's attribute, per the format
#     notes). A balloon number is a small positive integer.
#   * BOM items: the ITEM column of the BOM sheet. The BOM is a table; its item numbers are the
#     small positive integers on the TITLEBLOCK layer, but so are part-number fragments, so an
#     item number is bounded: 1..MAX_ITEM (default 999). Larger integers are part numbers and are
#     ignored. The BOM sheet is the drawing whose discipline code is BOM, or whose title-block
#     DWG_AREA reads BILL OF MATERIALS.
#   * No-position items: an allowance is a BOM item that legitimately has no balloon (cables,
#     labels, "TBC" spares). Those are listed in $NoPositionItems and are not required on the GA.
#
# Reads the texts JSON (card M2-C1). Writes $D\fusion\balloons.txt. Exit 0 when every balloon is
# a BOM item and every positioned BOM item is ballooned; 1 otherwise (each mismatch is an M3
# finding).

[CmdletBinding()]
param(
    [string]$TextsDir,
    [string]$ReportFile,
    # BOM item numbers are bounded; anything larger is a part number, not an item.
    [int]$MaxItem = 999,
    # BOM items that legitimately carry no balloon on the GA (allowances, cables, labels).
    # Populated from the BOM notes; extend as the engineering manager confirms them.
    # 13, 14, 17 are the cable/label/spare allowances named in the BOM notes.
    # 7 (the enclosure body) is the envelope the GA draws, not a mounted item, so it carries no
    # balloon -- this is an assumption; see psa/QUESTIONS.md, "From the drawings", D6.
    [int[]]$NoPositionItems = @(7, 13, 14, 17)
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-PSADrawingsRoot {
    foreach ($scope in 'Process', 'User', 'Machine') {
        $v = [Environment]::GetEnvironmentVariable('PSA_DRAWINGS', $scope)
        if (-not [string]::IsNullOrWhiteSpace($v) -and (Test-Path -LiteralPath $v)) { return $v.TrimEnd('\') }
    }
    throw 'PSA_DRAWINGS is not set to an existing folder. Ask Reinach for it (see psa/PLAN.md).'
}

$D = Get-PSADrawingsRoot
. (Join-Path $PSScriptRoot 'project.ps1')
if ([string]::IsNullOrWhiteSpace($TextsDir)) { $TextsDir = Join-Path $D 'fusion\texts' }
if ([string]::IsNullOrWhiteSpace($ReportFile)) { $ReportFile = Join-Path $D 'fusion\balloons.txt' }
if (-not (Test-Path -LiteralPath $TextsDir)) { throw "texts dir not found: $TextsDir (run card M2-C1)" }

# Find the GA and BOM sheets of the project under construction ($Project.project). The GA carries
# the balloons; the BOM carries the item list.
$gaDocs = @()
$bomDocs = @()
Get-ChildItem -LiteralPath $TextsDir -Filter '*.json' -File | Sort-Object Name | ForEach-Object {
    $doc = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
    $stem = ([string]$doc.drawing) -replace '\.dwg$', ''
    $parts = $stem -split '-'
    if ($parts.Count -lt 3) { return }
    if ($parts[0] -ne $Project.project) { return }   # project under construction
    $disc = $parts[2]
    if ($disc -eq 'GAD') {
        # GAD-001 is the general arrangement (balloons); GAD-002 is the BOM.
        # Decide by content: a sheet with TAGNUMBER attributes is the GA.
        $all = @()
        if ($doc.model -and $doc.model.texts) { $all += @($doc.model.texts) }
        if ($doc.paper -and $doc.paper.texts) { $all += @($doc.paper.texts) }
        if (@($all | Where-Object { $_.PSObject.Properties.Name -contains 'tag' -and $_.tag -eq 'TAGNUMBER' }).Count -gt 0) { $gaDocs += $doc }
        else { $bomDocs += $doc }
    }
}

if ($gaDocs.Count -eq 0) { throw 'no GA sheet with TAGNUMBER balloons found' }
if ($bomDocs.Count -eq 0) { throw 'no BOM sheet found' }

# Balloons: union of TAGNUMBER values across the GA sheets.
$balloons = @{}
foreach ($g in $gaDocs) {
    $all = @()
    if ($g.model -and $g.model.texts) { $all += @($g.model.texts) }
    if ($g.paper -and $g.paper.texts) { $all += @($g.paper.texts) }
    foreach ($t in $all) {
        if ($t.PSObject.Properties.Name -contains 'tag' -and $t.tag -eq 'TAGNUMBER') {
            $v = ([string]$t.text).Trim()
            if ($v -match '^\d+$') { $balloons[[int]$v] = $true }
        }
    }
}

# BOM items: small positive integers on the TITLEBLOCK layer (the ITEM column).
$bomItems = @{}
foreach ($b in $bomDocs) {
    $all = @()
    if ($b.model -and $b.model.texts) { $all += @($b.model.texts) }
    if ($b.paper -and $b.paper.texts) { $all += @($b.paper.texts) }
    foreach ($t in $all) {
        $v = ([string]$t.text).Trim()
        if ($v -match '^\d+$') {
            $n = [int]$v
            if ($n -ge 1 -and $n -le $MaxItem) { $bomItems[$n] = $true }
        }
    }
}

$noPos = @{}
foreach ($n in $NoPositionItems) { $noPos[$n] = $true }

$nl = "`n"
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('# Balloons vs BOM -- card M3 D6').Append($nl).Append($nl)
[void]$sb.Append("GA sheets    : $(($gaDocs | ForEach-Object { $_.drawing }) -join ', ')").Append($nl)
[void]$sb.Append("BOM sheets   : $(($bomDocs | ForEach-Object { $_.drawing }) -join ', ')").Append($nl)
[void]$sb.Append("balloon numbers on the GA : $(($balloons.Keys | Sort-Object) -join ', ')").Append($nl)
[void]$sb.Append("BOM item numbers          : $(($bomItems.Keys | Sort-Object) -join ', ')").Append($nl)
[void]$sb.Append("no-position items (allowances/cables/labels): $(($noPos.Keys | Sort-Object) -join ', ')").Append($nl).Append($nl)

# Direction 1: every balloon must be a BOM item.
$orphanBalloons = @($balloons.Keys | Where-Object { -not $bomItems.ContainsKey($_) } | Sort-Object)
# Direction 2: every BOM item must be ballooned or on the no-position list.
$missingBalloons = @($bomItems.Keys | Where-Object { -not $balloons.ContainsKey($_) -and -not $noPos.ContainsKey($_) } | Sort-Object)

[void]$sb.Append("balloons not on the BOM (orphan balloons): $(if($orphanBalloons.Count){$orphanBalloons -join ', '}else{'none'})").Append($nl)
[void]$sb.Append("BOM items with no balloon and not on the no-position list: $(if($missingBalloons.Count){$missingBalloons -join ', '}else{'none'})").Append($nl)

[System.IO.File]::WriteAllText($ReportFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

Write-Host "balloon numbers on GA : $(($balloons.Keys | Sort-Object) -join ', ')"
Write-Host "BOM item numbers      : $(($bomItems.Keys | Sort-Object) -join ', ')"
Write-Host "no-position items     : $(($noPos.Keys | Sort-Object) -join ', ')"
Write-Host ''
if ($orphanBalloons.Count -gt 0) { Write-Host "ORPHAN BALLOONS (not on BOM): $($orphanBalloons -join ', ')" }
if ($missingBalloons.Count -gt 0) { Write-Host "BOM ITEMS NOT BALLOONED (and not no-position): $($missingBalloons -join ', ')" }
Write-Host "wrote $ReportFile"
$total = $orphanBalloons.Count + $missingBalloons.Count
if ($total -gt 0) { Write-Host "D6: $total balloon/BOM mismatch(es) -- M3 finding"; exit 1 }
Write-Host 'PASS D6 (every balloon is a BOM item; every positioned BOM item is ballooned)'
exit 0
