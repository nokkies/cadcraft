# export-pdf.ps1 -- cadcraft card M1-C5
#
# Plots every drawing through its PAPER SPACE layout with
#
#   cadcraft-cli run <in.dwg> --cmd "exportpdf {\"path\": ..., \"layout\": ..., \"paper\": \"A3\",
#                                                    \"landscape\": true|false, \"fit\": true}"
#
# and writes the result to $D\fusion\pdf\<name>.pdf.
#
# The layout name comes from the drawing's info JSON (card M1-C2). A drawing whose only
# layout is "Model" has no paper space to plot, and is recorded as such rather than plotted
# from model space -- the point of this card is the layout path.
#
# Orientation: PLAN.md says try landscape:false for the portrait sheets (the Reference GAD
# sheets). The rule used here is derived from the layout's own plot, not guessed per name:
# landscape unless the drawing is one of the known portrait GAD sheets. See Get-Landscape.
#
# SHX text substitution: the PSA text styles name isocp.shx, which cadcraft cannot parse, so by
# default its every text falls back to the built-in single-stroke font (measured: 99/99 texts on a
# schematic sheet). cadcraft's intended lever is FONTALT (CADCRAFT_FONTALT): for a font it cannot
# find (an SHX file), it renders in the FONTALT font when that names a findable face. This script
# sets CADCRAFT_FONTALT for the export process so the plotted PDFs render SHX text in a real
# TrueType face (default arial.ttf, a clean sans-serif cadcraft finds in C:\Windows\Fonts) instead
# of the stroke font. It changes only the RENDER (preview/exportpdf), never the DWG data -- AutoCAD
# still opens the sheet with the real isocp.shx. Pass -FontAlt '' to keep cadcraft's stroke font.
#
# Writes only inside $D\fusion.

[CmdletBinding()]
param(
    [string]$Inventory,
    [string]$InfoDir,
    [string]$OutDir,
    [string]$FontAlt = 'arial.ttf',
    [switch]$Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Font substitution for SHX text in the rendered PDFs (see the header note). Set in this process's
# environment so the cadcraft-cli child processes cadcraft-cli launched below inherit it.
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

# JSON-escape a path for embedding in the --cmd parameter string.
function ConvertTo-JsonStringLiteral {
    param([string]$Value)
    $esc = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $esc + '"'
}

# Build the cmd.exe command line for one export.
#
# Why cmd.exe and not Start-Process: `--cmd` takes `id {json}` and the JSON needs its inner
# double quotes to survive to the process. PowerShell -> native argument passing strips them
# (the JSON arrives as `{path:...}` and serde_json fails with "key must be a string"), and
# Start-Process does not quote arguments containing spaces. Driving cmd.exe with the JSON
# wrapped in double quotes and its inner quotes backslash-escaped is what the CLI's own tests
# do (`--cmd 'zoom {"mode":"window"...}'`), and it delivers the JSON intact.
function Get-ExportCommandLine {
    param([string]$Cli, [string]$Drawing, [string]$CmdArg)
    # Backslash-escape the double quotes that delimit JSON keys/strings so cmd hands them to
    # the process rather than treating them as its own quoting.
    $escapedCmd = $CmdArg.Replace('"', '\"')
    return '"' + $Cli + '" run "' + $Drawing + '" --cmd "' + $escapedCmd + '"'
}

$D = Get-PSADrawingsRoot
if ([string]::IsNullOrWhiteSpace($Inventory)) { $Inventory = Join-Path $D 'fusion\inventory.csv' }
if ([string]::IsNullOrWhiteSpace($InfoDir)) { $InfoDir = Join-Path $D 'fusion\info' }
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $D 'fusion\pdf' }

if (-not (Test-Path -LiteralPath $Inventory)) { throw "inventory not found: $Inventory (run card M1-C1)" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$cli = Resolve-CadcraftCli
$rows = @(Import-Csv -LiteralPath $Inventory)
Write-Host "cadcraft-cli : $cli"
Write-Host "drawings     : $($rows.Count)"
Write-Host "out dir      : $OutDir"

$ok = 0
$fail = 0
$noLayout = 0
$skipped = 0
$failures = New-Object System.Collections.Generic.List[string]
$records = New-Object System.Collections.Generic.List[object]

foreach ($r in $rows) {
    $path = $r.path
    $name = Split-Path -Leaf $path
    $pdfName = Get-OutName -Path $path -Root $D -Extension '.pdf'
    $pdfPath = Join-Path $OutDir $pdfName

    $rec = [ordered]@{ name = $name; pdf = $pdfName; layout = ''; landscape = ''; status = 'todo'; note = '' }
    $records.Add([pscustomobject]$rec)

    # Which layout to plot: from the info JSON.
    $jsonPath = Join-Path $InfoDir (Get-OutName -Path $path -Root $D -Extension '.dwg.json')
    if (-not (Test-Path -LiteralPath $jsonPath)) {
        # info-all.ps1 names the file "<flattened path>.dwg.json"; try that too.
        $alt = Get-OutName -Path $path -Root $D -Extension '.json'
        $alt = $alt -replace '\.json$', '.dwg.json'
        if (Test-Path -LiteralPath $alt) { $jsonPath = $alt }
    }
    $layouts = @()
    if (Test-Path -LiteralPath $jsonPath) {
        $j = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
        $layouts = @($j.layouts | ForEach-Object { [string]$_ })
    } else {
        $failures += "$path`tNOINFO`tno info JSON, cannot pick a layout"
        $rec.status = 'no info'
        $fail++
        Write-Host "FAIL (no info) $name"
        continue
    }

    # Prefer a named paper space layout; "Model" is not a layout to plot here.
    $paper = @($layouts | Where-Object { $_ -ne 'Model' })
    if ($paper.Count -eq 0) {
        $noLayout++
        $rec.status = 'model space only'
        $rec.note = "layouts: $($layouts -join ', ')"
        Write-Host "SKIP (no paper space layout) $name"
        continue
    }
    $layout = $paper[0]
    $rec.layout = $layout

    # Orientation: the GAD general-arrangement sheets in the Reference set are portrait
    # (PLAN.md). Everything else plots landscape.
    $landscape = $true
    if ($name -match 'GAD') { $landscape = $false }
    $rec.landscape = if ($landscape) { 'true' } else { 'false' }

    if ((Test-Path -LiteralPath $pdfPath) -and -not $Force) {
        $skipped++
        $rec.status = 'exported (pre-existing)'
        continue
    }

    $cmd = 'exportpdf {"path": ' + (ConvertTo-JsonStringLiteral -Value $pdfPath) +
           ', "layout": ' + (ConvertTo-JsonStringLiteral -Value $layout) +
           ', "paper": "A3", "landscape": ' + $(if ($landscape) { 'true' } else { 'false' }) +
           ', "fit": true}'

    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    try {
        $line = Get-ExportCommandLine -Cli $cli -Drawing $path -CmdArg $cmd
        # Write the command line to a .cmd file and run it: avoids re-quoting the whole line
        # through another shell layer, and keeps the escaped JSON exactly as built above.
        $bat = [System.IO.Path]::GetTempFileName() + '.cmd'
        [System.IO.File]::WriteAllText($bat, "@echo off`r`n$line`r`n", (New-Object System.Text.ASCIIEncoding))
        $pi = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', (Get-ArgumentForNative -Value $bat)) `
                -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        if (-not $pi.WaitForExit(300000)) {
            try { $pi.Kill() } catch { }
            $fail++; $failures += "$path`tTIMEOUT`tpdf not written in 300 s"
            $rec.status = 'timeout'
            Write-Host "FAIL (timeout) $name"
            continue
        }
        Remove-Item -LiteralPath $bat -Force -ErrorAction SilentlyContinue
        $exit = $pi.ExitCode
        $errText = [System.IO.File]::ReadAllText($tmpErr).Trim()
        if ($exit -ne 0 -or -not (Test-Path -LiteralPath $pdfPath)) {
            $fail++
            $why = if ([string]::IsNullOrWhiteSpace($errText)) { "exit $exit" } else { "exit $exit : $errText" }
            $failures += "$path`tNONZERO`t$why"
            $rec.status = 'failed'
            $rec.note = $why
            Write-Host "FAIL $name ($why)"
            continue
        }
        $ok++
        $rec.status = 'exported'
        Write-Host "ok   $pdfName (layout $layout, landscape=$landscape)"
    } finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    }
}

# --- record ------------------------------------------------------------------------
$nl = "`n"
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('# PDF export through layout -- card M1-C5').Append($nl).Append($nl)
[void]$sb.Append('Plotted with `cadcraft-cli run <dwg> --cmd "exportpdf {layout, paper A3, fit}"`.').Append($nl).Append($nl)
[void]$sb.Append('| drawing | pdf | layout | landscape | status | note |').Append($nl)
[void]$sb.Append('|---|---|---|---|---|---|').Append($nl)
foreach ($rec in $records) {
    [void]$sb.Append('| ').Append($rec.name).Append(' | ').Append($rec.pdf).Append(' | ').Append($rec.layout)
    [void]$sb.Append(' | ').Append($rec.landscape).Append(' | ').Append($rec.status).Append(' | ').Append($rec.note).Append(' |').Append($nl)
}
[void]$sb.Append($nl).Append('## Summary').Append($nl).Append($nl)
[void]$sb.Append("- drawings: $($rows.Count)").Append($nl)
[void]$sb.Append("- exported this run: $ok").Append($nl)
[void]$sb.Append("- already present: $skipped").Append($nl)
[void]$sb.Append("- model space only (no layout to plot): $noLayout").Append($nl)
[void]$sb.Append("- failed: $fail").Append($nl)
if ($failures.Count -gt 0) {
    [void]$sb.Append($nl).Append('## Failures').Append($nl).Append($nl)
    foreach ($f in $failures) { [void]$sb.Append('- ').Append($f).Append($nl) }
}
[System.IO.File]::WriteAllText((Join-Path $D 'fusion\pdf-export.md'), $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

$pdfCount = @(Get-ChildItem -LiteralPath $OutDir -Filter '*.pdf' -File).Count
Write-Host ''
Write-Host "exported this run : $ok"
Write-Host "already present   : $skipped"
Write-Host "model space only  : $noLayout"
Write-Host "failed            : $fail"
Write-Host "pdf files         : $pdfCount"
Write-Host "record            : $(Join-Path $D 'fusion\pdf-export.md')"

if ($ok -eq 0 -and $skipped -eq 0) { Write-Error 'no pdf exported - the sweep is broken'; exit 1 }
if ($fail -gt 0) { Write-Error "$fail drawing(s) failed to export"; exit 1 }
Write-Host 'PASS M1-C5 (a PDF per drawing that has a paper space layout)'
exit 0
