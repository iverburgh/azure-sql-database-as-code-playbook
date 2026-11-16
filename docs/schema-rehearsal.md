# Schema rehearsal

The test environment proves that a release deploys on test data. Production has other data: more rows,
older rows, rows nobody thought of. A `NOT NULL` that holds on test fails on a production row from
years ago; a backfill that takes a second on test takes an hour on production; a column that is empty on
test has values on production, and the deploy report says "data loss".

A schema rehearsal deploys the release to a disposable copy of the production database, before the
production stage starts, and reports what happened.

```mermaid
sequenceDiagram
    participant P as Pipeline
    participant S as Production server
    P->>S: New-RehearsalDatabase.ps1: copy my-shop to my-shop-rehearsal-1234 (tagged)
    P->>S: Invoke-SchemaRehearsal.ps1: CDC check, migrations, deploy report, schema
    P->>S: Remove-RehearsalDatabase.ps1: drop my-shop-rehearsal-1234 (always)
    P->>P: Publish the reports; Production waits for the result
```

## The three scripts

| Script | Does |
|---|---|
| [New-RehearsalDatabase.ps1](../scripts/New-RehearsalDatabase.ps1) | Creates `<database>-rehearsal-<build id>` on the same server, tagged `purpose=schema-rehearsal`, and sets the pipeline variable `RehearsalDatabase`. A leftover with the same name and the tag (a re-run of the same build) is removed first. |
| [Invoke-SchemaRehearsal.ps1](../scripts/Invoke-SchemaRehearsal.ps1) | Compares the captured CDC columns of the baseline and the candidate, publishes the candidate migrations, writes the schema deploy report and, when nothing blocks, publishes the schema. |
| [Remove-RehearsalDatabase.ps1](../scripts/Remove-RehearsalDatabase.ps1) | Drops the rehearsal database. Runs with `condition: always()`. |

The logic is in [Rehearsal.ps1](../scripts/lib/Rehearsal.ps1); all Azure calls go through
`Invoke-AzCli` (`az sql db copy`, `az sql db create`, `az sql db delete`) and are tested with a fake.

Only the migrations and the schema are rehearsed: they are the steps that can lose data or fail on real
data. Seeds are idempotent `MERGE` statements and are covered by the test environment.

## Copy or Empty

| Mode | Creates | Then | Use when |
|---|---|---|---|
| `Copy` (default) | A copy of production (`az sql db copy`) | Deploys the candidate | You can: it is the only mode that tests real data and real volumes. |
| `Empty` | An empty database | Deploys the baseline release, then the candidate | Production data may not be copied, even within the same server, or the database is too large to copy in time. It still tests the upgrade path from the released schema, but not the data. |

The baseline is the artifact of the last pipeline run tagged `production` (see
[drift](pipeline-and-deployment.md#drift)).

## Exit codes

| Code | Result | In the pipeline |
|---|---|---|
| 0 | Passed | Succeeded |
| 1 | Passed with warnings: a CDC warning, a deploy report alert other than data loss | **SucceededWithIssues**: in Azure Pipelines (`TF_BUILD` is set) the script writes `##vso[task.complete result=SucceededWithIssues;]` and exits 0. The production stage still runs; the approver reads the report. |
| 2 | Blocked: possible data loss, a table rebuild, a CDC error, a migration or schema deployment that failed | Failed: the production stage does not run. |
| 3 | Could not run: no baseline, a name that is not a rehearsal name, a missing dacpac | Failed. Fail closed: a rehearsal that did not run is not a rehearsal that passed. |

## Safety guards

The rehearsal runs with an identity that can create and delete databases on the production server, so
every destructive step checks twice that it is touching a rehearsal copy:

- **The name.** All three scripts require a name ending in `-rehearsal-<digits>`; PowerShell validates
  the parameter before any code runs. `Invoke-SchemaRehearsal.ps1` checks the database name in the
  connection again.
- **The tag.** `Remove-RehearsalDatabase.ps1` and the leftover cleanup only delete a database tagged
  `purpose=schema-rehearsal`. A database with a rehearsal-like name but no tag is left alone and the
  script fails.
- **The source is never written.** The production database is only read (by the copy). Nothing in the
  rehearsal connects to it.
- **Always removed.** The remove step runs after a failure or a cancellation too. A copy that survives
  anyway (an agent that died) carries `build` and `source` tags, so a cleanup job can find it.
- **Conflicts are retried.** Azure rejects a second operation on a database while one is running (a copy
  that is still finishing, a delete after a timeout). `Invoke-WithConflictRetry` waits and retries those,
  and only those.

## Cost, time and security

- The copy is created with service objective `S3` and locally redundant backup storage. Choose a tier
  that deploys in reasonable time; a copy of a Hyperscale or Business Critical database can be cheaper on
  a lower tier for the hour it lives. The job has a timeout of 180 minutes.
- A copy of a large database takes time — usually minutes to tens of minutes, depending on size and
  activity. Run the rehearsal in parallel with the test deployment, as the sample does.
- **The copy is production data.** It stays on the production server, in the same network and firewall
  rules, with the same auditing, the same users and the same encryption. It is not copied to another
  subscription, not exported, and not kept. The rehearsal reports contain object names and messages,
  not data.
- Elastic pools: a copy on the same server can be put in a pool or not (`az sql db copy --elastic-pool`).
  Make sure it does not starve production of resources.

## When the rehearsal blocks

Read the published `rehearsal-reports` artifact. Then:

| Finding | Usually means |
|---|---|
| `DataIssue` alert | A drop or a narrower column on a table with rows. Use [expand and contract](breaking-changes.md). |
| `TableRebuild` | A change that `ALTER TABLE` cannot do. Plan it by hand. |
| Migration failed | Production has data the migration did not expect. Fix the migration (it has not run anywhere yet if it is new) or add one before it. |
| Schema deployment failed | Usually a constraint that production data violates (`NOT NULL`, a foreign key, a unique index). Clean the data in a migration first. |
| CDC error | A captured column changes type or size; see [CDC](cdc-and-schema-changes.md). |
| Could not run | Read the message: often no run is tagged `production` yet (the first release), or a permission. |

The deploy job and the rehearsal use the same scripts and the same profile, so what passes the rehearsal
deploys the same way to production — barring changes to production in between, which the drift check
catches.
