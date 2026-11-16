BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"

    Mock Invoke-AzCli { Invoke-FakeAzCli -Arguments $Arguments -AllowFailure:$AllowFailure }
    Mock Invoke-SqlPackage {
        Invoke-FakeSqlPackage -Action $Action -SourceFile $SourceFile -TargetConnectionString $TargetConnectionString -AccessToken $AccessToken `
            -ProfilePath $ProfilePath -OutputPath $OutputPath -Variables $Variables -Properties $Properties
    }

    function Invoke-EntryScript {
        <# Runs an entry script, captures its host output and returns ExitCode, Output and Result. #>
        param([string] $Name, [hashtable] $Parameters = @{})
        $global:LASTEXITCODE = 0
        $result = & (Join-Path $ScriptsPath $Name) @Parameters 6>&1
        $exitCode = $global:LASTEXITCODE
        $lines = @($result | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" })
        $values = @($result | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
        [pscustomobject]@{ ExitCode = $exitCode; Output = ($lines -join "`n"); Result = $values }
    }

    $script:OriginalTfBuild = $env:TF_BUILD
}

AfterAll {
    $env:TF_BUILD = $OriginalTfBuild
}

Describe 'New-MigrationScripts.ps1' {
    It 'confirms that the committed runner scripts are current' {
        $run = Invoke-EntryScript -Name 'New-MigrationScripts.ps1' -Parameters @{ Check = $true }
        $run.ExitCode | Should -Be 0
        $run.Output | Should -BeLike '*generated scripts are current*'
    }

    It 'generates the scripts, then fails the check when a migration is added' {
        $project = New-TestMigrationProject -Path (Join-Path $TestDrive 'generate') -Migrations @{ '0001_First' = @{ '01_Step.sql' = 'UPDATE Sales.[Order] SET Note = N''x'' WHERE Note IS NULL;' } }
        (Invoke-EntryScript -Name 'New-MigrationScripts.ps1' -Parameters @{ ProjectPath = $project }).ExitCode | Should -Be 0
        Join-Path $project 'Scripts/Generated/RunMigrations.sql' | Should -FileContentMatch '0001_First'
        (Invoke-EntryScript -Name 'New-MigrationScripts.ps1' -Parameters @{ ProjectPath = $project; Check = $true }).ExitCode | Should -Be 0

        New-TestMigrationProject -Path $project -Migrations @{ '0002_Second' = @{ '01_Step.sql' = 'SELECT 1;' } } | Out-Null
        $check = Invoke-EntryScript -Name 'New-MigrationScripts.ps1' -Parameters @{ ProjectPath = $project; Check = $true }
        $check.ExitCode | Should -Be 1
        $check.Output | Should -BeLike '*RunMigrations.sql is not current*'
    }

    It 'fails on a rule violation without writing anything' {
        $project = New-TestMigrationProject -Path (Join-Path $TestDrive 'violation') -Migrations @{ '0001_Bad' = @{ '01_Step.sql' = "UPDATE Sales.[Order] SET Note = N'x';`nGO" } }
        $run = Invoke-EntryScript -Name 'New-MigrationScripts.ps1' -Parameters @{ ProjectPath = $project }
        $run.ExitCode | Should -Be 1
        $run.Output | Should -BeLike '*contains GO*'
        Join-Path $project 'Scripts/Generated/RunMigrations.sql' | Should -Not -Exist
    }
}

Describe 'Update-ColumnDescriptions.ps1' {
    It 'confirms that the committed SQL is current' {
        $run = Invoke-EntryScript -Name 'Update-ColumnDescriptions.ps1' -Parameters @{ Check = $true }
        $run.ExitCode | Should -Be 0
    }

    It 'adds new columns to the JSON, regenerates the SQL and fails the check until a human describes them' {
        $folder = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'descriptions') -Force
        $path = Join-Path $folder 'ColumnDescriptions.json'
        [System.IO.File]::WriteAllText($path, '{ "standardColumns": {}, "excludedTables": [], "tables": {} }')
        $dacpac = New-TestDacpac -Path (Join-Path $TestDrive 'descriptions.dacpac') -Tables (Get-TestShopTables)

        $sync = Invoke-EntryScript -Name 'Update-ColumnDescriptions.ps1' -Parameters @{ DescriptionsPath = $path; DacpacPath = $dacpac }
        $sync.ExitCode | Should -Be 0
        $sync.Output | Should -BeLike '*TODO: Sales.Customer has no table description.*'
        (Read-ColumnDescription -Path $path).tables['Sales.Order'].columns.CustomerId | Should -Be 'Reference to Sales.Customer.'
        Join-Path $folder 'Generated/ColumnDescriptions.sql' | Should -FileContentMatch 'Reference to Sales.Customer.'

        $check = Invoke-EntryScript -Name 'Update-ColumnDescriptions.ps1' -Parameters @{ DescriptionsPath = $path; DacpacPath = $dacpac; Check = $true }
        $check.ExitCode | Should -Be 1
        $check.Output | Should -BeLike '*ERROR: Sales.Customer.EmailAddress has an empty description.*'
    }
}

Describe 'Publish-Database.ps1' {
    BeforeAll {
        $script:Artifact = New-TestArtifact -Path (Join-Path $TestDrive 'drop')
    }

    BeforeEach { Initialize-TestEnvironment }

    It 'plans an Azure deployment with -WhatIf using the az login token' {
        $run = Invoke-EntryScript -Name 'Publish-Database.ps1' -Parameters @{
            ArtifactPath = $Artifact; Environment = 'Production'; Server = 'my-sql-prod'; Database = 'my-shop'
            BuildNumber = '20260101.1'; OutputPath = (Join-Path $TestDrive 'reports'); WhatIf = $true
        }
        $run.Output | Should -BeLike '*Database deployment to my-shop (Production)*'
        $run.Output | Should -BeLike '*SeedConfiguration  Planned*'
        $global:FakeSql.Published.Count | Should -Be 0
        @(Get-FakeSqlCall -Action 'Script' | ForEach-Object AccessToken | Select-Object -Unique) | Should -Be @('fake-access-token')
        @(Get-FakeSqlCall -Action 'Script' | ForEach-Object Dacpac) | Should -Not -Contain 'Shop.Database.TestData.dacpac'
    }

    It 'deploys with a connection string and no token' {
        $run = Invoke-EntryScript -Name 'Publish-Database.ps1' -Parameters @{
            ArtifactPath = $Artifact; Environment = 'Development'; ConnectionString = 'Server=localhost;Initial Catalog=Shop;Integrated Security=True'
            BuildNumber = 'local'; OutputPath = (Join-Path $TestDrive 'reports'); AllowIncompatiblePlatform = $true
        }
        $run.Output | Should -BeLike '*TestData           Deployed*'
        $global:FakeSql.Published.Count | Should -Be 5
        @(Get-FakeSqlCall -Action 'Publish' | Where-Object { $_.AccessToken }).Count | Should -Be 0
        @(Get-FakeSqlCall -Action 'Publish')[0].Properties.AllowIncompatiblePlatform | Should -Be 'True'
        $global:Fake.Calls.Count | Should -Be 0
    }

    It 'throws on a blocker' {
        Set-FakeDeployReport -Dacpac 'Shop.Database.dacpac' -Alerts @(@{ Name = 'DataIssue'; Issue = 'Column dropped.' })
        { Invoke-EntryScript -Name 'Publish-Database.ps1' -Parameters @{
                ArtifactPath = $Artifact; Environment = 'Test'; ConnectionString = 'Server=localhost;Initial Catalog=Shop'
                BuildNumber = '1'; OutputPath = (Join-Path $TestDrive 'reports')
            } } | Should -Throw '*blocked*Column dropped.*'
    }

    It 'throws for a missing publish profile' {
        { Invoke-EntryScript -Name 'Publish-Database.ps1' -Parameters @{
                ArtifactPath = $Artifact; Environment = 'Test'; ConnectionString = 'Server=localhost;Initial Catalog=Shop'
                BuildNumber = '1'; ProfilePath = (Join-Path $TestDrive 'missing.publish.xml')
            } } | Should -Throw '*Publish profile not found*'
    }
}

Describe 'Test-CdcColumnChanges.ps1' {
    BeforeAll {
        $script:BaselineDacpac = New-TestDacpac -Path (Join-Path $TestDrive 'cdc-baseline.dacpac') -Tables (Get-TestShopTables)
        $script:CapturedPath = Join-Path $TestDrive 'captured.json'
        [System.IO.File]::WriteAllText($CapturedPath, '{ "tables": { "Sales.Customer": [ "EmailAddress" ] } }')

        function New-CandidateDacpac([string] $Name, [object] $EmailColumn) {
            $tables = Get-TestShopTables
            $tables['Sales.Customer'] = @(New-TestColumn -Name 'CustomerId' -PrimaryKey; $EmailColumn)
            New-TestDacpac -Path (Join-Path $TestDrive "$Name.dacpac") -Tables $tables
        }
    }

    It 'exits <ExitCode> for <Case>' -TestCases @(
        @{ Case = 'no change'; Length = 320; ExitCode = 0; Expected = '*No captured column changes.*' }
        @{ Case = 'a wider column'; Length = 400; ExitCode = 1; Expected = '*WARNING: Sales.Customer.EmailAddress*wider*' }
        @{ Case = 'a narrower column'; Length = 100; ExitCode = 2; Expected = '*ERROR: Sales.Customer.EmailAddress*narrower*' }
    ) {
        $candidate = New-CandidateDacpac -Name "cdc-$Length" -EmailColumn (New-TestColumn -Name 'EmailAddress' -Type 'nvarchar' -Length $Length)
        $run = Invoke-EntryScript -Name 'Test-CdcColumnChanges.ps1' -Parameters @{ BaselineDacpac = $BaselineDacpac; CandidateDacpac = $candidate; CapturedColumnsPath = $CapturedPath }
        $run.ExitCode | Should -Be $ExitCode
        $run.Output | Should -BeLike $Expected
    }

    It 'exits 3 when it cannot run' {
        $run = Invoke-EntryScript -Name 'Test-CdcColumnChanges.ps1' -Parameters @{ BaselineDacpac = (Join-Path $TestDrive 'missing.dacpac'); CandidateDacpac = $BaselineDacpac; CapturedColumnsPath = $CapturedPath }
        $run.ExitCode | Should -Be 3
        $run.Output | Should -BeLike '*could not run*Dacpac not found*'
    }
}

Describe 'Rehearsal entry scripts' {
    BeforeAll {
        $script:Candidate = New-TestArtifact -Path (Join-Path $TestDrive 'rehearsal-drop') -Projects @('Shop.Database', 'Shop.Database.Migrations')
        $script:Location = @{ ResourceGroup = $TestResourceGroup; Server = $TestServer }

        function Invoke-TestRehearsalScript([hashtable] $Extra = @{}) {
            $parameters = @{ Server = $TestServer; Database = 'my-shop-rehearsal-42'; ArtifactPath = $Candidate; BuildNumber = '1'; OutputPath = (Join-Path $TestDrive 'rehearsal-reports') }
            foreach ($key in $Extra.Keys) { $parameters[$key] = $Extra[$key] }
            Invoke-EntryScript -Name 'Invoke-SchemaRehearsal.ps1' -Parameters $parameters
        }
    }

    BeforeEach {
        Initialize-TestEnvironment
        Remove-Item Env:TF_BUILD -ErrorAction SilentlyContinue
    }

    It 'New-RehearsalDatabase.ps1 creates the copy and sets the pipeline variable' {
        $env:TF_BUILD = 'True'
        $run = Invoke-EntryScript -Name 'New-RehearsalDatabase.ps1' -Parameters @{ ResourceGroup = $TestResourceGroup; Server = $TestServer; SourceDatabase = $TestSourceDatabase; BuildId = '42'; RetryDelaySeconds = 0 }
        $run.Result | Should -Be @('my-shop-rehearsal-42')
        $run.Output | Should -BeLike '*##vso`[task.setvariable variable=RehearsalDatabase`]my-shop-rehearsal-42*'
        Get-FakeDatabase @Location -Name 'my-shop-rehearsal-42' | Should -Not -BeNullOrEmpty
    }

    It 'New-RehearsalDatabase.ps1 changes nothing with -WhatIf' {
        Invoke-EntryScript -Name 'New-RehearsalDatabase.ps1' -Parameters @{ ResourceGroup = $TestResourceGroup; Server = $TestServer; SourceDatabase = $TestSourceDatabase; BuildId = '42'; WhatIf = $true } | Out-Null
        $global:Fake.Writes.Count | Should -Be 0
    }

    It 'Remove-RehearsalDatabase.ps1 removes the copy and refuses other names' {
        Add-FakeDatabase @Location -Name 'my-shop-rehearsal-42' -Tags @{ purpose = 'schema-rehearsal' }
        (Invoke-EntryScript -Name 'Remove-RehearsalDatabase.ps1' -Parameters @{ ResourceGroup = $TestResourceGroup; Server = $TestServer; Name = 'my-shop-rehearsal-42'; RetryDelaySeconds = 0 }).Output | Should -BeLike '*is gone*'
        Get-FakeDatabase @Location -Name 'my-shop-rehearsal-42' | Should -BeNullOrEmpty
        { Invoke-EntryScript -Name 'Remove-RehearsalDatabase.ps1' -Parameters @{ ResourceGroup = $TestResourceGroup; Server = $TestServer; Name = 'my-shop' } } | Should -Throw
        Get-FakeDatabase @Location -Name 'my-shop' | Should -Not -BeNullOrEmpty
    }

    It 'Invoke-SchemaRehearsal.ps1 passes with the az login token' {
        $run = Invoke-TestRehearsalScript
        $run.ExitCode | Should -Be 0
        $run.Output | Should -BeLike '*Schema rehearsal passed.*'
        @(Get-FakeSqlCall -Action 'Publish')[0].AccessToken | Should -Be 'fake-access-token'
    }

    It 'Invoke-SchemaRehearsal.ps1 exits 2 when blocked' {
        Set-FakeDeployReport -Dacpac 'Shop.Database.dacpac' -Alerts @(@{ Name = 'DataIssue'; Issue = 'Column dropped.' })
        $run = Invoke-TestRehearsalScript
        $run.ExitCode | Should -Be 2
        $run.Output | Should -BeLike '*ERROR `[DeployReport`] Possible data loss: Column dropped.*Schema rehearsal blocked.*'
    }

    It 'Invoke-SchemaRehearsal.ps1 exits <ExitCode> with warnings when TF_BUILD is <TfBuild>' -TestCases @(
        @{ TfBuild = 'unset'; ExitCode = 1 }
        @{ TfBuild = 'True'; ExitCode = 0 }
    ) {
        if ($TfBuild -ne 'unset') { $env:TF_BUILD = $TfBuild }
        Set-FakeDeployReport -Dacpac 'Shop.Database.dacpac' -Alerts @(@{ Name = 'DataMotion'; Issue = 'Rows are moved.' })
        $run = Invoke-TestRehearsalScript
        $run.ExitCode | Should -Be $ExitCode
        $run.Output | Should -BeLike '*passed with warnings*'
        if ($TfBuild -eq 'True') {
            $run.Output | Should -BeLike '*##vso`[task.complete result=SucceededWithIssues;`]*'
        }
    }

    It 'Invoke-SchemaRehearsal.ps1 exits 3 when the rehearsal cannot run' {
        $run = Invoke-TestRehearsalScript -Extra @{ ArtifactPath = (Join-Path $TestDrive 'nowhere') }
        $run.ExitCode | Should -Be 3
        $run.Output | Should -BeLike '*could not run (blocked)*'
    }

    It 'Invoke-SchemaRehearsal.ps1 refuses a database name that is not a rehearsal copy' {
        { Invoke-TestRehearsalScript -Extra @{ Database = 'my-shop' } } | Should -Throw
        $global:FakeSql.Calls.Count | Should -Be 0
    }
}
