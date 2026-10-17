# roundtrip.ps1 -- cadcraft card M1-C6
#
# For each drawing:
#   1. cadcraft-cli convert <in.dwg> $D\fusion\roundtrip\<name>.dwg   (open, save)
#   2. cadcraft-cli info on the new file                              (re-open)
#   3. compare the re-opened info against the ORIGINAL's info JSON    (what changed on save)
#
# Every difference is a loss on save and an M5 card. The result is one line per drawing in
# $D\fusion\roundtrip-report.txt listing the differences, or "no loss".
#
# The comparison is cadcraft-vs-cadcraft (the original's info JSON from card M1-C2 against
# the round-tripped file's info), NOT against expected.csv: this card asks what cadcraft
# loses when IT saves, so the baseline is what cadcraft read on the way in.
#
# Writes only inside $D\fusion.

[CmdletBinding()]
param(
    [string]$Inventory,
    [string]$InfoDir,
    [string]$OutDir,
    [string]$ReportFile,
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

# Run `cadcraft-cli info <path>` and return the parsed JSON, or $null on failure.
function Get-InfoJson {
    param([string]$Cli, [string]$Path)
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    try {
        $pi = Start-Process -FilePath $Cli -ArgumentList @('info', (Get-ArgumentForNative -Value $Path)) `
                -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        if (-not $pi.WaitForExit(120000)) { try { $pi.Kill() } catch { }; return $null }
        if ($pi.ExitCode -ne 0) { return $null }
        $text = [System.IO.File]::ReadAllText($tmpOut)
        try { return ($text | ConvertFrom-Json) } catch { return $null }
    } catch {
        return $null
    } finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    }
}

$D = Get-PSADrawingsRoot
if ([string]::IsNullOrWhiteSpace($Inventory)) { $Inventory = Join-Path $D 'fusion\inventory.csv' }
if ([string]::IsNullOrWhiteSpace($InfoDir)) { $InfoDir = Join-Path $D 'fusion\info' }
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $D 'fusion\roundtrip' }
if ([string]::IsNullOrWhiteSpace($ReportFile)) { $ReportFile = Join-Path $D 'fusion\roundtrip-report.txt' }

if (-not (Test-Path -LiteralPath $Inventory)) { throw "inventory not found: $Inventory (run card M1-C1)" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$cli = Resolve-CadcraftCli
$rows = @(Import-Csv -LiteralPath $Inventory)
Write-Host "cadcraft-cli : $cli"
Write-Host "drawings     : $($rows.Count)"

$nl = "`n"
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('# Round trip report -- card M1-C6').Append($nl)
[void]$sb.Append('# open -> save (convert dwg->dwg) -> re-open (info) -> diff vs the original info.').Append($nl)
[void]$sb.Append('# A difference is a loss on save and an M5 card. "no loss" means the re-opened').Append($nl)
[void]$sb.Append('# drawing has the same entity/layer/block/layout counts as the original read.').Append($nl)
[void]$sb.Append($nl)

$lines = New-Object System.Collections.Generic.List[string]
$lossCount = 0
$cleanCount = 0
$failCount = 0

foreach ($r in $rows) {
    $path = $r.path
    $name = Split-Path -Leaf $path
    $rtPath = Join-Path $OutDir (Get-OutName -Path $path -Root $D -Extension '.dwg')

    # Original info (card M1-C2 output).
    $origJson = Join-Path $InfoDir (Get-OutName -Path $path -Root $D -Extension '.dwg.json')
    if (-not (Test-Path -LiteralPath $origJson)) {
        $origJsonAlt = Join-Path $InfoDir (Get-OutName -Path $path -Root $D -Extension '.json')
        if (Test-Path -LiteralPath $origJsonAlt) { $origJson = $origJsonAlt }
    }
    if (-not (Test-Path -LiteralPath $origJson)) {
        $failCount++
        $lines.Add("$name  NO ORIGINAL INFO (run card M1-C2)")
        continue
    }
    $orig = Get-Content -LiteralPath $origJson -Raw | ConvertFrom-Json

    # 1) save: convert dwg -> dwg.
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    try {
        $pi = Start-Process -FilePath $cli -ArgumentList @('convert', (Get-ArgumentForNative -Value $path), (Get-ArgumentForNative -Value $rtPath)) `
                -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        if (-not $pi.WaitForExit(300000)) { try { $pi.Kill() } catch { } }
    } finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $rtPath)) {
        $failCount++
        $lines.Add("$name  SAVE FAILED (no round-trip dwg written)")
        continue
    }

    # 2) re-open.
    $rt = Get-InfoJson -Cli $cli -Path $rtPath
    if ($null -eq $rt) {
        $failCount++
        $lines.Add("$name  RE-OPEN FAILED (info on the saved file did not parse)")
        continue
    }

    # 3) diff. Compare the counts the info JSON exposes.
    $oEnt = [int]$orig.entityCount
    $rEnt = [int]$rt.entityCount
    $oLay = @($orig.layers).Count
    $rLay = @($rt.layers).Count
    $oBlk = @($orig.blocks).Count
    $rBlk = @($rt.blocks).Count
    $oLay_names = @($orig.layers | ForEach-Object { [string]$_.name })
    $rLay_names = @($rt.layers | ForEach-Object { [string]$_.name })
    $oLayouts = @($orig.layouts | ForEach-Object { [string]$_ })
    $rLayouts = @($rt.layouts | ForEach-Object { [string]$_ })

    $diffs = New-Object System.Collections.Generic.List[string]
    if ($rEnt -ne $oEnt) { $diffs.Add("entities $oEnt->$rEnt") }
    if ($rLay -ne $oLay) { $diffs.Add("layers $oLay->$rLay") }
    if ($rBlk -ne $oBlk) { $diffs.Add("blocks $oBlk->$rBlk") }
    $lostLayers = @($oLay_names | Where-Object { $rLay_names -notcontains $_ })
    if ($lostLayers.Count -gt 0) { $diffs.Add("layers lost: " + ($lostLayers -join ',')) }
    $lostLayouts = @($oLayouts | Where-Object { $rLayouts -notcontains $_ })
    if ($lostLayouts.Count -gt 0) { $diffs.Add("layouts lost: " + ($lostLayouts -join ',')) }

    if ($diffs.Count -eq 0) {
        $cleanCount++
        $lines.Add("$name  no loss  (entities $rEnt, layers $rLay, blocks $rBlk, layouts $($rLayouts -join '|'))")
    } else {
        $lossCount++
        $lines.Add("$name  LOSS on save: " + ($diffs -join '; '))
    }
}

foreach ($l in $lines) { [void]$sb.Append($l).Append($nl) }
[void]$sb.Append($nl)
[void]$sb.Append("# drawings        : $($rows.Count)").Append($nl)
[void]$sb.Append("# no loss         : $cleanCount").Append($nl)
[void]$sb.Append("# loss on save    : $lossCount").Append($nl)
[void]$sb.Append("# failed          : $failCount").Append($nl)

[System.IO.File]::WriteAllText($ReportFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

foreach ($l in $lines) { Write-Host $l }
Write-Host ''
Write-Host "wrote $ReportFile"
Write-Host "no loss: $cleanCount   loss: $lossCount   failed: $failCount"

# The card's check: a report with one line per drawing listing the differences, or "no loss".
if ($lines.Count -ne $rows.Count) { Write-Error "report has $($lines.Count) lines for $($rows.Count) drawings"; exit 1 }
if ($failCount -gt 0) { Write-Error "$failCount drawing(s) failed the round trip outright"; exit 1 }
Write-Host 'PASS M1-C6 (report written; losses listed as M5 cards)'
exit 0
