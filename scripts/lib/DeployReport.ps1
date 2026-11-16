Set-StrictMode -Version Latest

<#
    Reads the XML report that 'SqlPackage /Action:DeployReport' writes, and decides which parts
    of it must stop a deployment. The report lists alerts (such as DataIssue: data loss could
    occur) and operations (Create, Alter, Drop, TableRebuild, ...) per object.
#>

$script:DeployReportNamespace = 'http://schemas.microsoft.com/sqlserver/dac/DeployReport/2012/02'

function Read-DeployReport {
    <#
    .SYNOPSIS
        Returns @{ Alerts = [{Name, Issue}]; Operations = [{Name, Item, Type}] } for a deploy report file.
    #>
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Deploy report not found: $Path"
    }
    $document = [System.Xml.XmlDocument]::new()
    $document.XmlResolver = $null
    $document.Load((Resolve-Path -LiteralPath $Path).ProviderPath)
    $ns = [System.Xml.XmlNamespaceManager]::new($document.NameTable)
    $ns.AddNamespace('r', $script:DeployReportNamespace)

    if ($null -eq $document.SelectSingleNode('/r:DeploymentReport', $ns)) {
        throw "${Path} is not a SqlPackage deploy report."
    }

    $alerts = [System.Collections.Generic.List[object]]::new()
    foreach ($alert in @($document.SelectNodes('/r:DeploymentReport/r:Alerts/r:Alert', $ns))) {
        foreach ($issue in @($alert.SelectNodes('r:Issue', $ns))) {
            $alerts.Add([pscustomobject]@{ Name = $alert.GetAttribute('Name'); Issue = $issue.GetAttribute('Value') })
        }
    }
    $operations = [System.Collections.Generic.List[object]]::new()
    foreach ($operation in @($document.SelectNodes('/r:DeploymentReport/r:Operations/r:Operation', $ns))) {
        foreach ($item in @($operation.SelectNodes('r:Item', $ns))) {
            $operations.Add([pscustomobject]@{ Name = $operation.GetAttribute('Name'); Item = $item.GetAttribute('Value'); Type = $item.GetAttribute('Type') })
        }
    }
    [pscustomobject]@{
        Alerts     = $alerts.ToArray()
        Operations = $operations.ToArray()
    }
}

function Get-DeployReportBlocker {
    <#
    .SYNOPSIS
        Emits one message per change that must not be deployed without a human decision.
    .DESCRIPTION
        - a DataIssue alert: SqlPackage expects data loss (a dropped column or table, a narrowed type);
        - a TableRebuild operation: the table is copied into a new one, which locks it, grows the
          transaction log and breaks change data capture on that table.
        The publish profile blocks the first one as well (BlockOnPossibleDataLoss); checking the
        report first gives a readable message before anything is changed.
    #>
    param([Parameter(Mandatory)] [object] $Report)

    foreach ($alert in @($Report.Alerts | Where-Object Name -eq 'DataIssue')) {
        "Possible data loss: $($alert.Issue)"
    }
    foreach ($operation in @($Report.Operations | Where-Object Name -eq 'TableRebuild')) {
        "Table rebuild: $($operation.Item). Split the change so the table is altered in place; see docs/migrations.md."
    }
}

function Format-DeployReport {
    <# A short, readable summary for the pipeline log. #>
    param([Parameter(Mandatory)] [object] $Report)

    if (@($Report.Operations).Count -eq 0) {
        '  No schema changes.'
    }
    foreach ($group in @($Report.Operations | Group-Object Name)) {
        "  $($group.Name):"
        foreach ($operation in $group.Group) {
            "    $($operation.Item) ($($operation.Type))"
        }
    }
    foreach ($alert in @($Report.Alerts)) {
        "  Alert $($alert.Name): $($alert.Issue)"
    }
}
