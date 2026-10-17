# Loads the private project settings. Dot-source this at the top of every script:
#   . (Join-Path $PSScriptRoot 'project.ps1')
# Then use $Project.project (the project number), $Project.referenceProject, $Project.sheets,
# $Project.template, $Project.workingDir and $Project.ioSheets. No script holds a project number,
# a client name or a drawing file name of its own: they all come from this file, which lives
# outside the repository.
$D = $env:PSA_DRAWINGS
if ([string]::IsNullOrWhiteSpace($D) -or -not (Test-Path -LiteralPath $D)) {
    throw 'PSA_DRAWINGS is not set or does not point at an existing folder.'
}
$projectFile = Join-Path $D 'fusion\project.json'
if (-not (Test-Path -LiteralPath $projectFile)) {
    throw "Missing $projectFile. Create it (see psa/PLAN.md, 'Two folders, two rules')."
}
$Project = Get-Content -LiteralPath $projectFile -Raw | ConvertFrom-Json
