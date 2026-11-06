# io-normalise.ps1 -- turn the project I/O list (the I/O list) into one clean signal table.
#
# The I/O list arrives as one worksheet per PLC station, exported from a field audit. Its shape is
# hostile in specific, repeatable ways, and every downstream drawing generator would otherwise have
# to re-discover them. This script finds them ONCE and writes one tidy CSV.
#
# What it fixes, in order of how much each one cost on the first pass:
#
#  1. The address column header is not stable. It is "In Out" on some tabs and "InOut" on others,
#     and it holds the address (I0.0, Q 32.0), not the in/out direction. The direction is the first
#     letter of the address.
#  2. Addresses carry padding inside the value: "I      32.0". Whitespace is removed.
#  3. A title row sits under the header ("P01 Building 1 - NO AS BUILT DOCUMENTS AVAILABLE") with
#     only one cell filled. It is dropped and kept as the station note.
#  4. Notes at the bottom of the tab ("NOTES FOR REPORT", "1. PLC Panel located in MSB"). Dropped
#     from the signal rows, kept as tab notes.
#  5. A row is a signal only when its address parses. Everything else is noise.
#  6. Trailing empty columns mean a row's field list ends early; missing values become empty
#     strings, never a hole in the middle of a record.
#
# Usage:
#   pwsh -File psa/scripts/io-normalise.ps1 -InDir <dir of tab CSVs> -OutFile <signals.csv>
#
# The input CSVs are what xlsx-dump.ps1 writes: column 1 is the source row number (R<n>), the rest
# are the sheet columns. The header row is found by looking for the row containing "Tag" and an
# address-like column, not assumed to be row 1.
#
# Output columns:
#   station, row, tag, address, dir, byte, bit, wire_no, terminal_no, cable_no, field_device,
#   field_name, serial_cable, condition, comments, spare, no_cable, card_hint
#
# `spare` is true when the row's own text says it is spare (a comment or condition naming it), and
# `no_cable` when the cable/wire field literally says no cable is present. Both matter on a
# termination drawing: a spare channel is drawn and labelled SPARE, it is not deleted.
#
# `card_hint` is the channel number the address implies (DI-1..DI-32 style index within the card),
# derived from byte and bit so a generator can group rows into cards.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InDir,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$Stations   # optional comma-separated filter on station name
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InDir)) { throw "no such input folder: $InDir" }

$stationFilter = $null
if ($Stations) {
    $stationFilter = @($Stations -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# A signal address: a direction letter, an optional space run, then byte '.' bit.
# Observed forms: "I0.0", "I      32.0", "Q0.7", "Q      81.7", "IW0", "QW12", "AIW64".
$addrRe = '^([IQA])(W?)(\d{1,3})\.(\d)$'
$wordRe = '^([IQ])(W)(\d{1,3})$'

function Split-Address([string]$raw) {
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $a = ($raw -replace '\s', '').ToUpperInvariant()
    $m = [regex]::Match($a, $addrRe)
    if ($m.Success) {
        return [pscustomobject]@{
            Address = $a
            Dir     = $m.Groups[1].Value
            Byte    = [int]$m.Groups[3].Value
            Bit     = [int]$m.Groups[4].Value
            Word    = $false
        }
    }
    $m = [regex]::Match($a, $wordRe)
    if ($m.Success) {
        return [pscustomobject]@{
            Address = $a; Dir = $m.Groups[1].Value; Byte = [int]$m.Groups[3].Value
            Bit = -1; Word = $true
        }
    }
    return $null
}

# Read one dumped sheet CSV into records. Returns signals plus the tab's prose.
function Read-Tab([string]$csvPath) {
    $allLines = [System.IO.File]::ReadAllLines($csvPath)
    if ($allLines.Count -eq 0) { return $null }

    # Parse every row into a string array (index 0 = the R<n> marker).
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in $allLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # Simple CSV split: the dumper already quoted embedded commas; handle quotes properly.
        $fields = New-Object System.Collections.Generic.List[string]
        $i = 0
        $cur = New-Object System.Text.StringBuilder
        $inQ = $false
        while ($i -lt $line.Length) {
            $ch = $line[$i]
            if ($inQ) {
                if ($ch -eq '"') {
                    if ($i + 1 -lt $line.Length -and $line[$i + 1] -eq '"') { [void]$cur.Append('"'); $i += 2; continue }
                    $inQ = $false; $i++; continue
                }
                [void]$cur.Append($ch); $i++; continue
            }
            if ($ch -eq '"') { $inQ = $true; $i++; continue }
            if ($ch -eq ',') { $fields.Add($cur.ToString()); [void]$cur.Clear(); $i++; continue }
            [void]$cur.Append($ch); $i++
        }
        $fields.Add($cur.ToString())
        $rows.Add([pscustomobject]@{ Row = $fields[0]; Fields = $fields })
    }
    if ($rows.Count -lt 2) { return $null }

    # Find the header row: the one that mentions Tag and an address-ish column.
    $hdrIdx = -1
    for ($r = 0; $r -lt [math]::Min($rows.Count, 8); $r++) {
        $joined = (($rows[$r].Fields | ForEach-Object { $_.Trim().ToLowerInvariant() }) -join '|')
        if ($joined -match 'tag' -and $joined -match 'in\s?out') { $hdrIdx = $r; break }
    }
    if ($hdrIdx -lt 0) { return $null }

    # Map column name -> index. Names are matched on a normalised form so "Wire No. " and
    # "Wire No." land on the same key.
    function Norm([string]$s) {
        $s = $s.Trim().ToLowerInvariant()
        $s = $s -replace '[^a-z0-9]', ''
        return $s
    }
    $colIdx = @{}
    $hdr = $rows[$hdrIdx].Fields
    for ($c = 1; $c -lt $hdr.Count; $c++) {
        $k = Norm $hdr[$c]
        if ($k -and -not $colIdx.ContainsKey($k)) { $colIdx[$k] = $c }
    }
    # Aliases: the address column has been seen as "inout", "inout2", "in out".
    $addrKeys = @('inout', 'inout2', 'inoutaddress', 'address', 'inout1')
    $addrCol = -1
    foreach ($k in $addrKeys) { if ($colIdx.ContainsKey($k)) { $addrCol = $colIdx[$k]; break } }
    if ($addrCol -lt 0) { return $null }

    function CellOf($fields, [int]$idx) {
        if ($idx -lt 0 -or $idx -ge $fields.Count) { return '' }
        $v = $fields[$idx]
        if ($null -eq $v) { return '' }
        return $v.Trim()
    }

    $signals = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]
    $title = ''

    for ($r = $hdrIdx + 1; $r -lt $rows.Count; $r++) {
        $f = $rows[$r].Fields
        $addrRaw = CellOf $f $addrCol
        $tag = CellOf $f $colIdx['tag']

        # A row with no address: either a title, a note, or blank.
        if ([string]::IsNullOrWhiteSpace($addrRaw)) {
            $only = ''
            foreach ($c in 1..($f.Count - 1)) {
                $v = CellOf $f $c
                if ($v) { if ($only) { $only = ''; break } else { $only = $v } }
            }
            if ($only) {
                if (-not $title -and $only -match '[A-Za-z]{3,}') { $title = $only }
                elseif ($only -match '[A-Za-z]{3,}') { $notes.Add($only) }
            }
            continue
        }

        $parsed = Split-Address $addrRaw
        if ($null -eq $parsed) {
            # Not an address but the cell is filled: a note in the address column.
            if ($addrRaw -match '[A-Za-z]{3,}' -and $addrRaw -notmatch '^[IQA]') { $notes.Add($addrRaw) }
            continue
        }

        $cond = ''
        foreach ($k in @('cableterminalcondition', 'condition')) { if ($colIdx.ContainsKey($k)) { $cond = CellOf $f $colIdx[$k]; break } }
        $cmt = ''
        foreach ($k in @('additionalcomments', 'comments', 'comment')) { if ($colIdx.ContainsKey($k)) { $cmt = CellOf $f $colIdx[$k]; break } }
        $wire = ''
        foreach ($k in @('wireno', 'wire')) { if ($colIdx.ContainsKey($k)) { $wire = CellOf $f $colIdx[$k]; break } }
        $term = ''
        foreach ($k in @('terminalno', 'terminal', 'termno')) { if ($colIdx.ContainsKey($k)) { $term = CellOf $f $colIdx[$k]; break } }
        $cable = ''
        foreach ($k in @('cablenumber', 'cable', 'cableno')) { if ($colIdx.ContainsKey($k)) { $cable = CellOf $f $colIdx[$k]; break } }
        $dev = ''
        foreach ($k in @('fielddevice', 'device')) { if ($colIdx.ContainsKey($k)) { $dev = CellOf $f $colIdx[$k]; break } }
        $fname = ''
        foreach ($k in @('fieldname', 'description')) { if ($colIdx.ContainsKey($k)) { $fname = CellOf $f $colIdx[$k]; break } }
        $serial = ''
        foreach ($k in $colIdx.Keys) { if ($k -match 'serial' -or $k -match 'rs485') { $serial = CellOf $f $colIdx[$k]; break } }

        $blob = ($cond + ' ' + $cmt + ' ' + $cable + ' ' + $wire).ToLowerInvariant()
        $spare = ($blob -match 'spare')
        $noCable = ($blob -match 'no cable')

        # Channel index within the card: bits run 0..7, so a byte holds 8 channels. The card
        # numbering on a termination drawing is 1-based across the station's channels of that type.
        $chan = -1
        if ($parsed.Bit -ge 0) { $chan = $parsed.Byte * 8 + $parsed.Bit + 1 }

        $signals.Add([pscustomobject]@{
            Row         = $rows[$r].Row
            Tag         = $tag
            Address     = $parsed.Address
            Dir         = $parsed.Dir
            Byte        = $parsed.Byte
            Bit         = $parsed.Bit
            Word        = $parsed.Word
            Channel     = $chan
            WireNo      = $wire
            TerminalNo  = $term
            CableNo     = $cable
            FieldDevice = $dev
            FieldName   = $fname
            SerialCable = $serial
            Condition   = $cond
            Comments    = $cmt
            Spare       = $spare
            NoCable     = $noCable
        })
    }

    return [pscustomobject]@{
        Csv     = $csvPath
        Header  = $rows[$hdrIdx].Fields
        Signals = $signals
        Title   = $title
        Notes   = $notes
    }
}

$tabFiles = Get-ChildItem -LiteralPath $InDir -Filter '*.csv' | Sort-Object Name
$records = New-Object System.Collections.Generic.List[object]
$tabInfo = New-Object System.Collections.Generic.List[object]

foreach ($tf in $tabFiles) {
    # Station = the tab name up to the building reference. The reference is the token "Building"
    # followed by a number, so anchor on "Building <digits>": a bare "Building" strip leaves
    # "BUS 1 Building 2" keeping its building number and splits one station in two.
    $station = ($tf.BaseName -replace '\s*Building\s+\d+\s*$', '').Trim() -replace '\s+', ' '
    if ($stationFilter -and -not ($stationFilter | Where-Object { $station -like $_ })) { continue }

    $t = Read-Tab $tf.FullName
    if ($null -eq $t) { Write-Warning "no recognisable header in $($tf.Name)"; continue }

    foreach ($s in $t.Signals) {
        $records.Add([pscustomobject]@{
            Station     = $station
            SourceRow   = $s.Row
            Tag         = $s.Tag
            Address     = $s.Address
            Dir         = $s.Dir
            Byte        = $s.Byte
            Bit         = $s.Bit
            Channel     = $s.Channel
            WireNo      = $s.WireNo
            TerminalNo  = $s.TerminalNo
            CableNo     = $s.CableNo
            FieldDevice = $s.FieldDevice
            FieldName   = $s.FieldName
            SerialCable = $s.SerialCable
            Condition   = $s.Condition
            Comments    = $s.Comments
            Spare       = if ($s.Spare) { 'Y' } else { '' }
            NoCable     = if ($s.NoCable) { 'Y' } else { '' }
        })
    }
    $tabInfo.Add([pscustomobject]@{
        Station = $station
        File    = $tf.Name
        Title   = $t.Title
        Signals = $t.Signals.Count
        Notes   = ($t.Notes -join ' | ')
    })
}

$outDir = Split-Path -Parent $OutFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$records | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Encoding UTF8

# Per-station summary: counts by direction, plus how many rows carry a tag / a wire / a cable.
Write-Host ("signals={0}  stations={1}" -f $records.Count, ($records.Station | Sort-Object -Unique).Count)
foreach ($g in ($records | Group-Object Station | Sort-Object Name)) {
    $d = $g.Group | Group-Object Dir | ForEach-Object { "$($_.Name)=$($_.Count)" }
    $tagged = @($g.Group | Where-Object { $_.Tag }).Count
    $wired = @($g.Group | Where-Object { $_.WireNo -and $_.WireNo -notmatch '(?i)no cable' }).Count
    $spare = @($g.Group | Where-Object { $_.Spare -eq 'Y' }).Count
    Write-Host ("  {0,-16} rows={1,-4} {2,-22} tagged={3,-4} wired={4,-4} spare={5}" -f $g.Name, $g.Count, ($d -join ' '), $tagged, $wired, $spare)
}
Write-Host "wrote $OutFile"
