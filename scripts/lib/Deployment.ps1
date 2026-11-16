Set-StrictMode -Version Latest

<#
    Deployment of the database dacpacs to one environment, in a fixed order:

      DropAll            only when asked and allowed: empties a development database
      Migrations         data migrations that a declarative model cannot express
      Schema             the declarative model, with a deploy report and a data loss check first
      ReferenceData      rows every environment needs (lookup values)
      SeedConfiguration  configuration rows for this environment only
      TestData           test rows, never in a protected environment

    Every step publishes one dacpac with Invoke-SqlPackage.
#>

function Find-Dacpac {
    <# The one dacpac with this name under the artifact path; throws when there is none or more than one. #>
    param(
        [Parameter(Mandatory)] [string] $ArtifactPath,
        [Parameter(Mandatory)] [string] $Name
    )
    if (-not (Test-Path -LiteralPath $ArtifactPath -PathType Container)) {
        throw "Artifact folder not found: $ArtifactPath"
    }
    $separator = [regex]::Escape([System.IO.Path]::DirectorySeparatorChar)
    $found = @(Get-ChildItem -LiteralPath $ArtifactPath -Recurse -File -Filter "$Name.dacpac" |
            Where-Object { $_.FullName -notmatch "${separator}obj${separator}" })
    if ($found.Count -eq 0) {
        throw "No $Name.dacpac under $ArtifactPath. Build the database projects first."
    }
    if ($found.Count -gt 1) {
        throw "More than one $Name.dacpac under ${ArtifactPath}: $(@($found | ForEach-Object FullName) -join ', '). Pass a narrower artifact path."
    }
    $found[0].FullName
}

function Get-DeploymentEnvironment {
    <# The settings of one environment from environments.json, validated. #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Name
    )
    $document = Read-JsonFile -Path $Path
    if (-not $document.Contains('environments') -or -not $document.environments.Contains($Name)) {
        $known = if ($document.Contains('environments')) { @($document.environments.Keys) -join ', ' } else { '' }
        throw "Environment '$Name' is not in ${Path}. Known environments: $known."
    }
    $settings = $document.environments[$Name]
    foreach ($key in @('seedConfiguration', 'testData', 'allowDropAll', 'protected')) {
        if (-not $settings.Contains($key)) {
            throw "${Path}: environment '$Name' has no '$key'."
        }
    }
    if ($settings.protected -and ($settings.testData -or $settings.allowDropAll)) {
        throw "${Path}: environment '$Name' is protected, so testData and allowDropAll must be false."
    }
    [pscustomobject]@{
        Name              = $Name
        SeedConfiguration = [string]$settings.seedConfiguration
        TestData          = [bool]$settings.testData
        AllowDropAll      = [bool]$settings.allowDropAll
        Protected         = [bool]$settings.protected
    }
}

function Get-DeploymentPlan {
    <# Emits the steps for an environment in deployment order: Step and Project (the dacpac name). #>
    param(
        [Parameter(Mandatory)] [object] $Environment,
        [string] $ProjectPrefix = 'Shop.Database',
        [switch] $DropAll
    )
    if ($DropAll -and -not $Environment.AllowDropAll) {
        throw "Environment '$($Environment.Name)' does not allow DropAll."
    }
    if ($DropAll) {
        [pscustomobject]@{ Step = 'DropAll'; Project = "$ProjectPrefix.DropAll" }
    }
    [pscustomobject]@{ Step = 'Migrations'; Project = "$ProjectPrefix.Migrations" }
    [pscustomobject]@{ Step = 'Schema'; Project = $ProjectPrefix }
    [pscustomobject]@{ Step = 'ReferenceData'; Project = "$ProjectPrefix.ReferenceData" }
    [pscustomobject]@{ Step = 'SeedConfiguration'; Project = "$ProjectPrefix.SeedConfiguration.$($Environment.SeedConfiguration)" }
    if ($Environment.TestData) {
        [pscustomobject]@{ Step = 'TestData'; Project = "$ProjectPrefix.TestData" }
    }
}

function Get-StepProperty {
    <# Deployment properties per step. Script-only dacpacs must never change database options or drop objects. #>
    param(
        [Parameter(Mandatory)] [string] $Step,
        [switch] $AllowIncompatiblePlatform
    )
    $properties = @{}
    if ($Step -ne 'Schema') {
        $properties.ScriptDatabaseOptions = 'False'
        $properties.DropObjectsNotInSource = 'False'
    }
    if ($AllowIncompatiblePlatform) {
        $properties.AllowIncompatiblePlatform = 'True'
    }
    $properties
}

function Test-DatabaseDrift {
    <#
    .SYNOPSIS
        Compares the target with the dacpac of the release it should match and emits one message per difference.
    .DESCRIPTION
        Run before the deployment with the dacpac of the previous release. Any operation in the
        report means the database was changed outside the pipeline (a hotfix, a manual index),
        which the deployment would silently undo or trip over.
    #>
    param(
        [Parameter(Mandatory)] [string] $BaselineDacpac,
        [Parameter(Mandatory)] [string] $TargetConnectionString,
        [string] $AccessToken,
        [string] $ProfilePath,
        [Parameter(Mandatory)] [string] $OutputPath,
        [hashtable] $Variables = @{},
        [switch] $AllowIncompatiblePlatform
    )
    $reportPath = Join-Path $OutputPath 'drift.deployreport.xml'
    Invoke-SqlPackage -Action DeployReport -SourceFile $BaselineDacpac -TargetConnectionString $TargetConnectionString -AccessToken $AccessToken `
        -ProfilePath $ProfilePath -OutputPath $reportPath -Variables $Variables -Properties (Get-StepProperty -Step Schema -AllowIncompatiblePlatform:$AllowIncompatiblePlatform)
    $report = Read-DeployReport -Path $reportPath
    foreach ($operation in @($report.Operations)) {
        "$($operation.Name) $($operation.Item) ($($operation.Type))"
    }
}

function Invoke-DatabaseDeployment {
    <#
    .SYNOPSIS
        Deploys the dacpacs of an artifact to one database and emits one result per step:
        Step, Dacpac, Status (Deployed or Planned), Report and Blockers.
    .DESCRIPTION
        With -WhatIf nothing is published: the Schema step writes its deploy report and script,
        every other step writes its script, and blockers are reported as warnings. Without
        -WhatIf a blocker in the Schema deploy report stops the deployment before the schema is
        changed. Note that under -WhatIf the pending migrations have not run, so the Schema
        report compares against the database as it is now.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $ArtifactPath,
        [Parameter(Mandatory)] [object] $Environment,
        [Parameter(Mandatory)] [string] $TargetConnectionString,
        [string] $AccessToken,
        [Parameter(Mandatory)] [string] $BuildNumber,
        [Parameter(Mandatory)] [string] $OutputPath,
        [string] $ProfilePath,
        [string] $ProjectPrefix = 'Shop.Database',
        [string] $DriftBaselineDacpac,
        [switch] $FailOnDrift,
        [switch] $DropAll,
        [switch] $AllowIncompatiblePlatform
    )

    $database = Get-ConnectionStringDatabase -ConnectionString $TargetConnectionString
    $plan = @(Get-DeploymentPlan -Environment $Environment -ProjectPrefix $ProjectPrefix -DropAll:$DropAll)
    $dacpacs = @{}
    foreach ($step in $plan) {
        $dacpacs[$step.Step] = Find-Dacpac -ArtifactPath $ArtifactPath -Name $step.Project
    }
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false | Out-Null
    }
    $variables = @{ BuildNumber = $BuildNumber }

    if ($DriftBaselineDacpac) {
        $drift = @(Test-DatabaseDrift -BaselineDacpac $DriftBaselineDacpac -TargetConnectionString $TargetConnectionString -AccessToken $AccessToken `
                -ProfilePath $ProfilePath -OutputPath $OutputPath -Variables $variables -AllowIncompatiblePlatform:$AllowIncompatiblePlatform)
        if ($drift.Count -gt 0) {
            $message = "$database differs from the previous release ($($drift.Count) difference(s)):`n  $($drift -join "`n  ")"
            if ($FailOnDrift) {
                throw $message
            }
            Write-Warning $message
        }
    }

    foreach ($step in $plan) {
        $dacpac = $dacpacs[$step.Step]
        $stepVariables = $variables.Clone()
        if ($step.Step -eq 'DropAll') {
            $stepVariables.ConfirmDropAll = $database
        }
        $properties = Get-StepProperty -Step $step.Step -AllowIncompatiblePlatform:$AllowIncompatiblePlatform
        $stepProfile = if ($step.Step -eq 'Schema') { $ProfilePath } else { $null }
        $common = @{
            SourceFile             = $dacpac
            TargetConnectionString = $TargetConnectionString
            AccessToken            = $AccessToken
            ProfilePath            = $stepProfile
            Variables              = $stepVariables
            Properties             = $properties
        }
        $reportPath = $null
        $blockers = @()

        if ($step.Step -eq 'Schema') {
            $reportPath = Join-Path $OutputPath "$($step.Step).deployreport.xml"
            Invoke-SqlPackage -Action DeployReport -OutputPath $reportPath @common
            $report = Read-DeployReport -Path $reportPath
            Write-Host "Schema changes for ${database}:"
            foreach ($line in @(Format-DeployReport -Report $report)) { Write-Host $line }
            $blockers = @(Get-DeployReportBlocker -Report $report)
        }
        Invoke-SqlPackage -Action Script -OutputPath (Join-Path $OutputPath "$($step.Step).sql") @common

        if ($blockers.Count -gt 0) {
            $message = "The schema change for $database is blocked:`n  $($blockers -join "`n  ")"
            if ($WhatIfPreference) {
                Write-Warning $message
            }
            else {
                throw $message
            }
        }

        $status = 'Planned'
        if ($PSCmdlet.ShouldProcess($database, "Publish $($step.Project)")) {
            Invoke-SqlPackage -Action Publish @common
            $status = 'Deployed'
        }
        [pscustomobject]@{
            Step     = $step.Step
            Dacpac   = $dacpac
            Status   = $status
            Report   = $reportPath
            Blockers = $blockers
        }
    }
}
