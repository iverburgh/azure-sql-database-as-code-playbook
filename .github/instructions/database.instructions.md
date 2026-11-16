---
applyTo: 'database/**, scripts/**, pipelines/**'
---

# Database as code

- The SQL projects under `database/` are the only source of the schema. Never change a database by hand, and never suggest a hand-run `ALTER` as the fix.
- Never edit a file under a `Generated/` folder (`InitMigrations.sql`, `RunMigrations.sql`, `ColumnDescriptions.sql`). Change the source and run the generator: `scripts/New-MigrationScripts.ps1` or `scripts/Update-ColumnDescriptions.ps1`.
- Schema changes are declarative: edit the `CREATE` statement of the object, never write an `ALTER` in the schema project.
- A change the model cannot express (rename, backfill, split, guarded drop) is a migration: a new folder `database/Shop.Database.Migrations/Migrations/NNNN_Description/` with the next free number and one or more `.sql` files.
- Never edit, renumber or delete a migration that is on the main branch. Add a new one.
- Every migration is idempotent: guard it on the state it changes (`IF COL_LENGTH(...)`, `WHERE ... IS NULL`), not on its own id.
- A migration never creates a table, index or other schema object; those belong in the schema project.
- A migration contains no `GO`, `USE`, SQLCMD commands, transaction statements or `sp_cdc_*` calls, and declares variables with a name no other migration uses.
- Wrap a statement that mentions a column which may not exist yet, or no longer, in `sp_executesql`: the whole migration batch is compiled before it runs.
- Rename a column or table with `sp_rename` in a migration in the same change that renames it in the project. Never let SqlPackage turn a rename into a drop and an add.
- A new `NOT NULL` column on an existing table gets a default constraint, or is added nullable, filled by a migration and made `NOT NULL` in a later release.
- A breaking change ships in more than one release (expand, migrate, contract). Never drop a column the running application still reads.
- Seed data is a `MERGE` on a stable key: reference data in `Shop.Database.ReferenceData`, per-environment configuration in `seed-configuration/`, test data in `Shop.Database.TestData`. Never a plain `INSERT`.
- Never put test data or `DropAll` in an environment marked `protected` in `database/environments.json`.
- Every table and column has a description in `database/Shop.Database/ColumnDescriptions.json`. Add descriptions in the same change as the column.
- Never edit `database/cdc/captured-columns.json` or the data classification; their owners change them. Flag a change to a captured column instead.
- Never set `BlockOnPossibleDataLoss`, `DropObjectsNotInSource`, `GenerateSmartDefaults` or `DoNotAlterChangeDataCaptureObjects` differently to make a deployment pass.
- Users, roles and permissions are not in the project; the platform creates them.
- Every external call in `scripts/` goes through `Invoke-AzCli` or `Invoke-SqlPackage`, so the tests can fake it. Every entry script that changes something supports `-WhatIf`.
- Before you finish, run:
  - `dotnet build database/build.proj -c Release`
  - `./scripts/New-MigrationScripts.ps1 -Check`
  - `./scripts/Update-ColumnDescriptions.ps1 -Check -DacpacPath database/Shop.Database/bin/Release/Shop.Database.dacpac`
  - `Invoke-Pester scripts/tests`
