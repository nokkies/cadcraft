# sheets-plan.ps1 -- turn the project document register into a sheet plan.
#
# The register is the master list of every drawing the job must produce, with its exact title.
# The handover is explicit: "The register on the server is the master; re-read it before starting.
# Do not edit it." So this script READS the dumped register CSV and emits one row per drawing the
# generator has to make, with the facts a generator needs:
#
#   number      the drawing number (NNNN-IC-TMD-001)
#   filename    number + "_" + revision + ".dwg"
#   discipline  GAD / SCD / TMD
#   title       the register's own title, used verbatim in the title block (DWG_TITLE)
#   station     which PLC panel it belongs to, matched against the panel list
#   card        the card or subject the sheet shows, parsed out of the title
#     ("... , CPU 1, B57 LEVEL 3, SM1221 DI16 (1 OF 3)" -> card "SM1221 DI16", instance 1 of 3)
#   instance / of  which copy of a repeated card this sheet is
#   hours       the register's budgeted hours, so the hours log the handover asks for is automatic
#   source      the the designer drawing it replaces, where the register names one
#
# Card parsing matters because the TMD sheets are one-per-card: the generator has to know which
# physical module a sheet belongs to, and the only place that says so is the title text.
#
# Usage:
#   pwsh -File psa/scripts/sheets-plan.ps1 -RegisterCsv <DOC_REGISTER.csv> `
#        -PanelsCsv <Panels.csv> -OutCsv <sheet-plan.csv> [-Summary]

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RegisterCsv,
    [Parameter(Mandatory = $true)][string]$PanelsCsv,
    [Parameter(Mandatory = $true)][string]$OutCsv,
    # Column names in the panel list that say which I/O source sheet feeds a panel, and how many
    # rows it has. Comma-separated so a caller can pass several spellings.
    [string]$IoSheetColumns = '',
    [string]$IoRowsColumns = '',
    [switch]$Summary
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

foreach ($p in @($RegisterCsv, $PanelsCsv)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "no such file: $p" }
}

# Parse a dumped sheet with ConvertFrom-Csv, then normalise every property name: the source headers
# carry trailing spaces ("Tag ", "Wire No. ", "APPROVED BUDGET  HR"), and two headers differing only
# by spacing would otherwise become two different properties holding one field.
#
# The dumper's first column is the source row marker ("R9"); it is dropped here so column indices
# downstream are not off by one. Dropping it BEFORE parsing (not after) matters: a naive
# split on ',' would break a quoted field containing a comma, and the register's titles are full of
# them ("TERMINATION DIAGRAM, CPU 1, B57 LEVEL 3, ..."). ConvertFrom-Csv handles the quoting; the
# marker column is stripped by rewriting only the header line's first field.
function Import-CsvNormalised([string]$path, [int]$skip = 0) {
    $lines = [System.IO.File]::ReadAllLines($path)
    if ($lines.Count -eq 0) { return @() }
    if ($skip -gt 0) { $lines = $lines[$skip..($lines.Count - 1)] }
    # Replace the header's first cell with a throwaway name, keep every other cell untouched so
    # ConvertFrom-Csv still sees the original quoting on the data rows.
    $hdr = $lines[0]
    $i = $hdr.IndexOf(',')
    if ($i -ge 0) {
        $lines[0] = '_row' + $hdr.Substring($i) + ',_pad'
    } else {
        $lines[0] = '_row,_pad'
    }
    # Data rows keep their marker cell (it never contains a comma), so field counts line up.
    $txt = $lines -join "`n"
    $objs = @(ConvertFrom-Csv -InputObject $txt)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($o in $objs) {
        $d = [ordered]@{}
        foreach ($prop in $o.PSObject.Properties) {
            $k = ([string]$prop.Name).Trim() -replace '\s+', ' '
            if (-not $k -or $k -match '^H\d+$' -or $k -eq '_row' -or $k -eq '_pad') { continue }
            if (-not $d.Contains($k)) { $d[$k] = ([string]$prop.Value).Trim() }
        }
        $out.Add([pscustomobject]$d)
    }
    return $out
}

$panelRows = Import-CsvNormalised -path $PanelsCsv
$IoSheetColumns = @($IoSheetColumns -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$IoRowsColumns = @($IoRowsColumns -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# Resolve one of a row's cells by trying a list of possible column names, so the caller can name
# the columns its own workbook uses instead of this script assuming a client's wording.
function Resolve-PanelColumn($row, [string[]]$candidates) {
    if ($null -eq $row) { return '' }
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        foreach ($p in $row.PSObject.Properties) {
            $n = (([string]$p.Name) -replace '\s+', ' ').Trim()
            if ($n -eq $c) { $v = [string]$p.Value; if ($v) { return $v } }
        }
    }
    return ''
}
$panels = New-Object System.Collections.Generic.List[object]
foreach ($r in $panelRows) {
    $station = [string]$r.'Station'
    $regNo = [string]$r.'Register no.'
    if (-not $station -or -not $regNo) { continue }
    $cards = [string]$r.'Cards to draw (qty x part)'
    # The two "which source sheet feeds this panel" columns are named differently on every job's
    # panel list, so they are passed in rather than hard-coded: a literal column name from one
    # client's workbook is project data, and it would silently read empty on the next.
    $ioSheetCol = Resolve-PanelColumn $r $IoSheetColumns
    $ioRowsCol = Resolve-PanelColumn $r $IoRowsColumns
    $panels.Add([pscustomobject]@{
        Station    = $station
        GaNumber   = $regNo
        PanelType  = [string]$r.'Panel type'
        Existing   = [string]$r.'Existing PLC'
        UsedDI     = [string]$r.'Used DI'
        UsedDO     = [string]$r.'Used DO'
        Sheets     = [string]$r.'Sheets priced'
        Hours      = [string]$r.'Hours priced'
        IoSheet    = $ioSheetCol
        IoRows     = $ioRowsCol
        Cards      = $cards
    })
}

# --- register: find the header row, then the drawing rows -------------------------
# The register is a formatted sheet: title and metadata rows above a header, one row per document.
$regLines = [System.IO.File]::ReadAllLines($RegisterCsv)
$hdrLine = -1
for ($i = 0; $i -lt [math]::Min($regLines.Count, 40); $i++) {
    # The header carries both a document-number column and a title column.
    if ($regLines[$i] -match '(?i)\bdoc' -and $regLines[$i] -match '(?i)title') { $hdrLine = $i; break }
}
if ($hdrLine -lt 0) {
    # Fall back: the row before the first row that holds a drawing number.
    for ($i = 0; $i -lt $regLines.Count; $i++) {
        if ($regLines[$i] -match '\b\d{4}-(IC|EL)-[A-Z]{3}-\d{3}\b') { $hdrLine = [math]::Max(0, $i - 1); break }
    }
}
if ($hdrLine -lt 0) { throw "could not find the register header row in $RegisterCsv" }

$reg = Import-CsvNormalised -path $RegisterCsv -skip $hdrLine

# Column discovery by content, because the register's header cells are sparse and merged.
function Find-Column($rows, [scriptblock]$test, [int]$maxScan = 40) {
    $props = @($rows[0].PSObject.Properties.Name)
    foreach ($p in $props) {
        $hits = 0
        $n = 0
        foreach ($r in $rows) {
            if ($n -ge $maxScan) { break }
            $n++
            $v = [string]$r.$p
            if ($v) {
                try { if (& $test $v) { $hits++ } } catch { }
            }
        }
        if ($hits -ge 3) { return $p }
    }
    return $null
}

# Column resolution: the register's own header name, matched EXACTLY (whitespace-collapsed), and
# only then a content test. Two failure modes this avoids, both measured on the real register:
#   - guessing by content length picked COMMENTS over DOCUMENT TITLE (comments run longer);
#   - a substring match on "DOCUMENT NUMBER" resolved to "PSA DOCUMENT NUMBER", shifting every
#     later column one place so the budget silently read as empty.
function Resolve-Column($rows, [string[]]$nameCandidates, [scriptblock]$contentTest) {
    $props = @($rows[0].PSObject.Properties.Name)
    foreach ($cand in $nameCandidates) {
        $c = ($cand -replace '\s+', ' ').Trim().ToUpperInvariant()
        foreach ($p in $props) {
            if ((($p -replace '\s+', ' ').Trim()).ToUpperInvariant() -eq $c) { return $p }
        }
    }
    if ($null -ne $contentTest) { return Find-Column $rows $contentTest }
    return $null
}

$numberCol = Resolve-Column $reg @('PSA DOCUMENT NUMBER') { param($v) $v -match '^\d{4}-[A-Z]{2}-[A-Z]{3}-\d{3}$' }
if (-not $numberCol) { throw "no document-number column found in the register" }

$titleCol = Resolve-Column $reg @('DOCUMENT TITLE') { $null }
$revCol = Resolve-Column $reg @('REVISION') { param($v) $v -match '^[0-9A-Z]$' }
# ORIGINAL BUDGET HR first: on this register APPROVED BUDGET is empty and the budget sits in the
# original column. Names are matched exactly, so neither can steal the other's match.
$hoursCol = Resolve-Column $reg @('ORIGINAL BUDGET HR', 'APPROVED BUDGET', 'ESTIMATED HRS TO COMPLETE') {
    param($v) $d = 0.0; [double]::TryParse($v, [ref]$d) -and $d -gt 0 -and $d -lt 5000
}
$sourceCol = Resolve-Column $reg @('CLIENT DOCUMENT NUMBER') { param($v) $v -match '^\d{6}-[A-Z]{3}-[A-Z]{2}-' }

# --- station matching -------------------------------------------------------------
# Titles read "TERMINATION DIAGRAM, CPU 1, B57 LEVEL 3, SM1221 DI16 (1 OF 3)". The station is the
# segment after the sheet type; the building follows it. Match against the panel list, longest
# first so "BUS 1" wins over a bare "H1" style prefix.
# $byLength is built after the PQM stations are added, further down, so Match-Station sees them.
function Match-Station([string]$title) {
    $t = $title.ToUpperInvariant()
    foreach ($p in $byLength) {
        $s = $p.Station.ToUpperInvariant()
        # The station sits between commas, or is followed by its building reference ("CPU 1, B57
        # LEVEL 3"). The station itself needs its own group so the tail alternation stays balanced.
        if ($t -match ('(^|,\s*)(' + [regex]::Escape($s) + ')(\s*,|$|\s+B\d)')) { return $p.Station }
    }
    # Loose fallback: the station appears anywhere as its own comma segment.
    foreach ($seg in ($title -split ',')) {
        $s2 = $seg.Trim().ToUpperInvariant()
        foreach ($p in $byLength) { if ($s2 -eq $p.Station.ToUpperInvariant()) { return $p.Station } }
    }
    return ''
}

# Card + instance from the trailing segments of a TMD title.
function Parse-Card([string]$title) {
    $segs = @($title -split ',' | ForEach-Object { $_.Trim() })
    $card = ''
    $inst = 0
    $of = 0
    for ($i = $segs.Count - 1; $i -ge 0; $i--) {
        $s = $segs[$i]
        $m = [regex]::Match($s, '^(.*?)\s*\((\d{1,2})\s*OF\s*(\d{1,2})\)\s*$', 'IgnoreCase')
        if ($m.Success) {
            $card = $m.Groups[1].Value.Trim(); $inst = [int]$m.Groups[2].Value; $of = [int]$m.Groups[3].Value
            break
        }
    }
    if (-not $card) {
        # No "(n of m)": the last segment that is not the sheet type, station or a building ref.
        for ($i = $segs.Count - 1; $i -ge 0; $i--) {
            $s = $segs[$i]
            if (-not $s) { continue }
            if ($s -match '^(TERMINATION DIAGRAM|GENERAL ARRANGEMENT|SCHEMATIC|PANEL SCHEDULE)') { continue }
            if ($s -match '^B\d+\b') { continue }
            if ($s -match '^(LEVEL|BUILDING)') { continue }
            $card = $s; break
        }
    }
    if (-not $card -and $segs.Count -gt 0) { $card = $segs[$segs.Count - 1] }
    if ($inst -eq 0) { $inst = 1; $of = 1 }
    return [pscustomobject]@{ Card = $card; Instance = $inst; Of = $of }
}

# --- stations the register names but the panel list does not ----------------------
# The PQM panels appear only as drawing titles ("TERMINATION DIAGRAM, PQM PANEL B02"). Without an
# entry here they land in the plan with an empty station and no generator can place them.
foreach ($extra in @('PQM PANEL B02', 'PQM PANEL B16')) {
    if (-not ($panels.Station -contains $extra)) {
        $panels.Add([pscustomobject]@{
            Station = $extra; GaNumber = ''; PanelType = 'NEW'; Existing = ''
            UsedDI = ''; UsedDO = ''; Sheets = ''; Hours = ''; AppendixA = ''; AppARows = ''; Cards = ''
        })
    }
}
$byLength = $panels | Sort-Object { -$_.Station.Length }

$plan = New-Object System.Collections.Generic.List[object]
$seen = @{}
foreach ($r in $reg) {
    $num = ([string]$r.$numberCol).Trim()
    # Any PSA document number: NNNN-IC-TMD-001, NNNN-EL-SLD-001, NNNN-PM-REG-003.
    if ($num -notmatch '^(\d{4})-([A-Z]{2})-([A-Z]{3})-(\d{3})$') { continue }
    $title = ''
    if ($titleCol) { $title = ([string]$r.$titleCol).Trim() }
    $rev = 'A'
    if ($revCol) { $v = ([string]$r.$revCol).Trim(); if ($v -match '^[0-9A-Z]$') { $rev = $v } }
    $hours = ''
    if ($hoursCol) { $hours = ([string]$r.$hoursCol).Trim() }
    $source = ''
    if ($sourceCol) { $source = ([string]$r.$sourceCol).Trim() }

    if ($seen.ContainsKey($num)) { continue }   # register repeats a number in a revision block
    $seen[$num] = $true

    $disc = ([regex]::Match($num, '-(IC|EL)-([A-Z]{3})-')).Groups[2].Value
    $station = Match-Station $title
    $pc = Parse-Card $title
    $ga = ''
    foreach ($p in $panels) { if ($p.Station -eq $station) { $ga = $p.GaNumber; break } }

    $plan.Add([pscustomobject]@{
        Number    = $num
        Filename  = ($num + '_' + $rev + '.dwg')
        Discipline = $disc
        Station   = $station
        GaNumber  = $ga
        Card      = $pc.Card
        Instance  = $pc.Instance
        Of        = $pc.Of
        Revision  = $rev
        Title     = $title
        Hours     = $hours
        # The drawing this sheet replaces, where the register names one.
        ReplacedSource = $source
    })
}

$parent = Split-Path -Parent $OutCsv
if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
$plan | Export-Csv -LiteralPath $OutCsv -NoTypeInformation -Encoding UTF8

if ($Summary) {
    Write-Host ("sheets={0}  columns: number={1} title={2} rev={3} hours={4} source={5}" -f `
        $plan.Count, $numberCol, $titleCol, $revCol, $hoursCol, $sourceCol)
    foreach ($g in ($plan | Group-Object Discipline | Sort-Object Name)) {
        Write-Host ("  {0,-4} {1}" -f $g.Name, $g.Count)
    }
    $noStation = @($plan | Where-Object { -not $_.Station })
    Write-Host ("  unmatched station: {0}" -f $noStation.Count)
    foreach ($x in ($noStation | Select-Object -First 8)) { Write-Host ("    {0}  {1}" -f $x.Number, $x.Title) }
    $noCard = @($plan | Where-Object { $_.Discipline -eq 'TMD' -and -not $_.Card })
    Write-Host ("  TMD with no card: {0}" -f $noCard.Count)
    Write-Host "wrote $OutCsv"
}
