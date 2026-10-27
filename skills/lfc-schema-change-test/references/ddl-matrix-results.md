# DDL matrix results

Generated from the run files in [results/ddl-matrix](../../../results/ddl-matrix/) by `uv run skills/lfc-schema-change-test/scripts/ddl-matrix.py render > skills/lfc-schema-change-test/references/ddl-matrix-results.md`. Don't edit by hand. The file format and the method: [ddl-matrix.md](ddl-matrix.md).

Cell: outcome, error class, row check and basis. Outcome: `restart` (the update restarts, no full refresh), `no-int` (no interruption), `stops` (the table stops and needs a full refresh), `pipe-fails`, `refused` (the source refused the DDL), `not run`. Row: `+` landed, `-` not landed, `?` not verified. Basis: `T` tested, `C` confounded by a batch, `U` unverified, `P` partial (the run recorded only part of the case). Notes are linked from the cell.

| Case | Types (SQL Server) | sqlserver cdc none (2 runs) | sqlserver cdc utility-1.7 (2 runs) | sqlserver cdc utility-1.7-cleanup | sqlserver ct none (3 runs) | sqlserver ct utility-1.7 (2 runs) | sqlserver ct utility-1.7-cleanup | postgres logical-replication none (2 runs) | postgres logical-replication ddl-objects-1.0 | mysql binlog none | oracle logminer setup-package |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `start-first-update` | - | pipe-fails DDL_OBJECTS_MISSING T |  | stops DDL_OBJECTS_MISSING T | no-int T |  | stops DDL_OBJECTS_MISSING T |  |  |  |  |
| `add-nullable` | absent -> INT NULL | pipe-fails DDL_OBJECTS_MISSING -T | restart FLOW_SCHEMA_CHANGED +T |  | restart FLOW_SCHEMA_CHANGED +T | restart FLOW_SCHEMA_CHANGED +T |  | pipe-fails DDL_NOT_SUPPORTED -T | no-int +T | not run TLS_VALIDATION_FAILURE [n1](#n1) | restart FLOW_SCHEMA_CHANGED -P |
| `add-nullable-keyless` | absent -> INT NULL | pipe-fails DDL_OBJECTS_MISSING -T | stops PRIMARY_KEY_CHANGE -T |  | not run [n2](#n2) | not run [n3](#n3) |  | pipe-fails DDL_NOT_SUPPORTED -T | pipe-fails PRIMARY_KEY_CHANGE -T | not run TLS_VALIDATION_FAILURE [n1](#n1) | restart FLOW_SCHEMA_CHANGED -P |
| `add-nullable-with-default` | absent -> INT NULL DEFAULT 5 | pipe-fails DDL_OBJECTS_MISSING -T | stops ADD_COLUMN_WITH_BACKFILL -T |  | stops ADD_COLUMN_WITH_BACKFILL -T | stops ADD_COLUMN_WITH_BACKFILL -T |  | pipe-fails DDL_NOT_SUPPORTED -T | pipe-fails ADD_COLUMN_WITH_BACKFILL -T | not run TLS_VALIDATION_FAILURE [n1](#n1) | restart FLOW_SCHEMA_CHANGED -P |
| `add-not-null-with-default` | absent -> INT NOT NULL DEFAULT 5 | pipe-fails DDL_OBJECTS_MISSING -T | stops ADD_COLUMN_WITH_BACKFILL -T |  | stops ADD_COLUMN_WITH_BACKFILL -T | stops ADD_COLUMN_WITH_BACKFILL -T |  | pipe-fails DDL_NOT_SUPPORTED -T | pipe-fails ADD_COLUMN_WITH_BACKFILL -T | not run TLS_VALIDATION_FAILURE [n1](#n1) | restart FLOW_SCHEMA_CHANGED -P |
| `add-computed-column` | absent -> computed | pipe-fails DDL_OBJECTS_MISSING -T | stops DDL_NOT_SUPPORTED -T |  | stops ADD_COLUMN_WITH_BACKFILL -T | stops ADD_COLUMN_WITH_BACKFILL -T |  | no-int +T silent [n4](#n4) | pipe-fails ADD_COLUMN_WITH_BACKFILL -T |  |  |
| `add-identity-column` | absent -> INT IDENTITY |  |  |  | not run [n5](#n5) |  |  |  |  |  |  |
| `drop-column` | NVARCHAR(50) -> absent | pipe-fails DDL_OBJECTS_MISSING -T | restart FLOW_SCHEMA_CHANGED +T |  | restart FLOW_SCHEMA_CHANGED +T | restart FLOW_SCHEMA_CHANGED +T |  | pipe-fails DDL_NOT_SUPPORTED -T | no-int +T | not run TLS_VALIDATION_FAILURE [n1](#n1) | restart FLOW_SCHEMA_CHANGED -P |
| `int-to-bigint` | INT -> BIGINT | pipe-fails DDL_OBJECTS_MISSING -T | restart FLOW_SCHEMA_CHANGED +T |  | restart FLOW_SCHEMA_CHANGED +T | restart FLOW_SCHEMA_CHANGED +T |  | pipe-fails DDL_NOT_SUPPORTED -T | pipe-fails UNSUPPORTED_DATA_TYPE_CHANGE -T | not run TLS_VALIDATION_FAILURE [n1](#n1) | restart FLOW_SCHEMA_CHANGED -P |
| `decimal-10-2-to-18-4` | DECIMAL(10,2) -> DECIMAL(18,4) | pipe-fails DDL_OBJECTS_MISSING -T | restart FLOW_SCHEMA_CHANGED +T |  | restart FLOW_SCHEMA_CHANGED +T | restart FLOW_SCHEMA_CHANGED +T |  | no-int +T | pipe-fails DDL_NOT_SUPPORTED -T | not run TLS_VALIDATION_FAILURE [n1](#n1) | restart FLOW_SCHEMA_CHANGED -P |
| `string-length-narrow` | NVARCHAR(50) -> NVARCHAR(20) | pipe-fails DDL_OBJECTS_MISSING -T | restart FLOW_SCHEMA_CHANGED +T |  | restart FLOW_SCHEMA_CHANGED +T | restart FLOW_SCHEMA_CHANGED +T |  | no-int +T | no-int +T | not run TLS_VALIDATION_FAILURE [n1](#n1) | restart FLOW_SCHEMA_CHANGED -P |
| `bigint-to-int` | BIGINT -> INT | pipe-fails DDL_OBJECTS_MISSING -T | stops UNSUPPORTED_DATA_TYPE_CHANGE -T |  | stops UNSUPPORTED_DATA_TYPE_CHANGE -T | stops UNSUPPORTED_DATA_TYPE_CHANGE -T |  | no-int +T | pipe-fails UNSUPPORTED_DATA_TYPE_CHANGE -T | not run TLS_VALIDATION_FAILURE [n1](#n1) | refused n/a T [n6](#n6) |
| `int-to-string` | INT -> NVARCHAR(20) | pipe-fails DDL_OBJECTS_MISSING -T | stops UNSUPPORTED_DATA_TYPE_CHANGE -T |  | stops UNSUPPORTED_DATA_TYPE_CHANGE -T | stops UNSUPPORTED_DATA_TYPE_CHANGE -T |  | pipe-fails DDL_NOT_SUPPORTED -T | pipe-fails PARSING_FAILURE -T | not run TLS_VALIDATION_FAILURE [n1](#n1) | refused n/a T [n7](#n7) |
| `int-to-decimal-18-2` | INT -> DECIMAL(18,2) | pipe-fails DDL_OBJECTS_MISSING -T | stops UNSUPPORTED_DATA_TYPE_CHANGE -T |  | stops UNSUPPORTED_DATA_TYPE_CHANGE -T | stops UNSUPPORTED_DATA_TYPE_CHANGE -T |  |  |  |  |  |
| `varchar-to-nvarchar` | VARCHAR(20) -> NVARCHAR(20) | pipe-fails DDL_OBJECTS_MISSING -T | restart FLOW_SCHEMA_CHANGED +T [n8](#n8) |  | restart FLOW_SCHEMA_CHANGED +T [n8](#n8) | restart FLOW_SCHEMA_CHANGED +T [n8](#n8) |  |  |  |  |  |
| `datetime-precision-up` | DATETIME -> DATETIME2(7) | pipe-fails DDL_OBJECTS_MISSING -T | restart FLOW_SCHEMA_CHANGED +T [n9](#n9) |  | restart FLOW_SCHEMA_CHANGED +T [n10](#n10) | restart FLOW_SCHEMA_CHANGED +T [n9](#n9) |  |  |  | not run TLS_VALIDATION_FAILURE [n1](#n1) |  |
| `date-to-timestamp` | DATE -> DATETIME2(0) |  |  |  |  |  |  | pipe-fails DDL_NOT_SUPPORTED -T | pipe-fails UNSUPPORTED_DATA_TYPE_CHANGE -T |  | restart FLOW_SCHEMA_CHANGED -P |
| `timestamp-to-timestamptz` | timestamp -> timestamptz |  |  |  |  |  |  | no-int +T | pipe-fails UNSUPPORTED_DATA_TYPE_CHANGE -T |  | refused n/a T [n7](#n7) |
| `null-to-not-null` | INT NULL -> INT NOT NULL | pipe-fails DDL_OBJECTS_MISSING -T | stops COLUMN_NULLABLE_TO_NON_NULLABLE -T |  | no-int +T | no-int +T |  | no-int +T | pipe-fails COLUMN_NULLABLE_TO_NON_NULLABLE -T | not run TLS_VALIDATION_FAILURE [n1](#n1) | restart FLOW_SCHEMA_CHANGED -P |
| `not-null-to-null` | INT NOT NULL -> INT NULL | pipe-fails DDL_OBJECTS_MISSING -T | no-int +T |  | no-int +T | no-int +T |  | no-int +T | pipe-fails COLUMN_NON_NULLABLE_TO_NULLABLE -T | not run TLS_VALIDATION_FAILURE [n1](#n1) | restart FLOW_SCHEMA_CHANGED -P |
| `add-unique` | no change (UNIQUE constraint) | pipe-fails DDL_OBJECTS_MISSING -T | stops DDL_NOT_SUPPORTED -T |  | no-int +T | no-int +T |  | no-int +T | pipe-fails ADD_CONSTRAINT -T | not run TLS_VALIDATION_FAILURE [n1](#n1) | stops +T |
| `drop-primary-key` | no change (PRIMARY KEY dropped) | pipe-fails DDL_OBJECTS_MISSING -T | refused n/a T [n11](#n11) |  | refused n/a T [n12](#n12) | refused n/a T [n13](#n13) |  | no-int +T | pipe-fails DROP_PRIMARY_KEY_CONSTRAINT -T | not run TLS_VALIDATION_FAILURE [n1](#n1) | stops +T |
| `rename-column` | INT (n) -> INT (n2) | pipe-fails DDL_OBJECTS_MISSING -T | refused n/a T [n14](#n14) |  | stops COLUMNS_ADDED_AND_DELETED -T | stops COLUMNS_ADDED_AND_DELETED -T |  | pipe-fails DDL_NOT_SUPPORTED -T | pipe-fails COLUMNS_ADDED_AND_DELETED -T | not run TLS_VALIDATION_FAILURE [n1](#n1) | restart FLOW_SCHEMA_CHANGED -P |
| `rename-table` | table name only | pipe-fails -T | no-int +T |  | pipe-fails MISSING_TABLE_IN_SOURCE -T | pipe-fails MISSING_TABLE_IN_SOURCE -T |  | no-int -T | no-int -T | not run TLS_VALIDATION_FAILURE [n1](#n1) | stops MISSING_TABLE_IN_SOURCE -T |
| `drop-table` | table dropped | pipe-fails T | pipe-fails T |  | pipe-fails MISSING_TABLE_IN_SOURCE T | pipe-fails MISSING_TABLE_IN_SOURCE T |  | no-int T | pipe-fails TABLE_DROPPED T | not run TLS_VALIDATION_FAILURE [n1](#n1) | not run [n15](#n15) |
| `truncate` | rows removed | pipe-fails DDL_OBJECTS_MISSING -T | refused n/a T [n16](#n16) |  | stops UNTRACEABLE_TABLE_MODIFICATION -T | stops UNTRACEABLE_TABLE_MODIFICATION -T |  | pipe-fails TRUNCATE_TABLE -T | pipe-fails TRUNCATE_TABLE -T | not run TLS_VALIDATION_FAILURE [n1](#n1) | not run [n17](#n17) |

A `(N runs)` column shows, for each case, the newest run that has the case; `--detail` lists every run. Each mechanism's `none` column and its `utility` column are the same cases with and without the setup script.

## Notes

<a id="n1"></a>1. not run: TLS is enforced but no server certificate provided. Provide a server certificate or set trustServerCertificate=true to skip SSL verification.
<a id="n2"></a>2. not run: CT needs a PK; CDC only (see cdc rows); recorded as 'add-keyless'
<a id="n3"></a>3. not run: CT needs a PK; the keyless case is CDC only; recorded as 'add-keyless'
<a id="n4"></a>4. silent (no error): no c column: the generated column is not replicated (silent: no error)
<a id="n5"></a>5. not run: recorded: skipped; planned, not run: not run (skipped, reason: table k_ident already has an identity column, so a second IDENTITY cannot be added)
<a id="n6"></a>6. the source refused the DDL: ORA-01440: column to be modified must be empty to decrease precision or scale
<a id="n7"></a>7. the source refused the DDL: ORA-01439: column to be modified must be empty to change datatype
<a id="n8"></a>8. landed with a different value: N'café' lands as café
<a id="n9"></a>9. landed with a different value: source .1234567 lands as .123 (milliseconds)
<a id="n10"></a>10. landed with a different value: source 2026-10-26 12:00:00.1234567 lands as 12:00:00.123 (milliseconds)
<a id="n11"></a>11. the source refused the DDL: refused: The unique index 'pk_c_droppk' ... is used by Change Data Capture
<a id="n12"></a>12. the source refused the DDL: refused, Msg 3735: primary key cannot be dropped because change tracking is enabled (Change tracking requires a primary key constraint on the table)
<a id="n13"></a>13. the source refused the DDL: refused. Msg 3735: The primary key constraint 'pk_t_droppk' on table 't_droppk' cannot be dropped because change tracking is enabled on the table. Change tracking requires a primary key constraint on the table. Disable change tracking before dropping the constraint. Then Msg 3727: Could not drop constraint. See previous errors.
<a id="n14"></a>14. the source refused the DDL: refused: Cannot alter column 'n' because it is 'REPLICATED'.
<a id="n15"></a>15. not run: not run (pipeline P1 stalled; not executed); run case c19
<a id="n16"></a>16. the source refused the DDL: refused: Cannot truncate table 'dbo.c_trunc' because it is published for replication or enabled for Change Data Capture (Msg 4711 class)
<a id="n17"></a>17. not run: update <id> RUNNING at 2026-10-27 00:48 UTC
