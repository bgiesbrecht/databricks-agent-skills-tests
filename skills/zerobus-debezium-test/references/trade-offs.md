# Trade-offs: detail

What silver gives up, and where, so a result can be read for what it is:

- **T while nothing writes (PostgreSQL, SQL Server, Oracle).** The snapshot is consistent only because the test stops writing between the fill and the snapshot. A source with live traffic would need the snapshot tied to the log position: PostgreSQL's exported snapshot from the slot, SQL Server's and Oracle's flashback or snapshot isolation.
- **SQL Server's sequence fits a BIGINT only while the log's file number is below 2^15.** `change_lsn` is 10 bytes; silver packs the three parts into 64 bits, which a test database never outgrows.

- **Foreign key actions applied after each update (`fk-actions.py`).** Silver re-applies what MySQL through 9.5 doesn't log, from the rules in the collected schema:
  - **Source rules only:** they have to match the source's. A rule added at the source after the schema was collected isn't applied until the schema is collected again.
  - **At the update, not at the parent's sequence:** between an update and the step after it, silver has the child rows; a reader then sees them. The history's version ends at the parent's last version's end (its delete) when the parent keeps history, else at the version's own start.
  - **DML on the pipeline's tables:** the step deletes and updates rows in tables AUTO CDC builds (Databricks allows it). A full refresh rebuilds them from bronze, orphans included, and the step after it removes them again.
  - **A consistent point:** the rule holds when silver has every source change up to some position; a parent's delete in bronze whose child's earlier insert isn't yet in silver can't happen with one ordered log per source (one producer per source database).
  - **Not handled:** `ON UPDATE CASCADE`, SET DEFAULT, and a parent's primary key change (Debezium sends it as a delete and an insert). Mautic has none of these.
  - **Turned off** for logs that carry the changes (`FK_ACTIONS=logged`).

- **Replays and identical changes.** A producer resends changes after a restart, under a new sequence. Silver drops a change as a replay when it has the same event (destination, key, operation, row image, and idempotency key where the producer gives one) within 10 minutes of one already applied (the pipeline's dedup watermark; `merge-silver.py`'s `REPLAY_NS`). So:
  - in the history (SCD type 2), a real update that sets a row to the same values within 10 minutes counts once; the history check counts consecutive identical versions once on both sides;
  - in a table without a key (append-only), two identical rows inserted within 10 minutes count as one;
  - current rows (SCD type 1) keep every change: a replay comes in order with a newer sequence and converges.
  - the history checks pass a key whose versions, with consecutive identical ones counted once, are the source's, as long as silver has no more versions than the source (a replay it failed to drop is one more);
  CockroachDB's connector on the Kafka route gives no idempotency key, so there replays are matched on the row image alone: a key deleted, reinserted and deleted again within 10 minutes has its second delete taken for a replay in the history (the reinserted version stays open). Current rows and the tombstones keep every delete. Debezium Server's key isn't unique per change either ([Round 3](rounds.md#round-3-debezium-killed-and-restarted)), so it's never used on its own.
- **Sequence.** CockroachDB's connector drops the commit time, so silver orders by `ts_ns`, when Debezium processed the change. Each key's changes stay in order, and the snapshot (sequenced by T, the database's clock) compares correctly only while the two clocks agree.
- **Timestamps as numbers.** A timestamp column without a declared precision is read as microseconds (6 digits, PostgreSQL's and CockroachDB's default). A producer that sends milliseconds for such a column (Debezium's `time.precision.mode=connect`) would be read wrong.
- **Schema drift on record.** Until a table is evolved and refreshed, a value its column type can't hold is NULL, a dropped column gets its default, and a new column waits. A refresh rebuilds the table from its snapshot and every change since T, so the change log has to be kept back to T.
- **MERGE in place of AUTO CDC.**
  - Every delete is kept (`_cdc_tombstones`), as is every appended fingerprint (`_cdc_appended`): they grow with the deletes and inserts. AUTO CDC drops its tombstones after a set time.
  - Silver tables carry `_seq` (current rows) and `_idem` (history), which AUTO CDC keeps hidden.
  - A batch rewrites the end of every version of each key it touches, from that key's whole history: more work for keys with long histories.
  - There's no `_history_nodedup` table.
- **Producers sharded.** Each Debezium Server has its own changefeed (CockroachDB recommends a maximum per cluster: lfc-source-sizing's limits), the servers start one after another (start-up grows with their number), and commit order holds per key, not across servers.
- **Own bronze on the direct route.** Debezium Server's Zerobus sink writes one table, so a table's own bronze is copied from the shared log by the fan-out: one more hop, and its changes stored twice.
- **Silver across schemas (`SPLIT`).** Readers and gold name each table's schema.
- **The Kafka route.** Zerobus's Kafka API takes the record value only, so the event is wrapped (`HoistField`, `StringifyField`) and nothing is dropped from it (no `DROP_FIELDS`): larger events than the direct route's.
- **Retries.** A call that fails to connect is retried, up to 5 times with backoff: ssh to the VM when ssh itself can't connect (the input is kept, so a retry gets all of it), and the Databricks CLI when the request was never sent (DNS, refused, dial, TLS handshake) or the workspace answered that it's temporarily unavailable (a 503, which a volume upload got once: the request wasn't taken). A connection lost after a request was sent isn't retried for a create or a run-now, which may have gone through; a read (get, list) is, after a timeout or reset too, since sending it again changes nothing (a job run's poll timed out once and failed a table move).
- **Test data on CockroachDB.** For the PostgreSQL dialect the generator casts `POWER`'s arguments, and any expression plus or minus a decimal constant, to double precision (CockroachDB doesn't mix float and decimal). On plain PostgreSQL that arithmetic was NUMERIC before, so a generated value can differ in its last digits, or round to the other side of an exact `FLOOR` boundary.
