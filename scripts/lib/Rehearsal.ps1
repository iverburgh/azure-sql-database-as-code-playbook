Set-StrictMode -Version Latest

<#
    Schema rehearsal: before a release reaches production, deploy it to a disposable copy of the
    production database and see what happens: data loss alerts, table rebuilds, migrations that
    fail on real data, changes to captured (CDC) columns. The copy lives on the same server,
    carries a tag that marks it as disposable, and is removed afterwards.

    Exit codes of the rehearsal check:
      0  passed
      1  passed with warnings (a planned follow-up is needed)
      2  blocked: the release must not be deployed as it is
      3  the rehearsal could not run; treat as blocked (fail closed)
#>

$script:RehearsalNamePattern = '-rehearsal-\d+$'

function Get-RehearsalDatabaseName {
    param(
        [Parameter(Mandatory)] [string] $SourceDatabase,
        [Parameter(Mandatory)] [ValidatePattern('^\d+$')] [string] $BuildId
    )
    $name = "$SourceDatabase-rehearsal-$BuildId"
    if ($name.Length -gt 128) {
        throw "The rehearsal database name '$name' is longer than 128 characters."
    }
    $name
}

function New-SchemaRehearsalDatabase {
    <#
    .SYNOPSIS
        Creates the rehearsal database and returns its name.
    .DESCRIPTION
        Copy: a copy of the source database (production data and all), for the most realistic test.
        Empty: an empty database; the rehearsal then deploys the released baseline first.
        A leftover rehearsal database with the same name (a re-run of the same build) is removed
        first, but only when it carries the rehearsal tag. Any other database with that name stops
        the script.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $Server,
        [Parameter(Mandatory)] [string] $SourceDatabase,
        [Parameter(Mandatory)] [ValidatePattern('^\d+$')] [string] $BuildId,
        [ValidateSet('Copy', 'Empty')] [string] $Mode = 'Copy',
        [string] $ServiceObjective = 'S3',
        [int] $RetryDelaySeconds = 30
    )

    $name = Get-RehearsalDatabaseName -SourceDatabase $SourceDatabase -BuildId $BuildId
    if ($Mode -eq 'Copy' -and $null -eq (Get-AzureSqlDatabase -ResourceGroup $ResourceGroup -Server $Server -Name $SourceDatabase)) {
        throw "Source database $SourceDatabase does not exist on server $Server."
    }

    $existing = Get-AzureSqlDatabase -ResourceGroup $ResourceGroup -Server $Server -Name $name
    if ($null -ne $existing) {
        if (-not (Test-RehearsalDatabaseTag -Database $existing)) {
            throw "Database $name exists but has no tag $($script:RehearsalTagName)=$($script:RehearsalTagValue). It is not a rehearsal database; it is left alone."
        }
        if ($PSCmdlet.ShouldProcess($name, 'Remove leftover rehearsal database')) {
            Invoke-WithConflictRetry -DelaySeconds $RetryDelaySeconds -ScriptBlock {
                Remove-AzureSqlDatabase -ResourceGroup $ResourceGroup -Server $Server -Name $name | Out-Null
            }
        }
    }

    $tags = @{
        $script:RehearsalTagName = $script:RehearsalTagValue
        source                   = $SourceDatabase
        build                    = $BuildId
    }
    $action = if ($Mode -eq 'Copy') { "Copy $SourceDatabase" } else { 'Create empty database' }
    if ($PSCmdlet.ShouldProcess($name, $action)) {
        Invoke-WithConflictRetry -DelaySeconds $RetryDelaySeconds -ScriptBlock {
            if ($Mode -eq 'Copy') {
                Copy-AzureSqlDatabase -ResourceGroup $ResourceGroup -Server $Server -SourceDatabase $SourceDatabase -TargetDatabase $name -ServiceObjective $ServiceObjective -Tags $tags | Out-Null
            }
            else {
                New-AzureSqlDatabase -ResourceGroup $ResourceGroup -Server $Server -Name $name -ServiceObjective $ServiceObjective -Tags $tags | Out-Null
            }
        }
    }
    $name
}

function Remove-SchemaRehearsalDatabase {
    <#
    .SYNOPSIS
        Removes a rehearsal database. Refuses any database whose name or tag does not mark it as one.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $Server,
        [Parameter(Mandatory)] [ValidatePattern('-rehearsal-\d+$')] [string] $Name,
        [int] $RetryDelaySeconds = 30
    )

    $existing = Get-AzureSqlDatabase -ResourceGroup $ResourceGroup -Server $Server -Name $Name
    if ($null -eq $existing) {
        Write-Host "Rehearsal database $Name does not exist; nothing to remove."
        return
    }
    if (-not (Test-RehearsalDatabaseTag -Database $existing)) {
        throw "Database $Name has no tag $($script:RehearsalTagName)=$($script:RehearsalTagValue). It is not removed."
    }
    if ($PSCmdlet.ShouldProcess($Name, 'Remove rehearsal database')) {
        Invoke-WithConflictRetry -DelaySeconds $RetryDelaySeconds -ScriptBlock {
            Remove-AzureSqlDatabase -ResourceGroup $ResourceGroup -Server $Server -Name $Name | Out-Null
        }
    }
}

function Get-RehearsalExitCode {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Findings)
    if (@($Findings | Where-Object Severity -eq 'Fatal').Count -gt 0) { return 3 }
    if (@($Findings | Where-Object Severity -eq 'Error').Count -gt 0) { return 2 }
    if (@($Findings | Where-Object Severity -eq 'Warning').Count -gt 0) { return 1 }
    0
}

function Invoke-SchemaRehearsalCheck {
    <#
    .SYNOPSIS
        Deploys the candidate release to a rehearsal database and returns ExitCode and Findings
        (Severity Fatal, Error or Warning; Source; Message).
    .DESCRIPTION
        1. When a baseline artifact and the captured columns are given, compares the captured
           columns of the baseline and candidate models (offline).
        2. Empty mode: deploys the baseline Migrations and Schema first, so the database looks
           like the current release.
        3. Publishes the candidate Migrations, writes the Schema deploy report and, when it has no
           blockers, publishes the candidate Schema.
        Only Migrations and Schema are rehearsed: they are the steps that can lose data or fail
        on real data. Seed scripts are idempotent MERGE statements.
    #>
    param(
        [Parameter(Mandatory)] [string] $TargetConnectionString,
        [string] $AccessToken,
        [Parameter(Mandatory)] [string] $ArtifactPath,
        [string] $BaselineArtifactPath,
        [ValidateSet('Copy', 'Empty')] [string] $Mode = 'Copy',
        [string] $CapturedColumnsPath,
        [string] $ProfilePath,
        [Parameter(Mandatory)] [string] $OutputPath,
        [string] $ProjectPrefix = 'Shop.Database',
        [Parameter(Mandatory)] [string] $BuildNumber,
        [switch] $AllowIncompatiblePlatform
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    $variables = @{ BuildNumber = $BuildNumber }
    $migrationProperties = Get-StepProperty -Step Migrations -AllowIncompatiblePlatform:$AllowIncompatiblePlatform
    $schemaProperties = Get-StepProperty -Step Schema -AllowIncompatiblePlatform:$AllowIncompatiblePlatform
    $connection = @{ TargetConnectionString = $TargetConnectionString; AccessToken = $AccessToken; Variables = $variables }

    try {
        $database = Get-ConnectionStringDatabase -ConnectionString $TargetConnectionString
        if ($database -notmatch $script:RehearsalNamePattern) {
            throw "Refusing to rehearse on ${database}: the name does not end in -rehearsal-<build id>."
        }
        if ($Mode -eq 'Empty' -and -not $BaselineArtifactPath) {
            throw 'Empty mode needs -BaselineArtifactPath: the database must look like the current release before the candidate is deployed.'
        }
        if ($CapturedColumnsPath -and -not $BaselineArtifactPath) {
            throw '-CapturedColumnsPath needs -BaselineArtifactPath to compare the captured columns with.'
        }
        if (-not (Test-Path -LiteralPath $OutputPath)) {
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        }
        $candidateMigrations = Find-Dacpac -ArtifactPath $ArtifactPath -Name "$ProjectPrefix.Migrations"
        $candidateSchema = Find-Dacpac -ArtifactPath $ArtifactPath -Name $ProjectPrefix

        if ($CapturedColumnsPath) {
            $captured = Read-CapturedColumn -Path $CapturedColumnsPath
            $baselineTables = @(Get-DacpacTable -Model (Read-DacpacModel -Path (Find-Dacpac -ArtifactPath $BaselineArtifactPath -Name $ProjectPrefix)))
            $candidateTables = @(Get-DacpacTable -Model (Read-DacpacModel -Path $candidateSchema))
            foreach ($finding in @(Compare-CdcColumn -BaselineTables $baselineTables -CandidateTables $candidateTables -CapturedColumns $captured)) {
                $findings.Add([pscustomobject]@{ Severity = $finding.Severity; Source = 'CDC'; Message = $finding.Message })
            }
        }

        if ($Mode -eq 'Empty') {
            Write-Host "Deploying the baseline release to $database."
            Invoke-SqlPackage -Action Publish -SourceFile (Find-Dacpac -ArtifactPath $BaselineArtifactPath -Name "$ProjectPrefix.Migrations") -Properties $migrationProperties @connection
            Invoke-SqlPackage -Action Publish -SourceFile (Find-Dacpac -ArtifactPath $BaselineArtifactPath -Name $ProjectPrefix) -ProfilePath $ProfilePath -Properties $schemaProperties @connection
        }
    }
    catch {
        $findings.Add([pscustomobject]@{ Severity = 'Fatal'; Source = 'Rehearsal'; Message = "The rehearsal could not run: $($_.Exception.Message)" })
        return [pscustomobject]@{ ExitCode = 3; Findings = $findings.ToArray() }
    }

    try {
        Write-Host "Deploying the candidate migrations to $database."
        Invoke-SqlPackage -Action Publish -SourceFile $candidateMigrations -Properties $migrationProperties @connection

        $reportPath = Join-Path $OutputPath 'Schema.deployreport.xml'
        Invoke-SqlPackage -Action DeployReport -SourceFile $candidateSchema -ProfilePath $ProfilePath -OutputPath $reportPath -Properties $schemaProperties @connection
        $report = Read-DeployReport -Path $reportPath
        Write-Host 'Schema changes against the rehearsal database:'
        foreach ($line in @(Format-DeployReport -Report $report)) { Write-Host $line }

        $blockers = @(Get-DeployReportBlocker -Report $report)
        foreach ($blocker in $blockers) {
            $findings.Add([pscustomobject]@{ Severity = 'Error'; Source = 'DeployReport'; Message = $blocker })
        }
        foreach ($alert in @($report.Alerts | Where-Object Name -ne 'DataIssue')) {
            $findings.Add([pscustomobject]@{ Severity = 'Warning'; Source = 'DeployReport'; Message = "$($alert.Name): $($alert.Issue)" })
        }
        if ($blockers.Count -eq 0) {
            Write-Host "Deploying the candidate schema to $database."
            Invoke-SqlPackage -Action Publish -SourceFile $candidateSchema -ProfilePath $ProfilePath -Properties $schemaProperties @connection
        }
    }
    catch {
        $findings.Add([pscustomobject]@{ Severity = 'Error'; Source = 'Deployment'; Message = "The candidate deployment failed: $($_.Exception.Message)" })
    }

    [pscustomobject]@{
        ExitCode = Get-RehearsalExitCode -Findings $findings.ToArray()
        Findings = $findings.ToArray()
    }
}
