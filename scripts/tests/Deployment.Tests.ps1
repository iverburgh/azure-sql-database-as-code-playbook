BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"

    Mock Invoke-SqlPackage {
        Invoke-FakeSqlPackage -Action $Action -SourceFile $SourceFile -TargetConnectionString $TargetConnectionString -AccessToken $AccessToken `
            -ProfilePath $ProfilePath -OutputPath $OutputPath -Variables $Variables -Properties $Properties
    }

    function Get-TestEnvironment([string] $Name) {
        Get-DeploymentEnvironment -Path $ExampleEnvironmentsPath -Name $Name
    }

    function Invoke-TestDeployment {
        param([string] $Environment = 'Test', [hashtable] $Extra = @{})
        $parameters = @{
            ArtifactPath           = $script:Artifact
            Environment            = (Get-TestEnvironment $Environment)
            TargetConnectionString = (Get-TestConnectionString)
            AccessToken            = 'token'
            BuildNumber            = '20260101.1'
            OutputPath             = (Join-Path $TestDrive 'reports')
            ProfilePath            = $ExampleProfilePath
        }
        foreach ($key in $Extra.Keys) { $parameters[$key] = $Extra[$key] }
        Invoke-DatabaseDeployment @parameters 6>$null
    }

    $script:Artifact = New-TestArtifact -Path (Join-Path $TestDrive 'drop')
}

Describe 'Get-DeploymentEnvironment' {
    It 'reads the example environments' {
        $production = Get-TestEnvironment 'Production'
        $production.Protected | Should -BeTrue
        $production.TestData | Should -BeFalse
        $production.SeedConfiguration | Should -Be 'Production'
        (Get-TestEnvironment 'Development').AllowDropAll | Should -BeTrue
    }

    It 'names the known environments for an unknown one' {
        { Get-TestEnvironment 'Staging' } | Should -Throw "*Environment 'Staging' is not in*Development, Test, Production*"
    }

    It 'rejects <Case>' -TestCases @(
        @{ Case = 'a missing setting'; Settings = '{ "seedConfiguration": "X", "testData": false, "protected": false }'; Expected = "*has no 'allowDropAll'*" }
        @{ Case = 'test data in a protected environment'; Settings = '{ "seedConfiguration": "X", "testData": true, "allowDropAll": false, "protected": true }'; Expected = '*is protected*' }
        @{ Case = 'DropAll in a protected environment'; Settings = '{ "seedConfiguration": "X", "testData": false, "allowDropAll": true, "protected": true }'; Expected = '*is protected*' }
    ) {
        $path = Join-Path $TestDrive 'environments.json'
        [System.IO.File]::WriteAllText($path, "{ `"environments`": { `"Bad`": $Settings } }")
        { Get-DeploymentEnvironment -Path $path -Name 'Bad' } | Should -Throw $Expected
    }
}

Describe 'Get-DeploymentPlan' {
    It 'plans <Environment>' -TestCases @(
        @{ Environment = 'Development'; DropAll = $true; Expected = 'DropAll Migrations Schema ReferenceData SeedConfiguration TestData' }
        @{ Environment = 'Test'; DropAll = $false; Expected = 'Migrations Schema ReferenceData SeedConfiguration TestData' }
        @{ Environment = 'Production'; DropAll = $false; Expected = 'Migrations Schema ReferenceData SeedConfiguration' }
    ) {
        $plan = @(Get-DeploymentPlan -Environment (Get-TestEnvironment $Environment) -DropAll:$DropAll)
        (@($plan | ForEach-Object Step) -join ' ') | Should -Be $Expected
        @($plan | Where-Object Step -eq 'SeedConfiguration')[0].Project | Should -Be "Shop.Database.SeedConfiguration.$Environment"
    }

    It 'refuses DropAll where the environment does not allow it' {
        { Get-DeploymentPlan -Environment (Get-TestEnvironment 'Production') -DropAll } | Should -Throw "*does not allow DropAll*"
    }
}

Describe 'Find-Dacpac' {
    It 'ignores copies under obj and finds the one dacpac' {
        $artifact = New-TestArtifact -Path (Join-Path $TestDrive 'find') -Projects @('Shop.Database')
        New-TestDacpac -Path (Join-Path $artifact 'Shop.Database/obj/Release/Shop.Database.dacpac') | Out-Null
        Find-Dacpac -ArtifactPath $artifact -Name 'Shop.Database' | Should -Be (Join-Path $artifact 'Shop.Database/Shop.Database.dacpac')
    }

    It 'fails on <Case>' -TestCases @(
        @{ Case = 'a missing folder'; Setup = 'none'; Expected = '*Artifact folder not found*' }
        @{ Case = 'a missing dacpac'; Setup = 'empty'; Expected = '*No Shop.Database.dacpac under*' }
        @{ Case = 'two dacpacs'; Setup = 'two'; Expected = '*More than one Shop.Database.dacpac*' }
    ) {
        $path = Join-Path $TestDrive "find-$Setup"
        if ($Setup -eq 'empty') { New-Item -ItemType Directory -Path $path -Force | Out-Null }
        if ($Setup -eq 'two') {
            New-TestDacpac -Path (Join-Path $path 'Debug/Shop.Database.dacpac') | Out-Null
            New-TestDacpac -Path (Join-Path $path 'Release/Shop.Database.dacpac') | Out-Null
        }
        { Find-Dacpac -ArtifactPath $path -Name 'Shop.Database' } | Should -Throw $Expected
    }
}

Describe 'Get-StepProperty' {
    It 'keeps script-only dacpacs from dropping objects or changing database options' {
        $properties = Get-StepProperty -Step 'ReferenceData'
        $properties.DropObjectsNotInSource | Should -Be 'False'
        $properties.ScriptDatabaseOptions | Should -Be 'False'
        (Get-StepProperty -Step 'Schema').Count | Should -Be 0
        (Get-StepProperty -Step 'Schema' -AllowIncompatiblePlatform).AllowIncompatiblePlatform | Should -Be 'True'
    }
}

Describe 'Invoke-DatabaseDeployment' {
    BeforeEach {
        Initialize-TestEnvironment
        Remove-Item -LiteralPath (Join-Path $TestDrive 'reports') -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'publishes every step in order with the build number' {
        $results = @(Invoke-TestDeployment -Environment 'Test')
        @($results | ForEach-Object Status) | Should -Be @('Deployed', 'Deployed', 'Deployed', 'Deployed', 'Deployed')
        @($global:FakeSql.Published) | Should -Be @(
            'Shop.Database.Migrations.dacpac'
            'Shop.Database.dacpac'
            'Shop.Database.ReferenceData.dacpac'
            'Shop.Database.SeedConfiguration.Test.dacpac'
            'Shop.Database.TestData.dacpac'
        )
        foreach ($call in @(Get-FakeSqlCall -Action 'Publish')) {
            $call.Variables.BuildNumber | Should -Be '20260101.1'
            $call.Database | Should -Be 'my-shop'
            $call.AccessToken | Should -Be 'token'
        }
    }

    It 'uses the publish profile for the schema only and keeps the other steps from dropping objects' {
        Invoke-TestDeployment | Out-Null
        foreach ($call in @(Get-FakeSqlCall -Action 'Publish')) {
            if ($call.Dacpac -eq 'Shop.Database.dacpac') {
                $call.ProfilePath | Should -Be $ExampleProfilePath
                $call.Properties.ContainsKey('DropObjectsNotInSource') | Should -BeFalse
            }
            else {
                $call.ProfilePath | Should -BeNullOrEmpty
                $call.Properties.DropObjectsNotInSource | Should -Be 'False'
            }
        }
    }

    It 'writes a deploy report for the schema and a script for every step' {
        $results = @(Invoke-TestDeployment)
        @(Get-FakeSqlCall -Action 'DeployReport' | ForEach-Object Dacpac) | Should -Be @('Shop.Database.dacpac')
        @(Get-FakeSqlCall -Action 'Script').Count | Should -Be 5
        @($results | Where-Object Step -eq 'Schema')[0].Report | Should -Exist
        Join-Path $TestDrive 'reports/SeedConfiguration.sql' | Should -Exist
    }

    It 'never deploys test data to production' {
        Invoke-TestDeployment -Environment 'Production' | Out-Null
        @($global:FakeSql.Published) | Should -Not -Contain 'Shop.Database.TestData.dacpac'
        @($global:FakeSql.Published) | Should -Contain 'Shop.Database.SeedConfiguration.Production.dacpac'
    }

    It 'publishes nothing with -WhatIf and reports every step as planned' {
        $results = @(Invoke-TestDeployment -Extra @{ WhatIf = $true })
        @($results | ForEach-Object Status | Select-Object -Unique) | Should -Be @('Planned')
        $global:FakeSql.Published.Count | Should -Be 0
        @(Get-FakeSqlCall -Action 'Script').Count | Should -Be 5
    }

    It 'stops before the schema is published when the report shows <Case>' -TestCases @(
        @{ Case = 'data loss'; Alerts = @(@{ Name = 'DataIssue'; Issue = 'The column [Sales].[Customer].[Phone] is being dropped.' }); Operations = @(); Expected = '*Possible data loss*Phone*' }
        @{ Case = 'a table rebuild'; Alerts = @(); Operations = @(@{ Name = 'TableRebuild'; Item = '[Sales].[Order]'; Type = 'SqlTable' }); Expected = '*Table rebuild*Order*' }
    ) {
        Set-FakeDeployReport -Dacpac 'Shop.Database.dacpac' -Alerts $Alerts -Operations $Operations
        { Invoke-TestDeployment } | Should -Throw $Expected
        # The migrations run first by design; the schema and everything after it is untouched.
        @($global:FakeSql.Published) | Should -Be @('Shop.Database.Migrations.dacpac')
    }

    It 'warns about a blocker with -WhatIf instead of failing' {
        Set-FakeDeployReport -Dacpac 'Shop.Database.dacpac' -Alerts @(@{ Name = 'DataIssue'; Issue = 'Column dropped.' })
        $results = @(Invoke-TestDeployment -Extra @{ WhatIf = $true } 3>&1)
        $warnings = @($results | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $warnings.Count | Should -Be 1
        $warnings[0].Message | Should -BeLike '*blocked*Possible data loss: Column dropped.*'
        @($results | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] } | Where-Object Step -eq 'Schema')[0].Blockers | Should -Be @('Possible data loss: Column dropped.')
    }

    It 'stops when a publish fails' {
        Set-FakePublishFailure -Dacpac 'Shop.Database.ReferenceData.dacpac'
        { Invoke-TestDeployment } | Should -Throw '*SqlPackage Publish failed*'
        @($global:FakeSql.Published) | Should -Be @('Shop.Database.Migrations.dacpac', 'Shop.Database.dacpac')
    }

    Context 'drift' {
        BeforeAll {
            $script:Baseline = New-TestDacpac -Path (Join-Path $TestDrive 'baseline/Shop.Database.dacpac') -Tables (Get-TestShopTables)
        }

        It 'continues when the database matches the previous release' {
            Invoke-TestDeployment -Extra @{ DriftBaselineDacpac = $Baseline; FailOnDrift = $true } | Out-Null
            @(Get-FakeSqlCall -Action 'DeployReport')[0].SourceFile | Should -Be $Baseline
            $global:FakeSql.Published.Count | Should -Be 5
        }

        It 'warns about drift by default' {
            Set-FakeDeployReport -Dacpac $Baseline -Operations @(@{ Name = 'Drop'; Item = '[Sales].[IX_Hotfix]'; Type = 'SqlIndex' })
            $output = @(Invoke-TestDeployment -Extra @{ DriftBaselineDacpac = $Baseline } 3>&1)
            @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })[0].Message | Should -BeLike '*differs from the previous release*Drop `[Sales`].`[IX_Hotfix`] (SqlIndex)*'
            $global:FakeSql.Published.Count | Should -Be 5
        }

        It 'fails on drift with -FailOnDrift before anything is published' {
            Set-FakeDeployReport -Dacpac $Baseline -Operations @(@{ Name = 'Drop'; Item = '[Sales].[IX_Hotfix]'; Type = 'SqlIndex' })
            { Invoke-TestDeployment -Extra @{ DriftBaselineDacpac = $Baseline; FailOnDrift = $true } } | Should -Throw '*differs from the previous release*'
            $global:FakeSql.Published.Count | Should -Be 0
        }
    }

    Context 'DropAll' {
        It 'runs first and passes the database name as confirmation' {
            Invoke-TestDeployment -Environment 'Development' -Extra @{ DropAll = $true } | Out-Null
            $global:FakeSql.Published[0] | Should -Be 'Shop.Database.DropAll.dacpac'
            @(Get-FakeSqlCall -Action 'Publish')[0].Variables.ConfirmDropAll | Should -Be 'my-shop'
            @(Get-FakeSqlCall -Action 'Publish')[1].Variables.ContainsKey('ConfirmDropAll') | Should -BeFalse
        }

        It 'is refused in an environment that does not allow it, before anything is called' {
            { Invoke-TestDeployment -Environment 'Test' -Extra @{ DropAll = $true } } | Should -Throw '*does not allow DropAll*'
            $global:FakeSql.Calls.Count | Should -Be 0
        }
    }
}
