BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"
}

Describe 'Read-DacpacModel' {
    It 'reads model.xml from a dacpac' {
        $path = New-TestDacpac -Path (Join-Path $TestDrive 'one.dacpac') -Tables (Get-TestShopTables)
        $model = Read-DacpacModel -Path $path
        $model | Should -BeOfType ([System.Xml.XmlDocument])
        $model.DocumentElement.LocalName | Should -Be 'DataSchemaModel'
    }

    It 'fails on <Case>' -TestCases @(
        @{ Case = 'a missing file'; Kind = 'missing'; Expected = '*Dacpac not found*' }
        @{ Case = 'a file that is not a zip'; Kind = 'text'; Expected = '*not a zip file*' }
        @{ Case = 'a zip without model.xml'; Kind = 'zip'; Expected = '*has no model.xml*' }
    ) {
        $path = Join-Path $TestDrive "$Kind.dacpac"
        if ($Kind -eq 'text') {
            [System.IO.File]::WriteAllText($path, 'not a zip')
        }
        if ($Kind -eq 'zip') {
            Add-Type -AssemblyName System.IO.Compression
            $stream = [System.IO.File]::Create($path)
            $zip = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create)
            [void]$zip.CreateEntry('Origin.xml')
            $zip.Dispose()
            $stream.Dispose()
        }
        { Read-DacpacModel -Path $path } | Should -Throw $Expected
    }
}

Describe 'Get-DacpacTable' {
    BeforeAll {
        $path = New-TestDacpac -Path (Join-Path $TestDrive 'tables.dacpac') -Tables ([ordered]@{
                'Sales.Order'    = @(
                    New-TestColumn -Name 'OrderId' -PrimaryKey
                    New-TestColumn -Name 'CustomerId' -References 'Sales.Customer'
                    New-TestColumn -Name 'Note' -Type 'nvarchar' -Max -Nullable
                    New-TestColumn -Name 'Total' -Type 'decimal' -Precision 19 -Scale 4
                    New-TestColumn -Name 'OrderedAt' -Type 'datetime2' -Scale 3
                    New-TestColumn -Name 'Margin' -Computed
                )
                'Sales.Customer' = @(New-TestColumn -Name 'CustomerId' -PrimaryKey)
            })
        $script:Tables = @(Get-DacpacTable -Model (Read-DacpacModel -Path $path))
        $script:Order = @($Tables | Where-Object Name -eq 'Sales.Order')[0]
        function Get-OrderColumn([string] $Name) { @($Order.Columns | Where-Object Name -eq $Name)[0] }
    }

    It 'emits every table with schema and name' {
        @($Tables | ForEach-Object Name) | Should -Be @('Sales.Order', 'Sales.Customer')
        $Order.Schema | Should -Be 'Sales'
        $Order.Table | Should -Be 'Order'
        @($Order.Columns | ForEach-Object Name) | Should -Be @('OrderId', 'CustomerId', 'Note', 'Total', 'OrderedAt', 'Margin')
    }

    It 'reads type, size and nullability' {
        $note = Get-OrderColumn 'Note'
        $note.DataType | Should -Be 'nvarchar'
        $note.IsMax | Should -BeTrue
        $note.IsNullable | Should -BeTrue
        Format-ColumnType -Column $note | Should -Be 'nvarchar(max)'
        Format-ColumnType -Column (Get-OrderColumn 'Total') | Should -Be 'decimal(19,4)'
        Format-ColumnType -Column (Get-OrderColumn 'OrderedAt') | Should -Be 'datetime2(3)'
        Format-ColumnType -Column (Get-OrderColumn 'OrderId') | Should -Be 'int'
        (Get-OrderColumn 'OrderId').IsNullable | Should -BeFalse
    }

    It 'marks primary keys and single-column foreign keys' {
        (Get-OrderColumn 'OrderId').IsPrimaryKey | Should -BeTrue
        (Get-OrderColumn 'CustomerId').IsPrimaryKey | Should -BeFalse
        (Get-OrderColumn 'CustomerId').ReferencedTable | Should -Be 'Sales.Customer'
        (Get-OrderColumn 'OrderId').ReferencedTable | Should -BeNullOrEmpty
    }

    It 'gives computed columns the type computed' {
        (Get-OrderColumn 'Margin').DataType | Should -Be 'computed'
    }

    It 'splits bracketed names, including escaped brackets' {
        @(Split-SqlName -Name '[Sales].[Order].[CustomerId]') | Should -Be @('Sales', 'Order', 'CustomerId')
        @(Split-SqlName -Name '[dbo].[odd]]name]') | Should -Be @('dbo', 'odd]name')
    }

    It 'emits nothing for a model without tables' {
        $path = New-TestDacpac -Path (Join-Path $TestDrive 'empty.dacpac')
        @(Get-DacpacTable -Model (Read-DacpacModel -Path $path)).Count | Should -Be 0
    }
}

BeforeDiscovery {
    $script:HasBuiltDacpac = Test-Path -LiteralPath (Join-Path $PSScriptRoot '../../database/Shop.Database/bin/Release/Shop.Database.dacpac')
}

Describe 'The built sample schema dacpac' -Skip:(-not $HasBuiltDacpac) {
    # Runs after 'dotnet build database/build.proj -c Release' (CI builds first).
    BeforeAll {
        $script:Built = @(Get-DacpacTable -Model (Read-DacpacModel -Path $BuiltSchemaDacpac))
    }

    It 'contains the sample tables' {
        @($Built | ForEach-Object Name) | Should -Contain 'Sales.Order'
        @($Built | ForEach-Object Name) | Should -Contain 'dbo.DeploymentHistory'
    }

    It 'reads the order columns as declared' {
        $order = @($Built | Where-Object Name -eq 'Sales.Order')[0]
        $currency = @($order.Columns | Where-Object Name -eq 'CurrencyCode')[0]
        Format-ColumnType -Column $currency | Should -Be 'char(3)'
        @($order.Columns | Where-Object Name -eq 'OrderId')[0].IsPrimaryKey | Should -BeTrue
        @($order.Columns | Where-Object Name -eq 'CustomerId')[0].ReferencedTable | Should -Be 'Sales.Customer'
    }
}
