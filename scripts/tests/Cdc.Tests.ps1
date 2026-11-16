BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"

    $script:DacpacCount = 0
    function ConvertTo-ModelTable([System.Collections.IDictionary] $Tables) {
        $script:DacpacCount++
        @(Get-DacpacTable -Model (Read-DacpacModel -Path (New-TestDacpac -Path (Join-Path $TestDrive "model$DacpacCount.dacpac") -Tables $Tables)))
    }

    function Get-ChangedShop {
        <# The test shop tables with one column of one table replaced. #>
        param([string] $Table, [string] $Column, [object] $Replacement)
        $tables = Get-TestShopTables
        $tables[$Table] = @($tables[$Table] | ForEach-Object { if ($_.Name -eq $Column) { $Replacement } else { $_ } } | Where-Object { $null -ne $_ })
        $tables
    }

    $script:Captured = [ordered]@{ tables = [ordered]@{ 'Sales.Customer' = @('CustomerId', 'EmailAddress'); 'Sales.Order' = @('OrderId', 'OrderedAt', 'Total') } }
    $script:Baseline = ConvertTo-ModelTable (Get-TestShopTables)
}

Describe 'Compare-CdcColumn' {
    It 'finds nothing when no captured column changes' {
        @(Compare-CdcColumn -BaselineTables $Baseline -CandidateTables (ConvertTo-ModelTable (Get-TestShopTables)) -CapturedColumns $Captured) | Should -BeNullOrEmpty
    }

    It 'ignores changes to columns that are not captured' {
        $candidate = ConvertTo-ModelTable (Get-ChangedShop -Table 'Sales.Customer' -Column 'DisplayName' -Replacement (New-TestColumn -Name 'DisplayName' -Type 'nvarchar' -Length 50))
        @(Compare-CdcColumn -BaselineTables $Baseline -CandidateTables $candidate -CapturedColumns $Captured) | Should -BeNullOrEmpty
    }

    It 'reports <Case> as <Severity>' -TestCases @(
        @{ Case = 'a type change'; Table = 'Sales.Customer'; Column = 'CustomerId'; New = @{ Name = 'CustomerId'; Type = 'bigint'; PrimaryKey = $true }; Severity = 'Error'; Message = '*changes type from int to bigint*' }
        @{ Case = 'a narrower string'; Table = 'Sales.Customer'; Column = 'EmailAddress'; New = @{ Name = 'EmailAddress'; Type = 'nvarchar'; Length = 200 }; Severity = 'Error'; Message = '*becomes narrower: nvarchar(320) to nvarchar(200)*' }
        @{ Case = 'a string to varchar'; Table = 'Sales.Customer'; Column = 'EmailAddress'; New = @{ Name = 'EmailAddress'; Type = 'varchar'; Length = 320 }; Severity = 'Error'; Message = '*changes type from nvarchar(320) to varchar(320)*' }
        @{ Case = 'less scale'; Table = 'Sales.Order'; Column = 'Total'; New = @{ Name = 'Total'; Type = 'decimal'; Precision = 19; Scale = 2; Nullable = $true }; Severity = 'Error'; Message = '*becomes narrower: decimal(19,4) to decimal(19,2)*' }
        @{ Case = 'less time precision'; Table = 'Sales.Order'; Column = 'OrderedAt'; New = @{ Name = 'OrderedAt'; Type = 'datetime2'; Scale = 3 }; Severity = 'Error'; Message = '*becomes narrower: datetime2(7) to datetime2(3)*' }
        @{ Case = 'a wider string'; Table = 'Sales.Customer'; Column = 'EmailAddress'; New = @{ Name = 'EmailAddress'; Type = 'nvarchar'; Length = 400 }; Severity = 'Warning'; Message = '*becomes wider: nvarchar(320) to nvarchar(400). Recreate the capture instance*' }
        @{ Case = 'a nullability change'; Table = 'Sales.Order'; Column = 'Total'; New = @{ Name = 'Total'; Type = 'decimal'; Precision = 19; Scale = 4 }; Severity = 'Warning'; Message = '*becomes NOT NULL*' }
        @{ Case = 'a dropped column'; Table = 'Sales.Order'; Column = 'Total'; New = $null; Severity = 'Warning'; Message = '*captured and dropped*Recreate the capture instance without it first*' }
    ) {
        $replacement = if ($null -ne $New) { New-TestColumn @New } else { $null }
        $candidate = ConvertTo-ModelTable (Get-ChangedShop -Table $Table -Column $Column -Replacement $replacement)
        $findings = @(Compare-CdcColumn -BaselineTables $Baseline -CandidateTables $candidate -CapturedColumns $Captured)
        $findings.Count | Should -Be 1
        $findings[0].Severity | Should -Be $Severity
        $findings[0].Table | Should -Be $Table
        $findings[0].Column | Should -Be $Column
        $findings[0].Message | Should -BeLike $Message
    }

    It 'treats (max) to a fixed size as narrower' {
        $baseline = ConvertTo-ModelTable ([ordered]@{ 'Sales.Note' = @(New-TestColumn -Name 'Text' -Type 'nvarchar' -Max) })
        $candidate = ConvertTo-ModelTable ([ordered]@{ 'Sales.Note' = @(New-TestColumn -Name 'Text' -Type 'nvarchar' -Length 4000) })
        $findings = @(Compare-CdcColumn -BaselineTables $baseline -CandidateTables $candidate -CapturedColumns ([ordered]@{ tables = [ordered]@{ 'Sales.Note' = @('Text') } }))
        $findings[0].Severity | Should -Be 'Error'
        $findings[0].Message | Should -BeLike '*nvarchar(max) to nvarchar(4000)*'
    }

    It 'warns about a dropped captured table and about entries the baseline does not have' {
        $tables = Get-TestShopTables
        $tables.Remove('Sales.Order')
        $captured = [ordered]@{ tables = [ordered]@{ 'Sales.Order' = @('OrderId'); 'Sales.Customer' = @('Phone'); 'Sales.Refund' = @('RefundId') } }
        $findings = @(Compare-CdcColumn -BaselineTables $Baseline -CandidateTables (ConvertTo-ModelTable $tables) -CapturedColumns $captured)
        @($findings | ForEach-Object Severity | Select-Object -Unique) | Should -Be @('Warning')
        @($findings | ForEach-Object Message) | Should -Be @(
            'Sales.Customer.Phone is listed as captured but is not in the baseline model.'
            'Sales.Order is captured and dropped by this change. Disable its capture instance first.'
            'Sales.Refund is listed as captured but is not in the baseline model.'
        )
    }
}

Describe 'Read-CapturedColumn' {
    It 'reads the example file' {
        $captured = Read-CapturedColumn -Path $ExampleCapturedColumnsPath
        @($captured.tables.Keys) | Should -Contain 'Sales.Order'
    }

    It 'rejects a file without tables' {
        $path = Join-Path $TestDrive 'captured.json'
        [System.IO.File]::WriteAllText($path, '{ "columns": [] }')
        { Read-CapturedColumn -Path $path } | Should -Throw "*expected an object with a 'tables' object*"
    }
}

BeforeDiscovery {
    $script:HasBuiltDacpac = Test-Path -LiteralPath (Join-Path $PSScriptRoot '../../database/Shop.Database/bin/Release/Shop.Database.dacpac')
}

Describe 'The example captured columns against the built dacpac' -Skip:(-not $HasBuiltDacpac) {
    It 'all exist in the model, so the check compares real columns' {
        $tables = @(Get-DacpacTable -Model (Read-DacpacModel -Path $BuiltSchemaDacpac))
        @(Compare-CdcColumn -BaselineTables $tables -CandidateTables $tables -CapturedColumns (Read-CapturedColumn -Path $ExampleCapturedColumnsPath)) | Should -BeNullOrEmpty
    }
}
