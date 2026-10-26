# YugabyteDB

`SOURCE=yb` runs the same test on YugabyteDB 2026.1.2.0 (`yugabytedb/yugabyte:2026.1.2.0-b137`), tables in a schema named `shop`. All 30 claims passed on 2026-10-21 (run 1792582605, commit `96c5547`, from `run-all.sh`).

**What works:**

| Step | How |
|---|---|
| T | Create the publication and the logical replication slot first (`pg_create_logical_replication_slot('dbz_slot', 'pgoutput')`). The slot's consistent snapshot is `pg_replication_slots.yb_restart_commit_ht`, a hybrid time: shift it right by 12 bits for microseconds (it matches `yb_restart_time`). Logical replication is on by default in 2026.1 (`wal_level=logical`, `yb_enable_replication_commands=on`) |
| Snapshot as of T | `SET yb_read_time TO <microseconds>`, then `COPY (SELECT * FROM shop.<table>) TO STDOUT WITH (FORMAT csv, HEADER)`. A row updated after the slot was created still reads as it was at T. Silver reads the CSV with `read_files(..., format => 'csv', header => true)` |
| Schema | `remote_query` on a POSTGRESQL UC connection (port 5433, user `yugabyte`) |
| History truth | An audit trigger writes every change to `shop.audit`, which isn't in the publication |

**Debezium Server 3.7 can't read the slot** (tested 2026-10-20):

| Connector in Debezium Server 3.7.0.Final | Result |
|---|---|
| Debezium's PostgreSQL connector | Fails and retries forever: "ERROR: pg_current_wal_lsn() is not yet supported", [yugabyte-db#30243](https://github.com/yugabyte/yugabyte-db/issues/30243) |
| Yugabyte's connector `dz.2.5.2.yb.2026.1.2.0.1`, in place of the PostgreSQL connector jar | Doesn't start: `ClassNotFoundException: io.debezium.connector.postgresql.PostgresConnector` (Quarkus expects it) |
| The same jar next to the PostgreSQL connector jar | Starts and connects to Zerobus, but the engine never runs (health `DOWN`): the jar bundles Debezium core 2.5.2 |

**So `SINK=kafka`** (the default for `SOURCE=yb`): Kafka Connect, without a broker, runs Yugabyte's connector, which is built for Kafka Connect. Its producer writes straight to Zerobus's Kafka-compatible endpoint.

| Piece | How |
|---|---|
| Kafka Connect | `apache/kafka:3.7.2`, `connect-standalone.sh`: offsets in a file, so no broker. The worker's admin client only describes the cluster, which Zerobus answers; `topic.creation.enable=false` |
| Producer settings | `bootstrap.servers=<workspace-id>.zerobus.<region>.<domain>:9092`, `SASL_SSL`, `OAUTHBEARER`, `acks=all`, `compression.type=none`, `enable.idempotence=false`; the same for `admin.` and `producer.` |
| Token | `sasl.login.callback.handler.class=io.debezium.server.databricks.zerobus.ZerobusOAuthBearerLoginCallbackHandler`, from Debezium's Zerobus sink jar on the worker's `CLASSPATH`. JAAS options `clientId`, `clientSecret`, `workspaceUrl`, `workspaceId`, `tables`: it mints and refreshes the table-scoped token |
| Workspace | The `zerobus_kafka_endpoint` preview on (**zerobus-workspace-setup** `enable.sh kafka --apply`); without it, SASL fails with error 4062 |
| Record shape | The Kafka API ingests only the record value. `HoistField` wraps the event as `value`, `InsertField` adds the topic as `destination`, [`StringifyField`](../scripts/kafka-connect/StringifyField.java) (in this skill, built with `javac` on the VM) makes `value` JSON text, and `RegexRouter` sends every topic to `<catalog>.<schema>.cdc_log`. A nested object for a `VARIANT` column is refused: "invalid type: map, expected a string" (error 4044) |
| Source | The tables get `REPLICA IDENTITY DEFAULT` before the slot is created. `pgoutput` refuses YugabyteDB's default `CHANGE` ("replica identity CHANGE ... is not supported for output plugin pgoutput"), and a slot keeps the identity it was created with. `decimal.handling.mode=string`, `snapshot.mode=never` |

**What's different from the Debezium Server route:**
- **Bronze has two columns**, `destination` and `value` (`VARIANT`). The pipeline reads it through `cdc_log_norm`, which gives both routes the same shape:
  - the operation comes from `value:op`;
  - a delete's key comes from `before`, because its `after` is a JSON null, which `COALESCE` keeps;
  - the sequence is `source.lsn`. It follows commit order, and the snapshot is sequence 0. That's better than CockroachDB, whose connector drops the commit time.
- **No replays after a restart:** 5 changes, 5 rows. Kafka Connect resumed from the slot's confirmed position. SCD type 2 without deduplication matched the history exactly (15 of 15).
- **An added column isn't resent** (PostgreSQL protocol). Rows from the snapshot, and changes made before the `ALTER`, have no field. Silver uses the column's default, read through the connection, when the field is missing, but keeps an explicit JSON null as NULL.
- **Event size:** about 690 B per event, with `before`, `source` and `transaction` still in. Kafka Connect has no `DROP_FIELDS` here yet.
