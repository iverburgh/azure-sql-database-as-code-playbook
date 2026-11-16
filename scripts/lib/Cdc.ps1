Set-StrictMode -Version Latest

<#
    Change data capture (CDC) safety check. CDC reads the transaction log with one log scan per
    database. When a captured column changes in a way the capture instance cannot follow, that
    single scan stops for every table, the log cannot be truncated and fills up. This check
    compares the captured columns in the released (baseline) model with the candidate model,
    offline, before anything is deployed. See docs/cdc-and-schema-changes.md.
#>

function Read-CapturedColumn {
    <# Reads captured-columns.json: tables -> 'Schema.Table' -> [column names]. #>
    param([Parameter(Mandatory)] [string] $Path)

    $document = Read-JsonFile -Path $Path
    if ($document -isnot [System.Collections.IDictionary] -or -not $document.Contains('tables') -or $document.tables -isnot [System.Collections.IDictionary]) {
        throw "${Path}: expected an object with a 'tables' object."
    }
    $document
}

function Get-ColumnSize {
    <# A comparable size in characters or digits; [int]::MaxValue for (max). #>
    param([Parameter(Mandatory)] [object] $Column)
    if ($Column.IsMax) { return [int]::MaxValue }
    if ($null -ne $Column.Length) { return [int]$Column.Length }
    if ($null -ne $Column.Precision) { return [int]$Column.Precision }
    $null
}

function Compare-CdcColumn {
    <#
    .SYNOPSIS
        Emits one finding per change to a captured column: Severity (Error or Warning), Table,
        Column and Message.
    .DESCRIPTION
        Error, the deployment must not continue:
          - the data type changes, or the column becomes narrower (including (max) to a fixed size)
            or loses scale: the capture instance fails on the existing log records.
        Warning, the deployment can continue with a planned follow-up:
          - the column becomes wider or changes nullability: the capture instance keeps the old
            definition and must be recreated to capture the new one;
          - a captured column or table is dropped: the capture instance must be recreated first;
          - a column is listed as captured but does not exist in the baseline model.
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $BaselineTables,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $CandidateTables,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $CapturedColumns
    )

    [string[]] $tableNames = @($CapturedColumns.tables.Keys)
    [System.Array]::Sort($tableNames, [System.StringComparer]::Ordinal)
    foreach ($tableName in $tableNames) {
        $baseline = @($BaselineTables | Where-Object { $_.Name -ieq $tableName })
        $candidate = @($CandidateTables | Where-Object { $_.Name -ieq $tableName })
        if ($baseline.Count -eq 0) {
            [pscustomobject]@{ Severity = 'Warning'; Table = $tableName; Column = $null; Message = "$tableName is listed as captured but is not in the baseline model." }
            continue
        }
        if ($candidate.Count -eq 0) {
            [pscustomobject]@{ Severity = 'Warning'; Table = $tableName; Column = $null; Message = "$tableName is captured and dropped by this change. Disable its capture instance first." }
            continue
        }
        foreach ($columnName in @($CapturedColumns.tables[$tableName])) {
            $before = @($baseline[0].Columns | Where-Object { $_.Name -ieq $columnName })
            $after = @($candidate[0].Columns | Where-Object { $_.Name -ieq $columnName })
            $location = "$tableName.$columnName"
            if ($before.Count -eq 0) {
                [pscustomobject]@{ Severity = 'Warning'; Table = $tableName; Column = $columnName; Message = "$location is listed as captured but is not in the baseline model." }
                continue
            }
            if ($after.Count -eq 0) {
                [pscustomobject]@{ Severity = 'Warning'; Table = $tableName; Column = $columnName; Message = "$location is captured and dropped by this change. Recreate the capture instance without it first." }
                continue
            }
            $old = $before[0]
            $new = $after[0]
            $oldType = Format-ColumnType -Column $old
            $newType = Format-ColumnType -Column $new
            if ($old.DataType -ne $new.DataType) {
                [pscustomobject]@{ Severity = 'Error'; Table = $tableName; Column = $columnName; Message = "$location is captured and changes type from $oldType to $newType." }
                continue
            }
            $oldSize = Get-ColumnSize -Column $old
            $newSize = Get-ColumnSize -Column $new
            $oldScale = if ($null -ne $old.Scale) { [int]$old.Scale } else { 0 }
            $newScale = if ($null -ne $new.Scale) { [int]$new.Scale } else { 0 }
            if (($null -ne $oldSize -and $null -ne $newSize -and $newSize -lt $oldSize) -or $newScale -lt $oldScale) {
                [pscustomobject]@{ Severity = 'Error'; Table = $tableName; Column = $columnName; Message = "$location is captured and becomes narrower: $oldType to $newType." }
                continue
            }
            if ($oldType -ne $newType) {
                [pscustomobject]@{ Severity = 'Warning'; Table = $tableName; Column = $columnName; Message = "$location is captured and becomes wider: $oldType to $newType. Recreate the capture instance after the deployment to capture the new size." }
            }
            if ($old.IsNullable -ne $new.IsNullable) {
                $change = if ($new.IsNullable) { 'NULL' } else { 'NOT NULL' }
                [pscustomobject]@{ Severity = 'Warning'; Table = $tableName; Column = $columnName; Message = "$location is captured and becomes $change. Recreate the capture instance after the deployment." }
            }
        }
    }
}
