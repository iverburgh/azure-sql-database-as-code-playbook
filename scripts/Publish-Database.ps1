<#
.SYNOPSIS
    Deploys the database dacpacs of a build to one environment.

.DESCRIPTION
    Publishes, in order: (DropAll), Migrations, Schema, ReferenceData, SeedConfiguration.<env>
    and (TestData), as configured for the environment in database/environments.json.

    Before the schema is changed, SqlPackage writes a deploy report and a change script to
    -OutputPath. Possible data loss or a table rebuild stops the deployment; the publish profile
    blocks data loss as a second line of defence.

    With -WhatIf nothing is published: the reports and scripts are written, blockers are shown
    as warnings. Use it in a pull request or before an approval.

    Azure: pass -Server and -Database. The access token of the az login is used unless -AccessToken
    is given. Local SQL Server or a container: pass -ConnectionString, and -AllowIncompatiblePlatform
    because the projects target Azure SQL Database.

.PARAMETER ArtifactPath
    The folder with the built dacpacs (the pipeline artifact, or database/ after a local build).

.PARAMETER Environment
    The environment name in environments.json.

.PARAMETER BuildNumber
    Recorded in dbo.DeploymentHistory for every migration and schema deployment.

.PARAMETER DriftBaselineDacpac
    The schema dacpac of the release that is deployed now. When given, the database is compared
    with it first, to find changes made outside the pipeline.

.PARAMETER FailOnDrift
    Stop when the drift check finds differences, instead of warning.

.PARAMETER DropAll
    Empty the database first. Only for environments with allowDropAll.

.EXAMPLE
    ./scripts/Publish-Database.ps1 -ArtifactPath ./drop -Environment Test -Server my-sql-test -Database my-shop -BuildNumber 20260101.1 -WhatIf

.EXAMPLE
    ./scripts/Publish-Database.ps1 -ArtifactPath ./database -Environment Development -ConnectionString 'Server=localhost;Initial Catalog=Shop;Integrated Security=True;TrustServerCertificate=True' -BuildNumber local -AllowIncompatiblePlatform
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Azure')]
param(
    [Parameter(Mandatory)]
    [string] $ArtifactPath,

    [Parameter(Mandatory)]
    [string] $Environment,

    [Parameter(Mandatory, ParameterSetName = 'Azure')]
    [string] $Server,

    [Parameter(Mandatory, ParameterSetName = 'Azure')]
    [string] $Database,

    [Parameter(ParameterSetName = 'Azure')]
    [string] $AccessToken,

    [Parameter(Mandatory, ParameterSetName = 'ConnectionString')]
    [string] $ConnectionString,

    [Parameter(Mandatory)]
    [string] $BuildNumber,

    [string] $OutputPath = 'deploy-reports',

    [string] $EnvironmentsPath,

    [string] $ProfilePath,

    [string] $ProjectPrefix = 'Shop.Database',

    [string] $DriftBaselineDacpac,

    [switch] $FailOnDrift,

    [switch] $DropAll,

    [switch] $AllowIncompatiblePlatform
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($lib in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'lib') -Filter '*.ps1' -File)) {
    . $lib.FullName
}

$root = Get-RepositoryRoot
if (-not $EnvironmentsPath) {
    $EnvironmentsPath = Join-Path $root 'database/environments.json'
}
if (-not $ProfilePath) {
    $ProfilePath = Join-Path $root "database/publish/$ProjectPrefix.publish.xml"
}
if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) {
    throw "Publish profile not found: $ProfilePath"
}

$settings = Get-DeploymentEnvironment -Path $EnvironmentsPath -Name $Environment

if ($PSCmdlet.ParameterSetName -eq 'Azure') {
    $target = New-AzureSqlConnectionString -Server $Server -Database $Database
    if (-not $AccessToken) {
        $AccessToken = Get-SqlAccessToken
    }
}
else {
    $target = $ConnectionString
    $AccessToken = $null
}

$results = @(Invoke-DatabaseDeployment -ArtifactPath $ArtifactPath -Environment $settings -TargetConnectionString $target -AccessToken $AccessToken `
        -BuildNumber $BuildNumber -OutputPath $OutputPath -ProfilePath $ProfilePath -ProjectPrefix $ProjectPrefix `
        -DriftBaselineDacpac $DriftBaselineDacpac -FailOnDrift:$FailOnDrift -DropAll:$DropAll -AllowIncompatiblePlatform:$AllowIncompatiblePlatform `
        -WhatIf:$WhatIfPreference)

Write-Host ''
Write-Host "Database deployment to $(Get-ConnectionStringDatabase -ConnectionString $target) ($Environment):"
foreach ($result in $results) {
    Write-Host ("  {0,-18} {1,-9} {2}" -f $result.Step, $result.Status, (Split-Path -Leaf $result.Dacpac))
}
Write-Host "Reports and scripts: $((Resolve-Path -LiteralPath $OutputPath).ProviderPath)"
