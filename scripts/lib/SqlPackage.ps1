Set-StrictMode -Version Latest

<#
.SYNOPSIS
    The only function in this playbook that runs SqlPackage.

.DESCRIPTION
    Builds the SqlPackage command line from named parameters, streams its output to the
    host and throws when it exits with a non-zero code. Secrets (the access token and a
    password in the connection string) are masked in the error message. Tests replace this
    function with a mock, or point SQLPACKAGE_PATH at a fake script.

    SqlPackage is found through the SQLPACKAGE_PATH environment variable, or on the PATH
    (install it with 'dotnet tool install --global microsoft.sqlpackage').

.PARAMETER Action
    Publish, DeployReport, Script, DriftReport or Extract.

.PARAMETER Variables
    SQLCMD variables, passed as /v:Name=Value.

.PARAMETER Properties
    Deployment properties, passed as /p:Name=Value. They override the publish profile.
#>
function Invoke-SqlPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Publish', 'DeployReport', 'Script', 'DriftReport', 'Extract')]
        [string] $Action,

        [string] $SourceFile,

        [Parameter(Mandatory)]
        [string] $TargetConnectionString,

        [string] $AccessToken,

        [string] $ProfilePath,

        [string] $OutputPath,

        [hashtable] $Variables = @{},

        [hashtable] $Properties = @{}
    )

    $arguments = Get-SqlPackageArgument -Action $Action -SourceFile $SourceFile -TargetConnectionString $TargetConnectionString `
        -AccessToken $AccessToken -ProfilePath $ProfilePath -OutputPath $OutputPath -Variables $Variables -Properties $Properties

    $executable = Get-SqlPackagePath
    $output = [System.Collections.Generic.List[string]]::new()
    & $executable @arguments 2>&1 | ForEach-Object {
        $line = "$_"
        $output.Add($line)
        Write-Host $line
    }
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $masked = (@($arguments | ForEach-Object { Hide-SqlPackageSecret -Argument $_ }) -join ' ')
        $tail = @($output | Select-Object -Last 20) -join "`n"
        throw "SqlPackage $Action failed with exit code ${exitCode}.`nArguments: $masked`n$tail"
    }
}

function Get-SqlPackagePath {
    if (-not [string]::IsNullOrWhiteSpace($env:SQLPACKAGE_PATH)) {
        if (-not (Test-Path -LiteralPath $env:SQLPACKAGE_PATH -PathType Leaf)) {
            throw "SQLPACKAGE_PATH points to '$env:SQLPACKAGE_PATH', which does not exist."
        }
        return $env:SQLPACKAGE_PATH
    }
    $command = Get-Command -Name 'sqlpackage' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        throw 'SqlPackage was not found. Install it with "dotnet tool install --global microsoft.sqlpackage" or set SQLPACKAGE_PATH.'
    }
    $command.Source
}

function Get-SqlPackageArgument {
    <# The SqlPackage arguments in a stable order: action, files, target, profile, then sorted /v: and /p:. #>
    param(
        [Parameter(Mandatory)] [string] $Action,
        [string] $SourceFile,
        [Parameter(Mandatory)] [string] $TargetConnectionString,
        [string] $AccessToken,
        [string] $ProfilePath,
        [string] $OutputPath,
        [hashtable] $Variables = @{},
        [hashtable] $Properties = @{}
    )

    "/Action:$Action"
    if ($SourceFile) { "/SourceFile:$SourceFile" }
    "/TargetConnectionString:$TargetConnectionString"
    if ($AccessToken) { "/AccessToken:$AccessToken" }
    if ($ProfilePath) { "/Profile:$ProfilePath" }
    if ($OutputPath) { "/OutputPath:$OutputPath" }
    [string[]] $variableNames = @($Variables.Keys)
    [System.Array]::Sort($variableNames, [System.StringComparer]::Ordinal)
    foreach ($name in $variableNames) { "/v:$name=$($Variables[$name])" }
    [string[]] $propertyNames = @($Properties.Keys)
    [System.Array]::Sort($propertyNames, [System.StringComparer]::Ordinal)
    foreach ($name in $propertyNames) { "/p:$name=$($Properties[$name])" }
}

function Hide-SqlPackageSecret {
    param([Parameter(Mandatory)] [string] $Argument)
    if ($Argument.StartsWith('/AccessToken:', [System.StringComparison]::OrdinalIgnoreCase)) {
        return '/AccessToken:***'
    }
    [regex]::Replace($Argument, '(?i)(password|pwd)\s*=\s*[^;]*', '$1=***')
}
