Set-StrictMode -Version Latest

<#
.SYNOPSIS
    The only function in this playbook that talks to Azure.

.DESCRIPTION
    Runs 'az' with the given arguments, adds '--only-show-errors --output json' and
    writes the parsed JSON to the pipeline. A JSON array is written item by item, so
    callers wrap the call in @(). Tests replace this function with a mock that talks
    to an in-memory fake.

.PARAMETER Arguments
    The az arguments, for example @('sql', 'db', 'show', '--name', $database).

.PARAMETER AllowFailure
    Return nothing instead of throwing when az exits with a non-zero code.
#>
function Invoke-AzCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [switch] $AllowFailure
    )

    $output = & az @Arguments --only-show-errors --output json 2>&1
    $exitCode = $LASTEXITCODE

    $stdout = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $stderr = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join "`n"

    if ($exitCode -ne 0) {
        if ($AllowFailure) {
            return
        }
        $command = @($Arguments | Where-Object { -not $_.StartsWith('-') } | Select-Object -First 4) -join ' '
        throw "az $command failed with exit code ${exitCode}: $stderr"
    }

    if ([string]::IsNullOrWhiteSpace($stdout)) {
        return
    }

    $convertParameters = @{ Depth = 64; NoEnumerate = $true }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $convertParameters.DateKind = 'String'
    }
    $parsed = ConvertFrom-Json -InputObject $stdout @convertParameters

    # WriteObject(x, $false) keeps a nested array intact; Write-Output -NoEnumerate would wrap a single object in a list.
    if ($parsed -is [System.Array]) {
        foreach ($item in $parsed) {
            $PSCmdlet.WriteObject($item, $false)
        }
    }
    else {
        $PSCmdlet.WriteObject($parsed, $false)
    }
}
