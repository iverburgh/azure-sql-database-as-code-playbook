Set-StrictMode -Version Latest

<#
    An in-memory stand-in for the Azure SQL calls the playbook makes through Invoke-AzCli:
    an access token and 'az sql db show | copy | create | delete'. Databases are kept per
    resource group and server, with their tags. Every call is recorded in $global:Fake.Calls and
    every change in $global:Fake.Writes, so tests can assert that a -WhatIf run changed nothing.
    $global:Fake.Conflicts makes the next N changes fail with ConflictingDatabaseOperation.
#>

function Reset-FakeAzure {
    $global:Fake = @{
        Databases = @{}
        Calls     = [System.Collections.Generic.List[string]]::new()
        Writes    = [System.Collections.Generic.List[string]]::new()
        Conflicts = 0
        Token     = 'fake-access-token'
    }
}

function Add-FakeDatabase {
    <# Arranges a database directly, without recording a write. #>
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $Server,
        [Parameter(Mandatory)] [string] $Name,
        [hashtable] $Tags = @{}
    )
    $global:Fake.Databases["$ResourceGroup/$Server/$Name"] = @{ Name = $Name; Tags = $Tags.Clone(); CopyOf = $null; ServiceObjective = 'S3' }
}

function Get-FakeDatabase {
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $Server,
        [Parameter(Mandatory)] [string] $Name
    )
    $key = "$ResourceGroup/$Server/$Name"
    if ($global:Fake.Databases.ContainsKey($key)) { $global:Fake.Databases[$key] } else { $null }
}

function Get-FakeArgument {
    param([string[]] $Arguments, [string] $Name)
    $index = [Array]::IndexOf($Arguments, $Name)
    if ($index -lt 0 -or $index + 1 -ge $Arguments.Count) {
        throw "Fake az: missing $Name in '$($Arguments -join ' ')'."
    }
    $Arguments[$index + 1]
}

function Get-FakeTagArgument {
    param([string[]] $Arguments)
    $tags = @{}
    $index = [Array]::IndexOf($Arguments, '--tags')
    if ($index -lt 0) { return $tags }
    for ($i = $index + 1; $i -lt $Arguments.Count -and -not $Arguments[$i].StartsWith('--'); $i++) {
        $name, $value = $Arguments[$i].Split('=', 2)
        $tags[$name] = $value
    }
    $tags
}

function ConvertTo-FakeDatabaseOutput {
    param([hashtable] $Database)
    $tags = [ordered]@{}
    foreach ($key in @($Database.Tags.Keys | Sort-Object)) { $tags[$key] = $Database.Tags[$key] }
    [pscustomobject]@{
        name = $Database.Name
        tags = [pscustomobject]$tags
    }
}

function Invoke-FakeChange {
    param([string] $Description)
    if ($global:Fake.Conflicts -gt 0) {
        $global:Fake.Conflicts--
        throw "az sql db failed with exit code 1: (ConflictingDatabaseOperation) There is already an operation in progress. ($Description)"
    }
    $global:Fake.Writes.Add($Description)
}

function Invoke-FakeAzCli {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [switch] $AllowFailure
    )
    $global:Fake.Calls.Add($Arguments -join ' ')
    $command = @($Arguments | Select-Object -First 3) -join ' '

    if ($command -eq 'account get-access-token --resource') {
        return [pscustomobject]@{ accessToken = $global:Fake.Token; tokenType = 'Bearer' }
    }

    $group = Get-FakeArgument -Arguments $Arguments -Name '--resource-group'
    $server = Get-FakeArgument -Arguments $Arguments -Name '--server'
    $name = Get-FakeArgument -Arguments $Arguments -Name '--name'
    $key = "$group/$server/$name"

    switch ($command) {
        'sql db show' {
            if (-not $global:Fake.Databases.ContainsKey($key)) {
                if ($AllowFailure) { return }
                throw "az sql db show failed with exit code 3: (ResourceNotFound) Database $name does not exist."
            }
            return ConvertTo-FakeDatabaseOutput -Database $global:Fake.Databases[$key]
        }
        'sql db copy' {
            if (-not $global:Fake.Databases.ContainsKey($key)) {
                throw "az sql db copy failed with exit code 3: (ResourceNotFound) Database $name does not exist."
            }
            $target = Get-FakeArgument -Arguments $Arguments -Name '--dest-name'
            $targetKey = "$group/$server/$target"
            if ($global:Fake.Databases.ContainsKey($targetKey)) {
                throw "az sql db copy failed with exit code 1: (DatabaseAlreadyExists) Database $target already exists."
            }
            Invoke-FakeChange -Description "copy $name -> $target"
            $global:Fake.Databases[$targetKey] = @{
                Name             = $target
                Tags             = Get-FakeTagArgument -Arguments $Arguments
                CopyOf           = $name
                ServiceObjective = Get-FakeArgument -Arguments $Arguments -Name '--service-objective'
            }
            return ConvertTo-FakeDatabaseOutput -Database $global:Fake.Databases[$targetKey]
        }
        'sql db create' {
            if ($global:Fake.Databases.ContainsKey($key)) {
                throw "az sql db create failed with exit code 1: (DatabaseAlreadyExists) Database $name already exists."
            }
            Invoke-FakeChange -Description "create $name"
            $global:Fake.Databases[$key] = @{
                Name             = $name
                Tags             = Get-FakeTagArgument -Arguments $Arguments
                CopyOf           = $null
                ServiceObjective = Get-FakeArgument -Arguments $Arguments -Name '--service-objective'
            }
            return ConvertTo-FakeDatabaseOutput -Database $global:Fake.Databases[$key]
        }
        'sql db delete' {
            if ($Arguments -notcontains '--yes') {
                throw 'Fake az: sql db delete without --yes would prompt.'
            }
            Invoke-FakeChange -Description "delete $name"
            [void]$global:Fake.Databases.Remove($key)
            return
        }
        default {
            throw "Fake az: unsupported command '$($Arguments -join ' ')'."
        }
    }
}
