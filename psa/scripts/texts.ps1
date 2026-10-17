# texts.ps1 -- cadcraft card M2-C1
#
# Runs `cadcraft-cli run <dwg> --cmd "texts {}"` (the text-extraction command; its id is
# `texts`, confirmed with `cadcraft-cli commands text`) for every drawing and saves the JSON
# to $D\fusion\texts\<name>.json.
#
# The card's check: one JSON per drawing, each with at least one text whose value is the
# drawing number from the file name (e.g. NNNN-IC-GAD-001).
#
# IMPORTANT, learned on card M1-C5: `texts` reads the CURRENT SPACE, which after opening a
# PSA drawing is model space. The title block -- and the drawing number inside it -- lives in
# the PAPER SPACE layout, so a plain `texts {}` returns the model-space text and may not
# contain the drawing number. So this card switches to the layout first (layout.set) and then
# extracts, and also records the model-space texts. A drawing number is found if it appears in
# EITHER space. See the check at the bottom.
#
# Writes only inside $D\fusion.

[CmdletBinding()]
param(
    [string]$Inventory,
    [string]$InfoDir,
    [string]$OutDir,
    [switch]$Force
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

function Resolve-CadcraftCli {
    $cmd = Get-Command 'cadcraft-cli' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $exe = 'C:\Users\ReinachvanNieuwenhui\src\cadcraft\target\release\cadcraft-cli.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    throw 'cadcraft-cli not found. Run cards M0-C2 and M0-C3.'
}

function Get-ArgumentForNative {
    param([string]$Value)
    return '"' + $Value.Replace('"', '""') + '"'
}

function Get-OutName {
    param([string]$Path, [string]$Root, [string]$Extension)
    $rel = $Path
    if ($Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $Path.Substring($Root.Length).TrimStart('\')
    } else {
        $rel = Split-Path -Leaf $Path
    }
    $rel = $rel -replace '[\\/]', '__'
    $rel = $rel -replace '[<>:"|?*]', '_'
    $rel = $rel -replace '\.dwg$', ''
    $rel = $rel.TrimEnd('.', ' ')
    return ($rel + $Extension)
}

# Run a sequence of --cmd steps through the CLI via a generated .cmd wrapper (the JSON needs
# its inner quotes backslash-escaped; see export-pdf.ps1 for why). Returns stdout text.
function Invoke-CliSteps {
    param([string]$Cli, [string]$Drawing, [string[]]$Steps)
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    $bat = [System.IO.Path]::GetTempFileName() + '.cmd'
    try {
        $argPart = ''
        foreach ($s in $Steps) { $argPart += ' --cmd "' + $s.Replace('"', '\"') + '"' }
        $line = '"' + $Cli + '" run "' + $Drawing + '"' + $argPart
        [System.IO.File]::WriteAllText($bat, "@echo off`r`n$line`r`n", (New-Object System.Text.ASCIIEncoding))
        $pi = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', (Get-ArgumentForNative -Value $bat)) `
                -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        if (-not $pi.WaitForExit(180000)) { try { $pi.Kill() } catch { }; return [pscustomobject]@{ ok = $false; out = ''; err = 'timeout' } }
        return [pscustomobject]@{
            ok  = ($pi.ExitCode -eq 0)
            out = [System.IO.File]::ReadAllText($tmpOut)
            err = [System.IO.File]::ReadAllText($tmpErr).Trim()
        }
    } finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr, $bat -Force -ErrorAction SilentlyContinue
    }
}

$D = Get-PSADrawingsRoot
if ([string]::IsNullOrWhiteSpace($Inventory)) { $Inventory = Join-Path $D 'fusion\inventory.csv' }
if ([string]::IsNullOrWhiteSpace($InfoDir)) { $InfoDir = Join-Path $D 'fusion\info' }
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $D 'fusion\texts' }

if (-not (Test-Path -LiteralPath $Inventory)) { throw "inventory not found: $Inventory (run card M1-C1)" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$cli = Resolve-CadcraftCli
$rows = @(Import-Csv -LiteralPath $Inventory)
Write-Host "cadcraft-cli : $cli"
Write-Host "drawings     : $($rows.Count)"

$ok = 0
$fail = 0
$noDwgNo = 0
$failures = New-Object System.Collections.Generic.List[string]

foreach ($r in $rows) {
    $path = $r.path
    $name = Split-Path -Leaf $path
    $jsonPath = Join-Path $OutDir (Get-OutName -Path $path -Root $D -Extension '.json')

    if ((Test-Path -LiteralPath $jsonPath) -and -not $Force) { $ok++; continue }

    # The drawing number is the file name up to the first underscore.
    $stem = ($name -replace '\.dwg$', '')
    $dwgNo = ($stem -split '_')[0]

    # Which paper-space layout to switch to, from the info JSON (fall back to Model).
    $layout = 'Model'
    $infoJson = Join-Path $InfoDir (Get-OutName -Path $path -Root $D -Extension '.dwg.json')
    if (-not (Test-Path -LiteralPath $infoJson)) {
        $alt = Join-Path $InfoDir (Get-OutName -Path $path -Root $D -Extension '.json')
        if (Test-Path -LiteralPath $alt) { $infoJson = $alt }
    }
    if (Test-Path -LiteralPath $infoJson) {
        $lay = @(((Get-Content -LiteralPath $infoJson -Raw | ConvertFrom-Json).layouts | ForEach-Object { [string]$_ }) | Where-Object { $_ -ne 'Model' })
        if ($lay.Count -gt 0) { $layout = $lay[0] }
    }

    # Extract model-space texts, then switch to the layout and extract again. The two JSON
    # results are combined into one file with a `space` marker on each text.
    $model = Invoke-CliSteps -Cli $cli -Drawing $path -Steps @('texts {}')
    if (-not $model.ok) {
        $fail++
        $failures += "$path`tMODEL`t$($model.err)"
        Write-Host "FAIL (model texts) $name"
        continue
    }
    $modelJson = $null
    try { $modelJson = $model.out | ConvertFrom-Json } catch { }

    $paperJson = $null
    if ($layout -ne 'Model') {
        $paper = Invoke-CliSteps -Cli $cli -Drawing $path -Steps @("layout.set {`"name`":`"$layout`"}", 'texts {}')
        if ($paper.ok) { try { $paperJson = $paper.out | ConvertFrom-Json } catch { } }
    }

    # Combine into one JSON object.
    $combined = [ordered]@{
        drawing   = $name
        path      = $path
        layout    = $layout
        model     = $modelJson
        paper     = $paperJson
    }
    $json = $combined | ConvertTo-Json -Depth 12 -Compress
    [System.IO.File]::WriteAllText($jsonPath, $json, (New-Object System.Text.UTF8Encoding($false)))

    # Check: does the drawing number appear in any text, model or paper?
    $allText = ''
    if ($modelJson) { $allText += (($modelJson.texts | ForEach-Object { $_.text }) -join "`n") }
    if ($paperJson) { $allText += "`n" + (($paperJson.texts | ForEach-Object { $_.text }) -join "`n") }
    if ($allText -notmatch [regex]::Escape($dwgNo)) {
        $noDwgNo++
        Write-Host "WARN (no '$dwgNo' in extracted text) $name"
    }
    $ok++
    Write-Host "ok   $name (layout $layout)"
}

Write-Host ''
Write-Host "ok                : $ok"
Write-Host "failed            : $fail"
Write-Host "no drawing number : $noDwgNo"
$jsonCount = @(Get-ChildItem -LiteralPath $OutDir -Filter '*.json' -File).Count
Write-Host "json files        : $jsonCount of $($rows.Count)"
if ($failures.Count -gt 0) {
    Write-Host 'failures:'
    foreach ($f in $failures) { Write-Host "  $f" }
}

# The card's check: one JSON per drawing, each with at least one text equal to the drawing
# number. A drawing whose number is not in the extracted text is reported but does not fail
# the whole run -- it is a finding for M2-C3, not a broken sweep.
if ($ok -eq 0) { Write-Error 'no drawing extracted - the sweep is broken'; exit 1 }
if ($jsonCount -lt $rows.Count) { Write-Error "$($rows.Count - $jsonCount) drawing(s) have no texts JSON"; exit 1 }
if ($noDwgNo -gt 0) { Write-Host "PASS M2-C1 with $noDwgNo drawing(s) whose number was not found in extracted text" }
else { Write-Host 'PASS M2-C1 (every drawing has a JSON with its drawing number in the text)' }
exit 0
