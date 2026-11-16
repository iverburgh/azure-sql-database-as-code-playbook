BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"

    function New-ReportFile {
        param([string] $Name, [string] $Body)
        $path = Join-Path $TestDrive $Name
        [System.IO.File]::WriteAllText($path, "<?xml version=`"1.0`" encoding=`"utf-8`"?><DeploymentReport xmlns=`"http://schemas.microsoft.com/sqlserver/dac/DeployReport/2012/02`">$Body</DeploymentReport>")
        $path
    }
}

Describe 'Read-DeployReport' {
    It 'reads alerts and operations in the format SqlPackage writes' {
        $path = New-ReportFile -Name 'report.xml' -Body (
            '<Alerts><Alert Name="DataIssue"><Issue Value="The column [Sales].[Customer].[Phone] is being dropped, data loss could occur." Id="1" /></Alert></Alerts>' +
            '<Operations><Operation Name="Alter"><Item Value="[Sales].[Customer]" Type="SqlTable"><Issue Id="1" /></Item></Operation>' +
            '<Operation Name="Create"><Item Value="[Sales].[Refund]" Type="SqlTable" /><Item Value="[Sales].[IX_Refund]" Type="SqlIndex" /></Operation></Operations>')
        $report = Read-DeployReport -Path $path
        @($report.Alerts).Count | Should -Be 1
        $report.Alerts[0].Name | Should -Be 'DataIssue'
        $report.Alerts[0].Issue | Should -BeLike '*Phone*data loss*'
        @($report.Operations | ForEach-Object { "$($_.Name) $($_.Item) $($_.Type)" }) | Should -Be @(
            'Alter [Sales].[Customer] SqlTable'
            'Create [Sales].[Refund] SqlTable'
            'Create [Sales].[IX_Refund] SqlIndex'
        )
    }

    It 'reads an empty report' {
        $report = Read-DeployReport -Path (New-ReportFile -Name 'empty.xml' -Body '')
        @($report.Alerts).Count | Should -Be 0
        @($report.Operations).Count | Should -Be 0
    }

    It 'rejects a missing file and XML that is not a deploy report' {
        { Read-DeployReport -Path (Join-Path $TestDrive 'nope.xml') } | Should -Throw '*Deploy report not found*'
        $other = Join-Path $TestDrive 'other.xml'
        [System.IO.File]::WriteAllText($other, '<DeploymentReport />')
        { Read-DeployReport -Path $other } | Should -Throw '*is not a SqlPackage deploy report*'
    }
}

Describe 'Get-DeployReportBlocker' {
    It 'blocks data loss and table rebuilds, nothing else' {
        $report = [pscustomobject]@{
            Alerts     = @(
                [pscustomobject]@{ Name = 'DataIssue'; Issue = 'Column dropped.' }
                [pscustomobject]@{ Name = 'DataMotion'; Issue = 'Something moves.' }
            )
            Operations = @(
                [pscustomobject]@{ Name = 'TableRebuild'; Item = '[Sales].[Order]'; Type = 'SqlTable' }
                [pscustomobject]@{ Name = 'Alter'; Item = '[Sales].[Customer]'; Type = 'SqlTable' }
                [pscustomobject]@{ Name = 'Drop'; Item = '[Sales].[IX_Old]'; Type = 'SqlIndex' }
            )
        }
        $blockers = @(Get-DeployReportBlocker -Report $report)
        $blockers.Count | Should -Be 2
        $blockers[0] | Should -Be 'Possible data loss: Column dropped.'
        $blockers[1] | Should -BeLike 'Table rebuild: `[Sales`].`[Order`]*'
    }

    It 'emits nothing for a report without alerts or operations' {
        @(Get-DeployReportBlocker -Report ([pscustomobject]@{ Alerts = @(); Operations = @() })).Count | Should -Be 0
    }
}

Describe 'Format-DeployReport' {
    It 'groups operations and lists alerts' {
        $report = [pscustomobject]@{
            Alerts     = @([pscustomobject]@{ Name = 'DataIssue'; Issue = 'Column dropped.' })
            Operations = @(
                [pscustomobject]@{ Name = 'Create'; Item = '[Sales].[Refund]'; Type = 'SqlTable' }
                [pscustomobject]@{ Name = 'Create'; Item = '[Sales].[IX_Refund]'; Type = 'SqlIndex' }
            )
        }
        @(Format-DeployReport -Report $report) | Should -Be @(
            '  Create:'
            '    [Sales].[Refund] (SqlTable)'
            '    [Sales].[IX_Refund] (SqlIndex)'
            '  Alert DataIssue: Column dropped.'
        )
    }

    It 'says so when nothing changes' {
        @(Format-DeployReport -Report ([pscustomobject]@{ Alerts = @(); Operations = @() })) | Should -Be @('  No schema changes.')
    }
}
