# xlsx-dump.ps1 -- read an .xlsx without Excel, openpyxl or any external dependency.
#
# An xlsx is a zip of XML parts. This script opens it with .NET's zip API, resolves the shared
# string table and the worksheet cells, and writes one CSV per sheet into the output folder.
# It exists because the project data (I/O lists, order schedules, registers, template lists) is
# all .xlsx and the machine has no Excel automation and no python openpyxl.
#
# Usage:
#   pwsh -File psa/scripts/xlsx-dump.ps1 -Path <file.xlsx> -OutDir <dir> [-Sheets a,b] [-Peek]
#
# -Peek prints the sheet names and their parts and writes nothing.
#
# Every XML read goes through SelectNodes with local-name() tests: the OOXML parts carry a
# default namespace, and property-style access ($x.sst.si) is unreliable under StrictMode.
#
# Cell values: cached formula results are used when a cell has both a formula and <v>.
# Dates are converted to yyyy-mm-dd when the cell's number format looks like a date.

[CmdletBinding()]
param(
    [string]$Path,
    [string]$OutDir,
    # Comma-separated sheet names, deliberately a single string and not [string[]]: a caller that
    # nests pwsh around this script has its array flattened into separate positional arguments
    # and the call fails with "positional parameter cannot be found".
    [string]$Sheets,
    [switch]$Peek
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { throw "No such file: $Path" }
$Path = (Resolve-Path -LiteralPath $Path).Path

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
try {
    function Read-Entry([string]$name) {
        $e = $zip.GetEntry($name)
        if ($null -eq $e) { return $null }
        $s = $e.Open()
        try {
            $r = New-Object System.IO.StreamReader($s, [System.Text.Encoding]::UTF8)
            try { return $r.ReadToEnd() } finally { $r.Dispose() }
        } finally { $s.Dispose() }
    }

    # --- shared strings ---------------------------------------------------------
    $shared = New-Object System.Collections.Generic.List[string]
    $ssXml = Read-Entry 'xl/sharedStrings.xml'
    if ($ssXml) {
        $ss = [xml]$ssXml
        foreach ($si in $ss.SelectNodes('//*[local-name()="si"]')) {
            # Concatenate every <t> under the si: covers plain and rich (multi-run) strings.
            $sb = New-Object System.Text.StringBuilder
            foreach ($t in $si.SelectNodes('.//*[local-name()="t"]')) { [void]$sb.Append($t.InnerText) }
            $shared.Add($sb.ToString())
        }
    }

    # --- workbook: sheet name -> target part -------------------------------------
    $wbXml = [xml](Read-Entry 'xl/workbook.xml')
    $relsXml = [xml](Read-Entry 'xl/_rels/workbook.xml.rels')
    $relById = @{}
    if ($null -ne $relsXml) {
        foreach ($rel in $relsXml.SelectNodes('//*[local-name()="Relationship"]')) {
            $t = $rel.GetAttribute('Target')
            if ($t -match '^/') { $t = $t.TrimStart('/') }
            else { $t = ('xl/' + ($t -replace '^\./', '')) -replace '/+', '/' }
            $relById[$rel.GetAttribute('Id')] = $t
        }
    }

    $sheetList = @()
    foreach ($sh in $wbXml.SelectNodes('//*[local-name()="sheet"]')) {
        $rid = ''
        foreach ($a in $sh.Attributes) { if ($a.LocalName -eq 'id') { $rid = $a.Value } }
        $sheetList += [pscustomobject]@{
            Name   = $sh.GetAttribute('name')
            Target = $relById[$rid]
        }
    }

    if ($Peek) {
        foreach ($s in $sheetList) { Write-Host ("SHEET`t{0}`t{1}" -f $s.Name, $s.Target) }
        return
    }

    # --- styles: which numFmt ids look like dates ------------------------------
    $dateFmtIds = New-Object System.Collections.Generic.HashSet[int]
    foreach ($i in @(14, 15, 16, 17, 18, 19, 20, 21, 22, 27, 30, 36, 45, 46, 47, 50, 57, 58)) {
        [void]$dateFmtIds.Add($i)
    }
    $cellXfNumFmt = New-Object System.Collections.Generic.List[int]
    $stylesRaw = Read-Entry 'xl/styles.xml'
    if ($stylesRaw) {
        $st = [xml]$stylesRaw
        foreach ($nf in $st.SelectNodes('//*[local-name()="numFmt"]')) {
            $f = $nf.GetAttribute('formatCode')
            if ($f -and $f -match '[dmyhDMYHS]' -and $f -notmatch '^General$') {
                $id = 0
                if ([int]::TryParse($nf.GetAttribute('numFmtId'), [ref]$id)) { [void]$dateFmtIds.Add($id) }
            }
        }
        $cxfs = $st.SelectSingleNode('//*[local-name()="cellXfs"]')
        if ($null -ne $cxfs) {
            foreach ($xf in $cxfs.SelectNodes('*[local-name()="xf"]')) {
                $id = 0
                if (-not [int]::TryParse($xf.GetAttribute('numFmtId'), [ref]$id)) { $id = 0 }
                $cellXfNumFmt.Add($id)
            }
        }
    }

    function ColToIndex([string]$ref) {
        $letters = ($ref -replace '\d', '')
        if ($letters.Length -eq 0 -or $letters.Length -gt 3) { return -1 }
        $n = 0
        foreach ($ch in $letters.ToUpperInvariant().ToCharArray()) {
            $d = [int]$ch - 64
            if ($d -lt 1 -or $d -gt 26) { return -1 }
            $n = $n * 26 + $d
        }
        return $n - 1
    }

    if (-not $OutDir) { throw '-OutDir is required unless -Peek' }
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

    $wanted = $sheetList
    if ($Sheets) {
        $wantNames = @($Sheets -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $wanted = @($sheetList | Where-Object { $wantNames -contains $_.Name })
        if ($wanted.Count -eq 0) { throw "None of the requested sheets found. Available: $($sheetList.Name -join ', ')" }
    }

    function CsvField([string]$v) {
        if ([string]::IsNullOrEmpty($v)) { return '' }
        $v = $v -replace '\r?\n', ' '
        if ($v -match '[",]') { return '"' + ($v -replace '"', '""') + '"' }
        return $v
    }

    $written = @()
    foreach ($s in $wanted) {
        $raw = Read-Entry $s.Target
        if (-not $raw) { Write-Warning "missing part $($s.Target)"; continue }
        $wx = [xml]$raw

        # A plain hashtable, deliberately: on an OrderedDictionary PowerShell's [n] indexes
        # by POSITION, not by key, so $rows[$rowNumber] throws for any row past the first few.
        $rows = @{}
        $maxCol = 0
        foreach ($c in $wx.SelectNodes('//*[local-name()="c"]')) {
            $ref = $c.GetAttribute('r')
            if ($ref -notmatch '^[A-Za-z]+\d+$') { continue }
            $rowNum = 0
            if (-not [int]::TryParse(($ref -replace '[A-Za-z]', ''), [ref]$rowNum)) { continue }
            $col = ColToIndex $ref
            if ($col -lt 0) { continue }
            if ($col -gt $maxCol) { $maxCol = $col }

            $t = $c.GetAttribute('t')
            $sAttr = $c.GetAttribute('s')
            $vNode = $c.SelectSingleNode('*[local-name()="v"]')
            $isNode = $c.SelectSingleNode('*[local-name()="is"]')
            $val = ''

            if ($t -eq 'inlineStr' -and $null -ne $isNode) {
                $val = $isNode.InnerText
            } elseif ($null -ne $vNode) {
                $rawv = $vNode.InnerText
                if ($t -eq 's') {
                    $i = 0
                    if ([int]::TryParse($rawv, [ref]$i) -and $i -ge 0 -and $i -lt $shared.Count) { $val = $shared[$i] }
                } elseif ($t -eq 'b') {
                    $val = if ($rawv -eq '1') { 'TRUE' } else { 'FALSE' }
                } elseif ($t -eq 'str' -or $t -eq 'e') {
                    $val = $rawv
                } else {
                    $num = 0.0
                    $ok = [double]::TryParse($rawv, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$num)
                    if (-not $ok) { $val = $rawv }
                    else {
                        $isDate = $false
                        if ($sAttr) {
                            $xfi = 0
                            if ([int]::TryParse($sAttr, [ref]$xfi) -and $xfi -lt $cellXfNumFmt.Count) {
                                $isDate = $dateFmtIds.Contains($cellXfNumFmt[$xfi])
                            }
                        }
                        if ($isDate -and $num -ge 1) {
                            try { $val = [datetime]::FromOADate($num).ToString('yyyy-mm-dd') } catch { $val = $rawv }
                        } elseif ($num -eq [math]::Floor($num) -and [math]::Abs($num) -lt 1e15) {
                            $val = ([long]$num).ToString([System.Globalization.CultureInfo]::InvariantCulture)
                        } else {
                            $val = $num.ToString([System.Globalization.CultureInfo]::InvariantCulture)
                        }
                    }
                }
            }

            if (-not $rows.Contains($rowNum)) { $rows[$rowNum] = @{} }
            $rows[$rowNum][$col] = $val
        }

        $rowNums = @($rows.Keys | Sort-Object)
        $safeMax = [math]::Min($maxCol, 400)
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($rn in $rowNums) {
            $d = $rows[$rn]
            $cells = New-Object System.Collections.Generic.List[string]
            $cells.Add("R$rn")
            for ($c = 0; $c -le $safeMax; $c++) {
                $v = ''
                if ($d.ContainsKey($c)) { $v = [string]$d[$c] }
                $cells.Add((CsvField $v))
            }
            while ($cells.Count -gt 2 -and $cells[$cells.Count - 1] -eq '') { $cells.RemoveAt($cells.Count - 1) }
            $lines.Add(($cells -join ','))
        }
        # Spaces collapse to a single underscore, and the building reference is dropped: downstream
        # scripts key on the station ("P01", "BUS 1"), and a file name carrying "Building 40"
        # makes every consumer re-derive the station from it (and get "BUS 1 Building 2").
        $safe = $s.Name -replace '\s*Building\s+\d+\s*$', ''
        $safe = (($safe -replace '\s+', '_') -replace '[^\w.\-]+', '_').Trim('_')
        $outFile = Join-Path $OutDir ($safe + '.csv')
        [System.IO.File]::WriteAllLines($outFile, $lines, (New-Object System.Text.UTF8Encoding($false)))
        $written += [pscustomobject]@{ Sheet = $s.Name; Rows = $rowNums.Count; File = $outFile }
    }
    foreach ($w in $written) { Write-Host ("WROTE`t{0}`trows={1}`t{2}" -f $w.Sheet, $w.Rows, $w.File) }
} finally {
    $zip.Dispose()
}
