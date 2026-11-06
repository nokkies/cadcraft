# gen-lst-data.ps1 -- build a LIST / SCHEDULE sheet (an A1 table) from a CSV.
#
# The producer for the register's LST discipline. A list sheet is not a diagram and not a Word
# document: the house issues cable schedules, I/O lists and IP schedules as ruled tables on an A1,
# columns of text with a header row and a title block. That is exactly what a CSV already is, so this
# generator lays a CSV out as a ruled table on the template sheet, paginating across sheets when the
# rows do not fit one A1.
#
# It is deliberately general: the columns to draw, their widths and their header captions are passed
# in (or defaulted per list kind), so the same generator produces the I/O list, the cable schedule and
# the IP schedule. What it never does is invent a value -- a blank cell stays blank.
#
# Inputs (all read, none written):
#   -Template    the PSA blank sheet (A1 BORDER, A1 TITLE TEXT, layers, styles, content viewport).
#   -SourceCsv   the data: one row per line item.
#   -OutDwg      where to write the sheet.
#   -Title       the heading printed on the sheet.
#   -Columns     comma-separated source column names to draw, in order. Defaults per -Kind.
#   -Headers     comma-separated captions for those columns. Defaults to the column names.
#   -Kind        io | cable | ip | generic -- picks default columns and column widths.
#   -DrawingNumber, -ProjectNumber, -Scope1, -Scale, -DrawnBy, -DrawnDate   title-block fields.
#
# Output: a cadcraft .scr, the generated DWG, and a .run.log beside it. Prints the row count drawn.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Template,
    [Parameter(Mandatory = $true)][string]$OutDwg,
    [Parameter(Mandatory = $true)][string]$SourceCsv,
    [string]$Title = 'SCHEDULE',
    [string]$Kind = 'generic',
    [string]$Columns = '',
    [string]$Headers = '',
    [string]$DrawingNumber = '',
    [string]$ScrPath,
    [string]$ProjectNumber = '',
    [string]$Scope1 = '',
    [string]$Scale = 'NTS',
    [string]$DrawnBy = 'PSA FUSION',
    [string]$DrawnDate = '',
    [string]$LayoutName = '',
    [int]$RowOffset = 0,
    [switch]$FitAll
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Resolve-CadcraftCli {
    $cmd = Get-Command 'cadcraft-cli' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $here = Split-Path -Parent $PSScriptRoot
    $exe = Join-Path $here '..\target\release\cadcraft-cli.exe'
    if (Test-Path -LiteralPath $exe) { return (Resolve-Path -LiteralPath $exe).Path }
    throw 'cadcraft-cli not found.'
}
function Get-ArgumentForNative([string]$Value) { return '"' + $Value.Replace('"', '""') + '"' }
function ConvertTo-JsonStringValue([string]$Value) {
    if ($null -eq $Value) { return '""' }
    $esc = $Value.Replace('\', '\\').Replace('"', '\"')
    $esc = $esc -replace '\r', ' '
    $esc = $esc -replace "`n", ' '
    return '"' + $esc + '"'
}
function JNum($v) { return ([double]$v).ToString([System.Globalization.CultureInfo]::InvariantCulture) }
function PropStr($obj, [string]$name) {
    if ($null -eq $obj) { return '' }
    if ($obj -is [System.Management.Automation.PSCustomObject] -and -not ($obj.PSObject.Properties.Name -contains $name)) { return '' }
    try { $v = $obj.$name } catch { return '' }
    if ($null -eq $v) { return '' }
    return [string]$v
}
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
        if (-not $pi.WaitForExit(180000)) { try { $pi.Kill() } catch { } ; return $null }
        if ($pi.ExitCode -ne 0) { return $null }
        $text = [System.IO.File]::ReadAllText($tmpOut)
        $jsonLines = @($text -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') -or $_.Trim().StartsWith('[') })
        if ($jsonLines.Count -eq 0) { return $null }
        try { return ($jsonLines[-1] | ConvertFrom-Json) } catch { return $null }
    } catch { return $null } finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr, $bat -Force -ErrorAction SilentlyContinue
    }
}

foreach ($p in @($Template, $SourceCsv)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "no such file: $p" }
}
$cli = Resolve-CadcraftCli

# --- the data ----------------------------------------------------------------------
$rows = @(Import-Csv -LiteralPath $SourceCsv)

# Column set and widths per kind. Widths are paper units on the A1 (the sheet content area is about
# 780 wide inside the border); they sum to under that. Chosen from the actual field lengths so a value
# is not cut off mid-word.
$colWidths = @{}
if (-not $Columns) {
    switch ($Kind) {
        'io' {
            $Columns = 'Station,Tag,Address,Dir,WireNo,TerminalNo,CableNo,FieldDevice,Condition'
            $colWidths = @{ Station=70; Tag=150; Address=55; Dir=28; WireNo=55; TerminalNo=55; CableNo=90; FieldDevice=170; Condition=90 }
        }
        'cable' {
            $Columns = 'Station,CableNo,From,To,FieldDevice,WireNo,Condition'
            $colWidths = @{ Station=70; CableNo=110; From=150; To=150; FieldDevice=180; WireNo=60; Condition=100 }
        }
        'ip' {
            $Columns = 'Station,Device,Part,IP,Note'
            $colWidths = @{ Station=90; Device=160; Part=140; IP=110; Note=220 }
        }
        default {
            $first = $rows[0]
            if ($null -ne $first) { $Columns = (($first.PSObject.Properties.Name) -join ',') }
        }
    }
}
$cols = @($Columns -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Headers) {
    $hdrs = @($Headers -split ',' | ForEach-Object { $_.Trim() })
} else {
    $hdrs = @($cols | ForEach-Object { $_ })
}
# Default widths when none were set for a column (generic kind): share the content width evenly.
$totalW = 0.0
foreach ($c in $cols) { if ($colWidths.ContainsKey($c)) { $totalW += [double]$colWidths[$c] } }
if ($totalW -le 0) {
    $each = [math]::Floor(760.0 / [math]::Max(1, $cols.Count))
    foreach ($c in $cols) { $colWidths[$c] = $each }
}

# --- layout constants (paper units on the A1) --------------------------------------
$originX = 30.0
$topY = 540.0            # first header row baseline
$rowPitch = 6.0
$hSmall = 2.5; $hLabel = 3.5; $hHead = 5.0
$styleName = 'isocp2'
# how many data rows fit before the bottom margin (title block occupies the lower right)
$bottomY = 60.0
$rowsPerPage = [math]::Floor(($topY - $bottomY) / $rowPitch)
if ($FitAll) { $rowsPerPage = [int]::MaxValue }   # caller wants one long sheet, no pagination

# --- build the script --------------------------------------------------------------
$lines = New-Object System.Collections.Generic.List[string]
$curLayer = ''
function Emit-Layer([string]$Name) {
    if ($Name -and $Name -ne $script:curLayer) {
        $script:lines.Add('layer.current {"name":' + (ConvertTo-JsonStringValue -Value $Name) + '}')
        $script:curLayer = $Name
    }
}
function Emit-Line([double]$x1, [double]$y1, [double]$x2, [double]$y2, [string]$Layer) {
    Emit-Layer $Layer
    $script:lines.Add('line {"points":[[' + (JNum $x1) + ',' + (JNum $y1) + '],[' + (JNum $x2) + ',' + (JNum $y2) + ']]}')
}
function Emit-Text([double]$x, [double]$y, [string]$Text, [double]$Height, [string]$Layer) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    Emit-Layer $Layer
    $script:lines.Add('style.current {"name":' + (ConvertTo-JsonStringValue -Value $styleName) + '}')
    $script:lines.Add('text {"at":[' + (JNum $x) + ',' + (JNum $y) + '],"text":' + (ConvertTo-JsonStringValue -Value $Text) + ',"height":' + (JNum $Height) + '}')
}

# --- title block -------------------------------------------------------------------
$tplLayout = $LayoutName
$tplTbHandle = ''
$tplVpHandle = ''
if (-not $tplLayout) {
    $tll = Invoke-CliSteps -Cli $cli -Drawing $Template -Steps @('layout.list {}')
    if ($null -ne $tll) {
        $lay = @($tll | ForEach-Object { [string]$_.name } | Where-Object { $_ -and $_ -ne 'Model' })
        if ($lay.Count -gt 0) { $tplLayout = $lay[0] }
    }
}
if ($tplLayout) {
    $tins = Invoke-CliSteps -Cli $cli -Drawing $Template -Steps @(
        ('layout.set {"name":' + (ConvertTo-JsonStringValue -Value $tplLayout) + '}'),
        'entities {"type":"Insert","limit":200}')
    if ($null -ne $tins) {
        foreach ($e in $tins.entities) {
            if ([string]$e.geometry.block -eq 'A1 TITLE TEXT') { $tplTbHandle = [string]$e.handle; break }
        }
    }
    $tvps = Invoke-CliSteps -Cli $cli -Drawing $Template -Steps @(
        ('layout.set {"name":' + (ConvertTo-JsonStringValue -Value $tplLayout) + '}'),
        'entities {"type":"Viewport","limit":50}')
    if ($null -ne $tvps) {
        $best = -1.0
        foreach ($e in $tvps.entities) {
            $g = $e.geometry
            $vid = -1
            if ($g.PSObject.Properties.Name -contains 'id') { $vid = [int]$g.id }
            if ($vid -lt 2) { continue }
            $w = 0.0; $h = 0.0
            if ($g.PSObject.Properties.Name -contains 'width') { $w = [double]$g.width }
            if ($g.PSObject.Properties.Name -contains 'height') { $h = [double]$g.height }
            if (($w * $h) -gt $best) { $best = $w * $h; $tplVpHandle = [string]$e.handle }
        }
    }
}
$attribs = [ordered]@{}
if ($ProjectNumber) { $attribs['PROJECTNO.'] = $ProjectNumber }
if ($Scope1) { $attribs['SCOPE1'] = $Scope1 }
$attribs['DWG_AREA'] = $Title
$attribs['DWG_TITLE'] = 'PSA ENGINEERING'
if ($DrawingNumber) { $attribs['DWG_NO'] = $DrawingNumber }
$attribs['REV'] = 'A'
$attribs['SCALE'] = $Scale
$attribs['CLIENTNO.'] = $ProjectNumber
if ($DrawnBy) { $attribs['BY7'] = $DrawnBy }
if ($DrawnDate) { $attribs['DATE7'] = $DrawnDate }
$attribJson = ($attribs.Keys | ForEach-Object {
    (ConvertTo-JsonStringValue -Value $_) + ':' + (ConvertTo-JsonStringValue -Value $attribs[$_])
}) -join ','
if ($tplLayout -and $tplTbHandle) {
    $lines.Add('layout.set {"name":' + (ConvertTo-JsonStringValue -Value $tplLayout) + '}')
    $lines.Add('attedit {"handle":' + (ConvertTo-JsonStringValue -Value $tplTbHandle) + ',"values":{' + $attribJson + '}}')
    $lines.Add('layout.set {"name":"Model"}')
} else {
    Write-Warning 'template title block not found; inserting into model space'
    $lines.Add('insert {"name":"A1 TITLE TEXT","at":[0,0],"attribs":{' + $attribJson + '}}')
    $lines.Add('insert {"name":"A1 BORDER","at":[0,0]}')
}

# --- the table ---------------------------------------------------------------------
# Column x positions.
$colX = @()
$x = $originX
foreach ($c in $cols) { $colX += $x; $x += [double]$colWidths[$c] }
$tableW = $x - $originX

function Emit-Header([double]$y) {
    # header captions + a rule under them
    for ($i = 0; $i -lt $cols.Count; $i++) {
        Emit-Text ($colX[$i] + 1.5) $y $hdrs[$i] $hLabel '2T'
    }
    Emit-Line $originX ($y - 2.0) ($originX + $tableW) ($y - 2.0) '2C'
    # vertical column rules through the header
    foreach ($cx in $colX) { Emit-Line $cx ($y + 5.0) $cx ($y - 2.0) '2C' }
    Emit-Line ($originX + $tableW) ($y + 5.0) ($originX + $tableW) ($y - 2.0) '2C'
}

# heading
Emit-Text $originX ($topY + 14.0) $Title $hHead '5T' 'L'
Emit-Header ($topY + 6.0)

$y = $topY
$drawn = 0
# Draw exactly one page: the rows from RowOffset up to the page limit. A single DWG has one model
# space, so a list longer than one A1 is issued as several sheets, one run per page (the caller sets
# -RowOffset); this generator does not fake a page break inside one file.
$pageEnd = $rows.Count
if (-not $FitAll) {
    $lim = $RowOffset + $rowsPerPage
    if ($lim -lt $pageEnd) { $pageEnd = $lim }
}
for ($r = $RowOffset; $r -lt $pageEnd; $r++) {
    $row = $rows[$r]
    for ($i = 0; $i -lt $cols.Count; $i++) {
        $val = PropStr $row $cols[$i]
        # a cell longer than its column is cut on a word boundary so it does not run into the next
        $w = [double]$colWidths[$cols[$i]]
        $maxChars = [math]::Max(3, [math]::Floor(($w - 3.0) / 1.7))
        if ($val.Length -gt $maxChars) {
            $cut = $val.Substring(0, $maxChars)
            $sp = $cut.LastIndexOf(' ')
            if ($sp -ge 3) { $cut = $cut.Substring(0, $sp) }
            $val = $cut
        }
        Emit-Text ($colX[$i] + 1.5) $y $val $hSmall '2T'
    }
    $y -= $rowPitch
    $drawn++
}
# final bottom rule
Emit-Line $originX ($y + 3.0) ($originX + $tableW) ($y + 3.0) '2C'
# left and right table edges
Emit-Line $originX ($topY + 6.0) $originX ($y + 3.0) '2C'
Emit-Line ($originX + $tableW) ($topY + 6.0) ($originX + $tableW) ($y + 3.0) '2C'
# column rules down the body
foreach ($cx in $colX) { Emit-Line $cx ($topY + 1.0) $cx ($y + 3.0) '2C' }

# the honest note: if rows overflowed one page, say how many pages this is
$totalPages = 1
if ($rowsPerPage -gt 0 -and $rows.Count -gt $rowsPerPage) { $totalPages = [math]::Ceiling($rows.Count / [double]$rowsPerPage) }
$sheetNo = 1
if ($rowsPerPage -gt 0) { $sheetNo = [math]::Floor($RowOffset / $rowsPerPage) + 1 }
if ($totalPages -gt 1) {
    Emit-Text $originX ($y - 6.0) ("SHEET $sheetNo OF $totalPages - $drawn ROWS ON THIS SHEET, $totalPages SHEETS FOR ALL $($rows.Count) ROWS") $hLabel '5T' 'L'
}

# --- draft stamps (paper space) ----------------------------------------------------
if ($tplLayout) {
    $lines.Add('layout.set {"name":' + (ConvertTo-JsonStringValue -Value $tplLayout) + '}')
}
$lines.Add('layer.current {"name":"Preliminary Not For Construction"}')
$lines.Add('style {"name":"Romans"}')
$lines.Add('text {"at":[768,72],"text":"PRELIMINARY","height":4}')
$lines.Add('text {"at":[753,66],"text":"NOT FOR CONSTRUCTION","height":4}')

# --- frame the content viewport ----------------------------------------------------
if ($tplLayout -and $tplVpHandle) {
    $lines.Add('layout.set {"name":' + (ConvertTo-JsonStringValue -Value $tplLayout) + '}')
    $lines.Add('viewport.set {"handle":' + (ConvertTo-JsonStringValue -Value $tplVpHandle) + ',"locked":false}')
    $lines.Add('viewport.set {"handle":' + (ConvertTo-JsonStringValue -Value $tplVpHandle) + ',"center":[420,300],"viewHeight":560}')
    $lines.Add('viewport.set {"handle":' + (ConvertTo-JsonStringValue -Value $tplVpHandle) + ',"locked":true}')
    $lines.Add('layout.set {"name":"Model"}')
}
$lines.Add('saveas {"path":' + (ConvertTo-JsonStringValue -Value $OutDwg) + ',"version":"2018"}')

# --- write and run -----------------------------------------------------------------
$scr = $ScrPath
if (-not $scr) { $scr = [System.IO.Path]::ChangeExtension($OutDwg, '.scr') }
$scrDir = Split-Path -Parent $scr
if ($scrDir -and -not (Test-Path -LiteralPath $scrDir)) { New-Item -ItemType Directory -Force -Path $scrDir | Out-Null }
[System.IO.File]::WriteAllLines($scr, $lines, (New-Object System.Text.ASCIIEncoding))
$outParent = Split-Path -Parent $OutDwg
if ($outParent -and -not (Test-Path -LiteralPath $outParent)) { New-Item -ItemType Directory -Force -Path $outParent | Out-Null }
if (Test-Path -LiteralPath $OutDwg) { Remove-Item -LiteralPath $OutDwg -Force }

$log = [System.IO.Path]::ChangeExtension($OutDwg, '.run.log')
$exit = 1
$bat = [System.IO.Path]::GetTempFileName() + '.cmd'
$tmpOut = [System.IO.Path]::GetTempFileName()
$tmpErr = [System.IO.Path]::GetTempFileName()
$runLine = '"' + $cli + '" run "' + $Template + '" --script-file "' + $scr + '"'
[System.IO.File]::WriteAllText($bat, "@echo off`r`n$runLine`r`n", (New-Object System.Text.ASCIIEncoding))
try {
    $p = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', (Get-ArgumentForNative -Value $bat)) `
            -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
    if (-not $p.WaitForExit(300000)) { try { $p.Kill() } catch { } }
    $exit = $p.ExitCode
} finally {
    try {
        $runLog = [System.IO.File]::ReadAllText($tmpOut) + [System.IO.File]::ReadAllText($tmpErr)
        [System.IO.File]::WriteAllText($log, $runLog)
    } catch { }
    Remove-Item -LiteralPath $bat, $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
}
$bytes = 0
if (Test-Path -LiteralPath $OutDwg) { $bytes = (Get-Item -LiteralPath $OutDwg).Length }
Write-Host ("{0}  kind={1}  rows={2}  cols={3}  pages={4}  bytes={5}  exit={6}" -f `
        $DrawingNumber, $Kind, $drawn, $cols.Count, $totalPages, $bytes, $exit)
if ($exit -ne 0 -or $bytes -eq 0) { exit 1 }
exit 0
