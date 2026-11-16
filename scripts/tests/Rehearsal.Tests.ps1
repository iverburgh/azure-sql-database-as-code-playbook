BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"

    Mock Invoke-AzCli { Invoke-FakeAzCli -Arguments $Arguments -AllowFailure:$AllowFailure }
    Mock Invoke-SqlPackage {
        Invoke-FakeSqlPackage -Action $Action -SourceFile $SourceFile -TargetConnectionString $TargetConnectionString -AccessToken $AccessToken `
            -ProfilePath $ProfilePath -OutputPath $OutputPath -Variables $Variables -Properties $Properties
    }

    $script:RehearsalTags = @{ purpose = 'schema-rehearsal'; source = 'my-shop'; build = '41' }
    $script:Location = @{ ResourceGroup = $TestResourceGroup; Server = $TestServer }

    function New-Rehearsal([hashtable] $Extra = @{}) {
        $parameters = @{ ResourceGroup = $TestResourceGroup; Server = $TestServer; SourceDatabase = $TestSourceDatabase; BuildId = '42'; RetryDelaySeconds = 0 }
        foreach ($key in $Extra.Keys) { $parameters[$key] = $Extra[$key] }
        New-SchemaRehearsalDatabase @parameters
    }
}

Describe 'Azure SQL helpers' {
    BeforeEach { Initialize-TestEnvironment }

    It 'builds a connection string without credentials' {
        $connectionString = New-AzureSqlConnectionString -Server 'my-sql-test' -Database 'my-shop'
        $connectionString | Should -BeLike 'Server=tcp:my-sql-test.database.windows.net,1433;Initial Catalog=my-shop;Encrypt=True;*'
        $connectionString | Should -Not -BeLike '*Password*'
        New-AzureSqlConnectionString -Server 'my-sql.example.com' -Database 'x' | Should -BeLike 'Server=tcp:my-sql.example.com,1433;*'
    }

    It 'reads the database name from <Key>' -TestCases @(
        @{ Key = 'Initial Catalog'; ConnectionString = 'Server=localhost;Initial Catalog=Shop;Integrated Security=True' }
        @{ Key = 'Database'; ConnectionString = 'Server=localhost;Database=Shop;Integrated Security=True' }
    ) {
        Get-ConnectionStringDatabase -ConnectionString $ConnectionString | Should -Be 'Shop'
    }

    It 'fails on a connection string without database' {
        { Get-ConnectionStringDatabase -ConnectionString 'Server=localhost' } | Should -Throw '*has no Initial Catalog*'
    }

    It 'gets an access token for Azure SQL' {
        Get-SqlAccessToken | Should -Be 'fake-access-token'
        $global:Fake.Calls[0] | Should -Be 'account get-access-token --resource https://database.windows.net/'
    }

    It 'recognises the rehearsal tag only with the exact value' {
        Test-RehearsalDatabaseTag -Database ([pscustomobject]@{ tags = [pscustomobject]@{ purpose = 'schema-rehearsal' } }) | Should -BeTrue
        Test-RehearsalDatabaseTag -Database ([pscustomobject]@{ tags = [pscustomobject]@{ purpose = 'production' } }) | Should -BeFalse
        Test-RehearsalDatabaseTag -Database ([pscustomobject]@{ tags = $null }) | Should -BeFalse
        Test-RehearsalDatabaseTag -Database ([pscustomobject]@{ name = 'no tags at all' }) | Should -BeFalse
    }
}

Describe 'Invoke-WithConflictRetry' {
    It 'retries a conflicting operation and returns the result' {
        $script:Attempts = 0
        $result = Invoke-WithConflictRetry -DelaySeconds 0 -ScriptBlock {
            $script:Attempts++
            if ($script:Attempts -lt 3) { throw '(ConflictingServerOperation) An operation is in progress.' }
            'done'
        } 3>$null
        $result | Should -Be 'done'
        $script:Attempts | Should -Be 3
    }

    It 'throws other errors at once' {
        $script:Attempts = 0
        { Invoke-WithConflictRetry -DelaySeconds 0 -ScriptBlock { $script:Attempts++; throw '(AuthorizationFailed) No access.' } } | Should -Throw '*AuthorizationFailed*'
        $script:Attempts | Should -Be 1
    }

    It 'gives up after the last attempt' {
        $script:Attempts = 0
        { Invoke-WithConflictRetry -DelaySeconds 0 -MaxAttempts 2 -ScriptBlock { $script:Attempts++; throw '(ConflictingDatabaseOperation) Busy.' } 3>$null } | Should -Throw '*Busy*'
        $script:Attempts | Should -Be 2
    }
}

Describe 'New-SchemaRehearsalDatabase' {
    BeforeEach { Initialize-TestEnvironment }

    It 'copies the source database with the rehearsal tag and returns the name' {
        New-Rehearsal | Should -Be 'my-shop-rehearsal-42'
        $copy = Get-FakeDatabase @Location -Name 'my-shop-rehearsal-42'
        $copy.CopyOf | Should -Be 'my-shop'
        $copy.ServiceObjective | Should -Be 'S3'
        $copy.Tags.purpose | Should -Be 'schema-rehearsal'
        $copy.Tags.source | Should -Be 'my-shop'
        $copy.Tags.build | Should -Be '42'
        @($global:Fake.Calls | Where-Object { $_ -like 'sql db copy*' })[0] | Should -BeLike '*--backup-storage-redundancy Local*'
    }

    It 'creates an empty database in Empty mode' {
        New-Rehearsal -Extra @{ Mode = 'Empty'; ServiceObjective = 'S1' } | Out-Null
        $database = Get-FakeDatabase @Location -Name 'my-shop-rehearsal-42'
        $database.CopyOf | Should -BeNullOrEmpty
        $database.ServiceObjective | Should -Be 'S1'
    }

    It 'changes nothing with -WhatIf' {
        New-Rehearsal -Extra @{ WhatIf = $true } | Should -Be 'my-shop-rehearsal-42'
        $global:Fake.Writes.Count | Should -Be 0
    }

    It 'replaces a tagged leftover of the same build' {
        Add-FakeDatabase @Location -Name 'my-shop-rehearsal-42' -Tags $RehearsalTags
        New-Rehearsal | Out-Null
        @($global:Fake.Writes) | Should -Be @('delete my-shop-rehearsal-42', 'copy my-shop -> my-shop-rehearsal-42')
    }

    It 'refuses to touch an untagged database with the rehearsal name' {
        Add-FakeDatabase @Location -Name 'my-shop-rehearsal-42'
        { New-Rehearsal } | Should -Throw '*is not a rehearsal database*'
        $global:Fake.Writes.Count | Should -Be 0
    }

    It 'fails when the source database does not exist' {
        { New-Rehearsal -Extra @{ SourceDatabase = 'my-missing' } } | Should -Throw '*Source database my-missing does not exist*'
    }

    It 'retries while another operation runs on the server' {
        $global:Fake.Conflicts = 2
        New-Rehearsal 3>$null | Out-Null
        Get-FakeDatabase @Location -Name 'my-shop-rehearsal-42' | Should -Not -BeNullOrEmpty
    }

    It 'rejects a build id that is not a number' {
        { New-Rehearsal -Extra @{ BuildId = '42; drop' } } | Should -Throw
    }

    It 'rejects a name longer than Azure allows' {
        { Get-RehearsalDatabaseName -SourceDatabase ('x' * 120) -BuildId '42' } | Should -Throw '*longer than 128 characters*'
    }
}

Describe 'Remove-SchemaRehearsalDatabase' {
    BeforeEach { Initialize-TestEnvironment }

    It 'removes a tagged rehearsal database' {
        Add-FakeDatabase @Location -Name 'my-shop-rehearsal-42' -Tags $RehearsalTags
        Remove-SchemaRehearsalDatabase @Location -Name 'my-shop-rehearsal-42' -RetryDelaySeconds 0
        Get-FakeDatabase @Location -Name 'my-shop-rehearsal-42' | Should -BeNullOrEmpty
    }

    It 'does nothing when the database is already gone' {
        Remove-SchemaRehearsalDatabase @Location -Name 'my-shop-rehearsal-42' 6>$null
        $global:Fake.Writes.Count | Should -Be 0
    }

    It 'refuses a database without the rehearsal tag' {
        Add-FakeDatabase @Location -Name 'my-shop-rehearsal-42' -Tags @{ purpose = 'production' }
        { Remove-SchemaRehearsalDatabase @Location -Name 'my-shop-rehearsal-42' } | Should -Throw '*It is not removed*'
        Get-FakeDatabase @Location -Name 'my-shop-rehearsal-42' | Should -Not -BeNullOrEmpty
    }

    It 'refuses a name that is not a rehearsal name, even with the tag' {
        Add-FakeDatabase @Location -Name 'my-shop' -Tags $RehearsalTags
        { Remove-SchemaRehearsalDatabase @Location -Name 'my-shop' } | Should -Throw
        Get-FakeDatabase @Location -Name 'my-shop' | Should -Not -BeNullOrEmpty
    }

    It 'changes nothing with -WhatIf' {
        Add-FakeDatabase @Location -Name 'my-shop-rehearsal-42' -Tags $RehearsalTags
        Remove-SchemaRehearsalDatabase @Location -Name 'my-shop-rehearsal-42' -WhatIf
        $global:Fake.Writes.Count | Should -Be 0
    }
}

Describe 'Invoke-SchemaRehearsalCheck' {
    BeforeAll {
        $script:Candidate = New-TestArtifact -Path (Join-Path $TestDrive 'candidate') -Projects @('Shop.Database', 'Shop.Database.Migrations')
        $script:BaselineArtifact = New-TestArtifact -Path (Join-Path $TestDrive 'baseline') -Projects @('Shop.Database', 'Shop.Database.Migrations')
        $narrowed = Get-TestShopTables
        $narrowed['Sales.Customer'] = @(
            New-TestColumn -Name 'CustomerId' -PrimaryKey
            New-TestColumn -Name 'EmailAddress' -Type 'nvarchar' -Length 200
            New-TestColumn -Name 'DisplayName' -Type 'nvarchar' -Length 200
        )
        $script:NarrowedCandidate = New-TestArtifact -Path (Join-Path $TestDrive 'narrowed') -Tables $narrowed -Projects @('Shop.Database', 'Shop.Database.Migrations')

        function Invoke-TestRehearsal([hashtable] $Extra = @{}) {
            $parameters = @{
                TargetConnectionString = (Get-TestConnectionString -Database 'my-shop-rehearsal-42')
                AccessToken            = 'token'
                ArtifactPath           = $Candidate
                OutputPath             = (Join-Path $TestDrive 'rehearsal')
                ProfilePath            = $ExampleProfilePath
                BuildNumber            = '20260101.1'
            }
            foreach ($key in $Extra.Keys) { $parameters[$key] = $Extra[$key] }
            Invoke-SchemaRehearsalCheck @parameters 6>$null
        }
    }

    BeforeEach { Initialize-TestEnvironment }

    It 'passes and deploys the candidate migrations and schema' {
        $result = Invoke-TestRehearsal
        $result.ExitCode | Should -Be 0
        @($result.Findings).Count | Should -Be 0
        @($global:FakeSql.Published) | Should -Be @('Shop.Database.Migrations.dacpac', 'Shop.Database.dacpac')
    }

    It 'deploys the baseline first in Empty mode' {
        $result = Invoke-TestRehearsal -Extra @{ Mode = 'Empty'; BaselineArtifactPath = $BaselineArtifact }
        $result.ExitCode | Should -Be 0
        @(Get-FakeSqlCall -Action 'Publish' | ForEach-Object { Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $_.SourceFile)) }) | Should -Be @('baseline', 'baseline', 'candidate', 'candidate')
    }

    It 'blocks on data loss and does not publish the schema' {
        Set-FakeDeployReport -Dacpac 'Shop.Database.dacpac' -Alerts @(@{ Name = 'DataIssue'; Issue = 'The column [Sales].[Customer].[Phone] is being dropped.' })
        $result = Invoke-TestRehearsal
        $result.ExitCode | Should -Be 2
        $result.Findings[0].Source | Should -Be 'DeployReport'
        @($global:FakeSql.Published) | Should -Be @('Shop.Database.Migrations.dacpac')
    }

    It 'passes with warnings on other alerts' {
        Set-FakeDeployReport -Dacpac 'Shop.Database.dacpac' -Alerts @(@{ Name = 'DataMotion'; Issue = 'Rows are moved.' })
        $result = Invoke-TestRehearsal
        $result.ExitCode | Should -Be 1
        $result.Findings[0].Message | Should -Be 'DataMotion: Rows are moved.'
    }

    It 'blocks when a migration fails on the data' {
        Set-FakePublishFailure -Dacpac 'Shop.Database.Migrations.dacpac'
        $result = Invoke-TestRehearsal
        $result.ExitCode | Should -Be 2
        $result.Findings[0].Source | Should -Be 'Deployment'
        $result.Findings[0].Message | Should -BeLike '*CHECK constraint*'
    }

    It 'blocks a narrowed captured column found offline' {
        $result = Invoke-TestRehearsal -Extra @{ ArtifactPath = $NarrowedCandidate; BaselineArtifactPath = $BaselineArtifact; CapturedColumnsPath = $ExampleCapturedColumnsPath }
        $result.ExitCode | Should -Be 2
        @($result.Findings | Where-Object Source -eq 'CDC')[0].Message | Should -BeLike '*Sales.Customer.EmailAddress*narrower*'
    }

    It 'fails closed with exit code 3 when <Case>' -TestCases @(
        @{ Case = 'the target is not a rehearsal database'; Extra = @{ TargetConnectionString = 'Server=tcp:my-sql-prod.database.windows.net;Initial Catalog=my-shop;' }; Expected = '*Refusing to rehearse on my-shop*' }
        @{ Case = 'Empty mode has no baseline'; Extra = @{ Mode = 'Empty' }; Expected = '*Empty mode needs -BaselineArtifactPath*' }
        @{ Case = 'captured columns have no baseline'; Extra = @{ CapturedColumnsPath = 'x.json' }; Expected = '*-CapturedColumnsPath needs -BaselineArtifactPath*' }
        @{ Case = 'the artifact has no dacpac'; Extra = @{ ArtifactPath = 'TestDrive:/nowhere' }; Expected = '*Artifact folder not found*' }
    ) {
        $result = Invoke-TestRehearsal -Extra $Extra
        $result.ExitCode | Should -Be 3
        $result.Findings[0].Severity | Should -Be 'Fatal'
        $result.Findings[0].Message | Should -BeLike $Expected
        $global:FakeSql.Calls.Count | Should -Be 0
    }
}
