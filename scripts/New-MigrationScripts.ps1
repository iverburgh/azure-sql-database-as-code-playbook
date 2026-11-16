<#
.SYNOPSIS
    Generates the migration runner scripts from the folders in Migrations, or checks that they are current.

.DESCRIPTION
    Reads every Migrations/NNNN_Description folder of the migrations project, checks the
    migration scripts against the rules in docs/migrations.md and writes:

      Scripts/Generated/RunMigrations.sql   runs each migration once on an existing database
      Scripts/Generated/InitMigrations.sql  records all migrations as applied on a new database

    With -Check nothing is written; the script fails when a rule is broken or a generated file
    is out of date. CI and the pre-commit hook run it that way.

.PARAMETER ProjectPath
    The folder of the migrations project. Defaults to the sample project.

.PARAMETER Check
    Do not write; exit with code 1 when the generated files are not current.

.EXAMPLE
    ./scripts/New-MigrationScripts.ps1

.EXAMPLE
    ./scripts/New-MigrationScripts.ps1 -Check
#>
[CmdletBinding()]
param(
    [string] $ProjectPath,

    [switch] $Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($lib in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'lib') -Filter '*.ps1' -File)) {
    . $lib.FullName
}

if (-not $ProjectPath) {
    $ProjectPath = Join-Path (Get-RepositoryRoot) 'database/Shop.Database.Migrations'
}
if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
    throw "Migrations project not found: $ProjectPath"
}

$migrations = @(Get-Migration -ProjectPath $ProjectPath)
$violations = @(Test-MigrationScript -Migrations $migrations)
foreach ($violation in $violations) {
    Write-Host "ERROR: $violation"
}
if ($violations.Count -gt 0) {
    Write-Host "$($violations.Count) migration rule violation(s). See docs/migrations.md."
    exit 1
}

$generatedPath = Join-Path $ProjectPath 'Scripts/Generated'
$files = [ordered]@{
    (Join-Path $generatedPath 'RunMigrations.sql')  = New-RunMigrationsSql -Migrations $migrations
    (Join-Path $generatedPath 'InitMigrations.sql') = New-InitMigrationsSql -Migrations $migrations
}

$stale = 0
foreach ($path in @($files.Keys)) {
    if ($Check) {
        if (-not (Test-GeneratedFileCurrent -Path $path -Content $files[$path])) {
            Write-Host "ERROR: $path is not current. Run scripts/New-MigrationScripts.ps1 and commit the result."
            $stale++
        }
    }
    elseif (Write-GeneratedFile -Path $path -Content $files[$path]) {
        Write-Host "Updated $path"
    }
}

if ($stale -gt 0) {
    exit 1
}
Write-Host "$($migrations.Count) migration(s); generated scripts are current."
exit 0
