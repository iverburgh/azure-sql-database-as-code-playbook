BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"

    function New-Descriptions {
        param([System.Collections.IDictionary] $Tables = [ordered]@{}, [string[]] $Excluded = @())
        [ordered]@{
            standardColumns = [ordered]@{ CreatedAt = 'Moment the row was created.' }
            excludedTables  = $Excluded
            tables          = $Tables
        }
    }

    $script:ModelTables = @(Get-DacpacTable -Model (Read-DacpacModel -Path (New-TestDacpac -Path (Join-Path $TestDrive 'model.dacpac') -Tables ([ordered]@{
                        'Sales.Order'           = @(
                            New-TestColumn -Name 'OrderId' -PrimaryKey
                            New-TestColumn -Name 'CustomerId' -References 'Sales.Customer'
                            New-TestColumn -Name 'CreatedAt' -Type 'datetimeoffset' -Scale 7
                            New-TestColumn -Name 'Note' -Type 'nvarchar' -Length 500 -Nullable
                        )
                        'dbo.DeploymentHistory' = @(New-TestColumn -Name 'DeploymentHistoryId' -PrimaryKey)
                    }))))
}

Describe 'Compare-ColumnDescription' {
    It 'finds nothing when every table and column is described' {
        $descriptions = New-Descriptions -Excluded @('dbo.DeploymentHistory') -Tables ([ordered]@{
                'Sales.Order' = [ordered]@{ description = 'An order.'; columns = [ordered]@{ OrderId = 'Id.'; CustomerId = 'Customer.'; CreatedAt = 'Created.'; Note = 'Note.' } }
            })
        @(Compare-ColumnDescription -Descriptions $descriptions -Tables $ModelTables) | Should -BeNullOrEmpty
    }

    It 'reports missing, empty, obsolete and unknown entries' {
        $descriptions = New-Descriptions -Excluded @('dbo.Gone') -Tables ([ordered]@{
                'Sales.Order'  = [ordered]@{ description = ''; columns = [ordered]@{ orderid = 'Id.'; CustomerId = ' '; CreatedAt = 'Created.'; Removed = 'Old.' } }
                'Sales.Legacy' = [ordered]@{ description = 'Old table.'; columns = [ordered]@{} }
            })
        $findings = @(Compare-ColumnDescription -Descriptions $descriptions -Tables $ModelTables)
        @($findings | ForEach-Object { "$($_.Kind) $($_.Table) $($_.Column)".Trim() }) | Should -Be @(
            'UnknownExcludedTable dbo.Gone'
            'EmptyDescription Sales.Order'
            'EmptyDescription Sales.Order CustomerId'
            'MissingColumn Sales.Order Note'
            'ObsoleteColumn Sales.Order Removed'
            'MissingTable dbo.DeploymentHistory'
            'ObsoleteTable Sales.Legacy'
        )
    }

    It 'reports a table that is both excluded and described' {
        $descriptions = New-Descriptions -Excluded @('dbo.DeploymentHistory') -Tables ([ordered]@{
                'Sales.Order'           = [ordered]@{ description = 'An order.'; columns = [ordered]@{ OrderId = 'Id.'; CustomerId = 'Customer.'; CreatedAt = 'Created.'; Note = 'Note.' } }
                'dbo.DeploymentHistory' = [ordered]@{ description = 'History.'; columns = [ordered]@{} }
            })
        $findings = @(Compare-ColumnDescription -Descriptions $descriptions -Tables $ModelTables)
        $findings.Count | Should -Be 1
        $findings[0].Message | Should -BeLike '*both excluded and described*'
    }
}

Describe 'Sync-ColumnDescription' {
    It 'adds missing columns with a proposal, keeps existing text, removes obsolete entries and sorts' {
        $descriptions = New-Descriptions -Excluded @('dbo.DeploymentHistory', 'dbo.Gone') -Tables ([ordered]@{
                'Sales.Order'  = [ordered]@{ description = 'An order.'; columns = [ordered]@{ Note = 'Free text.'; Removed = 'Old.' } }
                'Sales.Legacy' = [ordered]@{ description = 'Old table.'; columns = [ordered]@{} }
            })
        $synced = Sync-ColumnDescription -Descriptions $descriptions -Tables $ModelTables
        @($synced.tables.Keys) | Should -Be @('Sales.Order')
        $synced.excludedTables | Should -Be @('dbo.DeploymentHistory')
        $order = $synced.tables['Sales.Order']
        $order.description | Should -Be 'An order.'
        @($order.columns.Keys) | Should -Be @('CreatedAt', 'CustomerId', 'Note', 'OrderId')
        $order.columns.CreatedAt | Should -Be 'Moment the row was created.'
        $order.columns.CustomerId | Should -Be 'Reference to Sales.Customer.'
        $order.columns.OrderId | Should -Be 'Unique identifier of the order.'
        $order.columns.Note | Should -Be 'Free text.'
    }

    It 'leaves a column without a rule empty for a human to describe' {
        $synced = Sync-ColumnDescription -Descriptions (New-Descriptions -Excluded @('dbo.DeploymentHistory')) -Tables $ModelTables
        $synced.tables['Sales.Order'].description | Should -Be ''
        $synced.tables['Sales.Order'].columns.Note | Should -Be ''
        @(Compare-ColumnDescription -Descriptions $synced -Tables $ModelTables | ForEach-Object Kind) | Should -Be @('EmptyDescription', 'EmptyDescription')
    }

    It 'turns PascalCase into words for the proposal' {
        ConvertTo-WordPhrase -Name 'ProductCategory' | Should -Be 'product category'
        ConvertTo-WordPhrase -Name 'Order' | Should -Be 'order'
    }
}

Describe 'ConvertTo-ColumnDescriptionSql' {
    It 'writes one sorted extended property per description, escapes quotes and skips empty ones' {
        $descriptions = New-Descriptions -Tables ([ordered]@{
                'Sales.Order'    = [ordered]@{ description = "The customer's order."; columns = [ordered]@{ Note = ''; CustomerId = 'Customer.' } }
                'Catalog.Product' = [ordered]@{ description = ''; columns = [ordered]@{ Sku = 'Code.' } }
            })
        $lines = @((ConvertTo-ColumnDescriptionSql -Descriptions $descriptions).TrimEnd("`n").Split("`n") | Where-Object { $_ -notlike '--*' })
        $lines | Should -Be @(
            "EXECUTE sp_addextendedproperty @name = N'MS_Description', @value = N'Code.', @level0type = N'SCHEMA', @level0name = N'Catalog', @level1type = N'TABLE', @level1name = N'Product', @level2type = N'COLUMN', @level2name = N'Sku';"
            'GO'
            "EXECUTE sp_addextendedproperty @name = N'MS_Description', @value = N'The customer''s order.', @level0type = N'SCHEMA', @level0name = N'Sales', @level1type = N'TABLE', @level1name = N'Order';"
            'GO'
            "EXECUTE sp_addextendedproperty @name = N'MS_Description', @value = N'Customer.', @level0type = N'SCHEMA', @level0name = N'Sales', @level1type = N'TABLE', @level1name = N'Order', @level2type = N'COLUMN', @level2name = N'CustomerId';"
            'GO'
        )
    }

    It 'matches the committed SQL of the sample' {
        $sql = ConvertTo-ColumnDescriptionSql -Descriptions (Read-ColumnDescription -Path $ExampleDescriptionsPath)
        Test-GeneratedFileCurrent -Path (Join-Path $DatabasePath 'Shop.Database/Generated/ColumnDescriptions.sql') -Content $sql | Should -BeTrue
    }
}

Describe 'Read-ColumnDescription' {
    It 'rejects <Case>' -TestCases @(
        @{ Case = 'a missing section'; Json = '{ "standardColumns": {}, "tables": {} }'; Expected = "*missing 'excludedTables'*" }
        @{ Case = 'a table name without schema'; Json = '{ "standardColumns": {}, "excludedTables": [], "tables": { "Order": { "description": "", "columns": {} } } }'; Expected = '*must be written as Schema.Table*' }
        @{ Case = 'a table without columns'; Json = '{ "standardColumns": {}, "excludedTables": [], "tables": { "Sales.Order": { "description": "" } } }'; Expected = "*must have a 'columns' object*" }
    ) {
        $path = Join-Path $TestDrive "invalid-$($Case.GetHashCode()).json"
        [System.IO.File]::WriteAllText($path, $Json)
        { Read-ColumnDescription -Path $path } | Should -Throw $Expected
    }
}

BeforeDiscovery {
    $script:HasBuiltDacpac = Test-Path -LiteralPath (Join-Path $PSScriptRoot '../../database/Shop.Database/bin/Release/Shop.Database.dacpac')
}

Describe 'The sample descriptions against the built dacpac' -Skip:(-not $HasBuiltDacpac) {
    It 'describes every table and column of the built model' {
        $tables = @(Get-DacpacTable -Model (Read-DacpacModel -Path $BuiltSchemaDacpac))
        @(Compare-ColumnDescription -Descriptions (Read-ColumnDescription -Path $ExampleDescriptionsPath) -Tables $tables | ForEach-Object Message) | Should -BeNullOrEmpty
    }
}
