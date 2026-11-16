# Pitfalls

Things that go wrong with SQL projects and dacpac deployments, roughly in the order teams run into them.
Most of them are caught by a check in this playbook; the check is named.

## Renaming in the project drops the data

Rename `Email` to `EmailAddress` in `Customer.sql` and SqlPackage sees one column dropped and one added.
`BlockOnPossibleDataLoss` stops it — good — but the fix is not to turn the block off. Rename with
`sp_rename` in a [migration](migrations.md), which runs before the schema, so SqlPackage sees no
difference at all.

Visual Studio and the SQL projects extension can instead record a rename in a `.refactorlog` file, which
SqlPackage replays once and tracks in a `dbo.__RefactorLog` table. That works too, but then renames live
in two places with two tracking tables. Pick one; this playbook uses migrations because they also cover
the data moves a refactor log cannot.

## A new `NOT NULL` column fails on a table with rows

`GenerateSmartDefaults=False`, so `ADD [Column] INT NOT NULL` without a default fails on a table that has
rows. Either give it a default constraint in the project, or add it as `NULL`, fill it in a migration in
the next release, and make it `NOT NULL` then ([breaking changes](breaking-changes.md)).

## Editing a migration that already ran

Its id is recorded in `dbo.DeploymentHistory`; the edited version never runs where the original did, and
does run on a fresh database. Environments silently diverge. Never edit; add a new migration.

## `GO` or a transaction in a migration

All migrations run in one batch, in one transaction. `GO` splits the batch in the middle of an
`IF … BEGIN … END`, and a `COMMIT` ends the runner's transaction. `New-MigrationScripts.ps1 -Check`
rejects both.

## A migration that does not compile on an older database

The whole migration batch is compiled before any of it runs. A migration that updates a column added in
a later release fails to compile on a database that is a few releases behind — a restored backup, a
rarely used environment. Wrap statements that mention columns that may not exist in `sp_executesql`.

## A migration that is fine on test and runs for an hour on production

It runs inside the deployment transaction, holding locks, and with CDC enabled the log cannot be
truncated until it is done. Batch large data moves outside the deployment. The
[schema rehearsal](schema-rehearsal.md) on a copy of production shows the real duration.

## Hand-editing a generated file

`RunMigrations.sql`, `InitMigrations.sql` and `ColumnDescriptions.sql` are regenerated from their source.
A hand edit is overwritten the next time, and until then `-Check` fails in CI. Change the source and
regenerate. The check normalises line endings, so a Windows checkout with CRLF does not fail it.

## Seeds that insert instead of merge

An `INSERT` in a post-deployment script runs on every deployment: duplicates, or a primary-key violation
on the second deployment. Every seed is a `MERGE` (or an `INSERT … WHERE NOT EXISTS`) on a stable key.
See [seed data](seed-data-and-environments.md).

## Publishing a script-only dacpac with the schema profile

The migrations and seed dacpacs have no schema objects. Published with `DropObjectsNotInSource=True`,
SqlPackage would drop every table, because none of them is in that dacpac's model.
[Deployment.ps1](../scripts/lib/Deployment.ps1) publishes them without the profile and forces
`DropObjectsNotInSource=False`.

## Users and permissions disappear after a deployment

A database user created by the platform for a managed identity is not in the project, and with
`DropObjectsNotInSource=True` SqlPackage drops it. The profile's `DoNotDropObjectTypes` excludes users,
roles, role memberships and permissions. If your project *does* declare security objects, it must
declare all of them.

## Changing a captured column

A wider column on a table with change data capture deploys fine and stops the capture at the first long
value; the transaction log then grows until the database stops accepting writes.
`Test-CdcColumnChanges.ps1` warns; the owner of the change feed must recreate the capture instance. See
[CDC and schema changes](cdc-and-schema-changes.md).

## The plan is not the deployment

`Publish-Database.ps1 -WhatIf` writes the schema deploy report against the database *as it is*. Pending
migrations have not run yet, so a column that a migration renames shows up as a drop and an add in the
plan. The real deployment writes the report again after the migrations, and that is the one that blocks.
Read the plan with this in mind.

## The first production deployment with `checkDrift: true`

The drift check and the rehearsal need the artifact of a run tagged `production`. Before the first
production deployment there is none, the download fails, and a rehearsal without a baseline exits with
code 3. Run the first release with `checkDrift: false` and without the rehearsal stage, and let the
`TagRelease` job create the first baseline.

## Debug and Release dacpacs side by side

After a local `dotnet build` (Debug) and a `-c Release`, every project has two dacpacs.
`Publish-Database.ps1 -ArtifactPath ./database` refuses to guess and fails with "more than one". Delete
`bin/Debug`, or point `-ArtifactPath` at one configuration.

## A local SQL Server says the platform is incompatible

The projects target Azure SQL Database (`SqlAzureV12DatabaseSchemaProvider`). Deploying to SQL Server in
a container needs `-AllowIncompatiblePlatform`. Keep the target on Azure SQL so the build rejects
features Azure SQL does not have.

## SQLCMD variables and their defaults

The scripts use `$(BuildNumber)`, and DropAll uses `$(ConfirmDropAll)`. `BuildNumber` has the default
`local` in [Directory.Build.props](../database/Directory.Build.props), so a hand-run SqlPackage still
works but records `local` in `dbo.DeploymentHistory`. `ConfirmDropAll` has no default on purpose:
without it SqlPackage stops with *Missing values for the following SqlCmd variables*, and with a wrong
value the script refuses. The deploy script passes both; when you call SqlPackage yourself, pass
`/v:BuildNumber=…`.

## Database options in the project are ignored

`ScriptDatabaseOptions=False`: collation, compatibility level, read-committed snapshot and the like in
the project settings are not deployed. Set them in the infrastructure code, which owns the database.
