# Column descriptions and data classification

A table definition says what a column *is*; it does not say what it *means*. Is `ModifiedBy` a user name
or a process id? Is `UnitPrice` with or without tax? A description on every column answers that for the
next developer, for the people who query the data warehouse, and for whoever has to decide which
columns hold personal data.

## Descriptions as code

The descriptions live in one file next to the schema,
[ColumnDescriptions.json](../database/Shop.Database/ColumnDescriptions.json):

```json
"Sales.Order": {
  "description": "An order placed by a customer.",
  "columns": {
    "CurrencyCode": "ISO 4217 code of the currency of all amounts in the order.",
    "OrderedAt": "Moment the customer placed the order."
  }
}
```

[Update-ColumnDescriptions.ps1](../scripts/Update-ColumnDescriptions.ps1) generates
[Generated/ColumnDescriptions.sql](../database/Shop.Database/Generated/ColumnDescriptions.sql) from it:
one `sp_addextendedproperty` per description. The schema project builds that file into the model, so the
descriptions are part of the dacpac and SqlPackage deploys them like any other object — adds, changes
and removes them. In the database they are `MS_Description` extended properties, which SQL tools,
catalog scanners and documentation generators read.

Why JSON and not the `sp_addextendedproperty` statements directly: one line per column is reviewable,
the file can be checked against the model, and it cannot drift from the generated SQL because CI
regenerates and compares.

## Keeping it complete

With `-DacpacPath`, the script reads the tables and columns from the built dacpac (the `model.xml` inside
the zip; no DacFx or database needed) and compares:

| Finding | Meaning | Without `-Check` |
|---|---|---|
| `MissingTable`, `MissingColumn` | In the model, not in the file | Added, with a proposal or an empty description |
| `EmptyDescription` | Added but not written yet | — |
| `ObsoleteTable`, `ObsoleteColumn` | In the file, not in the model | Removed |
| `UnknownExcludedTable` | `excludedTables` lists a table that does not exist | — |

A proposal is only made where it cannot be wrong: a column listed in `standardColumns` (`CreatedAt`,
`ModifiedBy`) gets its standard text, a primary key gets "Unique identifier of the …", a foreign key
"Reference to …". Everything else is left empty, and `-Check` fails until someone writes it. A generated
description such as "The name" is worse than none: it looks finished.

`excludedTables` is for technical tables like `dbo.DeploymentHistory` that nobody outside the team reads.

```powershell
dotnet build database/Shop.Database -c Release
./scripts/Update-ColumnDescriptions.ps1 -DacpacPath database/Shop.Database/bin/Release/Shop.Database.dacpac
# write the empty descriptions, then:
./scripts/Update-ColumnDescriptions.ps1
dotnet build database/Shop.Database -c Release
```

CI and the [pipeline](../pipelines/templates/build-dacpacs.yml) build first and then run
`-Check -DacpacPath`, so a new column without a description fails the pull request.

## Data classification

Descriptions say what a column means. **Classification** says how it must be treated: personal data,
confidential, public; retention; who may see it in an export or a change feed. In most organisations that
is not the developers' call. A governance team (privacy, security, data management) decides, and keeps
the classification of every column in its own register.

Treat that register like the [captured-columns list](cdc-and-schema-changes.md): it is owned by someone
else.

- **Developers never edit the classification.** Not to make a build pass, not to fix an obvious typo.
  Report it to the owner.
- **A new column is a question for the owner.** The description is the input they need; write it with
  that reader in mind ("E-mail address the customer signs in with" tells them it is personal data).
- **A check may compare the two** — every column in the model has a classification — but it should fail
  with "ask the governance team to classify X", never offer to fix it.
- **Do not put the classification in the schema project** unless the owner maintains it there. SQL
  Server's `ADD SENSITIVITY CLASSIFICATION` is a schema object; if the project declares it, a developer
  edits it, and the publish profile's `DropObjectsNotInSource` removes classifications that someone set
  in the portal. When the classification lives elsewhere, set `IgnoreSensitivityClassifications=True`
  in the publish profile so the deployment leaves it alone; the
  [sample profile](../database/publish/Shop.Database.publish.xml) does.

The sample has no register: it is organisation-specific. The descriptions file is the part every team
can adopt.
