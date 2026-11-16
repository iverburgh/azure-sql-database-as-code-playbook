# Change data capture and schema changes

Change data capture (CDC) reads the transaction log and copies every change to a captured table into a
change table, from which another system — a data warehouse, a search index, an integration — picks it
up. It is invisible in daily work, and that is exactly what makes it dangerous during a schema change.

## What a capture instance remembers

When a table is enabled for CDC, SQL Server creates a **capture instance**: a change table with a copy of
the captured columns *as they were defined at that moment*. It does not follow later changes to the
source table.

| Change to a captured column | What happens |
|---|---|
| Added column | Not captured until a new capture instance includes it. Harmless. |
| Dropped column | The capture instance keeps returning `NULL` for it. Consumers may break. |
| Wider (`NVARCHAR(100)` → `NVARCHAR(200)`) | **Values longer than the old size cannot be written to the change table.** See below. |
| Narrower, other type, other scale | The change table and the source disagree; consumers get conversion errors or wrong values. |
| Nullability | Rows that the capture instance does not expect. |

The only fix for all of these is a new capture instance with the new definition. A table can have two
capture instances at the same time, which is how the switch is made without a gap: create the new one,
let the consumer move over, then drop the old one.

## The incident to avoid

A captured column was made wider in an ordinary release. The schema deployment succeeded. Then:

1. The first row with a value longer than the old size was committed.
2. The capture tried to write it to the change table and failed with error 2628 (*string or binary data
   would be truncated*).
3. The capture reads the log in one sequential scan. It stopped at that transaction and retried it, again
   and again. Nothing after it was captured either — for every captured table, not just this one.
4. The transaction log cannot be truncated past the oldest transaction that CDC has not read
   (`log_reuse_wait_desc = REPLICATION`). It grew until it was full: error 9002, and every write to the
   database failed.
5. Disabling CDC to get out of it needed log space too, and failed.

Recovery needed headroom first (a bigger log, or a higher service tier, depending on the platform), then
recreating the capture instance with the new size, and only then the change feed could catch up. The
schema change itself had passed every review: nobody had connected "wider column" to "capture stops".

**Lessons:**

- A schema change to a captured column is never a normal change. It is a planned change *with the owner
  of the change feed*, who recreates the capture instance.
- Watch the log and the capture, not just the database: `log_reuse_wait_desc`, used log percentage,
  capture latency and capture errors. An alert at 50 % log use buys hours.
- Know your way out before you need it: who may scale the database, how long that takes, and that
  disabling CDC is not the emergency brake it seems.

## The captured-columns list

[captured-columns.json](../database/cdc/captured-columns.json) lists which columns are captured. Its
`owner` field says who owns it: the team that consumes the change feed. Like a data classification
register, developers do not edit it to make a check pass. The schema project and the migrations never
call `sp_cdc_enable_table` or `sp_cdc_disable_table` (the [migration rules](migrations.md#the-rules)
reject it), and the publish profile sets `DoNotAlterChangeDataCaptureObjects=True`. Enabling CDC and
managing capture instances is an operational task of the owner, not part of a deployment.

## The offline check

[Test-CdcColumnChanges.ps1](../scripts/Test-CdcColumnChanges.ps1) compares the schema dacpac in
production (the baseline) with the schema dacpac of the change, for the listed columns only. It needs no
database, so it can run in a pull request build:

```powershell
./scripts/Test-CdcColumnChanges.ps1 `
    -BaselineDacpac ./baseline/dacpacs/Shop.Database.dacpac `
    -CandidateDacpac database/Shop.Database/bin/Release/Shop.Database.dacpac
```

| Exit code | Finding | Meaning |
|---|---|---|
| 0 | — | No captured column changes. |
| 1 | Warning: wider, nullability changed, dropped, or a listed column that is not in the baseline | Deployable, but the capture instance must be recreated as a planned follow-up. Talk to the owner **before** merging. |
| 2 | Error: other type, narrower size or scale | Do not deploy. |
| 3 | — | The check could not run (a missing file, an unreadable dacpac). Treat as blocked. |

The [schema rehearsal](schema-rehearsal.md) runs the same comparison against the release that is in
production, so it also catches changes that slipped past a pull request.

A wider column is a warning, not an error, because it does not break immediately: the capture only stops
when the first longer value arrives. That gives time to recreate the capture instance — if somebody
knows. The warning is there so somebody does.

## Changing a captured column safely

1. Agree the change and the timing with the owner of the change feed.
2. Release N: deploy the schema change. Keep the application from writing longer values yet (for a wider
   column), or deploy it in a quiet period.
3. The owner creates a second capture instance with the new definition, moves the consumer over, and
   drops the old instance.
4. Release N+1: the application starts to use the new size.

For a type change, add a new column instead, capture both for a while, and drop the old one later
([expand and contract](breaking-changes.md)).

## Monitoring

[monitoring-queries.sql](../database/cdc/monitoring-queries.sql) has four read-only queries:

1. Log use and `log_reuse_wait_desc`.
2. Recent capture scan sessions with their latency.
3. Recent capture errors (look for 2628).
4. Captured columns whose current definition differs from their capture instance.

Turn the first three into alerts (Azure Monitor has the log percentage as a metric; latency and errors
need a scheduled query or a [maintenance job](database-maintenance.md)). Run the fourth after every
release that touched a captured table.

Other operations that keep the log from being truncated while CDC is enabled: a long-running transaction
(a big migration — keep them small), an index rebuild of a captured table (use `RESUMABLE = ON` and
`ONLINE = ON`, and batch it), and a stopped capture on a paused or scaled-down database.
