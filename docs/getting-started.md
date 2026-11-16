# Getting started

## Requirements

| Tool | Why | Install |
|---|---|---|
| .NET SDK 10 | Builds the SQL projects (`Microsoft.Build.Sql`) | [Install .NET](https://learn.microsoft.com/dotnet/core/install/) |
| PowerShell 7.2+ | Runs the scripts and the tests | [Install PowerShell](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) |
| Pester 5 | The tests | `Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser` |
| SqlPackage | Deploys a dacpac (not needed for build and tests) | `dotnet tool install --global microsoft.sqlpackage` |
| Azure CLI | Only for Azure targets and the rehearsal | [Install the Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) |

## Build and test

```shell
dotnet build database/build.proj --configuration Release
pwsh -c "Invoke-Pester scripts/tests -Output Detailed"
```

The build writes one dacpac per project to `database/<project>/bin/Release/`. The first build downloads
the `Microsoft.Build.Sql` SDK from nuget.org.

Check the generated files the way CI does:

```shell
pwsh ./scripts/New-MigrationScripts.ps1 -Check
pwsh ./scripts/Update-ColumnDescriptions.ps1 -Check -DacpacPath database/Shop.Database/bin/Release/Shop.Database.dacpac
```

## Deploy to a local database

Any SQL Server 2019+ or the SQL Server container works. The projects target Azure SQL Database, so pass
`-AllowIncompatiblePlatform` for a local server.

```shell
docker run -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD='<a strong password>' -p 1433:1433 -d mcr.microsoft.com/mssql/server:2022-latest
```

Plan first — this writes the deploy report and the change scripts to `deploy-reports/` and changes
nothing:

```powershell
./scripts/Publish-Database.ps1 -ArtifactPath database -Environment Development `
    -ConnectionString 'Server=localhost;Initial Catalog=Shop;User ID=sa;Password=<a strong password>;TrustServerCertificate=True' `
    -BuildNumber local -AllowIncompatiblePlatform -WhatIf
```

Then deploy by running the same command without `-WhatIf`. Run it twice: the second run changes nothing,
because every step is idempotent. Look at `dbo.DeploymentHistory` to see what ran.

> When both a Debug and a Release build exist, `-ArtifactPath database` finds two dacpacs per project and
> stops. Build one configuration, or point at a folder with one set of dacpacs.

## Deploy to Azure SQL Database

Sign in with `az login` as an identity that is a user in the database (see
[pipeline and deployment](pipeline-and-deployment.md#identity-and-permissions)), then:

```powershell
./scripts/Publish-Database.ps1 -ArtifactPath database -Environment Test `
    -Server my-sql-test -Database my-shop -BuildNumber local -WhatIf
```

The script asks `az` for an access token for Azure SQL; no password is used.

## Make a change

1. **A new column or table**: edit the `.sql` file in `database/Shop.Database`, build, then run
   `./scripts/Update-ColumnDescriptions.ps1 -DacpacPath database/Shop.Database/bin/Release/Shop.Database.dacpac`.
   It adds the new column to `ColumnDescriptions.json` with a proposal or an empty description — fill it
   in, run it again and build once more.
2. **Data that has to move**: add `database/Shop.Database.Migrations/Migrations/0003_Description/01_Step.sql`
   and run `./scripts/New-MigrationScripts.ps1`. See [migrations](migrations.md).
3. **A rename or a drop**: read [breaking changes](breaking-changes.md) first; it takes more than one
   release.
4. **A reference or configuration row**: edit the `MERGE` in the seed project. See
   [seed data and environments](seed-data-and-environments.md).

Enable the pre-commit hook once per clone to regenerate the files for you:

```shell
git config core.hooksPath .githooks
```
