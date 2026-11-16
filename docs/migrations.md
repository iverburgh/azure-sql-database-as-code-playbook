# Migrations

The schema project declares the end state; SqlPackage works out how to get there. That covers most
changes — a new table, a new nullable column, an index, a wider column — and it is the default. A
migration is for the rest: the changes where *data* has to move and a model comparison cannot know how.

## Declarative or scripted?

| Change | Declarative (edit the table) | Also needs a migration |
|---|---|---|
| New table, view, index, nullable column | ✅ | — |
| New `NOT NULL` column with a default | ✅ | — |
| Column becomes wider | ✅ | — (but see [CDC](cdc-and-schema-changes.md)) |
| Nullable column becomes `NOT NULL` | ✅ | ✅ fill the `NULL` rows first |
| Rename a column or table | ✅ | ✅ `sp_rename`, otherwise SqlPackage drops and adds |
| Split or merge columns, change a type with conversion | ✅ | ✅ copy and convert the data |
| Drop a column or table | ✅ | Only in a later release; see [breaking changes](breaking-changes.md) |
| Fix bad data once | — | ✅ |
| Reference or configuration rows | — | — use [seed data](seed-data-and-environments.md) |

## Adding one

```text
database/Shop.Database.Migrations/Migrations/
  0001_BackfillOrderCurrency/01_Backfill.sql
  0002_RenameCustomerEmail/01_Rename.sql
  0003_YourChange/01_FirstStep.sql
                  02_SecondStep.sql
```

1. Create a folder `NNNN_Description`: the next free four-digit number, an underscore and a description
   in letters and digits. The number is the identity of the migration.
2. Put one or more `.sql` files in it. They run in ordinal file-name order, so prefix them `01_`, `02_`.
3. Run `./scripts/New-MigrationScripts.ps1`. It checks the rules below and regenerates the two runner
   scripts. Commit the folder and the generated files together.

[0001_BackfillOrderCurrency](../database/Shop.Database.Migrations/Migrations/0001_BackfillOrderCurrency/01_Backfill.sql)
and [0002_RenameCustomerEmail](../database/Shop.Database.Migrations/Migrations/0002_RenameCustomerEmail/01_Rename.sql)
are the two shapes you will write most.

## How they run

The migrations dacpac has no schema objects; its post-deployment script
([Script.PostDeployment.sql](../database/Shop.Database.Migrations/Scripts/Script.PostDeployment.sql)) is
the whole thing. It runs in one transaction, **before** the schema dacpac:

- **A new database** (no `dbo.DeploymentHistory`): creates the table and records every migration as
  applied. The schema dacpac will create every table in its final shape, so there is nothing to migrate.
  That is [InitMigrations.sql](../database/Shop.Database.Migrations/Scripts/Generated/InitMigrations.sql).
- **An existing database**: for each migration, in order, runs it when its id is not in
  `dbo.DeploymentHistory` and records it. That is
  [RunMigrations.sql](../database/Shop.Database.Migrations/Scripts/Generated/RunMigrations.sql).

```sql
IF NOT EXISTS (SELECT 1 FROM [dbo].[DeploymentHistory] WHERE [MigrationId] = 1)
BEGIN
    PRINT N'Running migration 0001_BackfillOrderCurrency.';
:r ../../Migrations/0001_BackfillOrderCurrency/01_Backfill.sql
    INSERT INTO [dbo].[DeploymentHistory] ([Type], [Build], [MigrationId], [Name])
    VALUES (N'Migration', N'$(BuildNumber)', 1, N'0001_BackfillOrderCurrency');
END
```

`SET XACT_ABORT ON` and one transaction mean: if any migration fails, none of this release's migrations
is recorded, the schema is not deployed, and the next attempt starts from the same state.

The schema post-deployment script records a `Schema` row with the build number, so
`dbo.DeploymentHistory` tells you which build is deployed and when each migration ran.

## The rules

All migrations end up in one batch inside one transaction. `New-MigrationScripts.ps1` rejects what would
break that:

| Rule | Why |
|---|---|
| No `GO` | It splits the batch, and the `IF … BEGIN … END` around the migration with it. |
| No `BEGIN TRAN`, `COMMIT`, `ROLLBACK`, `SAVE TRAN` | The runner owns the transaction. |
| No `USE` | A migration runs in the database it is deployed to. |
| No SQLCMD commands (`:r`, `:setvar`) | Keep the migration self-contained in its folder. |
| No `sp_cdc_enable_table`/`sp_cdc_disable_table` | Change data capture has its own owner; see [CDC](cdc-and-schema-changes.md). |
| A variable is declared by one migration only | Two `DECLARE @x` in one batch is a compile error. |
| Unique ids, no `0000`, every folder has a `.sql` file | The id is the identity. |

And the ones a script cannot check:

- **Make it idempotent.** Guard every statement (`IF COL_LENGTH(...) IS NOT NULL`, `WHERE ... IS NULL`).
  A migration also runs on a rehearsal copy, on a restored backup that is behind, and on a developer
  database in any state.
- **Use `sp_executesql` for statements that mention a column that may not exist yet.** The whole batch is
  compiled before it runs; a plain `UPDATE` of a column that a later release adds fails to compile on a
  database that does not have it.
- **Never edit a migration that has run anywhere.** Its id is recorded; the change never runs there. Add
  a new migration instead.
- **Never renumber.** Two branches that both add `0003`: the check fails on the duplicate; the second one
  to merge takes `0004`.
- **Keep it small and fast.** It runs inside the deployment transaction, holding locks. A backfill of
  millions of rows belongs in batches outside the deployment, or in a [maintenance job](database-maintenance.md).
- **Do not create schema objects.** A table or index belongs in the schema project, or the next schema
  deployment drops it. Dropping an object the project no longer has is fine — that is how a column is
  removed without tripping the data-loss guard ([breaking changes](breaking-changes.md#dropping-a-column-or-a-table)).

## Why generated, why committed

The runner is a plain function of the folders: sorted ids, one block each. Generating it removes the
copy-paste mistake of a migration that is in the folder but not in the runner (it never runs) or in the
runner twice. Committing the result makes the deployed SQL reviewable in the pull request, and
`-Check` in CI guarantees it matches the folders. Do not edit `Scripts/Generated` by hand: the next
generation overwrites it, and CI fails until then.

## Why the id, and not a hash or a file name

The id is short, stable and sortable, and it survives a rename of the folder description or a whitespace
fix in the script. A hash would re-run a migration after a comment change; a file name would re-run it
after a typo fix.
