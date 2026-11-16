Set-StrictMode -Version Latest

<#
    Small file helpers shared by the generators. Generated files are always written as UTF-8
    without a byte order mark, with LF line endings and one trailing newline, so the output is
    identical on Windows and Linux. Comparisons ignore CRLF versus LF, because Git may convert
    line endings on checkout.
#>

function ConvertTo-NormalizedText {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $normalized = $Text -replace "`r`n", "`n"
    $normalized.TrimEnd("`n") + "`n"
}

function Test-GeneratedFileCurrent {
    <# True when the file exists and has the expected content, ignoring line endings. #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $actual = ConvertTo-NormalizedText -Text ([System.IO.File]::ReadAllText($Path))
    $actual -ceq (ConvertTo-NormalizedText -Text $Content)
}

function Write-GeneratedFile {
    <# Writes the file only when its content changes, so timestamps and incremental builds stay quiet. #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content
    )
    if (Test-GeneratedFileCurrent -Path $Path -Content $Content) {
        return $false
    }
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, (ConvertTo-NormalizedText -Text $Content), [System.Text.UTF8Encoding]::new($false))
    $true
}

function Read-JsonFile {
    <# Reads a JSON file into ordered hashtables, so a missing key can be tested with ContainsKey. #>
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File not found: $Path"
    }
    try {
        Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 64
    }
    catch {
        throw "Invalid JSON in ${Path}: $($_.Exception.Message)"
    }
}

function Get-RepositoryRoot {
    Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
