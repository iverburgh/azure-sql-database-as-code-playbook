Set-StrictMode -Version Latest

<#
    Reads the schema model from a built .dacpac without DacFx. A dacpac is a zip file; its
    model.xml lists every element of the model. Only what the checks in this playbook need is
    read: tables, their columns with type, size and nullability, primary keys and foreign keys.
#>

$script:DacNamespace = 'http://schemas.microsoft.com/sqlserver/dac/Serialization/2012/02'

function Read-DacpacModel {
    <# Returns model.xml of a dacpac as an XmlDocument. #>
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Dacpac not found: $Path"
    }
    Add-Type -AssemblyName System.IO.Compression
    $stream = [System.IO.File]::OpenRead((Resolve-Path -LiteralPath $Path).ProviderPath)
    try {
        $zip = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Read)
        try {
            $entry = $zip.GetEntry('model.xml')
            if ($null -eq $entry) {
                throw "$Path is not a dacpac: it has no model.xml."
            }
            $reader = [System.IO.StreamReader]::new($entry.Open())
            try {
                $document = [System.Xml.XmlDocument]::new()
                $document.XmlResolver = $null
                $document.LoadXml($reader.ReadToEnd())
                , $document
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $zip.Dispose()
        }
    }
    catch [System.IO.InvalidDataException] {
        throw "$Path is not a dacpac: it is not a zip file."
    }
    finally {
        $stream.Dispose()
    }
}

function Split-SqlName {
    <# '[Sales].[Order].[CustomerId]' -> 'Sales', 'Order', 'CustomerId'. #>
    param([Parameter(Mandatory)] [string] $Name)
    foreach ($match in [regex]::Matches($Name, '\[((?:[^\]]|\]\])*)\]')) {
        $match.Groups[1].Value -replace '\]\]', ']'
    }
}

function Get-DacpacTable {
    <#
    .SYNOPSIS
        Emits one object per table in the model: Name ('Schema.Table'), Schema, Table and Columns.
    .DESCRIPTION
        Each column has Name, DataType, Length, IsMax, Precision, Scale, IsNullable, IsPrimaryKey
        and ReferencedTable ('Schema.Table' of a single-column foreign key, or $null).
    #>
    param([Parameter(Mandatory)] [System.Xml.XmlDocument] $Model)

    $ns = [System.Xml.XmlNamespaceManager]::new($Model.NameTable)
    $ns.AddNamespace('d', $script:DacNamespace)

    $primaryKeyColumns = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($reference in @($Model.SelectNodes("//d:Element[@Type='SqlPrimaryKeyConstraint']/d:Relationship[@Name='ColumnSpecifications']//d:Relationship[@Name='Column']/d:Entry/d:References", $ns))) {
        [void]$primaryKeyColumns.Add($reference.GetAttribute('Name'))
    }

    $foreignKeys = @{}
    foreach ($constraint in @($Model.SelectNodes("//d:Element[@Type='SqlForeignKeyConstraint']", $ns))) {
        $columns = @($constraint.SelectNodes("d:Relationship[@Name='Columns']/d:Entry/d:References", $ns))
        $foreignTable = $constraint.SelectSingleNode("d:Relationship[@Name='ForeignTable']/d:Entry/d:References", $ns)
        if ($columns.Count -eq 1 -and $null -ne $foreignTable) {
            $foreignKeys[$columns[0].GetAttribute('Name').ToLowerInvariant()] = (@(Split-SqlName -Name $foreignTable.GetAttribute('Name')) -join '.')
        }
    }

    foreach ($table in @($Model.SelectNodes("/d:DataSchemaModel/d:Model/d:Element[@Type='SqlTable']", $ns))) {
        $tableParts = @(Split-SqlName -Name $table.GetAttribute('Name'))
        $columns = [System.Collections.Generic.List[object]]::new()
        foreach ($column in @($table.SelectNodes("d:Relationship[@Name='Columns']/d:Entry/d:Element", $ns))) {
            $columnName = $column.GetAttribute('Name')
            $nullable = $column.SelectSingleNode("d:Property[@Name='IsNullable']", $ns)
            $specifier = $column.SelectSingleNode("d:Relationship[@Name='TypeSpecifier']/d:Entry/d:Element", $ns)
            $dataType = if ($column.GetAttribute('Type') -eq 'SqlComputedColumn') { 'computed' } else { $null }
            $length = $null; $precision = $null; $scale = $null; $isMax = $false
            if ($null -ne $specifier) {
                $type = $specifier.SelectSingleNode("d:Relationship[@Name='Type']/d:Entry/d:References", $ns)
                if ($null -ne $type) {
                    $dataType = @(Split-SqlName -Name $type.GetAttribute('Name'))[-1]
                }
                foreach ($property in @($specifier.SelectNodes('d:Property', $ns))) {
                    switch ($property.GetAttribute('Name')) {
                        'Length' { $length = [int]$property.GetAttribute('Value') }
                        'Precision' { $precision = [int]$property.GetAttribute('Value') }
                        'Scale' { $scale = [int]$property.GetAttribute('Value') }
                        'IsMax' { $isMax = $property.GetAttribute('Value') -eq 'True' }
                    }
                }
            }
            $referenced = $null
            if ($foreignKeys.ContainsKey($columnName.ToLowerInvariant())) {
                $referenced = $foreignKeys[$columnName.ToLowerInvariant()]
            }
            $columns.Add([pscustomobject]@{
                    Name            = @(Split-SqlName -Name $columnName)[-1]
                    DataType        = $dataType
                    Length          = $length
                    IsMax           = $isMax
                    Precision       = $precision
                    Scale           = $scale
                    IsNullable      = ($null -eq $nullable -or $nullable.GetAttribute('Value') -ne 'False')
                    IsPrimaryKey    = $primaryKeyColumns.Contains($columnName)
                    ReferencedTable = $referenced
                })
        }
        [pscustomobject]@{
            Name    = $tableParts -join '.'
            Schema  = $tableParts[0]
            Table   = $tableParts[-1]
            Columns = $columns.ToArray()
        }
    }
}

function Format-ColumnType {
    <# 'nvarchar(200)', 'decimal(19,4)', 'varchar(max)', 'int'. #>
    param([Parameter(Mandatory)] [object] $Column)
    if ($Column.IsMax) { return "$($Column.DataType)(max)" }
    if ($null -ne $Column.Length) { return "$($Column.DataType)($($Column.Length))" }
    if ($null -ne $Column.Precision) { return "$($Column.DataType)($($Column.Precision),$([int]$Column.Scale))" }
    if ($null -ne $Column.Scale) { return "$($Column.DataType)($($Column.Scale))" }
    "$($Column.DataType)"
}
