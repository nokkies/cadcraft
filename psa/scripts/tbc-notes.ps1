# tbc-notes.ps1 -- cadcraft card M3 / DRAWING-WORK D9
#
# Collects every "TBC" / "TO BE CONFIRMED" / "TBD" text found in the drawings into
# $D\fusion\QUESTIONS-drawings.md (PRIVATE, outside the repository) under `From the drawings`, one
# line each with the sheet number. The list is for Reinach and the engineering manager; PSA Fusion
# does not answer them. It never writes into the public psa/QUESTIONS.md.
#
# It reads the texts JSON (card M2-C1), so run that first. A note that spans several
# sentences (an MTEXT notes block) is reported once, with the whole block, because the
# question is the whole note -- splitting it would lose the context the answer needs.
#
# Writes $D\fusion\QUESTIONS-drawings.md (private) by replacing the `## From the drawings`
# section. It never touches the public psa/QUESTIONS.md.

[CmdletBinding()]
param(
    [string]$TextsDir,
    [string]$QuestionsFile
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

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # psa/scripts -> psa -> repo
$D = Get-PSADrawingsRoot
# The drawing notes carry client names, sheet numbers and signal tags, so they are PRIVATE and
# live outside the repository (PLAN.md: no client/site/project/signal data in the repo). Default
# to the private file under $D, never psa/QUESTIONS.md.
if ([string]::IsNullOrWhiteSpace($QuestionsFile)) { $QuestionsFile = Join-Path $D 'fusion\QUESTIONS-drawings.md' }

if ([string]::IsNullOrWhiteSpace($TextsDir)) { $TextsDir = Join-Path $D 'fusion\texts' }
if (-not (Test-Path -LiteralPath $TextsDir)) { throw "texts dir not found: $TextsDir (run card M2-C1)" }
if (-not (Test-Path -LiteralPath $QuestionsFile)) { throw "questions file not found: $QuestionsFile" }

# The pattern that marks an open question on a drawing.
$pattern = 'TBC|TO BE CONFIRMED|T\.B\.C|\bTBD\b'

$items = New-Object System.Collections.Generic.List[object]
Get-ChildItem -LiteralPath $TextsDir -Filter '*.json' -File | Sort-Object Name | ForEach-Object {
    # Skip the generated-sheet captures (fusion__out__*): D9 is about TBC notes on the working
    # drawings, and the generated faithful rebuilds carry the same texts, which would double them.
    if ($_.Name -like 'fusion__out__*') { return }
    $j = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
    $drawing = [string]$j.drawing
    $sheet = ($drawing -replace '\.dwg$', '')
    $all = @()
    if ($j.model -and $j.model.texts) { $all += @($j.model.texts) }
    if ($j.paper -and $j.paper.texts) { $all += @($j.paper.texts) }

    # Group identical texts so a repeated "RT PLC DI (TBC)" on one sheet is one line.
    $seen = @{}
    foreach ($t in $all) {
        $txt = ([string]$t.text) -replace '\s+', ' '
        $txt = $txt.Trim()
        if ($txt -notmatch $pattern) { continue }
        $key = $sheet + '|' + $txt
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $items.Add([pscustomobject]@{ sheet = $sheet; text = $txt; layer = [string]$t.layer })
    }
}

# Build the "From the drawings" section.
$nl = "`n"
$sec = New-Object System.Text.StringBuilder
[void]$sec.Append('## From the drawings').Append($nl).Append($nl)
[void]$sec.Append('Every "TBC" / "TO BE CONFIRMED" text on the working drawings, one line each').Append($nl)
[void]$sec.Append('with its sheet. These are open engineering questions for Reinach and the').Append($nl)
[void]$sec.Append('engineering manager; PSA Fusion does not answer them.').Append($nl)
[void]$sec.Append($nl)
foreach ($it in ($items | Sort-Object sheet, text)) {
    [void]$sec.Append('- [').Append($it.sheet).Append('] ').Append($it.text).Append($nl)
}
[void]$sec.Append($nl)
$sectionText = $sec.ToString()

# Replace the section between "## From the drawings" and the next "## " heading (or EOF).
$full = Get-Content -LiteralPath $QuestionsFile -Raw
$re = [regex]'(?ms)^## From the drawings.*?(?=^## |\z)'
if (-not $re.IsMatch($full)) { throw "no '## From the drawings' section in $QuestionsFile" }
$new = $re.Replace($full, $sectionText, 1)
[System.IO.File]::WriteAllText($QuestionsFile, $new, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "collected $($items.Count) open-question note(s) from the drawings"
Write-Host "wrote $QuestionsFile"

# Check: every TBC text found has a line in QUESTIONS.md.
$md = Get-Content -LiteralPath $QuestionsFile -Raw
$missing = 0
foreach ($it in $items) {
    # Match on the sheet + a distinctive fragment of the note.
    $frag = if ($it.text.Length -gt 40) { $it.text.Substring(0, 40) } else { $it.text }
    if ($md -notmatch [regex]::Escape($frag)) { $missing++ }
}
if ($missing -gt 0) { Write-Error "$missing note(s) not found in QUESTIONS.md"; exit 1 }
Write-Host 'PASS D9 (every TBC note has a line in QUESTIONS.md)'
exit 0
