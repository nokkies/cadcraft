# info-all.ps1 -- cadcraft card M1-C2
#
# For every path in $D\fusion\inventory.csv, runs `cadcraft-cli info <path>` and saves the
# JSON to $D\fusion\info\<filename>.json. A failure (non-zero exit, or output that is not
# JSON) is recorded in $D\fusion\info\FAILED.txt with the path and the error text, and the
# run continues with the next file.
#
# Writes only inside $D\fusion. Reads only.
#
# $D is %PSA_DRAWINGS%, resolved from the registry scopes because this machine does not
# export it into every process.

[CmdletBinding()]
param(
    [string]$Inventory,   # default $D\fusion\inventory.csv
    [string]$OutDir,      # default $D\fusion\info
    [switch]$Force        # re-run files that already have a JSON
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
    # Prefer whatever `cadcraft-cli` resolves to on PATH (card M0-C3 installed a shim);
    # fall back to the release build in the repository.
    $cmd = Get-Command 'cadcraft-cli' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $repo = 'C:\Users\ReinachvanNieuwenhui\src\cadcraft'
    $exe = Join-Path $repo 'target\release\cadcraft-cli.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    throw 'cadcraft-cli not found on PATH and no release build at target\release. Run cards M0-C2 and M0-C3.'
}

function Get-ArgumentForNative {
    # Start-Process joins -ArgumentList into one command line and does NOT quote arguments
    # that contain spaces, so a path like "...\01.Est\<private project folder>\..."
    # reaches the native program split at the first space. Quote it ourselves (the
    # CommandLineToArgvW rule: wrap in double quotes, double any embedded quote).
    param([string]$Value)
    return '"' + $Value.Replace('"', '""') + '"'
}

$D = Get-PSADrawingsRoot
if ([string]::IsNullOrWhiteSpace($Inventory)) { $Inventory = Join-Path $D 'fusion\inventory.csv' }
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $D 'fusion\info' }

if (-not (Test-Path -LiteralPath $Inventory)) { throw "inventory not found: $Inventory (run inventory.ps1, card M1-C1)" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$failedPath = Join-Path $OutDir 'FAILED.txt'
$cli = Resolve-CadcraftCli
Write-Host "cadcraft-cli : $cli"
Write-Host "out dir      : $OutDir"

$rows = @(Import-Csv -LiteralPath $Inventory)
Write-Host "drawings     : $($rows.Count)"

# Name the JSON after the drawing's path so two drawings with the same file name in
# different folders (the Reference tree has several) do not overwrite each other. The
# relative path is flattened into ONE file name: every path separator becomes '__' and
# every character Windows forbids in a name becomes '_'.
#   3. Working\<project>-IC-GAD-001_A.dwg -> 3. Working__<project>-IC-GAD-001_A.dwg.json
function Get-JsonName {
    param([string]$Path, [string]$Root)
    $rel = $Path
    if ($Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $Path.Substring($Root.Length).TrimStart('\')
    } else {
        $rel = Split-Path -Leaf $Path
    }
    $rel = $rel -replace '[\\/]', '__'
    $rel = $rel -replace '[<>:"|?*]', '_'
    # Windows names cannot end in a dot or a space.
    $rel = $rel.TrimEnd('.', ' ')
    return ($rel + '.json')
}

$ok = 0
$fail = 0
$skipped = 0
$failures = New-Object System.Collections.Generic.List[string]

foreach ($r in $rows) {
    $path = $r.path
    if (-not (Test-Path -LiteralPath $path)) {
        $fail++
        $failures += "$path`tFILE GONE`tfile no longer exists"
        Write-Host "FAIL (missing) $path"
        continue
    }

    $jsonName = Get-JsonName -Path $path -Root $D
    $jsonPath = Join-Path $OutDir $jsonName

    if ((Test-Path -LiteralPath $jsonPath) -and -not $Force) {
        $skipped++
        continue
    }

    # Run the CLI. stdout is the JSON, stderr is the human-readable noise (and the error
    # text when it fails). Redirect to temp files so a huge drawing cannot blow up memory
    # and the two streams stay separate.
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    try {
        # Start-Process (not `& cmd /c`, whose exit code arrives as a string array) so the
        # real numeric exit code and the two output streams stay separate and reliable.
        $pi = Start-Process -FilePath $cli -ArgumentList @('info', (Get-ArgumentForNative -Value $path)) `
                -NoNewWindow -PassThru `
                -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        # Bound the wait: a hung reader must not stall the whole sweep.
        if (-not $pi.WaitForExit(120000)) {
            try { $pi.Kill() } catch { }
            $fail++
            $failures += "$path`tTIMEOUT`tinfo did not finish in 120 s"
            Write-Host 'FAIL (timeout) '$path
            continue
        }
        $exit = $pi.ExitCode
        $outText = [System.IO.File]::ReadAllText($tmpOut)
        $errText = [System.IO.File]::ReadAllText($tmpErr).Trim()

        if ($exit -ne 0) {
            $fail++
            $why = if ([string]::IsNullOrWhiteSpace($errText)) { "exit $exit, no stderr" } else { "exit $exit : $errText" }
            $failures += "$path`tNONZERO`t$why"
            Write-Host "FAIL (exit $exit) $path"
            continue
        }

        if ([string]::IsNullOrWhiteSpace($outText)) {
            $fail++
            $failures += "$path`tEMPTY`texit 0 but no JSON on stdout"
            Write-Host "FAIL (empty) $path"
            continue
        }

        # Validate before saving: a stack trace printed on stdout with exit 0 would
        # otherwise be filed as a successful read.
        try {
            $null = $outText | ConvertFrom-Json
        } catch {
            $fail++
            $head = $outText.Substring(0, [Math]::Min(300, $outText.Length)).Replace("`r", ' ').Replace("`n", ' ')
            $failures += "$path`tNOTJSON`t$head"
            Write-Host "FAIL (not JSON) $path"
            continue
        }

        [System.IO.File]::WriteAllText($jsonPath, $outText, (New-Object System.Text.UTF8Encoding($false)))
        $ok++
        Write-Host "ok   $jsonName"
    } finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    }
}

# FAILED.txt is rewritten each run from the failures seen across all runs' files: a file
# that now succeeds must not stay listed. Rebuild it from what is missing on disk plus this
# run's failures.
$stillMissing = @()
foreach ($r in $rows) {
    $jsonPath = Join-Path $OutDir (Get-JsonName -Path $r.path -Root $D)
    if (-not (Test-Path -LiteralPath $jsonPath)) { $stillMissing += $r.path }
}

$nl = "`n"
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append("# cadcraft-cli info failures -- card M1-C2").Append($nl)
[void]$sb.Append("# one line per failure: path<TAB>kind<TAB>detail").Append($nl)
foreach ($f in $failures) { [void]$sb.Append($f).Append($nl) }
foreach ($m in $stillMissing) {
    # A file with no JSON and no failure line this run was skipped for a reason we do not
    # have a record of; list it so nothing disappears silently.
    if (-not ($failures | Where-Object { $_.StartsWith($m + "`t") })) {
        [void]$sb.Append($m).Append("`tNOJSON`tno JSON on disk and no failure recorded this run").Append($nl)
    }
}
[System.IO.File]::WriteAllText($failedPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host "succeeded : $ok"
Write-Host "failed    : $fail"
Write-Host "skipped   : $skipped (already had JSON; use -Force to re-run)"
Write-Host "no json   : $($stillMissing.Count)"
Write-Host "failures  : $failedPath"

# The card's check: one JSON per DWG, or a line in FAILED.txt. A drawing with no JSON must
# be named in FAILED.txt, and a sweep where nothing at all succeeded is a broken run, not a
# pass.
$jsonCount = @(Get-ChildItem -LiteralPath $OutDir -Filter '*.json' -File).Count
Write-Host ''
Write-Host "json files: $jsonCount of $($rows.Count) drawings"

if ($ok -eq 0 -and $skipped -eq 0) {
    Write-Error 'no drawing could be read at all - the sweep itself is broken, not the drawings'
    exit 1
}
if ($stillMissing.Count -gt 0) {
    Write-Host "$($stillMissing.Count) drawing(s) have no JSON - see FAILED.txt"
    Write-Host 'PASS M1-C2 (every drawing accounted for: JSON or FAILED.txt)'
    exit 0
}
Write-Host 'PASS M1-C2 (every drawing has a JSON)'
exit 0
