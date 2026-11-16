Set-StrictMode -Version Latest

<#
    Azure SQL helpers on top of Invoke-AzCli: access tokens, connection strings and the
    database copy, create and delete calls used by the schema rehearsal.
#>

$script:RehearsalTagName = 'purpose'
$script:RehearsalTagValue = 'schema-rehearsal'

function Get-SqlAccessToken {
    <# An Entra ID access token for Azure SQL, for the identity that az is logged in with. #>
    $token = Invoke-AzCli -Arguments @('account', 'get-access-token', '--resource', 'https://database.windows.net/')
    if ($null -eq $token -or -not $token.PSObject.Properties['accessToken']) {
        throw 'az account get-access-token returned no access token.'
    }
    $token.accessToken
}

function New-AzureSqlConnectionString {
    <# A connection string without credentials; pass the access token separately. #>
    param(
        [Parameter(Mandatory)] [string] $Server,
        [Parameter(Mandatory)] [string] $Database
    )
    $fqdn = if ($Server.Contains('.')) { $Server } else { '{0}.database.windows.net' -f $Server }
    "Server=tcp:$fqdn,1433;Initial Catalog=$Database;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
}

function Get-ConnectionStringDatabase {
    <# The database name (Initial Catalog or Database) of a connection string. #>
    param([Parameter(Mandatory)] [string] $ConnectionString)
    $builder = [System.Data.Common.DbConnectionStringBuilder]::new()
    # PowerShell adapts the builder as a dictionary, so '.ConnectionString = ' would add a key; call the setter.
    $builder.set_ConnectionString($ConnectionString)
    foreach ($key in @('Initial Catalog', 'Database')) {
        if ($builder.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$builder[$key])) {
            return [string]$builder[$key]
        }
    }
    throw 'The connection string has no Initial Catalog (database name).'
}

function Get-AzureSqlDatabase {
    <# The database as az returns it, or $null when it does not exist. #>
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $Server,
        [Parameter(Mandatory)] [string] $Name
    )
    Invoke-AzCli -Arguments @('sql', 'db', 'show', '--resource-group', $ResourceGroup, '--server', $Server, '--name', $Name) -AllowFailure
}

function Test-RehearsalDatabaseTag {
    <# True when the database carries the tag that marks it as a disposable rehearsal copy. #>
    param([Parameter(Mandatory)] [object] $Database)
    $tags = $Database.PSObject.Properties['tags']
    if ($null -eq $tags -or $null -eq $tags.Value) {
        return $false
    }
    $tag = $tags.Value.PSObject.Properties[$script:RehearsalTagName]
    $null -ne $tag -and $tag.Value -eq $script:RehearsalTagValue
}

function ConvertTo-AzTagArgument {
    param([Parameter(Mandatory)] [hashtable] $Tags)
    [string[]] $names = @($Tags.Keys)
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    foreach ($name in $names) { "$name=$($Tags[$name])" }
}

function Copy-AzureSqlDatabase {
    <# A transactionally consistent copy on the same server, with locally redundant backups. #>
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $Server,
        [Parameter(Mandatory)] [string] $SourceDatabase,
        [Parameter(Mandatory)] [string] $TargetDatabase,
        [Parameter(Mandatory)] [string] $ServiceObjective,
        [Parameter(Mandatory)] [hashtable] $Tags
    )
    $arguments = @('sql', 'db', 'copy', '--resource-group', $ResourceGroup, '--server', $Server, '--name', $SourceDatabase,
        '--dest-name', $TargetDatabase, '--service-objective', $ServiceObjective, '--backup-storage-redundancy', 'Local', '--tags') + @(ConvertTo-AzTagArgument -Tags $Tags)
    Invoke-AzCli -Arguments $arguments
}

function New-AzureSqlDatabase {
    <# An empty database with locally redundant backups. #>
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $Server,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $ServiceObjective,
        [Parameter(Mandatory)] [hashtable] $Tags
    )
    $arguments = @('sql', 'db', 'create', '--resource-group', $ResourceGroup, '--server', $Server, '--name', $Name,
        '--service-objective', $ServiceObjective, '--backup-storage-redundancy', 'Local', '--tags') + @(ConvertTo-AzTagArgument -Tags $Tags)
    Invoke-AzCli -Arguments $arguments
}

function Remove-AzureSqlDatabase {
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $Server,
        [Parameter(Mandatory)] [string] $Name
    )
    Invoke-AzCli -Arguments @('sql', 'db', 'delete', '--resource-group', $ResourceGroup, '--server', $Server, '--name', $Name, '--yes')
}

function Invoke-WithConflictRetry {
    <#
    .SYNOPSIS
        Runs the script block and retries it while Azure reports a conflicting operation.
    .DESCRIPTION
        Only one management operation can run per database (and some per server) at a time. Two
        pipelines that rehearse at once, or a delete right after a copy, fail with
        ConflictingServerOperation or ConflictingDatabaseOperation. Those are retried; every
        other error is thrown immediately.
    #>
    param(
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [ValidateRange(1, 20)] [int] $MaxAttempts = 5,
        [ValidateRange(0, 600)] [int] $DelaySeconds = 30
    )
    for ($attempt = 1; ; $attempt++) {
        try {
            return & $ScriptBlock
        }
        catch {
            $message = $_.Exception.Message
            if ($attempt -ge $MaxAttempts -or $message -notmatch 'Conflicting(Server|Database)Operation|OperationInProgress') {
                throw
            }
            Write-Warning "Attempt $attempt of ${MaxAttempts}: another operation is running ($($message.Split("`n")[0])). Retrying in $DelaySeconds seconds."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}
