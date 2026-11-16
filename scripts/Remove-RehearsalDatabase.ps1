<#
.SYNOPSIS
    Removes a schema rehearsal database.

.DESCRIPTION
    Refuses any database whose name does not end in -rehearsal-<build id> or that does not carry
    the tag purpose=schema-rehearsal, so a mistake in a pipeline variable cannot remove a real
    database. A database that does not exist is not an error: the pipeline runs this step
    always, also when creating the copy failed.

.EXAMPLE
    ./scripts/Remove-RehearsalDatabase.ps1 -ResourceGroup my-rg -Server my-sql-prod -Name my-shop-rehearsal-1234
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroup,

    [Parameter(Mandatory)]
    [string] $Server,

    [Parameter(Mandatory)]
    [ValidatePattern('-rehearsal-\d+$')]
    [string] $Name,

    [int] $RetryDelaySeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($lib in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'lib') -Filter '*.ps1' -File)) {
    . $lib.FullName
}

Remove-SchemaRehearsalDatabase -ResourceGroup $ResourceGroup -Server $Server -Name $Name -RetryDelaySeconds $RetryDelaySeconds -WhatIf:$WhatIfPreference
if (-not $WhatIfPreference) {
    Write-Host "Rehearsal database $Name is gone."
}
