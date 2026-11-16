# Applying it to your solution

The sample is one database called `Shop`. This page is the order in which to bring the same setup to
your own database, existing or new.

## 1. Get the schema into a project

**New database:** `dotnet new install Microsoft.Build.Sql.Templates`, then `dotnet new sqlproj`, and
copy the settings from [Directory.Build.props](../database/Directory.Build.props).

**Existing database:** extract it once and split the result into one file per object:

```powershell
sqlpackage /Action:Extract /SourceConnectionString:"<connection to production or a copy>" `
    /TargetFile:./MyApp.Database.dacpac /p:ExtractTarget=SchemaObjectType
```

`ExtractTarget=SchemaObjectType` writes a folder per schema and object type, like the sample. Remove
users, logins, role memberships and permissions from the result: they belong to the platform
(`DoNotDropObjectTypes`). Build with `TreatTSqlWarningsAsErrors` and fix every warning; most are
references to objects in other databases or to removed features.

Then publish the project with `-WhatIf` against a copy of production. The deploy report must be empty
(or only contain the extended properties you are about to add). Anything else is a difference between
the project and the database that must be resolved before the first real deployment.

## 2. Copy the scaffolding

| From the sample | Change |
|---|---|
| `database/Directory.Build.props`, `build.proj`, `global.json`, `nuget.config` | Nothing, or the SDK versions |
| `database/Shop.Database.*` projects | Rename to your prefix. `Publish-Database.ps1` takes `-ProjectPrefix`; the other scripts take a path. Change their defaults, or pass them in the pipeline |
| `database/publish/Shop.Database.publish.xml` | Rename to `<prefix>.publish.xml`. Review every setting with [the table](pipeline-and-deployment.md#the-publish-profile) |
| `database/environments.json` | Your environments; mark the ones with real data `protected` |
| `scripts/` | Nothing, apart from the `-ProjectPrefix` and path defaults |
| `pipelines/` | Service connections, servers, databases, Azure DevOps environments |

## 3. Start the migrations with an empty list

Keep `Shop.Database.Migrations` with no migration folders and generate the runner. On the first
deployment the post-deployment script finds no `dbo.DeploymentHistory`, creates it and records nothing
(there is nothing to record). From then on every migration runs exactly once.

Add `dbo.DeploymentHistory` to the schema project, as the sample does, so the schema deployment does not
drop it.

If you already have a tracking table from another tool, either keep that tool for the old migrations
and start the new table with a fresh numbering, or write a one-time migration that copies its history.

## 4. Split the seed data

Go through every `INSERT` in your existing post-deployment scripts and decide: reference data (same
everywhere), configuration (per environment), or test data. Rewrite each as a `MERGE` on a stable key.
Delete-unlisted for reference data owned by the code; keep-unlisted for production configuration.

## 5. Describe the columns

```powershell
dotnet build database/MyApp.Database -c Release
./scripts/Update-ColumnDescriptions.ps1 -DescriptionsPath database/MyApp.Database/ColumnDescriptions.json `
    -DacpacPath database/MyApp.Database/bin/Release/MyApp.Database.dacpac
```

Start from an empty file with `{ "standardColumns": {}, "excludedTables": [], "tables": {} }`. The
script adds every table and column, proposes descriptions for keys and standard columns, and leaves the
rest empty. With `-Check`, empty descriptions fail the build, so either fill them all in before you
add the check to CI, or fill them in over a few pull requests and turn the check on when the last one
is merged.

If the database already has `MS_Description` properties, they appear as removals in the deploy report:
copy their text into the JSON file first.

## 6. Change data capture

If CDC is enabled, list every captured column in `database/cdc/captured-columns.json` (query
`cdc.captured_columns`), agree with its owner that they own that file, and add the
[monitoring](cdc-and-schema-changes.md#monitoring) before the first deployment.

## 7. Pipeline

1. Run the build stage on pull requests.
2. Deploy to test.
3. Deploy to production the first time with `checkDrift: false` and no rehearsal; the run is tagged
   `production`.
4. Turn on the drift check and the [rehearsal](schema-rehearsal.md) for the next release.

Create the identities and database users from [identity and permissions](pipeline-and-deployment.md#identity-and-permissions)
in your infrastructure code.

## 8. Tell people, and the agents

Add [the instructions file](../.github/instructions/database.instructions.md) to your repository, and
the [skill](../skill/SKILL.md) if you use one. See [Copilot instructions](copilot-instructions.md).
Agree in the team that nobody changes a database by hand any more — the drift check will tell.
