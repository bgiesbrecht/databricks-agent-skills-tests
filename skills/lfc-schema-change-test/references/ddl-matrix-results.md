# DDL matrix results

Generated from the run files in [results/ddl-matrix](../../../results/ddl-matrix/) by `uv run skills/lfc-schema-change-test/scripts/ddl-matrix.py render > skills/lfc-schema-change-test/references/ddl-matrix-results.md`. Don't edit by hand. The file format and the method: [ddl-matrix.md](ddl-matrix.md).

Cell: outcome, error class, row check and basis. Outcome: `restart` (the update restarts, no full refresh), `no-int` (no interruption), `stops` (the table stops and needs a full refresh), `pipe-fails`, `refused` (the source refused the DDL), `not run`. Row: `+` landed, `-` not landed, `?` not verified. Basis: `T` tested, `C` confounded by a batch, `U` unverified. Notes are linked from the cell.

| Case | Types (SQL Server) | sqlserver cdc none | sqlserver cdc utility-1.7 | sqlserver cdc utility-1.7-cleanup | sqlserver ct none (2 runs) | sqlserver ct utility-1.7 | sqlserver ct utility-1.7-cleanup | postgres logical-replication none | mysql binlog none |
|---|---|---|---|---|---|---|---|---|---|
| `start-first-update` | - | pipe-fails DDL_OBJECTS_MISSING T |  | stops DDL_OBJECTS_MISSING T | no-int T |  | stops DDL_OBJECTS_MISSING T |  |  |
| `add-nullable` | absent -> INT NULL |  | restart FLOW_SCHEMA_CHANGED +T |  | restart ?U | restart +T |  | stops DDL_NOT_SUPPORTED -T | not run TLS_VALIDATION_FAILURE [n1](#n1) |
| `add-nullable-keyless` | absent -> INT NULL |  | stops PRIMARY_KEY_CHANGE -T |  |  |  |  | stops DDL_NOT_SUPPORTED -T | not run TLS_VALIDATION_FAILURE [n1](#n1) |
| `add-nullable-with-default` | absent -> INT NULL DEFAULT 5 |  | stops ADD_COLUMN_WITH_BACKFILL -T |  | stops ADD_COLUMN_WITH_BACKFILL ?U | stops ADD_COLUMN_WITH_BACKFILL ?U |  | stops DDL_NOT_SUPPORTED -T | not run TLS_VALIDATION_FAILURE [n1](#n1) |
| `add-not-null-with-default` | absent -> INT NOT NULL DEFAULT 5 |  | stops ADD_COLUMN_WITH_BACKFILL -T |  | stops ADD_COLUMN_WITH_BACKFILL ?U |  |  | stops DDL_NOT_SUPPORTED -T | not run TLS_VALIDATION_FAILURE [n1](#n1) |
| `add-computed-column` | absent -> computed |  |  |  | stops ADD_COLUMN_WITH_BACKFILL -T |  |  |  |  |
| `add-identity-column` | absent -> INT IDENTITY |  |  |  | not run [n2](#n2) |  |  |  |  |
| `drop-column` | NVARCHAR(50) -> absent |  | restart FLOW_SCHEMA_CHANGED +T |  | restart +T | restart CDC_APPLIER_SCHEMA_CHANGED_DURING_STREAMING +T |  | stops DDL_NOT_SUPPORTED -T | not run TLS_VALIDATION_FAILURE [n1](#n1) |
| `int-to-bigint` | INT -> BIGINT |  | restart +T |  | restart +T | restart +T |  | stops DDL_NOT_SUPPORTED -T | not run TLS_VALIDATION_FAILURE [n1](#n1) |
| `decimal-10-2-to-18-4` | DECIMAL(10,2) -> DECIMAL(18,4) |  | restart +T |  | restart +T | restart +T |  | no-int ?U [n3](#n3) | not run TLS_VALIDATION_FAILURE [n1](#n1) |
| `string-length-narrow` | NVARCHAR(50) -> NVARCHAR(20) |  | restart +T |  | restart +T | restart +T |  | no-int ?U [n3](#n3) | not run TLS_VALIDATION_FAILURE [n1](#n1) |
| `bigint-to-int` | BIGINT -> INT |  | stops UNSUPPORTED_DATA_TYPE_CHANGE -T |  | stops UNSUPPORTED_DATA_TYPE_CHANGE ?U | stops UNSUPPORTED_DATA_TYPE_CHANGE ?U |  | no-int ?U [n3](#n3) | not run TLS_VALIDATION_FAILURE [n1](#n1) |
| `int-to-string` | INT -> NVARCHAR(20) |  | stops UNSUPPORTED_DATA_TYPE_CHANGE -T |  | stops UNSUPPORTED_DATA_TYPE_CHANGE ?U | stops UNSUPPORTED_DATA_TYPE_CHANGE ?U |  | stops DDL_NOT_SUPPORTED -T | not run TLS_VALIDATION_FAILURE [n1](#n1) |
| `int-to-decimal-18-2` | INT -> DECIMAL(18,2) |  |  |  | stops UNSUPPORTED_DATA_TYPE_CHANGE -T |  |  |  |  |
| `varchar-to-nvarchar` | VARCHAR(20) -> NVARCHAR(20) |  |  |  | no-int +T |  |  |  |  |
| `datetime-precision-up` | DATETIME -> DATETIME2(7) |  |  |  | no-int +T [n4](#n4) |  |  |  | not run TLS_VALIDATION_FAILURE [n1](#n1) |
| `date-to-timestamp` | DATE -> DATETIME2(0) |  |  |  |  |  |  |  |  |
| `timestamp-to-timestamptz` | timestamp -> timestamptz |  |  |  |  |  |  | no-int ?U [n3](#n3) |  |
| `null-to-not-null` | INT NULL -> INT NOT NULL |  | stops COLUMN_NULLABLE_TO_NON_NULLABLE -T |  | no-int +T |  |  | no-int ?U [n3](#n3) | not run TLS_VALIDATION_FAILURE [n1](#n1) |
| `not-null-to-null` | INT NOT NULL -> INT NULL |  |  |  | no-int +T |  |  | no-int ?U [n3](#n3) | not run TLS_VALIDATION_FAILURE [n1](#n1) |
| `add-unique` | no change (UNIQUE constraint) |  | stops DDL_NOT_SUPPORTED -T |  | no-int +T |  |  | no-int ?U [n3](#n3) | not run TLS_VALIDATION_FAILURE [n1](#n1) |
| `drop-primary-key` | no change (PRIMARY KEY dropped) |  | refused +T [n5](#n5) |  | refused +T [n6](#n6) |  |  | no-int ?U [n3](#n3) | not run TLS_VALIDATION_FAILURE [n1](#n1) |
| `rename-column` | INT (n) -> INT (n2) |  | refused ?U [n7](#n7) |  | stops COLUMNS_ADDED_AND_DELETED -T |  |  | stops DDL_NOT_SUPPORTED -T | not run TLS_VALIDATION_FAILURE [n1](#n1) |
| `rename-table` | table name only |  | stops MISSING_TABLE_IN_SOURCE -T |  | stops MISSING_TABLE_IN_SOURCE -T |  |  | no-int ?U [n3](#n3) | not run TLS_VALIDATION_FAILURE [n1](#n1) |
| `drop-table` | table dropped |  | stops MISSING_TABLE_IN_SOURCE T |  | stops MISSING_TABLE_IN_SOURCE T |  |  | no-int C [n3](#n3) | not run TLS_VALIDATION_FAILURE [n1](#n1) |
| `truncate` | rows removed |  | refused ?U [n8](#n8) |  | stops UNTRACEABLE_TABLE_MODIFICATION -T |  |  | stops TRUNCATE_TABLE -T | not run TLS_VALIDATION_FAILURE [n1](#n1) |

A `(N runs)` column merges the runs of one setup; two different cells in one column are joined with ` / `. Each mechanism's `none` column and its `utility` column are the same cases with and without the setup script.

## Notes

<a id="n1"></a>1. not run: TLS is enforced but no server certificate provided. Provide a server certificate or set trustServerCertificate=true to skip SSL verification.
<a id="n2"></a>2. not run: recorded: skipped; planned, not run: not run (skipped, reason: table k_ident already has an identity column, so a second IDENTITY cannot be added)
<a id="n3"></a>3. confounded: the batch's update failed, so this row is not attributed to the change (unverified)
<a id="n4"></a>4. landed with a different value: source .1234567 landed as .123 (milliseconds)
<a id="n5"></a>5. the source refused the DDL: The unique index 'pk_c_droppk' ... is used by Change Data Capture
<a id="n6"></a>6. the source refused the DDL: Msg 3735: primary key cannot be dropped because change tracking is enabled
<a id="n7"></a>7. the source refused the DDL: Cannot alter column 'n' because it is 'REPLICATED'.
<a id="n8"></a>8. the source refused the DDL: Cannot truncate table 'dbo.c_trunc' because it is published for replication or enabled for Change Data Capture
