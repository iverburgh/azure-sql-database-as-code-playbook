<#
.SYNOPSIS
    Deploys a release to a rehearsal database and reports what would happen in production.

.DESCRIPTION
    Runs the candidate Migrations and Schema dacpacs against a rehearsal database created by
    New-RehearsalDatabase.ps1, and optionally compares the captured (CDC) columns with the
    released baseline. The database name must end in -rehearsal-<build id>.

    Exit codes:
      0  passed
      1  passed with warnings; in Azure Pipelines the step ends as SucceededWithIssues
      2  blocked: data loss, a table rebuild, a failing migration or a captured column that
         changes type; do not deploy this release
      3  the rehearsal could not run; treat as blocked

.PARAMETER ArtifactPath
    The dacpacs of the release to rehearse.

.PARAMETER BaselineArtifactPath
    The dacpacs of the release in production. Required in Empty mode and for the CDC check.

.PARAMETER Mode
    Copy: the database is a copy of production. Empty: deploy the baseline first.

.EXAMPLE
    ./scripts/Invoke-SchemaRehearsal.ps1 -Server my-sql-prod -Database my-shop-rehearsal-1234 -ArtifactPath ./drop -BaselineArtifactPath ./baseline -CapturedColumnsPath database/cdc/captured-columns.json -BuildNumber 20260101.1
#>
[CmdletBinding(DefaultParameterSetName = 'Azure')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Azure')]
    [string] $Server,

    [Parameter(Mandatory, ParameterSetName = 'Azure')]
    [ValidatePattern('-rehearsal-\d+$')]
    [string] $Database,

    [Parameter(ParameterSetName = 'Azure')]
    [string] $AccessToken,

    [Parameter(Mandatory, ParameterSetName = 'ConnectionString')]
    [string] $ConnectionString,

    [Parameter(Mandatory)]
    [string] $ArtifactPath,

    [string] $BaselineArtifactPath,

    [ValidateSet('Copy', 'Empty')]
    [string] $Mode = 'Copy',

    [string] $CapturedColumnsPath,

    [string] $OutputPath = 'rehearsal-reports',

    [string] $ProfilePath,

    [string] $ProjectPrefix = 'Shop.Database',

    [Parameter(Mandatory)]
    [string] $BuildNumber,

    [switch] $AllowIncompatiblePlatform
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($lib in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'lib') -Filter '*.ps1' -File)) {
    . $lib.FullName
}

if (-not $ProfilePath) {
    $ProfilePath = Join-Path (Get-RepositoryRoot) "database/publish/$ProjectPrefix.publish.xml"
}

try {
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
    $result = Invoke-SchemaRehearsalCheck -TargetConnectionString $target -AccessToken $AccessToken -ArtifactPath $ArtifactPath `
        -BaselineArtifactPath $BaselineArtifactPath -Mode $Mode -CapturedColumnsPath $CapturedColumnsPath -ProfilePath $ProfilePath `
        -OutputPath $OutputPath -ProjectPrefix $ProjectPrefix -BuildNumber $BuildNumber -AllowIncompatiblePlatform:$AllowIncompatiblePlatform
}
catch {
    Write-Host "FATAL: the rehearsal could not run: $($_.Exception.Message)"
    exit 3
}

Write-Host ''
Write-Host 'Schema rehearsal findings:'
if (@($result.Findings).Count -eq 0) {
    Write-Host '  none'
}
foreach ($finding in @($result.Findings)) {
    Write-Host "  $($finding.Severity.ToUpperInvariant()) [$($finding.Source)] $($finding.Message)"
}
$verdict = switch ($result.ExitCode) {
    0 { 'passed' }
    1 { 'passed with warnings' }
    2 { 'blocked' }
    default { 'could not run (blocked)' }
}
Write-Host "Schema rehearsal $verdict."

if ($env:TF_BUILD -and $result.ExitCode -eq 1) {
    Write-Host '##vso[task.complete result=SucceededWithIssues;]Schema rehearsal passed with warnings.'
    exit 0
}
exit $result.ExitCode
