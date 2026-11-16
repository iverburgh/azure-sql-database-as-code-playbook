# Seed data and environments

Rows that the database needs are code too. They come in three kinds, and mixing them up is how test
customers end up in production and production endpoints end up in a developer database.

| Kind | Example | Same in every environment? | Project |
|---|---|---|---|
| **Reference data** | Order statuses, product categories: rows the code refers to by id or code | Yes | [Shop.Database.ReferenceData](../database/Shop.Database.ReferenceData) |
| **Configuration** | Payment providers and their endpoints, feature switches stored in a table | No — one project per environment | [Shop.Database.SeedConfiguration.&lt;Env&gt;](../database/seed-configuration) |
| **Test data** | Customers, products and orders to click through | Never in production | [Shop.Database.TestData](../database/Shop.Database.TestData) |

Each is a separate project whose dacpac only carries a post-deployment script, so each can be deployed
(or not) on its own. The [deployment](../scripts/Publish-Database.ps1) publishes them after the schema.

## Writing a seed script

Every seed runs on every deployment, on a database in any state. It must be idempotent, and it must
state the *desired* rows rather than *inserting* them:

```sql
MERGE INTO [Sales].[OrderStatus] WITH (HOLDLOCK) AS target
USING (VALUES
    (CAST(1 AS TINYINT), N'Placed',    N'Placed'),
    (CAST(2 AS TINYINT), N'Paid',      N'Paid'),
    (CAST(3 AS TINYINT), N'Shipped',   N'Shipped'),
    (CAST(4 AS TINYINT), N'Cancelled', N'Cancelled')
) AS source ([OrderStatusId], [Code], [Name])
ON target.[OrderStatusId] = source.[OrderStatusId]
WHEN MATCHED AND (target.[Code] <> source.[Code] OR target.[Name] <> source.[Name]) THEN
    UPDATE SET [Code] = source.[Code], [Name] = source.[Name]
WHEN NOT MATCHED BY TARGET THEN
    INSERT ([OrderStatusId], [Code], [Name]) VALUES (source.[OrderStatusId], source.[Code], source.[Name])
WHEN NOT MATCHED BY SOURCE THEN
    DELETE;
```

- **Fixed keys.** Reference rows have explicit ids (no `IDENTITY`), so every environment has the same
  id for `Paid` and the code can use it.
- **Update only what changed** (`WHEN MATCHED AND ...`). An update of an unchanged row still writes to
  the log, fires triggers and shows up in change data capture.
- **Delete or keep unlisted rows — decide per table.** Reference data owned by the code deletes them
  (`WHEN NOT MATCHED BY SOURCE THEN DELETE`), so removing a status from the script removes it everywhere.
  The production configuration [keeps them](../database/seed-configuration/Shop.Database.SeedConfiguration.Production/Scripts/Seed-PaymentProvider.sql):
  removing a payment provider from production is a deliberate migration, not a side effect.
- **Nullable columns** need `ISNULL` or `EXISTS (SELECT target.x EXCEPT SELECT source.x)` in the
  comparison, because `NULL <> 'a'` is not true.
- **One file per table**, included with `:r` from `Script.PostDeployment.sql`, parents before children.

Test data follows the same rules, so a test environment can be redeployed without duplicating customers.
Its tables use `IDENTITY` keys, so the [test data scripts](../database/Shop.Database.TestData/Scripts/TestData-Customers.sql)
insert only rows whose natural key (an e-mail address, a SKU) is not there yet, and never delete: testers
add their own rows too.

A reference row that is still referenced cannot be deleted: the foreign key makes the deployment fail.
That is intended — remove the code that uses it and the data that refers to it first.

## No secrets in seeds

A seed script ends up in the dacpac, the pipeline artifact and the deploy logs. Store endpoints and
switches in it, never keys or passwords. Those belong in a secret store, referenced from the
application's configuration.

## environments.json

[environments.json](../database/environments.json) decides what each environment gets:

```json
"Production": {
  "seedConfiguration": "Production",
  "testData": false,
  "allowDropAll": false,
  "protected": true
}
```

| Setting | Meaning |
|---|---|
| `seedConfiguration` | Which `Shop.Database.SeedConfiguration.<name>` project to deploy. Two environments can share one. |
| `testData` | Deploy `Shop.Database.TestData` after the seeds. |
| `allowDropAll` | `Publish-Database.ps1 -DropAll` is allowed: the database is emptied before the deployment. |
| `protected` | The environment holds real data. Then `testData` and `allowDropAll` must be `false`. |

The [JSON schema](../scripts/schemas/environments.schema.json) enforces the `protected` rule in the editor
and in the tests, and `Get-DeploymentEnvironment` enforces it again at deployment time. A pipeline cannot
pass test data to production by a typo in a parameter: there is no such parameter.

## Adding an environment

1. Add it to `environments.json`.
2. If its configuration differs from the existing ones, copy a `seed-configuration` project, rename it
   to `Shop.Database.SeedConfiguration.<Name>`, and change the values. `build.proj` picks it up.
3. Add a deployment stage that passes `-Environment <Name>`.

## DropAll

[Shop.Database.DropAll](../database/Shop.Database.DropAll/Scripts/Script.PostDeployment.sql) empties a
database: foreign keys, views, procedures, functions, tables, sequences, types and schemas. Users,
roles and permissions stay. It is for a developer or ephemeral database that should start from scratch,
for example to test that a new database deploys from zero.

Three guards keep it out of the wrong place:

1. The environment must have `allowDropAll: true`, which a protected environment cannot have.
2. `Publish-Database.ps1` must be called with `-DropAll`.
3. The script itself refuses to run unless the SQLCMD variable `ConfirmDropAll` equals `DB_NAME()`.
   The deploy script sets it to the database in the connection, so the dacpac cannot be published to
   another database by accident with a stale variable.

It disables change data capture first, because capture instances prevent dropping captured tables.
