# compare-info.ps1 -- cadcraft card M1-C3
#
# Compares what cadcraft read (the $D\fusion\info\*.json files from card M1-C2) against the
# reference numbers in $D\fusion\expected.csv (what the ACadSharp reader sees), and prints
# one line per drawing:
#
#   <file>  entities <read>/<expected>  layers <read>/<expected>  blocks <read>/<expected>  layouts <ok|MISSING: name>
#
# Anything cadcraft reads FEWER of than expected is a LOSS, and every loss is an M5 card.
# Reading MORE than expected is noted as MORE (cadcraft counting something the reference
# reader does not) -- not a loss, but not silently ignored either.
#
# Two deliberate counting rules, both because the two readers count differently:
#
#  * entities: expected.csv holds `entities_model`, the count in MODEL SPACE. cadcraft's
#    `info` reports `entityCount` for the space it currently has open, and a DWG file order
#    can leave a paper space layout current after load. So the comparison takes the best of
#    the model-space count (when cadcraft reports one) and the current-space count, and the
#    line says which. A layout left current is reported as a finding, not a loss.
#  * layouts: expected.csv lists "Model" among the layouts. cadcraft reports model space
#    separately (`space`) and lists only paper space layouts in `layouts`. "Model" is
#    therefore satisfied by cadcraft having a model space at all.
#
# Writes $D\fusion\compare-info.txt. Reads only, apart from that one output file.

[CmdletBinding()]
param(
    [string]$InfoDir,       # default $D\fusion\info
    [string]$ExpectedCsv,   # default $D\fusion\expected.csv
    [string]$Inventory,     # default $D\fusion\inventory.csv
    [string]$OutFile        # default $D\fusion\compare-info.txt
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

# Same flattening rule as info-all.ps1 -- keep the two in step.
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
    $rel = $rel.TrimEnd('.', ' ')
    return ($rel + '.json')
}

$D = Get-PSADrawingsRoot

function Resolve-CadcraftCli {
    $cmd = Get-Command 'cadcraft-cli' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $exe = 'C:\Users\ReinachvanNieuwenhui\src\cadcraft\target\release\cadcraft-cli.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    return $null
}

function Get-ArgumentForNative {
    # Start-Process does not quote arguments containing spaces; quote per CommandLineToArgvW.
    param([string]$Value)
    return '"' + $Value.Replace('"', '""') + '"'
}

# Ask the engine for EVERY block record (blocks.list does not filter '*' names the way the
# info report does). Returns $null when the CLI is unavailable or the call fails, in which
# case the caller falls back to the filtered info count and says so.
function Invoke-BlocksList {
    param([string]$Path)
    $cli = $script:CliPath
    if ([string]::IsNullOrWhiteSpace($cli)) { return $null }
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    try {
        $pi = Start-Process -FilePath $cli -ArgumentList @('run', (Get-ArgumentForNative -Value $Path), '--cmd', (Get-ArgumentForNative -Value 'blocks.list {}')) `
                -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        if (-not $pi.WaitForExit(120000)) { try { $pi.Kill() } catch { }; return $null }
        if ($pi.ExitCode -ne 0) { return $null }
        $text = [System.IO.File]::ReadAllText($tmpOut)
        try { $parsed = $text | ConvertFrom-Json } catch { return $null }
        if ($null -eq $parsed.blocks) { return $null }
        $names = @($parsed.blocks | ForEach-Object { [string]$_.name })
        return [pscustomobject]@{
            total  = $names.Count
            hidden = @($names | Where-Object { $_.StartsWith('*') }).Count
        }
    } catch {
        return $null
    } finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    }
}

$script:CliPath = Resolve-CadcraftCli
if ([string]::IsNullOrWhiteSpace($InfoDir)) { $InfoDir = Join-Path $D 'fusion\info' }
if ([string]::IsNullOrWhiteSpace($ExpectedCsv)) { $ExpectedCsv = Join-Path $D 'fusion\expected.csv' }
if ([string]::IsNullOrWhiteSpace($Inventory)) { $Inventory = Join-Path $D 'fusion\inventory.csv' }
if ([string]::IsNullOrWhiteSpace($OutFile)) { $OutFile = Join-Path $D 'fusion\compare-info.txt' }

foreach ($p in @(@($InfoDir, $ExpectedCsv, $Inventory))) {
    if (-not (Test-Path -LiteralPath $p)) { throw "missing input: $p" }
}

# expected.csv is keyed by file name. Several drawings share a file name across folders, so
# a name maps to a LIST of expectations and each is used once, in path order.
$expectedByName = @{}
foreach ($e in @(Import-Csv -LiteralPath $ExpectedCsv)) {
    $name = $e.file
    if (-not $expectedByName.ContainsKey($name)) { $expectedByName[$name] = New-Object System.Collections.Generic.List[object] }
    $expectedByName[$name].Add($e)
}

$rows = @(Import-Csv -LiteralPath $Inventory)
$nl = "`n"
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append("# cadcraft info vs ACadSharp reference -- card M1-C3").Append($nl)
[void]$sb.Append("# LOSS means cadcraft read fewer than the reference reader saw; each loss is an M5 card.").Append($nl)
[void]$sb.Append("# MORE means cadcraft read more (a counting difference, not a loss).").Append($nl)
[void]$sb.Append($nl)

$lines = New-Object System.Collections.Generic.List[string]
$lossCount = 0
$moreCount = 0
$noExpected = 0
$noJson = 0
$refFailed = 0
$findings = New-Object System.Collections.Generic.List[string]

foreach ($r in $rows) {
    $path = $r.path
    $name = Split-Path -Leaf $path
    $jsonPath = Join-Path $InfoDir (Get-JsonName -Path $path -Root $D)

    if (-not (Test-Path -LiteralPath $jsonPath)) {
        $noJson++
        $lines.Add("$name  NO JSON (card M1-C2 did not read this file)")
        continue
    }

    $exp = $null
    if ($expectedByName.ContainsKey($name) -and $expectedByName[$name].Count -gt 0) {
        $exp = $expectedByName[$name][0]
        $expectedByName[$name].RemoveAt(0)
    }

    if ($null -eq $exp) {
        $noExpected++
        $lines.Add("$name  no expected row (nothing to compare against)")
        continue
    }

    # A row whose expected count is ERROR means the reference reader could not open the file.
    if ($exp.entities_model -eq 'ERROR' -or $exp.entities_model -notmatch '^\d+$') {
        $refFailed++
        $lines.Add("$name  entities n/a  layers n/a  blocks n/a  layouts ok  REFERENCE READER FAILED ($($exp.layers)) - cadcraft read it: WIN")
        continue
    }

    $j = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json

    # --- entities ------------------------------------------------------------------
    # StrictMode 3 throws on a property the object does not have, so probe the JSON's
    # property names instead of touching a key that may be absent.
    $jProps = @($j.PSObject.Properties.Name)
    $entRead = [int]$j.entityCount
    $entBasis = 'current'
    # If cadcraft has a paper space layout current, its entityCount is that layout's, not
    # model space. Look for a model-space count in the JSON before blaming the reader.
    if ($jProps -contains 'entities_model') { $entRead = [int]$j.entities_model; $entBasis = 'model' }
    elseif ([string]$j.space -ne 'Model') {
        $findings.Add("$name : cadcraft reports space=$($j.space) and no model-space count; compared entityCount ($entRead) against entities_model")
    }
    $entExp = [int]$exp.entities_model

    # --- layers --------------------------------------------------------------------
    $layRead = @($j.layers).Count
    $layExp = [int]$exp.layers

    # --- blocks --------------------------------------------------------------------
    # `info` deliberately hides block records whose name starts with '*' (AutoCAD's internal
    # blocks: the *D... dimension blocks AutoCAD generates per dimension, *Model_Space,
    # *Paper_Space, anonymous *U... blocks). `blocks.list` does not filter, so it is asked
    # too -- that is the number to compare against the reference reader, which counts every
    # record. The engine is invoked through the CLI, once per drawing.
    $blkRead = @($j.blocks).Count
    $blkAll = $blkRead
    $blkHidden = 0
    $blkProbe = 'info'
    if (-not [string]::IsNullOrWhiteSpace($script:CliPath)) {
        $probe = Invoke-BlocksList -Path $path
        if ($null -ne $probe) {
            $blkAll = $probe.total
            $blkHidden = $probe.hidden
            $blkProbe = 'blocks.list'
        }
    }
    $blkExp = [int]$exp.blocks
    $blkRead = $blkAll

    # --- layouts -------------------------------------------------------------------
    $expLayouts = @()
    if (-not [string]::IsNullOrWhiteSpace($exp.layouts)) { $expLayouts = @($exp.layouts -split '\|' | Where-Object { $_ -ne '' }) }
    $readLayouts = @()
    if ($jProps -contains 'layouts') { $readLayouts = @($j.layouts | ForEach-Object { [string]$_ }) }
    $missing = @()
    foreach ($want in $expLayouts) {
        if ($want -eq 'Model') {
            # cadcraft keeps model space outside the `layouts` list; it has one if `space`
            # names a space at all.
            if ([string]::IsNullOrWhiteSpace([string]$j.space)) { $missing += $want }
            continue
        }
        if ($readLayouts -notcontains $want) { $missing += $want }
    }

    $parts = New-Object System.Collections.Generic.List[string]
    $isLoss = $false
    $isMore = $false

    $entFlag = ''
    if ($entRead -lt $entExp) { $entFlag = ' LOSS'; $isLoss = $true } elseif ($entRead -gt $entExp) { $entFlag = ' MORE'; $isMore = $true }
    $layFlag = ''
    if ($layRead -lt $layExp) { $layFlag = ' LOSS'; $isLoss = $true } elseif ($layRead -gt $layExp) { $layFlag = ' MORE'; $isMore = $true }
    $blkFlag = ''
    if ($blkRead -lt $blkExp) { $blkFlag = ' LOSS'; $isLoss = $true } elseif ($blkRead -gt $blkExp) { $blkFlag = ' MORE'; $isMore = $true }

    $layPart = if ($missing.Count -eq 0) { 'ok' } else { 'MISSING: ' + ($missing -join ',') }
    if ($missing.Count -gt 0) { $isLoss = $true }

    $line = '{0}  entities {1}/{2}{3}  layers {4}/{5}{6}  blocks {7}/{8}{9}  layouts <{10}>' -f `
        $name, $entRead, $entExp, $entFlag, $layRead, $layExp, $layFlag, $blkRead, $blkExp, $blkFlag, $layPart
    if ($entBasis -ne 'current') { $line += "  [entities from $entBasis space]" }
    if ($blkProbe -eq 'blocks.list' -and $blkHidden -gt 0) { $line += "  [$blkHidden internal * block records]" }
    if ($isLoss) { $line += '  => LOSS' } elseif ($isMore) { $line += '  => more than expected' }
    $lines.Add($line)
    if ($isLoss) { $lossCount++ }
    if ($isMore -and -not $isLoss) { $moreCount++ }
}

foreach ($l in $lines) { [void]$sb.Append($l).Append($nl) }
[void]$sb.Append($nl)
[void]$sb.Append("# drawings compared      : $($lines.Count)").Append($nl)
[void]$sb.Append("# drawings with a LOSS   : $lossCount").Append($nl)
[void]$sb.Append("# drawings reading MORE  : $moreCount").Append($nl)
[void]$sb.Append("# reference reader failed: $refFailed (cadcraft read them anyway)").Append($nl)
[void]$sb.Append("# no expected row        : $noExpected").Append($nl)
[void]$sb.Append("# no info JSON           : $noJson").Append($nl)
if ($findings.Count -gt 0) {
    [void]$sb.Append($nl).Append('# findings (counting differences, not losses):').Append($nl)
    foreach ($f in $findings) { [void]$sb.Append('#   ').Append($f).Append($nl) }
}

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

foreach ($l in $lines) { Write-Host $l }
Write-Host ''
Write-Host "wrote $OutFile"
Write-Host "compared $($lines.Count): $lossCount with a loss, $moreCount reading more, $refFailed where the reference reader failed, $noExpected without an expected row, $noJson without a JSON"

# The card's check: the script runs over every drawing without error and the output is saved.
if ($noJson -gt 0) { Write-Error "$noJson drawing(s) have no info JSON; run card M1-C2 first"; exit 1 }
if ($lines.Count -ne $rows.Count) { Write-Error "compared $($lines.Count) of $($rows.Count) drawings"; exit 1 }
Write-Host 'PASS M1-C3'
exit 0
