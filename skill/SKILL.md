---
name: azure-sql-database-as-code
description: Change, review and deploy an Azure SQL database that is defined as code in SQL projects (dacpac). Use when changing a table, column, view or procedure in a .sqlproj, writing a data migration, renaming or dropping a column, adding seed or reference data, adding column descriptions, reviewing a deploy report, investigating a failed dacpac deployment, a schema drift report or a schema rehearsal, or changing a captured (change data capture) column. Triggers on 'sqlproj', 'dacpac', 'sqlpackage', 'Microsoft.Build.Sql', 'migration', 'post-deployment script', 'pre-deployment script', 'RunMigrations.sql', 'InitMigrations.sql', 'DeploymentHistory', 'seed data', 'reference data', 'MERGE', 'ColumnDescriptions.json', 'MS_Description', 'extended property', 'BlockOnPossibleDataLoss', 'possible data loss', 'deploy report', 'drift', 'schema rehearsal', 'rehearsal database', 'change data capture', 'CDC', 'captured column', 'sp_rename', 'expand and contract', 'breaking database change'.
---

# Azure SQL database as code

Operational knowledge for databases defined in SQL projects and deployed as dacpacs with SqlPackage.
Treat everything here as settled and do not re-derive it. The reasoning lives in
[../docs/](../docs/how-it-works.md); the most common mistakes are in
[../docs/pitfalls.md](../docs/pitfalls.md).

## Mandatory self-check

After **every** change under `database/` or `scripts/`, run these without being asked. The change is
not finished until all of them are clean.

```powershell
dotnet build database/build.proj -c Release
./scripts/New-MigrationScripts.ps1 -Check
./scripts/Update-ColumnDescriptions.ps1 -Check -DacpacPath database/Shop.Database/bin/Release/Shop.Database.dacpac
Invoke-Pester scripts/tests
```

When `-Check` fails, run the same script without `-Check`, review the regenerated files and fill in
any empty description. Never edit a generated file to make the check pass.

When the change touches a column that has change data capture, also run:

```powershell
./scripts/Test-CdcColumnChanges.ps1 -BaselineDacpac <dacpac of the release in production> `
    -CandidateDacpac database/Shop.Database/bin/Release/Shop.Database.dacpac
```

Exit code 0 is clean, 1 warnings, 2 errors, 3 could not run.

### Show the plan, do not assert it

For a change whose effect on an existing database matters (a rename, a type change, a drop), produce
a deploy report against a database at the previous release and read it:

```powershell
./scripts/Publish-Database.ps1 -ArtifactPath ./database -Environment Development `
    -ConnectionString '<local or test>' -WhatIf
```

The report under `-WhatIf` is taken *before* the pending migrations run, so a rename that a migration
performs still shows up as a drop and an add. The real deployment reports again after the migrations.

## Decisions that are settled

| Question | Answer |
|---|---|
| Where the schema lives | `CREATE` statements in `database/Shop.Database`, one object per file. Never an `ALTER` in the schema project |
| A change the model cannot express | A migration: `database/Shop.Database.Migrations/Migrations/NNNN_Description/*.sql`, the next free number |
| Migration tracking | By id in `dbo.DeploymentHistory`; each migration runs once. Never by file name or hash |
| Migration order | Before the schema deployment. A migration sees the schema of the previous release |
| Rename | `sp_rename` in a migration, in the same change as the rename in the project. No `.refactorlog` |
| New `NOT NULL` column | A default constraint, or nullable → backfill migration → `NOT NULL` in a later release |
| Drop a column or table | Only after the application no longer uses it (expand, migrate, contract), with a guarded drop migration in the release that removes it from the project |
| Seed data | `MERGE` on a stable key. Reference data for all environments, configuration per environment, test data only where allowed |
| Column descriptions | `ColumnDescriptions.json` → generated `sp_addextendedproperty` statements in the model |
| Data loss | `BlockOnPossibleDataLoss=True`, `AllowTableRecreation=False`. A data-loss alert or a table rebuild blocks the deployment |
| Objects not in the project | Dropped, except users, roles, permissions and other security objects |
| Database options | Infrastructure code, not the project (`ScriptDatabaseOptions=False`) |
| Change data capture | Managed by its owner. The deployment never alters capture objects; migrations never call `sp_cdc_*` |
| Data classification | Owned by a governance team. `IgnoreSensitivityClassifications=True`; never edited from here |
| Production deployment | Drift check against the last run tagged `production`, then a rehearsal on a copy, then deploy |

## Things that fail silently

These produce no error, so check them deliberately.

- **A rename in the project without `sp_rename` is a drop and an add.** On an empty test table it
  deploys; on production it blocks, or with the block off, loses the column.
- **An edited migration that already ran never runs again** where it ran, but does on a fresh
  database. Environments diverge without any error.
- **A migration that is not idempotent** works on the database it was written against and fails, or
  does the work twice, on a developer database in another state or a restored backup that is behind.
- **A table or index created in a migration** is dropped again by the next schema deployment, because
  it is not in the project.
- **The migration batch is compiled as a whole.** A statement on a column that does not exist yet (or
  any more) fails the compilation on an older database, not on yours. Use `sp_executesql`.
- **A plain `INSERT` seed** succeeds on the first deployment and duplicates or fails on the second.
- **A script-only dacpac published with the schema profile** drops every table, because
  `DropObjectsNotInSource` sees none of them in that dacpac. The deploy script never does this; a
  hand-run SqlPackage can.
- **A wider captured column deploys fine** and stops change data capture at the first long value; the
  transaction log then grows until writes fail. Only `Test-CdcColumnChanges.ps1` says so in advance.
- **A hand-run SqlPackage without `/v:BuildNumber=`** records `local` in `dbo.DeploymentHistory`.
- **Database options in the project are not deployed.**
- **Debug and Release dacpacs next to each other** make `Publish-Database.ps1 -ArtifactPath ./database`
  fail with "more than one". Delete `bin/Debug`.
- **The first production run with the drift check or the rehearsal on** fails: no run is tagged
  `production` yet.

## Diagnosing a failed deployment

| Symptom | Look at |
|---|---|
| `The schema update is terminating because data loss might occur` | A column or table dropped, or a column narrowed. A rename without `sp_rename`, or a contract step without its drop migration |
| Deploy report has a `TableRebuild` operation, deployment blocked | A change SqlPackage can only make by copying the table. Make it in steps, or as a migration |
| `Cannot insert the value NULL` while adding a column | A `NOT NULL` column without a default on a table with rows |
| `Missing values for the following SqlCmd variables` | Pass `/v:BuildNumber=…` (and `/v:ConfirmDropAll=…` for DropAll) |
| `A project which specifies SQL Server ... platform` / incompatible platform | Deploying to SQL Server instead of Azure SQL: `-AllowIncompatiblePlatform` |
| Migration error `Invalid column name` on one environment only | A migration that refers to a column added or removed in another release; wrap it in `sp_executesql` |
| Users or permissions gone after a deployment | Security objects declared in the project, or `DoNotDropObjectTypes` changed |
| Drift report not empty | Someone changed the database by hand. Find out what and why before deploying; the fix goes into the project |
| Rehearsal exit code 3 | No baseline (no run tagged `production`), a missing dacpac or a non-rehearsal database name |
| Rehearsal blocked, test deployment fine | Production data the test data does not have. Read the rehearsal deploy report |
| Transaction log usage climbing, `log_reuse_wait_desc = REPLICATION` | Change data capture stopped or lagging. See [../docs/cdc-and-schema-changes.md](../docs/cdc-and-schema-changes.md) |

## Boundaries

- **Never change a database by hand**, and never suggest it as a fix. The fix goes into the project.
- **Never edit `Generated/` files, `database/cdc/captured-columns.json` or the data classification.**
  The first are generated; the others have an owner outside the team.
- **Never turn off a safety setting** (`BlockOnPossibleDataLoss`, `AllowTableRecreation`,
  `GenerateSmartDefaults`, `DropObjectsNotInSource`, `DoNotDropObjectTypes`) to make a deployment pass.
- **Never put test data or DropAll in a protected environment.** `environments.json` rejects it; do not
  remove the guard.
- **Never point a rehearsal script at a database that is not a rehearsal copy.** The name and tag
  guards exist for that; do not work around them.
- **No secrets in seed scripts.** Configuration seeds hold settings, not passwords or keys.

## Installing this skill

Copy this folder into the location your agent tooling expects — for GitHub Copilot that is
`.github/skills/azure-sql-database-as-code/`. The relative links assume the `docs/` folder of this
playbook sits alongside it; if you copy the skill on its own, either bring `docs/` with it or
replace the links with your own. Replace the `Shop.Database` paths with your own project names.
