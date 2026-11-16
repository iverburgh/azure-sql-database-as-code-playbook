<#
.SYNOPSIS
    Keeps the column descriptions in step with the schema and generates their extended properties.

.DESCRIPTION
    ColumnDescriptions.json in the schema project describes every table and column. This script:

      - with -DacpacPath: compares the file with the tables in the built dacpac and adds missing
        tables and columns (with a proposed description, or an empty one to fill in), removes
        obsolete ones and sorts the file;
      - always: generates Generated/ColumnDescriptions.sql, one sp_addextendedproperty statement
        per description, which the schema project builds into the model.

    With -Check nothing is written. The script fails when the file does not match the dacpac
    (missing, obsolete or empty descriptions) or the generated SQL is not current.

    The build runs before the check, so a description added in the same change is built in the
    next build. CI therefore builds, checks, and fails when anything is out of date.

.PARAMETER DescriptionsPath
    The descriptions file. Defaults to the sample schema project.

.PARAMETER DacpacPath
    The built schema dacpac. Without it, only the SQL is generated or checked.

.PARAMETER Check
    Do not write; exit with code 1 on findings or a stale generated file.

.EXAMPLE
    dotnet build database/Shop.Database -c Release
    ./scripts/Update-ColumnDescriptions.ps1 -DacpacPath database/Shop.Database/bin/Release/Shop.Database.dacpac
#>
[CmdletBinding()]
param(
    [string] $DescriptionsPath,

    [string] $DacpacPath,

    [switch] $Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($lib in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'lib') -Filter '*.ps1' -File)) {
    . $lib.FullName
}

if (-not $DescriptionsPath) {
    $DescriptionsPath = Join-Path (Get-RepositoryRoot) 'database/Shop.Database/ColumnDescriptions.json'
}
$descriptions = Read-ColumnDescription -Path $DescriptionsPath
$sqlPath = Join-Path (Split-Path -Parent $DescriptionsPath) 'Generated/ColumnDescriptions.sql'
$failures = 0

if ($DacpacPath) {
    $tables = @(Get-DacpacTable -Model (Read-DacpacModel -Path $DacpacPath))
    if ($Check) {
        $findings = @(Compare-ColumnDescription -Descriptions $descriptions -Tables $tables)
        foreach ($finding in $findings) {
            Write-Host "ERROR: $($finding.Message)"
        }
        $failures += $findings.Count
        if ($findings.Count -gt 0) {
            Write-Host 'Run scripts/Update-ColumnDescriptions.ps1 -DacpacPath <dacpac>, fill in the empty descriptions and commit the result.'
        }
    }
    else {
        $descriptions = Sync-ColumnDescription -Descriptions $descriptions -Tables $tables
        if (Write-GeneratedFile -Path $DescriptionsPath -Content (ConvertTo-ColumnDescriptionJson -Descriptions $descriptions)) {
            Write-Host "Updated $DescriptionsPath"
        }
        foreach ($finding in @(Compare-ColumnDescription -Descriptions $descriptions -Tables $tables)) {
            Write-Host "TODO: $($finding.Message)"
        }
    }
}

$sql = ConvertTo-ColumnDescriptionSql -Descriptions $descriptions
if ($Check) {
    if (-not (Test-GeneratedFileCurrent -Path $sqlPath -Content $sql)) {
        Write-Host "ERROR: $sqlPath is not current. Run scripts/Update-ColumnDescriptions.ps1 and commit the result."
        $failures++
    }
}
elseif (Write-GeneratedFile -Path $sqlPath -Content $sql) {
    Write-Host "Updated $sqlPath"
}

if ($failures -gt 0) {
    exit 1
}
Write-Host 'Column descriptions are current.'
exit 0
