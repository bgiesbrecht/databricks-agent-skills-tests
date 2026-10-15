# Full matrix: 2026-10-15, Azure serverless sandbox workspace

Skills repo branch `lfc-query-based-lakebase-demo`. Run with `bin/run_matrix.sh` (about 21 min).
Target catalog: a managed catalog on **Default Storage**, created with SQL `CREATE CATALOG` because
the metastore has no storage root. The workspace requires serverless compute.

| Source | QBC via connection | QBC via foreign catalog | Integrated CDC | Standard CDC |
|---|---|---|---|---|
| Lakebase | ✅ snapshot 1,000 / 10,000; run 2: `orders` 100 upserts + 1 delete | ✅ created foreign catalog `<firstname><lastname>-lfc_demo_pg_conn`; 1,001 / 9,999 (soft-deleted row excluded) | ✅ expected stop: no integrated CDC for Postgres | ✅ expected stop: Lakebase refused `CREATE PUBLICATION`; nothing left |
| Postgres | ✅ 34,408 / 39,213 = source | ✅ reused existing foreign catalog; 34,408 / 39,213 | ✅ expected stop: no integrated CDC for Postgres | ✅ expected stop: 403 `POSTGRESQL` at deploy; no slot or publication created |
| MySQL | ✅ 10 / 10 | ✅ reused existing foreign catalog; 10 / 10 | ⛔ blocked: Default Storage catalog | ✅ expected stop: 403 `MYSQL` at deploy |
| SQL Server | ✅ 4,894 / 5,494 | ✅ reused existing foreign catalog; 4,894 / 5,494 | ⛔ blocked: Default Storage catalog | ⛔ blocked: Default Storage catalog |

DML round trip (Lakebase): ✅ 10 inserts / 10 updates / 10 soft deletes per table arrived. `orders`
(SCD1) report: 20 upserts, 10 deletes. `customers` (SCD2) per-key count from the table: 10 / 10 / 10.

Names: base for QBC via connection, `-2` for QBC via foreign catalog, `-3` for integrated CDC
(not created, blocked), `-gw` / `-ap` for standard CDC. Every cell asked before creating anything.

**Blocked cells (⛔):** "Default Storage for Unity Catalog is not supported on LakeFlow Connect
pipelines." CDC pipelines (integrated and standard) can't use a Default Storage catalog;
query-based pipelines can. Rerun `icdc` and `scdc` with a catalog that has its own managed
location. Each blocked cell stopped cleanly and left only empty schemas.

Skill fixes from this run: Default Storage limit and how to detect it (SKILL.md); foreign
catalog `information_schema` gives columns and keys in one shot (reference 7).

## Data shapes (fixtures/lakebase-shapes), same workspace

Product test (`fixtures/lakebase-shapes/run.sh`, no agent): results match the table in
`fixtures/lakebase-shapes/README.md`. Highlights:

- **No checks:** a declared key with duplicates and NULLs, cursors without an index, and NULL
  cursors were all accepted, and the runs COMPLETED with no warning. `fake_pk` lost 16 of 102
  rows.
- **Insert-only cursor:** 0 of 5 updates arrived.
- **Differences from the docs:** SCD1/SCD2 with no key fail at runtime
  (`CANNOT_INGEST_TABLE_WITHOUT_PRIMARY_KEY`, no synthetic key). APPEND_ONLY without a cursor is
  rejected at create. SCD1 with no key and no cursor works (full replace). `cursor_column` is
  dropped as an unknown field, so the pipeline has no cursor.
- **Event log:** no-cursor tables record no row counts. Hard-delete tracking is its own `_delete`
  flow.

Skill test (`preflight-lakebase`): ✅ turn 1 reported all four problems with counts (non-unique
key with 85 distinct of 102 and 6 NULLs; unindexed cursors; 11 NULL cursors; no update trigger;
no-key SCD1 will fail) before creating anything. Turn 2 ("only a snapshot test") kept the user's
keys and cursors and changed only the no-key table, to no cursor. The run confirmed the
predicted loss (86 of 102).
