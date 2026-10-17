# inventory.ps1 -- cadcraft card M1-C1
#
# Lists every *.dwg under $D\3. Working and under $D\Reference (recursively) and writes
# $D\fusion\inventory.csv with columns: path, size_bytes, acadver.
#
# acadver is the first 6 bytes of the file read as text: the AutoCAD version marker the
# format stores in plain ASCII at offset 0 ("AC1032" for the 2018-format DWG).
#
# $D is %PSA_DRAWINGS%. On this machine that variable is set in the User scope only and is
# not inherited by every process, so it is resolved from [Environment] explicitly; the
# process value is used when it is present.
#
# Nothing outside $D\fusion is written.

[CmdletBinding()]
param(
    # Where to write the CSV. Defaults to $D\fusion\inventory.csv.
    [string]$OutFile
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

function Get-DwgVersion {
    # First 6 bytes of the file as text. Returns '' when the file cannot be opened or is
    # shorter than 6 bytes, so the caller sees an empty acadver rather than a crash.
    param([string]$Path)
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $buf = New-Object byte[] 6
        $got = 0
        while ($got -lt 6) {
            $n = $fs.Read($buf, $got, 6 - $got)
            if ($n -le 0) { break }
            $got += $n
        }
        if ($got -lt 6) { return '' }
        # The marker is ASCII; NonLatinSpaced keeps odd bytes from throwing.
        return [System.Text.Encoding]::ASCII.GetString($buf).Trim([char]0)
    } catch {
        return ''
    } finally {
        if ($null -ne $fs) { $fs.Dispose() }
    }
}

$D = Get-PSADrawingsRoot
if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $OutFile = Join-Path (Join-Path $D 'fusion') 'inventory.csv'
}

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

# The two trees the card names. A missing tree is reported, not fatal: the other one still
# has to be inventoried.
$roots = @(
    (Join-Path $D '3. Working'),
    (Join-Path $D 'Reference')
)

$files = New-Object System.Collections.Generic.List[object]
$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) {
        Write-Warning "not found, skipped: $root"
        continue
    }
    Write-Host "walking $root"
    foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -Filter '*.dwg' -File -ErrorAction SilentlyContinue) {
        # Guard against a reparse-point cycle in the Reference tree.
        if (-not $seen.Add($f.FullName)) { continue }
        $files.Add([pscustomobject]@{
                path       = $f.FullName
                size_bytes = $f.Length
                acadver    = Get-DwgVersion -Path $f.FullName
            })
    }
}

# Stable order so two runs diff cleanly.
$rows = $files | Sort-Object path

# Write with an explicit UTF-8 (no BOM) encoding and LF endings: the CSV is read back by
# PowerShell, Python and cadcraft scripts alike.
$nl = "`n"
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('path,size_bytes,acadver').Append($nl)
foreach ($r in $rows) {
    $p = $r.path
    if ($p -match '[",\r\n]') { $p = '"' + $p.Replace('"', '""') + '"' }
    [void]$sb.Append($p).Append(',').Append($r.size_bytes).Append(',').Append($r.acadver).Append($nl)
}
[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

# --- the card's check -------------------------------------------------------------
# "the CSV exists, has one row per DWG, and no row has an empty acadver"
$expectedCount = 0
foreach ($root in $roots) {
    if (Test-Path -LiteralPath $root) {
        $expectedCount += @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.dwg' -File -ErrorAction SilentlyContinue).Count
    }
}
$written = @($rows).Count
$empty = @($rows | Where-Object { [string]::IsNullOrWhiteSpace($_.acadver) })

Write-Host ''
Write-Host "wrote $OutFile"
Write-Host "dwg files found : $expectedCount"
Write-Host "rows written    : $written"
Write-Host "empty acadver   : $($empty.Count)"
foreach ($e in $empty) { Write-Host "  EMPTY: $($e.path)" }
foreach ($g in ($rows | Group-Object acadver | Sort-Object Name)) {
    Write-Host ("  acadver {0,-8} {1}" -f $g.Name, $g.Count)
}

if (-not (Test-Path -LiteralPath $OutFile)) { Write-Error 'inventory.csv was not written'; exit 1 }
if ($written -ne $expectedCount) { Write-Error "row count $written != dwg count $expectedCount"; exit 1 }
if ($empty.Count -gt 0) { Write-Error "$($empty.Count) row(s) have an empty acadver"; exit 1 }
if ($written -eq 0) { Write-Error 'no DWG files found'; exit 1 }

Write-Host 'PASS M1-C1'
exit 0
