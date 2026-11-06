# scrub-project-facts.ps1 -- replace project-specific text in the public pipeline files.
#
# The cadcraft fork's rule (psa/PLAN.md, "Two folders, two rules"): nothing from a client, a project
# or a PSA controlled document goes into the repository -- no project numbers, no client names, no
# site names, no signal tags, no drawing file names. Comments and usage examples break that rule as
# surely as string literals do, because they are what gets read.
#
# This script rewrites the known project-specific tokens in the listed files to the placeholders the
# plan already uses (NNNN = project, RRRR = reference project, P01 = a panel, <order number> = a
# Siemens MLFB). Run it after editing a pipeline file, before committing.
#
# Usage: pwsh -File psa/scripts/scrub-project-facts.ps1 [-Check]
#   -Check: report what still looks project-specific and change nothing.

# The substitution table is NOT in this file. It is a private mapping from a project's real names to
# the placeholders, and putting it here would defeat the purpose: the whole point of the rule is that
# a project's words never enter the repository. It is read from a JSON file outside the repo.
#
#   { "from": [ {"from": "<project word>", "to": "<placeholder>"}, ... ] }
#
# Longest-first ordering is the caller's responsibility in that file; this script applies entries in
# the order given.
[CmdletBinding()]
param(
    [switch]$Check,
    [string]$Substitutions
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$files = @(
    'scripts/xlsx-dump.ps1', 'scripts/io-normalise.ps1', 'scripts/sheets-plan.ps1',
    'scripts/gen-tmd-data.ps1', 'scripts/gen-pack.ps1', 'scripts/check-pack.ps1'
) | ForEach-Object { Join-Path $root $_ }

if (-not $Substitutions) {
    # Default: a private file beside the project data, never inside the repository.
    $Substitutions = Join-Path $env:PSA_DRAWINGS 'fusion\scrub-substitutions.json'
}
if (-not (Test-Path -LiteralPath $Substitutions)) {
    throw "no substitution file at $Substitutions. It must live outside the repository: its keys are the project's own words."
}
$subsRaw = Get-Content -LiteralPath $Substitutions -Raw | ConvertFrom-Json
$subs = @($subsRaw.from)
if ($subs.Count -eq 0) { throw "the substitution file has no entries under 'from'" }

$changed = 0
foreach ($f in $files) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Warning "missing $f"; continue }
    $txt = [System.IO.File]::ReadAllText($f)
    $orig = $txt
    foreach ($s in $subs) { $txt = $txt.Replace($s.from, $s.to) }
    if ($txt -ne $orig) {
        $changed++
        if ($Check) { Write-Host ("WOULD SCRIBE  " + $f) }
        else {
            [System.IO.File]::WriteAllText($f, $txt, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host ("SCRIBED  " + $f)
        }
    }
}

# Report whatever still looks project-specific. The pattern is built FROM the substitution file, so
# this script never carries a project's own words.
$alt = @($subs | ForEach-Object { [regex]::Escape([string]$_.from) })
$pat = ($alt -join '|')
Write-Host "--- remaining matches ---"
$left = 0
if ($pat) {
    foreach ($f in $files) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $hits = @(Select-String -Path $f -Pattern $pat -AllMatches -ErrorAction SilentlyContinue)
        foreach ($h in $hits) {
            $left++
            $line = $h.Line.Trim()
            if ($line.Length -gt 130) { $line = $line.Substring(0, 130) + '...' }
            Write-Host ((Split-Path -Leaf $f) + ':' + $h.LineNumber + ': ' + $line)
        }
    }
}
Write-Host ("files changed: {0}   remaining matches: {1}" -f $changed, $left)
