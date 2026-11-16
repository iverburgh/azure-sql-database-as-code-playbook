<#
.SYNOPSIS
    Creates the disposable database for a schema rehearsal and prints its name.

.DESCRIPTION
    Copy mode (default) copies the source database on the same server; Empty mode creates an
    empty database, and the rehearsal deploys the released baseline into it first.

    The database is named <source>-rehearsal-<build id> and tagged purpose=schema-rehearsal.
    A leftover with that name and tag (a re-run of the same build) is removed first; a database
    with that name but without the tag stops the script. Conflicting Azure operations are
    retried.

    In Azure Pipelines the name is also set as the pipeline variable RehearsalDatabase.

.PARAMETER Mode
    Copy or Empty.

.PARAMETER ServiceObjective
    The size of the rehearsal database. A copy of a large database takes longer on a small one.

.EXAMPLE
    ./scripts/New-RehearsalDatabase.ps1 -ResourceGroup my-rg -Server my-sql-prod -SourceDatabase my-shop -BuildId 1234 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroup,

    [Parameter(Mandatory)]
    [string] $Server,

    [Parameter(Mandatory)]
    [string] $SourceDatabase,

    [Parameter(Mandatory)]
    [ValidatePattern('^\d+$')]
    [string] $BuildId,

    [ValidateSet('Copy', 'Empty')]
    [string] $Mode = 'Copy',

    [string] $ServiceObjective = 'S3',

    [int] $RetryDelaySeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($lib in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'lib') -Filter '*.ps1' -File)) {
    . $lib.FullName
}

$name = New-SchemaRehearsalDatabase -ResourceGroup $ResourceGroup -Server $Server -SourceDatabase $SourceDatabase -BuildId $BuildId `
    -Mode $Mode -ServiceObjective $ServiceObjective -RetryDelaySeconds $RetryDelaySeconds -WhatIf:$WhatIfPreference

Write-Host "Rehearsal database: $name"
if ($env:TF_BUILD) {
    Write-Host "##vso[task.setvariable variable=RehearsalDatabase]$name"
}
$name
