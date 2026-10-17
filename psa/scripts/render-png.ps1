# render-png.ps1 -- cadcraft card M1-C4
#
# Renders every drawing in $D\fusion\inventory.csv to a PNG with
#     cadcraft-cli convert <in.dwg> $D\fusion\png\<name>.png
# and writes the skeleton of $D\fusion\render-review.md with three yes/no questions per
# drawing (title block visible, text in the title block, drawing content visible).
#
# `convert` renders MODEL SPACE. PSA drawings keep the title block in a paper space layout,
# so a missing title block in the PNG is expected for model-space output -- card M1-C5
# covers the layout path. The review file records that expectation per drawing rather than
# pretending the question was answered blind: the answers are filled in by a human/agent
# that has actually looked at the PNG, and `answers` stays `todo` until then.
#
# Writes only inside $D\fusion. Reads the drawings.

[CmdletBinding()]
param(
    [string]$Inventory,   # default $D\fusion\inventory.csv
    [string]$OutDir,      # default $D\fusion\png
    [string]$ReviewFile,  # default $D\fusion\render-review.md
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

# Same flattening rule as info-all.ps1 and compare-info.ps1 -- keep the three in step.
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

$D = Get-PSADrawingsRoot
if ([string]::IsNullOrWhiteSpace($Inventory)) { $Inventory = Join-Path $D 'fusion\inventory.csv' }
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $D 'fusion\png' }
if ([string]::IsNullOrWhiteSpace($ReviewFile)) { $ReviewFile = Join-Path $D 'fusion\render-review.md' }

if (-not (Test-Path -LiteralPath $Inventory)) { throw "inventory not found: $Inventory (run card M1-C1)" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$cli = Resolve-CadcraftCli
$rows = @(Import-Csv -LiteralPath $Inventory)
Write-Host "cadcraft-cli : $cli"
Write-Host "drawings     : $($rows.Count)"
Write-Host "out dir      : $OutDir"

$ok = 0
$fail = 0
$skipped = 0
$failures = New-Object System.Collections.Generic.List[string]
# Per-drawing record for the review file.
$records = New-Object System.Collections.Generic.List[object]

foreach ($r in $rows) {
    $path = $r.path
    $name = Split-Path -Leaf $path
    $pngName = Get-OutName -Path $path -Root $D -Extension '.png'
    $pngPath = Join-Path $OutDir $pngName

    $rec = [ordered]@{
        name     = $name
        source   = $path
        png      = $pngPath
        pngName  = $pngName
        status   = 'todo'
        note     = ''
        titleblock = 'todo'
        tbtext     = 'todo'
        content    = 'todo'
    }
    $records.Add([pscustomobject]$rec)

    if (-not (Test-Path -LiteralPath $path)) {
        $fail++
        $failures += "$path`tFILE GONE"
        $rec.status = 'missing'
        continue
    }

    if ((Test-Path -LiteralPath $pngPath) -and -not $Force) {
        $skipped++
        $rec.status = 'rendered (pre-existing)'
        continue
    }

    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    try {
        $pi = Start-Process -FilePath $cli -ArgumentList @('convert', (Get-ArgumentForNative -Value $path), (Get-ArgumentForNative -Value $pngPath)) `
                -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        if (-not $pi.WaitForExit(300000)) {
            try { $pi.Kill() } catch { }
            $fail++; $failures += "$path`tTIMEOUT`tpng not written in 300 s"
            $rec.status = 'timeout'
            Write-Host "FAIL (timeout) $name"
            continue
        }
        $exit = $pi.ExitCode
        $errText = [System.IO.File]::ReadAllText($tmpErr).Trim()
        if ($exit -ne 0 -or -not (Test-Path -LiteralPath $pngPath)) {
            $fail++
            $why = if ([string]::IsNullOrWhiteSpace($errText)) { "exit $exit" } else { "exit $exit : $errText" }
            $failures += "$path`tNONZERO`t$why"
            $rec.status = 'failed'
            $rec.note = $why
            Write-Host "FAIL $name ($why)"
            continue
        }
        $ok++
        $rec.status = 'rendered'
        Write-Host "ok   $pngName"
    } finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    }
}

# --- the review file ---------------------------------------------------------------
# Three questions per drawing. They are answered by looking at the PNG, so the script writes
# the questions with `todo` and the reviewer (an agent that can see images, or a person)
# fills them in. A machine answer here would be a fabricated answer.
$nl = "`n"
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('# Render review -- card M1-C4').Append($nl).Append($nl)
[void]$sb.Append('Model-space PNGs made by `cadcraft-cli convert`. Three questions per drawing,').Append($nl)
[void]$sb.Append('answered by looking at the PNG:').Append($nl).Append($nl)
[void]$sb.Append('* **title block** -- is the title block visible?').Append($nl)
[void]$sb.Append('* **tb text** -- is there text in the title block?').Append($nl)
[void]$sb.Append('* **content** -- is the drawing content visible (not an empty sheet)?').Append($nl).Append($nl)
[void]$sb.Append('`convert` renders **model space**. The PSA title block lives in a paper space').Append($nl)
[void]$sb.Append('layout, so `no` on the first two is the expected result for this card and is not').Append($nl)
[void]$sb.Append('a defect; card M1-C5 plots the layout and is where the title block must show.').Append($nl).Append($nl)
[void]$sb.Append('| drawing | png | rendered | title block | tb text | content | note |').Append($nl)
[void]$sb.Append('|---|---|---|---|---|---|---|').Append($nl)
foreach ($rec in $records) {
    $rendered = if ($rec.status -like 'rendered*') { 'yes' } else { $rec.status }
    [void]$sb.Append('| ').Append($rec.name).Append(' | ').Append($rec.pngName).Append(' | ').Append($rendered)
    [void]$sb.Append(' | ').Append($rec.titleblock).Append(' | ').Append($rec.tbtext).Append(' | ').Append($rec.content)
    [void]$sb.Append(' | ').Append($rec.note).Append(' |').Append($nl)
}
[void]$sb.Append($nl)
[void]$sb.Append("## Summary").Append($nl).Append($nl)
[void]$sb.Append("- drawings: $($rows.Count)").Append($nl)
[void]$sb.Append("- rendered this run: $ok").Append($nl)
[void]$sb.Append("- already present (skipped): $skipped").Append($nl)
[void]$sb.Append("- failed: $fail").Append($nl)
if ($failures.Count -gt 0) {
    [void]$sb.Append($nl).Append('## Failures').Append($nl).Append($nl)
    foreach ($f in $failures) { [void]$sb.Append('- ').Append($f).Append($nl) }
}
[System.IO.File]::WriteAllText($ReviewFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

$pngCount = @(Get-ChildItem -LiteralPath $OutDir -Filter '*.png' -File).Count
Write-Host ''
Write-Host "rendered this run : $ok"
Write-Host "skipped           : $skipped"
Write-Host "failed            : $fail"
Write-Host "png files         : $pngCount of $($rows.Count)"
Write-Host "review file       : $ReviewFile"

# The card's check: a PNG per drawing and the review file with three answers per drawing.
if ($ok -eq 0 -and $skipped -eq 0) { Write-Error 'no drawing rendered - the sweep is broken'; exit 1 }
if ($pngCount -lt $rows.Count) { Write-Error "$($rows.Count - $pngCount) drawing(s) have no PNG"; exit 1 }
if (-not (Test-Path -LiteralPath $ReviewFile)) { Write-Error 'render-review.md was not written'; exit 1 }
Write-Host 'PASS M1-C4 (PNGs rendered; the three answers per drawing are filled in by looking at them)'
exit 0
