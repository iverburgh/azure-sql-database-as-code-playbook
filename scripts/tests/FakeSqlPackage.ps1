Set-StrictMode -Version Latest

<#
    An in-memory stand-in for SqlPackage. Tests mock Invoke-SqlPackage with Invoke-FakeSqlPackage.

      - every call is recorded in $global:FakeSql.Calls (Action, Dacpac, Database, Variables,
        Properties, ProfilePath, OutputPath, AccessToken);
      - DeployReport writes a report with the alerts and operations arranged with
        Set-FakeDeployReport for that dacpac (an empty report otherwise);
      - Script writes a placeholder script;
      - Publish records the dacpac in $global:FakeSql.Published, or throws when the dacpac is
        arranged with Set-FakePublishFailure.

    Arrangements are keyed by the dacpac's full path first and its file name second, so a
    baseline and a candidate dacpac with the same name can get different reports.
#>

function Reset-FakeSqlPackage {
    $global:FakeSql = @{
        Calls     = [System.Collections.Generic.List[object]]::new()
        Published = [System.Collections.Generic.List[string]]::new()
        Reports   = @{}
        Failures  = @{}
    }
}

function Set-FakeDeployReport {
    <#
    .PARAMETER Dacpac
        A dacpac file name (Shop.Database.dacpac) or a full path.
    .PARAMETER Alerts
        Hashtables with Name and Issue.
    .PARAMETER Operations
        Hashtables with Name, Item and Type.
    #>
    param(
        [Parameter(Mandatory)] [string] $Dacpac,
        [hashtable[]] $Alerts = @(),
        [hashtable[]] $Operations = @()
    )
    $global:FakeSql.Reports[$Dacpac] = @{ Alerts = $Alerts; Operations = $Operations }
}

function Set-FakePublishFailure {
    param(
        [Parameter(Mandatory)] [string] $Dacpac,
        [string] $Message = '*** Could not deploy package. Error SQL72014: Msg 547, The UPDATE statement conflicted with the CHECK constraint.'
    )
    $global:FakeSql.Failures[$Dacpac] = $Message
}

function Get-FakeArrangement {
    param([hashtable] $Table, [string] $SourceFile)
    if ($Table.ContainsKey($SourceFile)) { return $Table[$SourceFile] }
    $leaf = Split-Path -Leaf $SourceFile
    if ($Table.ContainsKey($leaf)) { return $Table[$leaf] }
    $null
}

function New-FakeDeployReportXml {
    param([hashtable] $Report)
    $escape = { param($value) [System.Security.SecurityElement]::Escape([string]$value) }
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('<?xml version="1.0" encoding="utf-8"?><DeploymentReport xmlns="http://schemas.microsoft.com/sqlserver/dac/DeployReport/2012/02">')
    if ($null -eq $Report -or $Report.Alerts.Count -eq 0) {
        [void]$builder.Append('<Alerts />')
    }
    else {
        [void]$builder.Append('<Alerts>')
        $id = 1
        foreach ($alert in $Report.Alerts) {
            [void]$builder.Append("<Alert Name=`"$(& $escape $alert.Name)`"><Issue Value=`"$(& $escape $alert.Issue)`" Id=`"$id`" /></Alert>")
            $id++
        }
        [void]$builder.Append('</Alerts>')
    }
    [void]$builder.Append('<Operations>')
    if ($null -ne $Report) {
        foreach ($group in @($Report.Operations | Group-Object { $_.Name })) {
            [void]$builder.Append("<Operation Name=`"$(& $escape $group.Name)`">")
            foreach ($operation in $group.Group) {
                [void]$builder.Append("<Item Value=`"$(& $escape $operation.Item)`" Type=`"$(& $escape $operation.Type)`" />")
            }
            [void]$builder.Append('</Operation>')
        }
    }
    [void]$builder.Append('</Operations></DeploymentReport>')
    $builder.ToString()
}

function Invoke-FakeSqlPackage {
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
    $global:FakeSql.Calls.Add([pscustomobject]@{
            Action      = $Action
            Dacpac      = if ($SourceFile) { Split-Path -Leaf $SourceFile } else { $null }
            SourceFile  = $SourceFile
            Database    = Get-ConnectionStringDatabase -ConnectionString $TargetConnectionString
            AccessToken = $AccessToken
            ProfilePath = $ProfilePath
            OutputPath  = $OutputPath
            Variables   = $Variables.Clone()
            Properties  = $Properties.Clone()
        })

    switch ($Action) {
        'DeployReport' {
            $report = Get-FakeArrangement -Table $global:FakeSql.Reports -SourceFile $SourceFile
            [System.IO.File]::WriteAllText($OutputPath, (New-FakeDeployReportXml -Report $report))
        }
        'Script' {
            [System.IO.File]::WriteAllText($OutputPath, "-- Fake deployment script for $(Split-Path -Leaf $SourceFile)`n")
        }
        'Publish' {
            $failure = Get-FakeArrangement -Table $global:FakeSql.Failures -SourceFile $SourceFile
            if ($null -ne $failure) {
                throw "SqlPackage Publish failed with exit code 1.`n$failure"
            }
            $global:FakeSql.Published.Add((Split-Path -Leaf $SourceFile))
        }
        default {
            throw "Fake SqlPackage: unsupported action $Action."
        }
    }
}

function Get-FakeSqlCall {
    <# The recorded calls, optionally filtered by action, emitted one by one. #>
    param([string] $Action)
    foreach ($call in $global:FakeSql.Calls) {
        if (-not $Action -or $call.Action -eq $Action) { $call }
    }
}
