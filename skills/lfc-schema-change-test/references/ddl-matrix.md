# DDL matrix: the result format and the method

The matrix runs the same schema-change cases on each engine, mechanism and setup, and keeps one result file per run. [ddl-matrix-results.md](ddl-matrix-results.md) is the comparison table, generated from those files. The cases and their DDL are in [scripts/ddl-cases.yaml](../scripts/ddl-cases.yaml); the commands are in [scripts/ddl-matrix.py](../scripts/ddl-matrix.py); the checks are in [scripts/ddl-matrix-validate.py](../scripts/ddl-matrix-validate.py).

## File name

`results/ddl-matrix/<engine>-<mechanism>-<setup>-<yyyy-mm-dd>[-<n>].yaml`, for example `sqlserver-ct-utility-1.7-2026-10-26.yaml`. `<n>` numbers a second run on the same day. The name must match the `environment` block; the validator checks it.

- `engine`: `sqlserver`, `postgres`, `mysql`, `oracle`
- `mechanism`: `ct`, `cdc` (SQL Server), `logical-replication` (PostgreSQL), `binlog` (MySQL), `logminer` (Oracle), `query-based`
- `setup`: `none`, `utility-1.7`, `utility-1.7-cleanup` (the utility installed, then its CDC objects removed by `CLEANUP`), `setup-package` (Oracle: the Databricks setup package), `ddl-objects-1.0` (PostgreSQL: the DDL support objects and inline DDL tracking enabled by Databricks support). A new setup needs its slug in the validator's list. The run number after the date orders the runs of a day (no suffix is run 1).

## The `environment` block

| Field | What to write |
|---|---|
| `engine`, `mechanism`, `setup` | the values above |
| `product` | the service, e.g. `Azure SQL Database` |
| `edition_tier` | edition or tier, e.g. `serverless GP_S_Gen5_1`; null if not recorded |
| `version` | the server's version string, verbatim |
| `source_setup` | the setup in words: for `none`, the manual grants or enable calls; for a utility, the script version and options |
| `pipeline_mode` | `integrated`, `standard` or `query-based` |
| `compute` | `serverless` or `classic` |
| `runtime` | `dbr_version`, `channel`, `image_key`, `dp_build` (the `dp-YYYYMMDD-rcN` in the image key), `cloud_region`, and `basis` (where the values were read). `collect` reads them from the pipeline's runtime event. A null `dbr_version` needs a `reason`. From 2026-10-27 `dbr_version` and `dp_build` are required |
| `workspace` | `cloud` and `region` of the workspace, not its name |
| `date` | the run date, `YYYY-MM-DD` |
| `method` | `batch` (all the DDL first, then the updates), `one-case-at-a-time`, or `not-recorded` |
| `caveats` | a list: what was confounded, what didn't run, what the run notes couldn't confirm |
| `who_ran` | optional, free text |

No pipeline ID, warehouse ID, workspace name, connection name, server name, address or path goes in a file. The validator scans for the common ones; the rest is the author's check.

Every run records the runtime (DBR version, channel, dp build), the setup script version, and, when a result rests on a code change, which release builds have it (the change's commit and the builds checked) and the flag's observed rollout value if one decides it.

Run `collect` before the pipeline is destroyed: it reads the runtime from the pipeline's events, and after the pipeline is gone there's nothing to read.

## Cases

Each case is one table with two starting rows, one DDL, and one insert in the new shape (the catalog's `post`).

| Field | Meaning |
|---|---|
| `id` | the catalog id (`int-to-bigint`); an old name goes in the catalog's `aliases` |
| `ddl` | the DDL as run, verbatim; null when the case had none (the control) |
| `column_before`, `column_after` | the column's type in the source's own words, e.g. `INT -> BIGINT`; `absent` when the column isn't there |
| `source_accepted` | `true`; the server's refusal verbatim (`Msg 3735: ...`); or null when not recorded |
| `events` | the error and warning classes in order: `class` (null when the run notes don't name one), `level` (`error`, `warning`, `info`), `message` (short) |
| `outcome` | `restart-no-full-refresh`, `no-interruption`, `table-stops-full-refresh`, `pipeline-fails`, `not-applicable` (the source refused), `not-run` |
| `full_refresh_needed` | true for a stop, false for a restart or none, null when refused or not run |
| `auto_full_refresh_applies` | true or false when `auto_full_refresh_policy` was tested; else null |
| `destination_type_after` | the destination's type for the case's column after the change |
| `post_change_row_landed` | `true`, `false`, `unverified`, or null when the case has no post-change insert |
| `value_check` | what the row shows, e.g. `3000000000 landed`, `source .1234567 landed as .123` |
| `basis` | `tested` (the outcome and row are observed), `confounded` (a failed batch update could explain it), `partial` (the run recorded only part of the case; kept as recorded), `code-only`; null when not run |
| `notes` | the run's own words, verbatim (`recorded: ...`) and anything added |

### Outcome rules

- A **restart** is a running update that ends with `FLOW_SCHEMA_CHANGED` or `CDC_APPLIER_SCHEMA_CHANGED_DURING_STREAMING` and starts a new one by itself; no full refresh.
- A **stop** is a table that needs a full refresh: a `CDC_INCOMPATIBLE_SCHEMA_CHANGES.*`, `INGESTION_GATEWAY_DDL_NOT_SUPPORTED`, `INGESTION_GATEWAY_MISSING_TABLE_IN_SOURCE`, `INGESTION_GATEWAY_UNTRACEABLE_TABLE_MODIFICATION` or `INGESTION_GATEWAY_DDL_OBJECTS_MISSING` class on the table.
- **pipe-fails** is the pipeline stopping as a whole before any table loads.
- **refused** is the source's own refusal of the DDL (nothing changed on the source for that statement). A refusal has no post-change row: `post_change_row_landed` is null and the table shows `n/a`.

A stop or a pipeline failure whose error class was seen means the row is not landed: it is written `post_change_row_landed: false` and `basis: tested`, never `unverified`. The validator refuses the other combination.

A row that landed only after a table was reset (a table-only full refresh) came from the snapshot, not from CDC. It is written `post_change_row_landed: false` with a value check that says so; it is never CDC landed. A silent result (no error, a wrong value or a missing column) has `silent` in its value check and shows in the table.

### Landed rows, and what counts as a pass

A row is landed only when the destination shows the post-change row with the expected values (`collect` reads it with `SELECT ... WHERE id = 3`). A pipeline that was created, or an update that COMPLETED, doesn't make a row landed, and neither is a pass. The `collect` verdicts:

| Verdict | Meaning |
|---|---|
| `PASS` | the row is in the destination with the expected values, and the outcome is a restart or none |
| `VALUE` | the row is there with a different value (`3.1234 landed as 3.12`) |
| `FAIL` | the row is missing after a restart or no interruption |
| `STOP` | the table stopped and needs a full refresh; no row expected |
| `UNVERIFIED` | the update hadn't finished, or the case's basis is confounded |
| `OBSERVED` | no post-change insert in the case (a drop) |

### Confounded rows

A batch runs every case's DDL before one update. If that update fails, every table is re-snapshotted, so a table without an error class of its own can't be credited with a landed row. Such rows get `basis: confounded` and `post_change_row_landed: unverified`. Error-class cells stay `tested`. To settle one, run the case alone (`method: one-case-at-a-time`).

## Marks in the table

Cell: outcome, error class, then the row and the basis.

- Row: `+` landed, `-` not landed, `?` unverified.
- Basis: `T` tested, `C` confounded, `U` unverified (the row is unverified, or the basis is confounded and the row isn't landed), `P` partial.
- A column with more than one run shows, for each case, the newest run that has the case. `render --detail` lists every run.

## Running one combination

```bash
cd skills/lfc-schema-change-test/scripts
uv run ddl-matrix.py sql sqlserver cdc --setup utility-1.7 > /tmp/cdc-setup.sql            # run on the source with your client
uv run ddl-matrix.py bundle --connection <uc-connection> --catalog <catalog> --schema <schema> \
  --source-catalog <database> --engine sqlserver --mechanism cdc --mode integrated --out databricks.yml
uv run ddl-matrix.py collect --pipeline <pipeline-id> --profile <profile> --warehouse <warehouse-id> \
  --dest <catalog>.<schema> --env env.yaml --since 2026-10-26T22:00:00Z --out ../../../results/ddl-matrix/sqlserver-cdc-utility-1.7-2026-10-26.yaml
uv run ddl-matrix-validate.py ../../../results/ddl-matrix/*.yaml
```

`env.yaml` is the `environment` block above, with the optional keys the converter reads (`class_map` for prose class names, `redact` for literal source names, `redact_re` for patterns such as pipeline names, profiles and IDs, `confound_no_error`, `not_run_events`, `overrides` for a case's fields; overrides apply before the stop-row rule), `case_map` (the run's own case names, mapped to catalog ids), `snapshot_after_reset` (a row seen only after a table reset is snapshot: false, with the value check). `collect --events-json ... --tables-json ...` runs the same parse on saved data, which is how the unit test runs.

A run recorded in a structured file (`cases:` with type_before, type_after and events as text), or in prose (a scratch file, one line per case), goes through `convert`. The file's own environment block is replaced by `--env`:

```bash
uv run ddl-matrix.py convert scratch.yaml --env env.yaml --out ../../../results/ddl-matrix/<name>.yaml
```

Each scratch `case:` must be a catalog id or one of its aliases. A value with `: ` in it needs quotes. `overrides` in the env file set a case's fields where the prose is not enough (for example a value the run notes give that the text doesn't say was landed).

## Oracle

Oracle's run is `results/ddl-matrix/oracle-logminer-setup-package-2026-10-26.yaml`: the setup package, a C## user, and no DDL-tracking objects. Its environment records the recovery-area fix (the area filled at 10G and was raised to 50G). The catalog's Oracle templates are written; `sql oracle logminer` prints them.

## Rendering

```bash
uv run ddl-matrix.py render > ../references/ddl-matrix-results.md          # every file in results/ddl-matrix
uv run ddl-matrix.py render --detail                                       # every field of every case
```

The render checks every file first and stops at the first that fails.
