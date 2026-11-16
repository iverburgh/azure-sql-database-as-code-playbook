BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"

    function New-Project {
        param([string] $Name, [System.Collections.IDictionary] $Migrations)
        New-TestMigrationProject -Path (Join-Path $TestDrive $Name) -Migrations $Migrations
    }
}

Describe 'Get-Migration' {
    It 'orders the migrations by id and their scripts ordinally' {
        $project = New-Project 'ordered' ([ordered]@{
                '0010_Later'   = @{ 'b.sql' = 'SELECT 1;'; 'a.sql' = 'SELECT 1;'; '9.sql' = 'SELECT 1;'; '10.sql' = 'SELECT 1;' }
                '0002_Earlier' = @{ '01_Step.sql' = 'SELECT 1;' }
            })
        $migrations = @(Get-Migration -ProjectPath $project)
        @($migrations | ForEach-Object Id) | Should -Be @(2, 10)
        # Ordinal, not natural: prefix script names with zero-padded numbers.
        $migrations[1].Scripts | Should -Be @('10.sql', '9.sql', 'a.sql', 'b.sql')
    }

    It 'returns nothing when there is no Migrations folder' {
        $project = Join-Path $TestDrive 'no-migrations'
        New-Item -ItemType Directory -Path $project | Out-Null
        @(Get-Migration -ProjectPath $project).Count | Should -Be 0
    }

    It 'rejects a folder name that is not NNNN_Description' -TestCases @(
        @{ Folder = '1_TooShort' }
        @{ Folder = '0001-Dash' }
        @{ Folder = '0001_with space' }
        @{ Folder = '0001_1StartsWithDigit' }
    ) {
        $project = New-Project "bad-$($Folder.GetHashCode())" @{ $Folder = @{ 'a.sql' = 'SELECT 1;' } }
        { Get-Migration -ProjectPath $project } | Should -Throw '*does not match NNNN_Description*'
    }

    It 'rejects a migration without scripts' {
        $project = New-Project 'empty' @{ '0001_Empty' = @{ 'readme.txt' = 'no sql' } }
        { Get-Migration -ProjectPath $project } | Should -Throw '*contains no .sql files*'
    }

    It 'rejects two migrations with the same id' {
        $project = New-Project 'duplicate' @{ '0003_One' = @{ 'a.sql' = 'SELECT 1;' }; '0003_Two' = @{ 'a.sql' = 'SELECT 1;' } }
        { Get-Migration -ProjectPath $project } | Should -Throw '*share an id*0003_One*0003_Two*'
    }

    It 'rejects id 0000' {
        $project = New-Project 'zero' @{ '0000_Zero' = @{ 'a.sql' = 'SELECT 1;' } }
        { Get-Migration -ProjectPath $project } | Should -Throw '*0000 is not allowed*'
    }
}

Describe 'Test-MigrationScript' {
    It 'reports <Rule>' -TestCases @(
        @{ Rule = 'GO'; Sql = "UPDATE Sales.[Order] SET Note = NULL;`nGO`n"; Expected = '*contains GO*' }
        @{ Rule = 'GO with a comment'; Sql = "SELECT 1;`n  go -- next batch`n"; Expected = '*contains GO*' }
        @{ Rule = 'SQLCMD'; Sql = ":r other.sql`n"; Expected = '*SQLCMD command*' }
        @{ Rule = 'USE'; Sql = "USE master;`nSELECT 1;"; Expected = '*contains USE*' }
        @{ Rule = 'BEGIN TRAN'; Sql = 'BEGIN TRAN; SELECT 1;'; Expected = '*transaction statement*' }
        @{ Rule = 'COMMIT'; Sql = 'SELECT 1; COMMIT;'; Expected = '*transaction statement*' }
        @{ Rule = 'ROLLBACK'; Sql = 'IF @@ROWCOUNT = 0 ROLLBACK;'; Expected = '*transaction statement*' }
        @{ Rule = 'CDC'; Sql = "EXEC sys.sp_cdc_enable_table @source_schema = N'Sales', @source_name = N'Order', @role_name = NULL;"; Expected = '*change data capture*' }
    ) {
        $project = New-Project "rule-$($Rule.GetHashCode())" @{ '0001_Change' = @{ '01.sql' = $Sql } }
        $violations = @(Test-MigrationScript -Migrations @(Get-Migration -ProjectPath $project))
        $violations.Count | Should -Be 1
        $violations[0] | Should -BeLike "0001_Change/01.sql: $Expected"
    }

    It 'ignores keywords in comments and string literals' {
        $sql = @"
-- BEGIN TRAN and USE are mentioned here
/* COMMIT;
   ROLLBACK; */
UPDATE Sales.[Order] SET Note = N'Please COMMIT to the ROLLBACK plan; USE it';
"@
        $project = New-Project 'comments' @{ '0001_Comments' = @{ '01.sql' = $sql } }
        @(Test-MigrationScript -Migrations @(Get-Migration -ProjectPath $project)) | Should -BeNullOrEmpty
    }

    It 'reports a variable that two migrations declare' {
        $project = New-Project 'declare' ([ordered]@{
                '0001_First'  = @{ '01.sql' = 'DECLARE @count int = 0;' }
                '0002_Second' = @{ '01.sql' = 'DECLARE @Count int = 1; DECLARE @other int;' }
            })
        $violations = @(Test-MigrationScript -Migrations @(Get-Migration -ProjectPath $project))
        $violations.Count | Should -Be 1
        $violations[0] | Should -BeLike '0002_Second/01.sql: declares @Count, which 0001_First declares too*'
    }

    It 'allows a migration to declare a variable in two of its own scripts' {
        $project = New-Project 'declare-same' @{ '0001_Split' = @{ '01.sql' = 'DECLARE @batch int = 1000;'; '02.sql' = 'DECLARE @batch int = 500;' } }
        @(Test-MigrationScript -Migrations @(Get-Migration -ProjectPath $project)) | Should -BeNullOrEmpty
    }

    It 'accepts the example migrations' {
        @(Test-MigrationScript -Migrations @(Get-Migration -ProjectPath $ExampleMigrationsProject)) | Should -BeNullOrEmpty
    }
}

Describe 'Generated runner scripts' {
    BeforeAll {
        $project = New-Project 'generated' ([ordered]@{
                '0001_Backfill' = @{ '01_Update.sql' = 'SELECT 1;'; '02_Cleanup.sql' = 'SELECT 2;' }
                '0007_Rename'   = @{ '01.sql' = 'SELECT 3;' }
            })
        $script:Migrations = @(Get-Migration -ProjectPath $project)
    }

    It 'runs each migration once, guarded by its id, and records it' {
        $sql = New-RunMigrationsSql -Migrations $Migrations
        $sql | Should -BeLike '-- <auto-generated>*'
        $sql | Should -Match "IF NOT EXISTS \(SELECT 1 FROM \[dbo\]\.\[DeploymentHistory\] WHERE \[MigrationId\] = 1\)\nBEGIN\n    PRINT N'Running migration 0001_Backfill\.';\n:r \.\./\.\./Migrations/0001_Backfill/01_Update\.sql\n:r \.\./\.\./Migrations/0001_Backfill/02_Cleanup\.sql\n"
        $sql | Should -Match "VALUES \(N'Migration', N'\`$\(BuildNumber\)', 7, N'0007_Rename'\);\nEND\n$"
        $sql | Should -Not -Match "`r"
    }

    It 'records every migration as a baseline on a new database' {
        $sql = New-InitMigrationsSql -Migrations $Migrations
        $sql | Should -Match "VALUES\n    \(N'Baseline', N'\`$\(BuildNumber\)', 1, N'0001_Backfill'\),\n    \(N'Baseline', N'\`$\(BuildNumber\)', 7, N'0007_Rename'\);\n$"
    }

    It 'prints a message when no migrations are registered' {
        New-RunMigrationsSql -Migrations @() | Should -Match "PRINT N'No migrations registered\.';\n$"
        New-InitMigrationsSql -Migrations @() | Should -Match "PRINT N'No migrations registered\.';\n$"
    }

    It 'is deterministic' {
        New-RunMigrationsSql -Migrations $Migrations | Should -BeExactly (New-RunMigrationsSql -Migrations $Migrations)
    }

    It 'matches the committed files of the example project' {
        $migrations = @(Get-Migration -ProjectPath $ExampleMigrationsProject)
        $generated = Join-Path $ExampleMigrationsProject 'Scripts/Generated'
        Test-GeneratedFileCurrent -Path (Join-Path $generated 'RunMigrations.sql') -Content (New-RunMigrationsSql -Migrations $migrations) | Should -BeTrue
        Test-GeneratedFileCurrent -Path (Join-Path $generated 'InitMigrations.sql') -Content (New-InitMigrationsSql -Migrations $migrations) | Should -BeTrue
    }
}

Describe 'Generated file helpers' {
    It 'ignores CRLF versus LF and a missing trailing newline' {
        $path = Join-Path $TestDrive 'crlf.sql'
        [System.IO.File]::WriteAllText($path, "a`r`nb`r`n")
        Test-GeneratedFileCurrent -Path $path -Content "a`nb" | Should -BeTrue
        Test-GeneratedFileCurrent -Path $path -Content "a`nB`n" | Should -BeFalse
    }

    It 'writes UTF-8 without BOM and LF, and only when the content changes' {
        $path = Join-Path $TestDrive 'nested/out.sql'
        Write-GeneratedFile -Path $path -Content "x`r`ny" | Should -BeTrue
        [System.IO.File]::ReadAllBytes($path)[0] | Should -Be ([byte][char]'x')
        [System.IO.File]::ReadAllText($path) | Should -BeExactly "x`ny`n"
        Write-GeneratedFile -Path $path -Content "x`ny`n" | Should -BeFalse
    }

    It 'reports invalid JSON with the file name' {
        $path = Join-Path $TestDrive 'broken.json'
        [System.IO.File]::WriteAllText($path, '{ "a": ')
        { Read-JsonFile -Path $path } | Should -Throw "*Invalid JSON in*broken.json*"
    }
}
