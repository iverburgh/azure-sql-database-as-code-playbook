# Copilot instructions and skill

An agent that changes a database project makes the same mistakes a new team member makes: it renames a
column in the `CREATE TABLE`, writes an `ALTER` next to it, edits the generated runner, or inserts seed
rows. Two files in this playbook give it the rules up front.

| File | Loaded | Contains |
|---|---|---|
| [.github/instructions/database.instructions.md](../.github/instructions/database.instructions.md) | Automatically, for every file that matches its `applyTo` pattern | The rules, one line each: what to change where, what never to touch, the commands to run before finishing |
| [skill/SKILL.md](../skill/SKILL.md) | On demand, when a request matches the triggers in its `description` | The self-check, the decisions that are settled, the things that fail silently, a table for diagnosing a failed deployment, and the boundaries |

The instructions file is short on purpose: it is added to the context of every request that touches
`database/`, `scripts/` or `pipelines/`. The skill is longer and is only loaded when it is relevant, such
as a question about a failed deployment or a drift report.

## Installing

1. Copy `.github/instructions/database.instructions.md` to the same path in your repository. Change the
   `applyTo` pattern to where your SQL projects, scripts and pipelines live, and replace the
   `Shop.Database` paths.
2. Copy the `skill/` folder to `.github/skills/azure-sql-database-as-code/`. Its links point to
   `../docs/`; bring the documents you want the agent to read, or replace the links.
3. Keep the commands in both files identical to what CI runs. An agent that is told to run a check CI
   does not run, or the other way round, drifts from the pipeline quickly.

## What makes the rules work

- **The checks exist.** "Never edit a generated file" is only enforceable because
  `New-MigrationScripts.ps1 -Check` fails when someone does. Every rule that matters has a check in CI;
  the instructions tell the agent to run it locally first.
- **The rules say what to do instead.** "No `ALTER` in the schema project" alone produces a refusal;
  "rename with `sp_rename` in a migration" produces the right change.
- **Ownership is explicit.** The captured-columns list and the data classification belong to other
  people. The instructions say so, so the agent flags a change instead of making it.
- **Self-check before done.** The skill makes the build, both `-Check` scripts and the tests mandatory
  after every change, so the agent finds its own mistakes instead of the reviewer.
