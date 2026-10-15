<!-- PR description for databricks-agent-skills branch lfc-query-based-lakebase-demo (copy of the text pasted into the PR). -->

## Summary

Extends the `databricks-lakeflow-connect` skill so an agent can build, run, monitor, and clean up Lakeflow Connect database pipelines end to end, and asks before creating anything. Covers query-based ingestion (via a UC connection or a foreign catalog), integrated CDC (now the default), and standard gateway CDC. Postgres, MySQL, and SQL Server are covered, with Lakebase as a Postgres demo source.

Every behavior here was exercised in real workspaces (one AWS, one Azure serverless) with headless Claude Code sessions. Where the product behaved differently from the docs, the skill follows what the product did.

### New references

- **`3-query-based-connectors.md`: query-based ingestion (QBC).**
  - Source discovery through the UC connection with `remote_query` (Postgres, MySQL, SQL Server), and how `source_catalog` / `source_schema` map for each source.
  - A tested table of source shape (primary key, unique key, no key, duplicate rows, declared key that isn't unique, timestamp / numeric / no / NULL / insert-only cursor) against `SCD_TYPE_1`, `SCD_TYPE_2`, and `APPEND_ONLY`.
  - **Pre-flight checks** before creating a pipeline. The product doesn't check whether a declared key is unique, whether the cursor is indexed, or whether it has NULLs. The agent checks these from the schema it already introspected, reports what it finds, and lets the user skip them (for a snapshot or a test).
  - Cursor rules, soft and hard deletes, and gotchas (for example uuid primary keys on Postgres < 18), plus the Postgres → Delta type changes worth calling out in a demo.
- **`6-lakebase-as-postgres-source.md`: end-to-end QBC demo with Lakebase as the Postgres source.**
  - One input-gathering step and a single confirm.
  - Per-demo schema, role, and connection names, plus a per-user target schema, so several demos can share one Lakebase project and catalog.
  - The connector password is generated inside Postgres and never appears in commands or the transcript. `conn.json` is excluded from bundle sync.
  - Bundle names are unique per pipeline, so a deploy can't replace another demo's pipelines.
  - Teardown that works on Lakebase (`REVOKE CONNECT` before `DROP ROLE`).
  - CDC on Lakebase is attempted by creating the publication. If Lakebase refuses ("CREATE PUBLICATION is not enabled on this Lakebase instance"), the skill falls back to QBC.
- **`7-source-sql-through-connection.md`: source-side SQL using only the UC connection, no secrets.**
  - One-shot introspection of a whole database: all columns in one query, all keys and indexes in another, never table by table.
  - Foreign catalogs: reuse an existing one on the connection. Otherwise offer to create `<firstname><lastname>-<connection>` when the user has `CREATE_CATALOG`. A foreign catalog's `information_schema` gives columns and keys without `remote_query`.
  - Test DML generation from the metadata, run by the user (or by the agent on Lakebase).
  - Postgres replication-slot create / drop via a small notebook run with `jobs submit`. Cleanup is by exact name only; it refuses to drop an active slot, and slot creation needs `REPLICATION`.

### Updated references

- **`2-database-connectors.md`**
  - **Integrated CDC is the default** for CDC requests. Standard (gateway) CDC is used when the user asks for it or the source has no integrated CDC (Postgres).
  - Release stage, compute (classic / serverless), and runtime channel change between releases. The skill checks the current docs, and the workspace's errors take precedence.
  - **Smart closure:** integrated CDC updates run until they catch up or hit a maximum runtime, so the agent starts them without waiting and reports the update ID. Includes the event types to watch.
  - **Postgres CDC:** one publication and one slot per pipeline, named after the pipeline. No `SET ROLE` (fails on PG 16+ for non-superuser admins). Create the slot after the pipelines deploy, and stop the auto-started gateway until it exists.
  - **Workspace feature gates:** the per-source 403 ("Ingestion source '...' is not supported in your workspace"), serverless-only workspaces, and cleaning up schemas a rejected deploy leaves behind.
- **`5-troubleshooting-and-monitoring.md`**
  - A **rows-per-table-per-run report** with snapshot inserts, upserts, appends, deletes, and run type for every pipeline type. It handles query-based upsert / append / no-cursor full load, hard-delete flows, integrated CDC, and standard CDC.
  - A per-key change count for query-based SCD2 tables, whose event-log counts aren't change counts.
- **`SKILL.md`**
  - Ask before creating anything, gathering every missing input in one message.
  - A bare "Lakeflow Connect demo" request means Lakebase + QBC.
  - Default pipeline names `<firstname><lastname>-<connection>`, with `-2` / `-3` when taken and `-gw` / `-ap` for standard CDC. Bundle names follow the pipeline name.
  - **CDC pipelines can't use a Default Storage catalog** ("Default Storage for Unity Catalog is not supported on LakeFlow Connect pipelines"; QBC can). Includes how to detect one before building.
  - Prerequisites, billing, and key-concept text updated for integrated CDC, which has no separate gateway.

### Product behavior found in testing that differs from the docs

These are written into the skill so agents don't rely on the doc statements:

| Doc statement | What the product did |
|---|---|
| A table with no key gets a synthetic key from all columns | SCD1 / SCD2 without `primary_keys` failed at runtime with `CANNOT_INGEST_TABLE_WITHOUT_PRIMARY_KEY` |
| No key and no cursor needs `APPEND_ONLY` | `APPEND_ONLY` without a cursor was rejected at create. SCD1 with no key and no cursor worked (a full replace each run). |
| The connection field is `cursor_column` | The API drops it as an unknown field (the CLI only warns), creating the pipeline **without a cursor** |
| Rows with a NULL cursor are not ingested | The initial snapshot loads them; later NULL-cursor rows are skipped |
| (not documented) | A declared key with duplicates or NULLs is accepted and silently loses rows (102 → 86), with no warning |

### Other

- **`CLAUDE.md`:** a sandbox file-bridge section, and a pointer to the end-to-end tests, which live in a separate repo ([rsleedbx/databricks-agent-skills-tests](https://github.com/rsleedbx/databricks-agent-skills-tests)) to keep test scripts, fixtures, and results out of this repo. Happy to drop or move the pointer if maintainers prefer.
- Plugin bundles and `manifest.json` regenerated with `python3 scripts/skills.py`.

## Testing

Run with headless Claude Code sessions (a plain request, then the go-ahead) against two workspaces: **AWS** and **Azure serverless**. The test definitions, fixtures, and results are in the tests repo (`MATRIX.md`).

**Legend:** ✅ works · 🛑 expected stop (unsupported, the skill explains why and leaves nothing behind) · ⛔ blocked by the test environment · — not run

### 1. Source × ingestion mode

| Source | QBC via connection | QBC via foreign catalog | Integrated CDC | Standard CDC (gateway) |
|---|---|---|---|---|
| **Lakebase** (Postgres) | ✅ AWS · ✅ Azure: snapshot + incremental match the source | — AWS · ✅ Azure: created the foreign catalog `<firstname><lastname>-<connection>` | 🛑 AWS · 🛑 Azure: no integrated CDC for Postgres | 🛑 AWS · 🛑 Azure: Lakebase refuses `CREATE PUBLICATION` |
| **Postgres** | ✅ AWS · ✅ Azure | — AWS · ✅ Azure: reused the existing catalog | 🛑 AWS · 🛑 Azure: no integrated CDC for Postgres | 🛑 AWS · 🛑 Azure: workspace 403; no slot or publication created |
| **MySQL** | ✅ AWS · ✅ Azure | — AWS · ✅ Azure: reused | ✅ AWS (snapshot; stopped at 30 min, idle source) · ⛔ Azure | 🛑 AWS · 🛑 Azure: workspace 403 |
| **SQL Server** | ✅ AWS · ✅ Azure | — AWS · ✅ Azure: reused | ✅ AWS (completed on its own, about 21 min) · ⛔ Azure | ✅ AWS (`-gw` / `-ap`) · ⛔ Azure |

⛔ Azure: the test's target catalog was on Default Storage, which CDC pipelines reject. Each blocked cell stopped cleanly, and the skill now checks for this before building CDC.

In every cell the skill asked before creating anything. In every cell that ran, snapshot counts matched the source. For a CDC table without a primary key, they matched the number of distinct rows.

### 2. Source shape × target type (query-based, Lakebase fixture)

Eleven tables, one per shape, two runs with inserts, updates, and deletes in between. Run directly against the product (no agent), to record what it does:

| Source shape | `SCD_TYPE_1` | `SCD_TYPE_2` | `APPEND_ONLY` |
|---|---|---|---|
| Primary key + timestamp cursor | ✅ inserts, updates, soft deletes | ✅ version per change; soft delete closes it | ✅ every change appended |
| Primary key + numeric cursor | ✅ | ✅ | — |
| Unique key, no primary key | ✅ (unique column as the key) | ✅ | — |
| No key + cursor | ❌ `CANNOT_INGEST_TABLE_WITHOUT_PRIMARY_KEY` | ❌ same | ✅ duplicates kept |
| No key, no cursor | ✅ full replace each run | — | ❌ rejected: needs a cursor |
| Primary key, no cursor | ✅ full load, incl. hard deletes | — | ❌ needs a cursor (same create check; not run separately) |
| Declared key not unique / has NULLs | ⚠️ accepted, **silent data loss** (102 → 86 rows) | — | — |
| Cursor set on insert only | ⚠️ updates never arrive | — | — |
| Cursor with NULLs | ⚠️ snapshot loads them; later NULL rows skipped | — | — |
| Hard deletes (`hard_deletion_sync_min_interval_in_seconds`) | ✅ | not supported (docs) | — |

❌ fails or rejected · ⚠️ accepted with no warning, but loses or misses data.

The agent's **pre-flight checks** catch each ⚠️ row: a skill session given these flawed tables reported every problem, with counts, before creating anything. When told "only a snapshot test", it went ahead and changed only what would fail.

### 3. Other checks

| Check | Result |
|---|---|
| DML round trip (Lakebase): generate 10 inserts / 10 updates / 10 soft deletes per table, run the pipeline | ✅ SCD1 report exactly 20 upserts and 10 deletes; SCD2 per-key count 10 / 10 / 10 |
| Rows-per-run report on every pipeline type | ✅ query-based (upsert / append / no-cursor / hard deletes), integrated CDC, standard CDC |
| One-shot introspection (all columns, all keys and indexes) | ✅ Postgres, MySQL, SQL Server (about 2 s per database, 100+ tables) |
| Postgres slot create / drop through the UC connection | ✅ on a source whose connection user has `REPLICATION`; slots cleaned up |
| Pipeline names across modes on one connection | ✅ base, `-2`, `-3`, `-gw` / `-ap` |
| No secrets on disk, and nothing left on any source after tests or expected stops | ✅ |
| `python3 scripts/skills.py validate` | ✅ everything up to date |
| `python3 -m unittest discover -s tests -p '*_test.py'` | ✅ 133 tests OK |
| `/code-review` | Run twice; fixes are in the second and third commits |

This pull request and its description were written by Isaac.
