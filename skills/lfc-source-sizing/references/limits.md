# Documented limits

Generated from `limits/*.yaml` by `scripts/limits-check.py --markdown`, which printed only rows whose quote it found on the cited page (checked 2026-10-22). Kind: **hard** (fixed), **soft** (raised on request), **configurable** (a setting), **recommended** (the vendor's guidance), **behavior** (documented, not a cap). The YAML holds each row's quote.

## Databricks (Unity Catalog, pipelines, jobs, Lakeflow Connect)

| Product | Limit | Value | Kind | What to ask | Source |
|---|---|---|---|---|---|
| Databricks | Unity Catalog tables per metastore | 1,000,000 | hard | how many tables in total across every source and silver/gold? | [docs](https://docs.databricks.com/aws/en/resources/limits) |
| Databricks | Unity Catalog tables per schema | 10,000 | soft | more than about 5,000 source tables into one schema (each makes 2 silver tables)? split schemas, or ask the account team to raise it | [docs](https://docs.databricks.com/aws/en/resources/limits) |
| Databricks | Unity Catalog volumes per schema | 10,000 | soft | one staging volume per table or per source? | [docs](https://docs.databricks.com/aws/en/resources/limits) |
| Databricks | Unity Catalog volumes per metastore | 100,000 | soft | how many volumes across all schemas? | [docs](https://docs.databricks.com/aws/en/resources/limits) |
| Databricks | Lakeflow pipelines tables per pipeline | 1,000 | hard | more than 999 source tables in one ingestion pipeline? the hidden CDC staging table takes one (tested 2026-10-26): split them over pipelines | [docs](https://docs.databricks.com/aws/en/resources/limits) |
| Databricks | Lakeflow pipelines saved pipelines | 12,000 | hard | one pipeline per source or per table group: how many in total? | [docs](https://docs.databricks.com/aws/en/resources/limits) |
| Databricks | Lakeflow pipelines concurrent updates | 1,000 | hard | how many pipelines update at the same time? | [docs](https://docs.databricks.com/aws/en/resources/limits) |
| Databricks | SQL Statement Execution API result payload | 25 MiB | hard | a result over 25 MiB inline? use EXTERNAL_LINKS | [docs](https://docs.databricks.com/aws/en/dev-tools/sql-execution-tutorial) |
| Databricks | Jobs tasks running simultaneously | 2,000 | hard | how many jobs or tasks (MERGE jobs, fan-out) run at once? | [docs](https://docs.databricks.com/aws/en/resources/limits) |
| Databricks | Jobs saved jobs | 12,000 | hard | one job per source or per shard: how many in total? | [docs](https://docs.databricks.com/aws/en/resources/limits) |
| Databricks | Unity Catalog catalogs per metastore | 1,000 | soft | one catalog per source system or per environment? | [docs](https://docs.databricks.com/aws/en/resources/limits) |
| Databricks | Unity Catalog schemas per catalog | 10,000 | soft | one schema per source database: how many databases? | [docs](https://docs.databricks.com/aws/en/resources/limits) |
| Databricks | Unity Catalog connections per metastore | 1,000 | soft | one connection per source host: how many hosts? | [docs](https://docs.databricks.com/aws/en/resources/limits) |
| Databricks | Managed disaster recovery catalogs per failover group | 10 | soft | is disaster recovery in scope? how many catalogs fail over together? | [docs](https://docs.databricks.com/aws/en/resources/limits) |
| Databricks | Unity Catalog columns per table | 32,768 | hard | any source table wider than 32,768 columns? | [docs](https://docs.databricks.com/aws/en/resources/limits) |
| Databricks | Secrets scopes per workspace | 1,000 | soft | one secret scope per source? | [docs](https://docs.databricks.com/aws/en/resources/limits) |
| Databricks | API request rate limits for workspace APIs | 50 requests per second | hard | does automation create or poll many objects at once? | [docs](https://docs.databricks.com/aws/en/resources/limits) |
| Lakeflow Connect PostgreSQL | Tables per pipeline with same name | 0 (not allowed) | behavior | do several source schemas share table names? they need separate pipelines | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/postgresql-limits) |
| Lakeflow Connect PostgreSQL | Replication slots management | manual cleanup required | behavior | who removes the slot when a pipeline is deleted? an orphaned slot keeps WAL growing | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/postgresql-limits) |
| Lakeflow Connect PostgreSQL | Failover recovery requirement | full refresh required | behavior | does the source fail over (HA, managed service)? a failover means a full refresh of the pipeline's tables | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/postgresql-limits) |
| Lakeflow Connect PostgreSQL | Replica identity requirement | FULL or DEFAULT required | behavior | which tables have no primary key, or TOASTed columns? set REPLICA IDENTITY FULL | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/postgresql-limits) |
| Lakeflow Connect PostgreSQL | New column backfill | not automatic | behavior | are columns added often? historical values need a full refresh of the table | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/postgresql-limits) |
| Lakeflow Connect PostgreSQL | Cursor columns requirement | monotonically increasing | behavior | query-based: which column only ever increases (updated_at, an ID)? | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/postgresql-limits) |
| Lakeflow Connect SQL Server | Pipeline gateway association | exactly one per pipeline | hard | several pipelines on one source need a gateway each (classic compute) | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/sql-server-limits) |
| Lakeflow Connect SQL Server | Failover recovery requirement | full refresh required | behavior | does the source fail over (HA, managed service)? a failover means a full refresh of the pipeline's tables | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/sql-server-limits) |
| Lakeflow Connect SQL Server | CDC version support | SQL Server 2012 SP1 CU3 or above | hard | which SQL Server version and edition? | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/sql-server-limits) |
| Lakeflow Connect SQL Server | Change tracking version support | SQL Server 2012 or above | hard | change tracking or CDC: which version? | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/sql-server-limits) |
| Lakeflow Connect (SQL Server) | tables per ingestion pipeline | 250 or fewer | recommended | how many tables? more than 250: plan several pipelines (the create call accepted 300 tables on 2026-10-25) | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/sql-server-limits) |
| Lakeflow Connect (SQL Server) | rows and columns per table | no limit | behavior |  | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/sql-server-limits) |
| Lakeflow Connect (SQL Server) | source instance | primary only | behavior | can the gateway read the primary? a read replica or secondary won't do | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/sql-server-limits) |
| Lakeflow Connect (SQL Server) | gateway mode | continuous | behavior | how long is CDC or change-tracking retention on the source? | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/sql-server-limits) |
| Lakeflow Connect (database connectors) | gateways per pipeline | exactly one, not shared | hard | several pipelines for one source each need their own gateway (classic compute) | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/mysql-limits) |
| Lakeflow Connect (database connectors) | gateway compute | classic | behavior | does the workspace allow classic compute? a serverless-only workspace can't run the gateway | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/mysql-limits) |
| Lakeflow Connect (database connectors) | table names in one pipeline | unique, across source schemas | behavior | do several source schemas share table names? they need separate pipelines | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/oracle-limits) |
| Lakeflow Connect (MySQL) | binary log format | binlog_format=ROW, binlog_row_image=FULL | configurable (`binlog_format, binlog_row_image`) | what are binlog_format and binlog_row_image now? | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/mysql-limits) |
| Lakeflow Connect (MySQL) | binlog purged before it's read | full refresh of every table in the pipeline | behavior | how long is binlog retention? it bounds how long the gateway can be down | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/mysql-limits) |
| Lakeflow Connect (MySQL) | spatial types | not supported | hard | any spatial columns? | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/mysql-limits) |
| Lakeflow Connect (Oracle) | versions | 12c and above | hard | which Oracle version? | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/oracle-limits) |
| Lakeflow Connect (Oracle) | RAC | not supported | hard | is it RAC or Exadata RAC? | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/oracle-limits) |
| Lakeflow Connect (Oracle) | deployments not supported | physical standby, Autonomous Database, multi-tenant RDS for Oracle | hard | where does the database run? | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/oracle-limits) |
| Lakeflow Connect (Oracle) | table and column name length (LogMiner) | 30 characters | hard | any table or column names longer than 30 characters? | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/oracle-limits) |
| Lakeflow Connect (Oracle) | tables per pipeline | the pipelines limit | hard | see Lakeflow pipelines: 1,000 tables per pipeline | [docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/oracle-limits) |

## PostgreSQL (MySQL: see managed services; its own docs refuse scripted fetches)

| Product | Limit | Value | Kind | What to ask | Source |
|---|---|---|---|---|---|
| PostgreSQL | database size | unlimited | hard | how big is the database? (no limit itself: ask about the largest table) | [docs](https://www.postgresql.org/docs/current/limits.html) |
| PostgreSQL | number of databases | 4,294,950,911 | hard | how many databases on the server? | [docs](https://www.postgresql.org/docs/current/limits.html) |
| PostgreSQL | relations per database | 1,431,650,303 | hard | how many tables in the database? | [docs](https://www.postgresql.org/docs/current/limits.html) |
| PostgreSQL | relation (table) size | 32 TB | hard | how big is the largest table? one table can't pass 32 TB (8 kB blocks) | [docs](https://www.postgresql.org/docs/current/limits.html) |
| PostgreSQL | rows per table | limited by pages (4,294,967,295) | hard | how many rows in the largest table? | [docs](https://www.postgresql.org/docs/current/limits.html) |
| PostgreSQL | columns per table | 1,600 | hard | any table wider than the engine allows? | [docs](https://www.postgresql.org/docs/current/limits.html) |
| PostgreSQL | field size (TOAST maximum) | 1 GB | hard | any values over 1 GB (large JSON, bytea)? | [docs](https://www.postgresql.org/docs/current/limits.html) |
| PostgreSQL | identifier length (table, column, index names) | 63 bytes | hard | any names longer than 63 bytes (truncated)? | [docs](https://www.postgresql.org/docs/current/limits.html) |
| PostgreSQL | maximum replication slots | 10 (default) | configurable (`max_replication_slots`) | how many slots are in use already? each CDC reader takes one | [docs](https://www.postgresql.org/docs/current/runtime-config-replication.html) |
| PostgreSQL | maximum WAL senders | 10 (default) | configurable (`max_wal_senders`) | how many replication connections are in use already? | [docs](https://www.postgresql.org/docs/current/runtime-config-replication.html) |
| PostgreSQL | WAL file retention (per slot) | unlimited (default) or configurable | configurable (`max_slot_wal_keep_size`) | is max_slot_wal_keep_size set? if not, a stopped reader's slot keeps WAL until the disk fills | [docs](https://www.postgresql.org/docs/current/runtime-config-replication.html) |
| PostgreSQL | wal_level for logical decoding (CDC) | logical | configurable (`wal_level`) | is wal_level already logical? changing it needs a server restart | [docs](https://www.postgresql.org/docs/current/runtime-config-wal.html) |
| PostgreSQL | changing wal_level | server start only | behavior (`wal_level`) | when is the next restart window? | [docs](https://www.postgresql.org/docs/current/runtime-config-wal.html) |

## SQL Server and Oracle (Db2: not yet)

| Product | Limit | Value | Kind | What to ask | Source |
|---|---|---|---|---|---|
| SQL Server | Database size | 524,272 terabytes | hard | How large is the largest database to capture? | [docs](https://learn.microsoft.com/en-us/sql/sql-server/maximum-capacity-specifications-for-sql-server) |
| SQL Server | File size (data) | 16 terabytes | hard | Are data files larger than 16 TB? | [docs](https://learn.microsoft.com/en-us/sql/sql-server/maximum-capacity-specifications-for-sql-server) |
| SQL Server | File size (log) | 2 terabytes | hard | Are transaction log files larger than 2 TB? | [docs](https://learn.microsoft.com/en-us/sql/sql-server/maximum-capacity-specifications-for-sql-server) |
| SQL Server | Databases per instance | 32,767 | hard | How many databases need to be captured? | [docs](https://learn.microsoft.com/en-us/sql/sql-server/maximum-capacity-specifications-for-sql-server) |
| SQL Server | Columns per table | 1,024 | hard | Any tables with more than 1,024 columns? | [docs](https://learn.microsoft.com/en-us/sql/sql-server/maximum-capacity-specifications-for-sql-server) |
| SQL Server | Bytes per row | 8,060 | hard | Any rows wider than 8,060 bytes of fixed-length columns? | [docs](https://learn.microsoft.com/en-us/sql/sql-server/maximum-capacity-specifications-for-sql-server) |
| SQL Server | Identifier length | 128 characters | hard | Any table or column names longer than 128 characters? | [docs](https://learn.microsoft.com/en-us/sql/sql-server/maximum-capacity-specifications-for-sql-server) |
| SQL Server | Capture instances per table | 2 | hard | how many capture instances are already on each table? the limit is 2 | [docs](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sys-sp-cdc-enable-table-transact-sql) |
| SQL Server | CDC available in | Enterprise, Standard editions | behavior | which SQL Server edition? | [docs](https://learn.microsoft.com/en-us/sql/sql-server/editions-and-components-of-sql-server-2022) |
| SQL Server | Filegroups per database | 32,767 | hard | How many filegroups are in the databases? | [docs](https://learn.microsoft.com/en-us/sql/sql-server/maximum-capacity-specifications-for-sql-server) |
| SQL Server | Files per database | 32,767 | hard | How many data and log files are in the databases? | [docs](https://learn.microsoft.com/en-us/sql/sql-server/maximum-capacity-specifications-for-sql-server) |
| Oracle Database | Bigfile tablespace datafile size (32 KB blocks) | 128 terabytes | hard | Are any tablespaces larger than the datafile size limit? | [docs](https://docs.oracle.com/en/database/oracle/oracle-database/21/refrn/physical-database-limits.html) |
| Oracle Database | Bigfile tablespace datafile size (8 KB blocks) | 32 terabytes | hard | Are tablespaces using 8 KB blocks larger than 32 TB? | [docs](https://docs.oracle.com/en/database/oracle/oracle-database/21/refrn/physical-database-limits.html) |
| Oracle Database | Smallfile tablespace datafiles per tablespace | 1,023 | hard | Any smallfile tablespaces with more than 1,023 datafiles? | [docs](https://docs.oracle.com/en/database/oracle/oracle-database/21/refrn/physical-database-limits.html) |
| Oracle Database | Columns per table | 1,000 | hard | Any tables with more than 1,000 columns? | [docs](https://docs.oracle.com/en/database/oracle/oracle-database/21/refrn/logical-database-limits.html) |
| Oracle Database | Partitions per table or index | 1,048,575 | hard | Any tables or indexes with more than 1 million partitions? | [docs](https://docs.oracle.com/en/database/oracle/oracle-database/21/refrn/logical-database-limits.html) |
| Oracle Database | Columns per index | 32 | hard | Any indexes with more than 32 columns? | [docs](https://docs.oracle.com/en/database/oracle/oracle-database/21/refrn/logical-database-limits.html) |
| Oracle Database Free | user data on disk | 12 GB | hard | is the test database Oracle Free? more than 12 GB of tables and indexes needs another edition | [docs](https://www.oracle.com/database/free/faq/) |

## Managed services (RDS, Aurora, Azure SQL, Azure flexible server, Cloud SQL)

| Product | Limit | Value | Kind | What to ask | Source |
|---|---|---|---|---|---|
| Amazon RDS for PostgreSQL | maximum connections (configurable) | 6–262143 | configurable (`max_connections`) | how many connections are free for the CDC reader? | [docs](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html) |
| Amazon RDS for MySQL | maximum connections (configurable) | 1–100000 | configurable (`max_connections`) | how many connections are free for the CDC reader? | [docs](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html) |
| Amazon RDS for MariaDB | maximum connections (configurable) | 1–100000 | configurable (`max_connections`) | how many connections are free for the CDC reader? | [docs](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html) |
| Amazon RDS for SQL Server | maximum connections (configurable) | 0–32767 | configurable (`user connections`) | how many connections are free for the CDC reader? | [docs](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html) |
| Amazon RDS for Oracle | maximum user processes | 80–20000 | configurable (`processes`) | how many sessions are free for the CDC reader? | [docs](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html) |
| Amazon RDS for Oracle | maximum database sessions | 100–65535 | configurable (`sessions`) | how many sessions are free for the CDC reader? | [docs](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html) |
| Amazon RDS (all engines) | DB instances per region | 40 | soft | how many RDS instances in the region? raisable through Service Quotas | [docs](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html) |
| Amazon RDS (all engines) | total storage per region (EBS) | 100000 GB (100 TB) | soft | how much RDS storage is already used in the region? raisable through Service Quotas | [docs](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html) |
| Amazon Aurora | cluster storage capacity | 128 TiB | hard | more than 128 TiB in one Aurora cluster isn't possible: how is it split? | [docs](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html) |
| Amazon Aurora | read replicas per primary DB instance | 15 | hard | will CDC read a replica? how many replicas exist? | [docs](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html) |
| Amazon RDS for Db2 | maximum connections | 64000 | hard | how many connections are free for the CDC reader? | [docs](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html) |
| Google Cloud SQL for PostgreSQL | maximum table size | 32 TB | hard | how big is the largest table? | [docs](https://cloud.google.com/sql/docs/postgres/quotas) |
| Google Cloud SQL (dedicated core) | maximum instance storage | 64 TB | hard | how big is the instance? more than the tier's cap means several instances | [docs](https://cloud.google.com/sql/docs/postgres/quotas) |
| Google Cloud SQL (shared core) | maximum instance storage | 3 TB | hard | how big is the instance? more than the tier's cap means several instances | [docs](https://cloud.google.com/sql/docs/postgres/quotas) |
| Azure SQL Database (General Purpose, Business Critical) | maximum database storage | 4 TB | hard | how big is the database, and which service tier? | [docs](https://learn.microsoft.com/en-us/azure/azure-sql/database/service-tiers-sql-database-vcore) |
| Azure SQL Database (Hyperscale) | maximum database storage | 128 TB | hard | how big is the database, and which service tier? | [docs](https://learn.microsoft.com/en-us/azure/azure-sql/database/service-tiers-sql-database-vcore) |
| Azure SQL Database (Hyperscale) | maximum elastic pool size | 100 TB | hard | is it in an elastic pool? how big is the pool? | [docs](https://learn.microsoft.com/en-us/azure/azure-sql/database/service-tier-hyperscale) |
| Azure SQL Managed Instance | maximum instance storage (General Purpose) | 32 TB | hard | how big is the managed instance, and which tier? | [docs](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/resource-limits) |
| Azure SQL Managed Instance | maximum instance storage (Business Critical) | 16 TB | hard | how big is the managed instance, and which tier? | [docs](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/resource-limits) |
| Azure SQL Database (Logical Server) | maximum databases per server | 5000 | hard | how many databases on the logical server? | [docs](https://learn.microsoft.com/en-us/azure/azure-sql/database/resource-limits-logical-server) |
| Azure Database for PostgreSQL Flexible Server | maximum connections (B12ms+) | 5000 | hard | how many connections are free for the CDC reader? | [docs](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-limits) |
| Azure Database for PostgreSQL Flexible Server | storage scaling behavior | 2x increments only | hard | how much headroom for WAL while CDC is stopped? | [docs](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-limits) |
| Azure Database for PostgreSQL Flexible Server | storage reduction capability | not supported | hard | storage only grows: plan the test's size up front | [docs](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-limits) |
| Azure Database for PostgreSQL Flexible Server | read-only mode threshold | 95% storage | behavior | how much free storage is there? a slot holding WAL can make the server read-only | [docs](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-limits) |
| Azure SQL Database (Hyperscale) | log rate (other hardware) | 100 MiB/s | hard | what change rate (MiB/s of log) at peak? | [docs](https://learn.microsoft.com/en-us/azure/azure-sql/database/resource-limits-logical-server) |
| Amazon RDS (PostgreSQL, MySQL, MariaDB, Db2) | storage per DB instance | 64 TiB | hard | more than 64 TiB on RDS PostgreSQL or MySQL can't be one instance: is it Aurora (128 TiB), self-managed, or several instances? | [docs](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Storage.html) |
| Amazon RDS (Oracle, SQL Server) | storage per DB instance, with additional storage volumes | 256 TiB | hard | over 64 TiB: are additional storage volumes attached? | [docs](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Storage.html) |

## CockroachDB and Debezium (YugabyteDB, Kafka: not yet)

| Product | Limit | Value | Kind | What to ask | Source |
|---|---|---|---|---|---|
| CockroachDB | row size (error threshold) | 80 MiB | configurable (`sql.guardrails.max_row_size_err`) | any rows over 80 MiB (large JSON, blobs)? | [docs](https://www.cockroachlabs.com/docs/stable/cluster-settings) |
| CockroachDB | row size (log threshold) | 16 MiB | configurable (`sql.guardrails.max_row_size_log`) | any rows over 16 MiB? | [docs](https://www.cockroachlabs.com/docs/stable/cluster-settings) |
| CockroachDB | changefeeds per cluster (recommendation) | 80 | recommended | one changefeed per producer or per shard: how many in total? | [docs](https://www.cockroachlabs.com/docs/stable/create-changefeed) |
| CockroachDB | changefeed memory buffer | 512 MiB | configurable (`changefeed.memory.per_changefeed_limit`) | how many tables and how busy, per changefeed? | [docs](https://www.cockroachlabs.com/docs/stable/create-changefeed) |
| Debezium (every connector) | batch size (maximum records per batch) | 2048 | configurable (`max.batch.size`) | the default batch; raise it with max.batch.size for a busy source | [docs](https://debezium.io/documentation/reference/stable/connectors/postgresql.html) |
| Debezium PostgreSQL | queue size (maximum records in queue) | 8192 | configurable (`max.queue.size`) | a busy source: max.queue.size must be larger than max.batch.size | [docs](https://debezium.io/documentation/reference/stable/connectors/postgresql.html) |
| Debezium PostgreSQL | snapshot threads (parallel snapshot concurrency) | 1 | configurable (`snapshot.max.threads`) | a large initial snapshot: snapshot.max.threads reads tables in parallel | [docs](https://debezium.io/documentation/reference/stable/connectors/postgresql.html) |
| Debezium Server (Kafka sink) | batch size (maximum bytes per batch) | 1048576 bytes | configurable (`debezium.sink.kafka.producer.batch.size`) |  | [docs](https://debezium.io/documentation/reference/stable/operations/debezium-server.html) |
| Debezium Server (HTTP sink) | batch size (maximum events per HTTP request) | 200 | configurable (`debezium.sink.http.batch.max-size`) |  | [docs](https://debezium.io/documentation/reference/stable/operations/debezium-server.html) |
| Debezium CockroachDB | changefeeds per cluster (per Debezium consolidation) | 80 | recommended | one changefeed per Debezium connector: how many connectors? | [docs](https://debezium.io/documentation/reference/stable/connectors/cockroachdb.html) |
| Debezium (every connector) | queue size in bytes (volume limit) | 0 (disabled) | configurable (`max.queue.size.in.bytes`) | large rows: cap the queue by bytes (max.queue.size.in.bytes) to bound memory | [docs](https://debezium.io/documentation/reference/stable/connectors/postgresql.html) |
| Debezium PostgreSQL | poll interval (CDC poll frequency) | 500 ms | configurable (`poll.interval.ms`) | how low must latency be? | [docs](https://debezium.io/documentation/reference/stable/connectors/postgresql.html) |
| Debezium (every connector) | incremental snapshot chunk size (rows per snapshot iteration) | 1024 | configurable (`incremental.snapshot.chunk.size`) | a backfill while streaming: rows per chunk | [docs](https://debezium.io/documentation/reference/stable/connectors/postgresql.html) |
| Debezium Server (Zerobus sink) | open Zerobus streams | 100 | configurable (`debezium.sink.zerobus.max.open.streams`) | per-table bronze over 100 tables: raise the setting or expect streams to close and reopen | [docs](https://debezium.io/documentation/reference/stable/operations/debezium-server.html) |
