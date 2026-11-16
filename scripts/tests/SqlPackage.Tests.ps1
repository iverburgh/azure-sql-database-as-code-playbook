BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"

    # A stand-in for the SqlPackage executable: records its arguments and exits with a chosen code.
    $script:FakeExe = Join-Path $TestDrive 'sqlpackage.ps1'
    [System.IO.File]::WriteAllText($FakeExe, @'
$argsFile = Join-Path $PSScriptRoot 'args.txt'
[System.IO.File]::WriteAllLines($argsFile, [string[]]$args)
Write-Output 'Publishing to database ...'
Write-Output 'An error occurred while the batch was being executed.'
exit ([int]$env:FAKE_SQLPACKAGE_EXIT)
'@)
    $script:OriginalSqlPackagePath = $env:SQLPACKAGE_PATH
}

AfterAll {
    $env:SQLPACKAGE_PATH = $OriginalSqlPackagePath
    Remove-Item Env:FAKE_SQLPACKAGE_EXIT -ErrorAction SilentlyContinue
}

Describe 'Get-SqlPackageArgument' {
    It 'orders action, files, target, profile, then sorted variables and properties' {
        $arguments = @(Get-SqlPackageArgument -Action 'Publish' -SourceFile 'a.dacpac' -TargetConnectionString 'Server=my-sql;Database=my-shop' `
                -AccessToken 'token' -ProfilePath 'p.xml' -OutputPath 'out.sql' `
                -Variables @{ Zeta = '1'; Alpha = '2' } -Properties @{ DropObjectsNotInSource = 'False'; BlockOnPossibleDataLoss = 'True' })
        $arguments | Should -Be @(
            '/Action:Publish'
            '/SourceFile:a.dacpac'
            '/TargetConnectionString:Server=my-sql;Database=my-shop'
            '/AccessToken:token'
            '/Profile:p.xml'
            '/OutputPath:out.sql'
            '/v:Alpha=2'
            '/v:Zeta=1'
            '/p:BlockOnPossibleDataLoss=True'
            '/p:DropObjectsNotInSource=False'
        )
    }

    It 'leaves out what is not given' {
        @(Get-SqlPackageArgument -Action 'DriftReport' -TargetConnectionString 'Server=my-sql') | Should -Be @('/Action:DriftReport', '/TargetConnectionString:Server=my-sql')
    }
}

Describe 'Hide-SqlPackageSecret' {
    It 'masks <Case>' -TestCases @(
        @{ Case = 'the access token'; Argument = '/AccessToken:eyJ0eXAi'; Expected = '/AccessToken:***' }
        @{ Case = 'a password'; Argument = '/TargetConnectionString:Server=my-sql;User ID=app;Password=secret;Encrypt=True'; Expected = '/TargetConnectionString:Server=my-sql;User ID=app;Password=***;Encrypt=True' }
        @{ Case = 'a pwd in any case'; Argument = '/TargetConnectionString:Server=my-sql;PWD = secret'; Expected = '/TargetConnectionString:Server=my-sql;PWD=***' }
        @{ Case = 'nothing in a plain argument'; Argument = '/p:BlockOnPossibleDataLoss=True'; Expected = '/p:BlockOnPossibleDataLoss=True' }
    ) {
        Hide-SqlPackageSecret -Argument $Argument | Should -Be $Expected
    }
}

Describe 'Invoke-SqlPackage' {
    BeforeEach {
        $env:SQLPACKAGE_PATH = $FakeExe
    }

    It 'passes the arguments to the executable and succeeds on exit code 0' {
        $env:FAKE_SQLPACKAGE_EXIT = '0'
        Invoke-SqlPackage -Action 'Publish' -SourceFile 'a.dacpac' -TargetConnectionString 'Server=my-sql' -Properties @{ BlockOnPossibleDataLoss = 'True' } 6>$null
        @(Get-Content -LiteralPath (Join-Path $TestDrive 'args.txt')) | Should -Be @('/Action:Publish', '/SourceFile:a.dacpac', '/TargetConnectionString:Server=my-sql', '/p:BlockOnPossibleDataLoss=True')
    }

    It 'throws on a non-zero exit code with masked secrets and the output tail' {
        $env:FAKE_SQLPACKAGE_EXIT = '1'
        $thrown = $null
        try {
            Invoke-SqlPackage -Action 'Publish' -SourceFile 'a.dacpac' -TargetConnectionString 'Server=my-sql;Password=secret' -AccessToken 'token-value' 6>$null
        }
        catch {
            $thrown = $_.Exception.Message
        }
        $thrown | Should -BeLike '*SqlPackage Publish failed with exit code 1*'
        $thrown | Should -Match '/AccessToken:\*\*\*'
        $thrown | Should -Match 'Password=\*\*\*'
        $thrown | Should -BeLike '*An error occurred while the batch was being executed.*'
        $thrown | Should -Not -BeLike '*secret*'
        $thrown | Should -Not -BeLike '*token-value*'
    }

    It 'fails clearly when SQLPACKAGE_PATH points nowhere' {
        $env:SQLPACKAGE_PATH = Join-Path $TestDrive 'missing.exe'
        { Invoke-SqlPackage -Action 'Publish' -TargetConnectionString 'Server=my-sql' } | Should -Throw '*SQLPACKAGE_PATH points to*does not exist*'
    }
}
