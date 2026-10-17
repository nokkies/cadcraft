# run-step.ps1 -- cadcraft helper
#
# Runs one or more --cmd steps against a drawing through a generated .cmd wrapper (the quoting
# that survives PowerShell -> cmd -> the native exe), and prints the LAST step's JSON to stdout.
# Stops me re-deriving the --cmd escaping in every inline test.
#
#   run-step.ps1 <drawing> <step> [<step> ...]
#
# Each step is passed as a separate argument in its plain JSON form, e.g.
#   run-step.ps1 file.dwg 'texts {"limit":2000}'
#   run-step.ps1 file.dwg 'layout.set {"name":"TMD"}' 'entities {"limit":2000}'

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Drawing,
    [Parameter(Mandatory = $true, Position = 1, ValueFromRemainingArguments = $true)][string[]]$Steps
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Resolve-CadcraftCli {
    $cmd = Get-Command 'cadcraft-cli' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $exe = 'C:\Users\ReinachvanNieuwenhui\src\cadcraft\target\release\cadcraft-cli.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    throw 'cadcraft-cli not found.'
}

$cli = Resolve-CadcraftCli
$argPart = ''
foreach ($s in $Steps) { $argPart += ' --cmd "' + $s.Replace('"', '\"') + '"' }
$line = '"' + $cli + '" run "' + $Drawing + '"' + $argPart
$bat = [System.IO.Path]::GetTempFileName() + '.cmd'
[System.IO.File]::WriteAllText($bat, "@echo off`r`n$line`r`n", (New-Object System.Text.ASCIIEncoding))
$batQ = '"' + $bat.Replace('"', '""') + '"'
$outFile = [System.IO.Path]::GetTempFileName()
$pi = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', $batQ) -NoNewWindow -PassThru -RedirectStandardOutput $outFile
if (-not $pi.WaitForExit(120000)) { try { $pi.Kill() } catch { } }
$text = ''
if (Test-Path -LiteralPath $outFile) { $text = [System.IO.File]::ReadAllText($outFile); Remove-Item -LiteralPath $outFile -Force }
Remove-Item -LiteralPath $bat -Force -ErrorAction SilentlyContinue
# Print only the JSON lines (skip any stderr noise already excluded by redirect).
foreach ($l in ($text -split "`r?`n")) { if ($l.Trim().StartsWith('{') -or $l.Trim().StartsWith('[')) { Write-Output $l } }
