<#
.SYNOPSIS
    Checks, offline, whether a change touches columns that change data capture (CDC) reads.

.DESCRIPTION
    Compares the captured columns in the schema dacpac of the released version (the baseline)
    with the schema dacpac of the change (the candidate). No database is needed, so it runs in
    a pull request build.

    Exit codes:
      0  no captured column changes
      1  warnings: a captured column becomes wider, changes nullability or is dropped; the
         capture instance must be recreated as a planned follow-up
      2  errors: a captured column changes type or becomes narrower; do not deploy
      3  the check could not run

    See docs/cdc-and-schema-changes.md.

.PARAMETER BaselineDacpac
    The schema dacpac of the release that is in production.

.PARAMETER CandidateDacpac
    The schema dacpac of this change.

.PARAMETER CapturedColumnsPath
    The list of captured columns. Defaults to database/cdc/captured-columns.json.

.EXAMPLE
    ./scripts/Test-CdcColumnChanges.ps1 -BaselineDacpac ./baseline/Shop.Database.dacpac -CandidateDacpac database/Shop.Database/bin/Release/Shop.Database.dacpac
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $BaselineDacpac,

    [Parameter(Mandatory)]
    [string] $CandidateDacpac,

    [string] $CapturedColumnsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    foreach ($lib in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'lib') -Filter '*.ps1' -File)) {
        . $lib.FullName
    }
    if (-not $CapturedColumnsPath) {
        $CapturedColumnsPath = Join-Path (Get-RepositoryRoot) 'database/cdc/captured-columns.json'
    }
    $captured = Read-CapturedColumn -Path $CapturedColumnsPath
    $baselineTables = @(Get-DacpacTable -Model (Read-DacpacModel -Path $BaselineDacpac))
    $candidateTables = @(Get-DacpacTable -Model (Read-DacpacModel -Path $CandidateDacpac))
    $findings = @(Compare-CdcColumn -BaselineTables $baselineTables -CandidateTables $candidateTables -CapturedColumns $captured)
}
catch {
    Write-Host "ERROR: the CDC check could not run: $($_.Exception.Message)"
    exit 3
}

foreach ($finding in $findings) {
    Write-Host "$($finding.Severity.ToUpperInvariant()): $($finding.Message)"
}
if (@($findings | Where-Object Severity -eq 'Error').Count -gt 0) {
    Write-Host 'A captured column changes in a way the capture instance cannot follow. See docs/cdc-and-schema-changes.md.'
    exit 2
}
if ($findings.Count -gt 0) {
    Write-Host 'Plan the capture instance follow-up with the owner of the captured columns.'
    exit 1
}
Write-Host 'No captured column changes.'
exit 0
