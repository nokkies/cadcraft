# capture-json.ps1 -- cadcraft M4 helper
#
# Runs `info` and `texts` (model + the first paper-space layout) on a generated DWG and writes
# the two JSON files that check-drawing.ps1 reads, into $D\fusion\info and $D\fusion\texts, using
# the same flattened names info-all.ps1 and texts.ps1 use. Lets a generated sheet be checked with
# the same checker as a working drawing.
#
# Writes only inside $D\fusion.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Drawing
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-PSADrawingsRoot {
    foreach ($scope in 'Process', 'User', 'Machine') {
        $v = [Environment]::GetEnvironmentVariable('PSA_DRAWINGS', $scope)
        if (-not [string]::IsNullOrWhiteSpace($v) -and (Test-Path -LiteralPath $v)) { return $v.TrimEnd('\') }
    }
    throw 'PSA_DRAWINGS is not set to an existing folder.'
}

function Resolve-CadcraftCli {
    $cmd = Get-Command 'cadcraft-cli' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $exe = 'C:\Users\ReinachvanNieuwenhui\src\cadcraft\target\release\cadcraft-cli.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    throw 'cadcraft-cli not found.'
}

function Get-ArgumentForNative { param([string]$Value) return '"' + $Value.Replace('"', '""') + '"' }

# Run steps in one invocation, return the last step's JSON (object or array).
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
        if (-not $pi.WaitForExit(120000)) { try { $pi.Kill() } catch { }; return $null }
        if ($pi.ExitCode -ne 0) { return $null }
        $text = [System.IO.File]::ReadAllText($tmpOut)
        $jsonLines = @($text -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') -or $_.Trim().StartsWith('[') })
        if ($jsonLines.Count -eq 0) { return $null }
        try { return ($jsonLines[-1] | ConvertFrom-Json) } catch { return $null }
    } catch { return $null } finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr, $bat -Force -ErrorAction SilentlyContinue
    }
}

$D = Get-PSADrawingsRoot
$cli = Resolve-CadcraftCli
if (-not (Test-Path -LiteralPath $Drawing)) { throw "drawing not found: $Drawing" }

# Flattened name relative to $D (matches info-all.ps1 / texts.ps1).
$rel = ($Drawing -replace [regex]::Escape($D + '\'), '') -replace '\\', '__' -replace '\.dwg$', ''
$infoDir = Join-Path $D 'fusion\info'
$textsDir = Join-Path $D 'fusion\texts'
foreach ($d in @($infoDir, $textsDir)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

# info (CLI subcommand, not a --cmd step).
$bat = [System.IO.Path]::GetTempFileName() + '.cmd'
$line = '"' + $cli + '" info "' + $Drawing + '"'
[System.IO.File]::WriteAllText($bat, "@echo off`r`n$line`r`n", (New-Object System.Text.ASCIIEncoding))
$pi = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', (Get-ArgumentForNative -Value $bat)) -NoNewWindow -PassThru
$stdoutFile = [System.IO.Path]::GetTempFileName()
$pi2 = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', (Get-ArgumentForNative -Value $bat)) -NoNewWindow -PassThru -RedirectStandardOutput $stdoutFile
if (-not $pi2.WaitForExit(120000)) { try { $pi2.Kill() } catch { } }
$infoText = [System.IO.File]::ReadAllText($stdoutFile)
Remove-Item -LiteralPath $bat, $stdoutFile -Force -ErrorAction SilentlyContinue
[System.IO.File]::WriteAllText((Join-Path $infoDir ($rel + '.dwg.json')), $infoText, (New-Object System.Text.UTF8Encoding($false)))

# model texts
$model = Invoke-CliSteps -Cli $cli -Drawing $Drawing -Steps @('texts {"limit":1000}')

# first paper-space layout name
$ll = Invoke-CliSteps -Cli $cli -Drawing $Drawing -Steps @('layout.list {}')
$layoutName = ''
if ($null -ne $ll) {
    $lay = @($ll | ForEach-Object { [string]$_.name } | Where-Object { $_ -and $_ -ne 'Model' })
    if ($lay.Count -gt 0) { $layoutName = $lay[0] }
}
$paper = $null
if ($layoutName) {
    $paper = Invoke-CliSteps -Cli $cli -Drawing $Drawing -Steps @(
        ('layout.set {"name":"' + $layoutName + '"}'),
        'texts {"limit":1000}'
    )
}

$combined = [ordered]@{
    drawing = (Split-Path -Leaf $Drawing)
    path    = $Drawing
    layout  = $layoutName
    model   = $model
    paper   = $paper
} | ConvertTo-Json -Depth 12 -Compress
[System.IO.File]::WriteAllText((Join-Path $textsDir ($rel + '.json')), $combined, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "captured info + texts for $Drawing (layout=$layoutName)"
exit 0
