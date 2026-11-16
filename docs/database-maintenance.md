# Database maintenance

Azure SQL Database takes care of backups, patching and high availability. It does not rebuild your
fragmented indexes, refresh statistics on a table that only grows at the end, or clean up rows that your
application no longer needs. Those are recurring jobs, and they are not part of the dacpac.

## Why not in the dacpac

A dacpac describes a state; maintenance is an action on a schedule. A post-deployment script that
rebuilds indexes runs on every deployment and never in between, holds locks inside the deployment, and
makes the deployment slow and unpredictable. A stored procedure in the schema project is fine — the
*schedule* that runs it is not schema.

## Elastic Jobs

For Azure SQL Database, [Elastic Jobs](https://learn.microsoft.com/azure/azure-sql/database/elastic-jobs-overview)
is the native scheduler: an *elastic job agent* with its own job database runs T-SQL jobs on a schedule
against one or more target databases.

| Choice | Recommendation |
|---|---|
| Authentication | A user-assigned managed identity on the agent, added as a database user in each target with only the rights the job needs. No database credentials. |
| Target | A target group with the database, or the server (all its databases), or an elastic pool. |
| Job content | `EXEC` a stored procedure that lives in the schema project. The job then has one line, and the logic is versioned, reviewed and deployed with the schema. |
| Infrastructure | The agent, its job database and identity in the infrastructure code (Bicep or Terraform). The jobs, steps and schedules as an idempotent T-SQL script against the job database, run by the pipeline (`jobs.sp_add_job` when missing, `jobs.sp_update_job` otherwise). |
| Monitoring | `jobs.job_executions` in the job database: alert on failed executions and on jobs that did not run. |

Alternatives when Elastic Jobs does not fit: an Azure Automation runbook, a timer-triggered function, or a
pipeline on a schedule. They have the same shape: a scheduler outside the database that calls a
procedure inside it.

## Typical jobs

- **Index maintenance**: reorganise or rebuild indexes above a fragmentation threshold, with
  `ONLINE = ON` and `RESUMABLE = ON` so it can be paused and does not block the application. Use a
  well-known maintenance solution instead of writing your own, and keep its settings in source control.
- **Statistics**: update statistics on large tables with ever-increasing keys, where automatic updates
  come too late.
- **Retention**: delete rows past their retention period in small batches (`DELETE TOP (5000) … WHERE …`
  in a loop), so a run never holds a large transaction.
- **CDC health**: run the [monitoring queries](../database/cdc/monitoring-queries.sql) and raise an
  alert when the capture lags or fails.

## Watch the transaction log

Maintenance writes a lot of log: an index rebuild logs the whole index, a large delete logs every row.
With [change data capture](cdc-and-schema-changes.md) enabled, the log cannot be truncated until CDC has
read it all. Run maintenance in a quiet window, in batches, one large table at a time, and keep the
log-use alert in place.
