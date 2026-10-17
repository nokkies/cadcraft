# wire-consistency.ps1 -- cadcraft card M3 / DRAWING-WORK D5
#
# The schematic sheets (SCD) are the wire-number master. Every wire number that appears on a
# termination sheet (TMD) must also appear on a schematic sheet. This is the check DRAWING-WORK
# D5 asks for: a wire number typed only on a termination sheet is a number that goes nowhere on
# the schematic -- a real drafting error.
#
# Wire-number pattern, from the format notes ("net name plus sequence, such as 24V/1, 0V/2") and
# the I/O convention the drawings use (DInn / DInn+ for digital, AInn / AInn- for analogue):
#   NET/SEQ   e.g. 24V/1, 0V/3, A/1, N/2
#   DInn / DInn+   e.g. DI1, DI1+
#   AInn / AInn-   e.g. AI1, AI1-
#
# Reads the texts JSON (card M2-C1). Writes $D\fusion\wire-consistency.txt and prints the
# result. Exit 0 when every termination-sheet wire number exists on a schematic sheet, 1
# otherwise (each orphan is an M3 finding).
#
# Schematic vs termination is decided by the drawing-number discipline code: SCD = schematic,
# TMD = termination. GAD/BOM sheets are neither and are ignored.
#
# The check is PROJECT-SCOPED: a termination sheet's wire numbers are matched against the
# schematic sheets of the SAME project (the AAAA segment of the drawing number). The Reference
# set is the reference project ($Project.referenceProject), whose schematic masters are not in
# this folder, so its TMD sheets are
# reported as "no schematic master in this set" rather than as orphans -- an orphan is only a
# real error when the project's own schematics are present to carry the number.

[CmdletBinding()]
param(
    [string]$TextsDir,
    [string]$ReportFile,
    # The project under construction (the generator's output). D5 is about wire numbers typed
    # by hand into the generator, so only this project's sheets are checked; other projects in
    # the Reference set use a different discipline/wire-numbering convention and are reported
    # as out-of-scope, not as failures. Defaults to $Project.project (the private settings).
    [string]$TargetProject
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
if ([string]::IsNullOrWhiteSpace($TargetProject)) { $TargetProject = $Project.project }
if ([string]::IsNullOrWhiteSpace($TextsDir)) { $TextsDir = Join-Path $D 'fusion\texts' }
if ([string]::IsNullOrWhiteSpace($ReportFile)) { $ReportFile = Join-Path $D 'fusion\wire-consistency.txt' }
if (-not (Test-Path -LiteralPath $TextsDir)) { throw "texts dir not found: $TextsDir (run card M2-C1)" }

# A wire number is a whole text token matching one of the patterns (trimmed, upper-cased for
# comparison so "di1" and "DI1" match).
$wireRe = [regex]'^(?:[A-Z0-9]+/\d+|DI\d+\+?|AI\d+[-+]?)$'

function Get-WireNumbers {
    param($doc)
    $set = @{}
    $all = @()
    if ($doc.model -and $doc.model.texts) { $all += @($doc.model.texts) }
    if ($doc.paper -and $doc.paper.texts) { $all += @($doc.paper.texts) }
    foreach ($t in $all) {
        $txt = ([string]$t.text).Trim().ToUpperInvariant()
        if ($wireRe.IsMatch($txt)) { $set[$txt] = $true }
    }
    return $set
}

$schematic = @{}   # project -> set of wire numbers across that project's SCD sheets
$projectHasSchematic = @{}
$termSheets = @()

Get-ChildItem -LiteralPath $TextsDir -Filter '*.json' -File | Sort-Object Name | ForEach-Object {
    $doc = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
    $drawing = [string]$doc.drawing
    $stem = $drawing -replace '\.dwg$', ''
    # Drawing number AAAA-BB-CCC-DDD_rev. Project is segment 0, discipline is segment 2.
    $parts = $stem -split '-'
    if ($parts.Count -lt 3) { return }
    $project = $parts[0]
    $disc = $parts[2]   # e.g. SCD, TMD, GAD
    $wires = Get-WireNumbers -doc $doc
    if ($disc -eq 'SCD') {
        if (-not $schematic.ContainsKey($project)) { $schematic[$project] = @{} }
        $projectHasSchematic[$project] = $true
        foreach ($k in $wires.Keys) { $schematic[$project][$k] = $true }
    } elseif ($disc -eq 'TMD') {
        $termSheets += [pscustomobject]@{ stem = $stem; project = $project; wires = $wires }
    }
}

$nl = "`n"
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('# Wire consistency -- card M3 D5').Append($nl)
[void]$sb.Append('# every wire number on a termination sheet must exist on a schematic sheet').Append($nl)
[void]$sb.Append('# of the SAME project. A project with no schematic in this set is reported').Append($nl)
[void]$sb.Append('# as "no master", not as orphans.').Append($nl).Append($nl)
[void]$sb.Append("projects with a schematic master: $(($projectHasSchematic.Keys | Sort-Object) -join ', ')").Append($nl)
[void]$sb.Append("termination sheets checked : $($termSheets.Count)").Append($nl).Append($nl)

$orphanTotal = 0
$outOfScopeTotal = 0
foreach ($ts in $termSheets) {
    if ($ts.project -ne $TargetProject) {
        $outOfScopeTotal++
        [void]$sb.Append("$($ts.stem)  out of scope (project $($ts.project); D5 checks the generator's project $TargetProject)").Append($nl)
        continue
    }
    if (-not $projectHasSchematic.ContainsKey($ts.project)) {
        [void]$sb.Append("$($ts.stem)  no schematic master for project $($ts.project) in this set (skipped)").Append($nl)
        continue
    }
    $master = $schematic[$ts.project]
    $orphans = @($ts.wires.Keys | Where-Object { -not $master.ContainsKey($_) } | Sort-Object)
    if ($orphans.Count -eq 0) {
        [void]$sb.Append("$($ts.stem)  ok ($($ts.wires.Count) wire number(s), all on a $($ts.project) schematic)").Append($nl)
    } else {
        $orphanTotal += $orphans.Count
        [void]$sb.Append("$($ts.stem)  ORPHANS ($($orphans.Count)): " + ($orphans -join ', ')).Append($nl)
    }
}
[void]$sb.Append($nl)
[void]$sb.Append("orphan wire numbers (project $TargetProject): $orphanTotal").Append($nl)
[void]$sb.Append("out-of-scope termination sheets        : $outOfScopeTotal").Append($nl)

[System.IO.File]::WriteAllText($ReportFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

Write-Host "project under construction: $TargetProject"
Write-Host "termination sheets: $($termSheets.Count)"
foreach ($ts in $termSheets) {
    if ($ts.project -ne $TargetProject) { Write-Host "skip   $($ts.stem) (out of scope, project $($ts.project))"; continue }
    $master = $schematic[$ts.project]
    $orphans = @($ts.wires.Keys | Where-Object { -not $master.ContainsKey($_) })
    if ($orphans.Count -gt 0) { Write-Host "ORPHANS $($ts.stem): $($orphans -join ', ')" }
    else { Write-Host "ok     $($ts.stem)" }
}
Write-Host ''
Write-Host "wrote $ReportFile"
Write-Host "orphan wire numbers (project $TargetProject): $orphanTotal   out-of-scope sheets: $outOfScopeTotal"
if ($orphanTotal -gt 0) { Write-Host "D5: $TargetProject termination sheets carry wire numbers not on a $TargetProject schematic -- M3 finding"; exit 1 }
Write-Host "PASS D5 (every $TargetProject termination-sheet wire number exists on a $TargetProject schematic)"
exit 0
