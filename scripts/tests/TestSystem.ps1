Set-StrictMode -Version Latest

<#
    Shared setup for the Pester tests: paths, the libraries, the fakes, and helpers that write
    small dacpacs, artifact folders and migration projects into a temporary folder.
#>

$global:PlaybookRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$global:ScriptsPath = Join-Path $global:PlaybookRoot 'scripts'
$global:SchemaPath = Join-Path $global:ScriptsPath 'schemas'
$global:DatabasePath = Join-Path $global:PlaybookRoot 'database'
$global:ExampleMigrationsProject = Join-Path $global:DatabasePath 'Shop.Database.Migrations'
$global:ExampleDescriptionsPath = Join-Path $global:DatabasePath 'Shop.Database/ColumnDescriptions.json'
$global:ExampleEnvironmentsPath = Join-Path $global:DatabasePath 'environments.json'
$global:ExampleCapturedColumnsPath = Join-Path $global:DatabasePath 'cdc/captured-columns.json'
$global:ExampleProfilePath = Join-Path $global:DatabasePath 'publish/Shop.Database.publish.xml'
$global:BuiltSchemaDacpac = Join-Path $global:DatabasePath 'Shop.Database/bin/Release/Shop.Database.dacpac'

$global:TestResourceGroup = 'my-rg'
$global:TestServer = 'my-sql-prod'
$global:TestSourceDatabase = 'my-shop'

foreach ($lib in @(Get-ChildItem -LiteralPath (Join-Path $global:ScriptsPath 'lib') -Filter '*.ps1' -File)) {
    . $lib.FullName
}
. (Join-Path $PSScriptRoot 'FakeAzure.ps1')
. (Join-Path $PSScriptRoot 'FakeSqlPackage.ps1')

$global:AllProjects = @(
    'Shop.Database'
    'Shop.Database.Migrations'
    'Shop.Database.ReferenceData'
    'Shop.Database.SeedConfiguration.Development'
    'Shop.Database.SeedConfiguration.Test'
    'Shop.Database.SeedConfiguration.Production'
    'Shop.Database.TestData'
    'Shop.Database.DropAll'
)

function New-TestColumn {
    <# A column definition for New-TestDacpac. #>
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string] $Type = 'int',
        [object] $Length = $null,
        [object] $Precision = $null,
        [object] $Scale = $null,
        [switch] $Max,
        [switch] $Nullable,
        [switch] $PrimaryKey,
        [string] $References,
        [switch] $Computed
    )
    @{
        Name = $Name; Type = $Type; Length = $Length; Precision = $Precision; Scale = $Scale
        Max = [bool]$Max; Nullable = [bool]$Nullable; PrimaryKey = [bool]$PrimaryKey; References = $References; Computed = [bool]$Computed
    }
}

function ConvertTo-TestModelXml {
    <#
    .SYNOPSIS
        A minimal model.xml with the elements Get-DacpacTable reads.
    .PARAMETER Tables
        'Schema.Table' -> array of New-TestColumn hashtables.
    #>
    param([System.Collections.IDictionary] $Tables = @{})
    $escape = { param($value) [System.Security.SecurityElement]::Escape([string]$value) }
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine('<?xml version="1.0" encoding="utf-8"?>')
    [void]$builder.AppendLine('<DataSchemaModel FileFormatVersion="1.2" SchemaVersion="2.9" DspName="Microsoft.Data.Tools.Schema.Sql.SqlAzureV12DatabaseSchemaProvider" xmlns="http://schemas.microsoft.com/sqlserver/dac/Serialization/2012/02">')
    [void]$builder.AppendLine('<Model>')
    $constraints = [System.Text.StringBuilder]::new()
    foreach ($tableName in @($Tables.Keys)) {
        $schema, $table = $tableName.Split('.', 2)
        $tableId = "[$schema].[$table]"
        [void]$builder.AppendLine("<Element Type=`"SqlTable`" Name=`"$(& $escape $tableId)`"><Relationship Name=`"Columns`">")
        foreach ($column in @($Tables[$tableName])) {
            $columnId = "$tableId.[$($column.Name)]"
            $elementType = if ($column.Computed) { 'SqlComputedColumn' } else { 'SqlSimpleColumn' }
            [void]$builder.Append("<Entry><Element Type=`"$elementType`" Name=`"$(& $escape $columnId)`">")
            if (-not $column.Nullable -and -not $column.Computed) {
                [void]$builder.Append('<Property Name="IsNullable" Value="False" />')
            }
            if (-not $column.Computed) {
                [void]$builder.Append('<Relationship Name="TypeSpecifier"><Entry><Element Type="SqlTypeSpecifier">')
                if ($null -ne $column.Length) { [void]$builder.Append("<Property Name=`"Length`" Value=`"$($column.Length)`" />") }
                if ($null -ne $column.Precision) { [void]$builder.Append("<Property Name=`"Precision`" Value=`"$($column.Precision)`" />") }
                if ($null -ne $column.Scale) { [void]$builder.Append("<Property Name=`"Scale`" Value=`"$($column.Scale)`" />") }
                if ($column.Max) { [void]$builder.Append('<Property Name="IsMax" Value="True" />') }
                [void]$builder.Append("<Relationship Name=`"Type`"><Entry><References ExternalSource=`"BuiltIns`" Name=`"[$($column.Type)]`" /></Entry></Relationship>")
                [void]$builder.Append('</Element></Entry></Relationship>')
            }
            [void]$builder.AppendLine('</Element></Entry>')
            if ($column.PrimaryKey) {
                [void]$constraints.AppendLine("<Element Type=`"SqlPrimaryKeyConstraint`" Name=`"[$schema].[PK_$table]`"><Relationship Name=`"ColumnSpecifications`"><Entry><Element Type=`"SqlIndexedColumnSpecification`"><Relationship Name=`"Column`"><Entry><References Name=`"$(& $escape $columnId)`" /></Entry></Relationship></Element></Entry></Relationship></Element>")
            }
            if ($column.References) {
                $refSchema, $refTable = $column.References.Split('.', 2)
                [void]$constraints.AppendLine("<Element Type=`"SqlForeignKeyConstraint`" Name=`"[$schema].[FK_${table}_$($column.Name)]`"><Relationship Name=`"Columns`"><Entry><References Name=`"$(& $escape $columnId)`" /></Entry></Relationship><Relationship Name=`"ForeignTable`"><Entry><References Name=`"[$refSchema].[$refTable]`" /></Entry></Relationship></Element>")
            }
        }
        [void]$builder.AppendLine('</Relationship></Element>')
    }
    [void]$builder.Append($constraints.ToString())
    [void]$builder.AppendLine('</Model>')
    [void]$builder.AppendLine('</DataSchemaModel>')
    $builder.ToString()
}

function New-TestDacpac {
    <# Writes a dacpac (a zip with model.xml) and returns its path. #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [System.Collections.IDictionary] $Tables = @{}
    )
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression
    $stream = [System.IO.File]::Create($Path)
    try {
        $zip = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $writer = [System.IO.StreamWriter]::new($zip.CreateEntry('model.xml').Open())
            try { $writer.Write((ConvertTo-TestModelXml -Tables $Tables)) } finally { $writer.Dispose() }
        }
        finally { $zip.Dispose() }
    }
    finally { $stream.Dispose() }
    $Path
}

function Get-TestShopTables {
    <# The captured tables of the sample, as New-TestDacpac input; change a copy to make a candidate. #>
    [ordered]@{
        'Sales.Customer' = @(
            New-TestColumn -Name 'CustomerId' -PrimaryKey
            New-TestColumn -Name 'EmailAddress' -Type 'nvarchar' -Length 320
            New-TestColumn -Name 'DisplayName' -Type 'nvarchar' -Length 200
        )
        'Sales.Order'    = @(
            New-TestColumn -Name 'OrderId' -PrimaryKey
            New-TestColumn -Name 'CustomerId' -References 'Sales.Customer'
            New-TestColumn -Name 'OrderStatusId' -Type 'tinyint'
            New-TestColumn -Name 'OrderedAt' -Type 'datetime2' -Scale 7
            New-TestColumn -Name 'CurrencyCode' -Type 'char' -Length 3
            New-TestColumn -Name 'Total' -Type 'decimal' -Precision 19 -Scale 4 -Nullable
        )
    }
}

function New-TestArtifact {
    <#
    .SYNOPSIS
        An artifact folder with one dacpac per project, like the pipeline artifact. The schema
        dacpac gets -Tables; the others are empty models.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [System.Collections.IDictionary] $Tables = (Get-TestShopTables),
        [string[]] $Projects = $global:AllProjects
    )
    foreach ($project in $Projects) {
        $projectTables = if ($project -eq 'Shop.Database') { $Tables } else { @{} }
        New-TestDacpac -Path (Join-Path $Path "$project/$project.dacpac") -Tables $projectTables | Out-Null
    }
    $Path
}

function New-TestMigrationProject {
    <#
    .SYNOPSIS
        A migrations project folder with the given migrations.
    .PARAMETER Migrations
        Folder name -> hashtable of script file name -> SQL text.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [System.Collections.IDictionary] $Migrations = @{}
    )
    New-Item -ItemType Directory -Path (Join-Path $Path 'Migrations') -Force | Out-Null
    foreach ($folder in @($Migrations.Keys)) {
        $folderPath = Join-Path $Path "Migrations/$folder"
        New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
        foreach ($file in @($Migrations[$folder].Keys)) {
            [System.IO.File]::WriteAllText((Join-Path $folderPath $file), [string]$Migrations[$folder][$file])
        }
    }
    $Path
}

function Get-TestConnectionString {
    param([string] $Database = 'my-shop')
    "Server=tcp:my-sql-test.database.windows.net,1433;Initial Catalog=$Database;Encrypt=True;"
}

function Initialize-TestEnvironment {
    Reset-FakeAzure
    Reset-FakeSqlPackage
    Add-FakeDatabase -ResourceGroup $global:TestResourceGroup -Server $global:TestServer -Name $global:TestSourceDatabase
}
