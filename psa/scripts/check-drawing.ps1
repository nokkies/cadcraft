# check-drawing.ps1 -- cadcraft card M2-C3
#
#   check-drawing.ps1 <dwg> <rules.json>
#
# Uses the drawing's info JSON (card M1-C2) and texts JSON (card M2-C1) and prints one line
# per rule: `PASS <id>` or `FAIL <id> <reason>`. Exit code 0 when all pass, 1 otherwise.
#
# Rule kinds (implemented in the order PLAN.md lists them):
#   1 attribute-present          : a block attribute with that tag has a non-empty value.
#   2 attribute-equals-filename  : that attribute equals the file name up to `_`.
#   3 layers-only-from           : every entity's layer is in the list.
#   4 text-height-min            : no text or attribute is smaller than `min`.
#   5 draft-stamp-present        : some text equals `text`.
#   6 cross-reference-exists     : every match of `pattern` names a drawing in the inventory.
#
# Where the data comes from:
#   * attributes and text heights come from the texts JSON. `texts` reports block attributes
#     with their `tag`, so attribute-present/equals-filename read the tagged texts (paper
#     space first, then model). The `block` field names the owning block (A1 TITLE TEXT) and
#     is advisory: the tag is what identifies the attribute, because `texts` gives the tag,
#     not the owning block name. A rule with a `block` still matches by tag.
#   * layers come from the info JSON's `layers` table (the layers defined in the drawing).
#     An entity's layer is checked by the entity layer list the info JSON exposes; cadcraft's
#     info lists the layer TABLE, so layers-only-from checks that table -- a layer used by an
#     entity but absent from the table cannot exist (AutoCAD requires it to be defined).
#   * cross-references are matched against the inventory CSV (drawing numbers that exist).
#
# Reads only.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Drawing,
    [Parameter(Position = 1)][string]$RulesFile,
    [string]$InfoDir,
    [string]$TextsDir,
    [string]$Inventory
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

$D = Get-PSADrawingsRoot
if ([string]::IsNullOrWhiteSpace($RulesFile)) { $RulesFile = Join-Path $D 'fusion\rules.json' }
if ([string]::IsNullOrWhiteSpace($InfoDir)) { $InfoDir = Join-Path $D 'fusion\info' }
if ([string]::IsNullOrWhiteSpace($TextsDir)) { $TextsDir = Join-Path $D 'fusion\texts' }
if ([string]::IsNullOrWhiteSpace($Inventory)) { $Inventory = Join-Path $D 'fusion\inventory.csv' }

# Resolve the drawing to a full path if only a name was given.
$drawPath = $Drawing
if (-not (Test-Path -LiteralPath $drawPath)) {
    $hit = @(Get-ChildItem -LiteralPath $D -Recurse -Filter $Drawing -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($hit.Count -gt 0) { $drawPath = $hit[0].FullName }
}
if (-not (Test-Path -LiteralPath $drawPath)) { Write-Error "drawing not found: $Drawing"; exit 2 }
if (-not (Test-Path -LiteralPath $RulesFile)) { Write-Error "rules file not found: $RulesFile"; exit 2 }

$name = Split-Path -Leaf $drawPath
$stem = ($name -replace '\.dwg$', '')
$dwgNo = ($stem -split '_')[0]

# --- load data ---------------------------------------------------------------------
$infoPath = Join-Path $InfoDir (Get-OutName -Path $drawPath -Root $D -Extension '.dwg.json')
if (-not (Test-Path -LiteralPath $infoPath)) {
    $alt = Join-Path $InfoDir (Get-OutName -Path $drawPath -Root $D -Extension '.json')
    if (Test-Path -LiteralPath $alt) { $infoPath = $alt }
}
$textsPath = Join-Path $TextsDir (Get-OutName -Path $drawPath -Root $D -Extension '.json')

if (-not (Test-Path -LiteralPath $infoPath)) { Write-Error "no info JSON for $name (run card M1-C2)"; exit 2 }
if (-not (Test-Path -LiteralPath $textsPath)) { Write-Error "no texts JSON for $name (run card M2-C1)"; exit 2 }

$info = Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json
$textsDoc = Get-Content -LiteralPath $textsPath -Raw | ConvertFrom-Json

# All texts from both spaces, tagged ones included.
$allTexts = @()
if ($textsDoc.model -and $textsDoc.model.texts) { $allTexts += @($textsDoc.model.texts) }
if ($textsDoc.paper -and $textsDoc.paper.texts) { $allTexts += @($textsDoc.paper.texts) }

# Attribute lookup by tag (case-insensitive, as AutoCAD tags are). Returns an array even when
# nothing matches: PowerShell unrolls an empty array returned from a function to $null, and
# $null.Count trips StrictMode, so the comma operator keeps it a single array object.
function Get-AttributeByTag {
    param([string]$Tag)
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($t in $allTexts) {
        if ($t.PSObject.Properties.Name -contains 'tag' -and $t.tag -and
            ([string]$t.tag).Equals($Tag, [StringComparison]::OrdinalIgnoreCase)) {
            $found.Add($t)
        }
    }
    return ,$found.ToArray()
}

# The set of drawing numbers that exist (inventory), for cross-references.
$existingNumbers = @{}
if (Test-Path -LiteralPath $Inventory) {
    foreach ($row in @(Import-Csv -LiteralPath $Inventory)) {
        $leaf = Split-Path -Leaf $row.path
        $num = (($leaf -replace '\.dwg$', '') -split '_')[0]
        $existingNumbers[$num.ToUpperInvariant()] = $true
    }
}

# Force an array from a pipeline result. `@($x | Where-Object ...)` yields $null (not an empty
# array) when nothing matches, and $null.Count trips StrictMode -- so wrap every filtered result
# through this. The comma operator keeps the empty case an array across the function boundary.
function As-Array {
    param([object[]]$Items)
    if ($null -eq $Items) { return ,@() }
    return ,$Items
}

$rules = @(Get-Content -LiteralPath $RulesFile -Raw | ConvertFrom-Json)

# --- evaluate ----------------------------------------------------------------------
$failCount = 0
Write-Host "# $name"
foreach ($rule in $rules) {
    $id = $rule.id
    $kind = $rule.kind
    $result = 'PASS'
    $reason = ''

    switch ($kind) {
        'attribute-present' {
            $m = Get-AttributeByTag -Tag $rule.tag
            if ($m.Count -eq 0) { $result = 'FAIL'; $reason = "no attribute with tag $($rule.tag)" }
            elseif ((As-Array ($m | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.text) })).Count -eq 0) {
                $result = 'FAIL'; $reason = "attribute $($rule.tag) is empty"
            }
        }
        'attribute-equals-filename' {
            $m = Get-AttributeByTag -Tag $rule.tag
            if ($m.Count -eq 0) { $result = 'FAIL'; $reason = "no attribute with tag $($rule.tag)" }
            else {
                $vals = As-Array ($m | ForEach-Object { ([string]$_.text).Trim() })
                if ($vals -notcontains $dwgNo) { $result = 'FAIL'; $reason = "$($rule.tag)='$($vals -join '|')' != '$dwgNo'" }
            }
        }
        'layers-only-from' {
            $allowed = As-Array $rule.layers
            $used = As-Array ($info.layers | ForEach-Object { [string]$_.name })
            $extra = As-Array ($used | Where-Object { $allowed -notcontains $_ })
            if ($extra.Count -gt 0) { $result = 'FAIL'; $reason = 'layers not in list: ' + ($extra -join ',') }
        }
        'text-height-min' {
            $min = [double]$rule.min
            $small = As-Array ($allTexts | Where-Object {
                $_.PSObject.Properties.Name -contains 'height' -and $_.height -and
                ([double]$_.height) -lt $min
            })
            if ($small.Count -gt 0) {
                $sample = ($small | Select-Object -First 3 | ForEach-Object { "'$($_.text)'=$($_.height)" }) -join ', '
                $result = 'FAIL'; $reason = "$($small.Count) text(s) below $min (e.g. $sample)"
            }
        }
        'draft-stamp-present' {
            $want = ([string]$rule.text).Trim()
            $hit = As-Array ($allTexts | Where-Object { ([string]$_.text).Trim() -eq $want })
            if ($hit.Count -eq 0) { $result = 'FAIL'; $reason = "no text equals '$want'" }
        }
        'cross-reference-exists' {
            $pat = [string]$rule.pattern
            $missing = New-Object System.Collections.Generic.List[string]
            foreach ($t in $allTexts) {
                $txt = [string]$t.text
                foreach ($mm in [regex]::Matches($txt, $pat)) {
                    $ref = $mm.Groups[1].Value
                    if (-not $existingNumbers.ContainsKey($ref.ToUpperInvariant())) { $missing.Add($ref) }
                }
            }
            if ($missing.Count -gt 0) { $result = 'FAIL'; $reason = 'refs to unknown drawings: ' + (($missing | Sort-Object -Unique) -join ',') }
        }
        default {
            $result = 'FAIL'; $reason = "unknown rule kind '$kind'"
        }
    }

    if ($result -eq 'FAIL') {
        $failCount++
        Write-Host "FAIL $id $reason"
    } else {
        Write-Host "PASS $id"
    }
}

exit $(if ($failCount -gt 0) { 1 } else { 0 })
