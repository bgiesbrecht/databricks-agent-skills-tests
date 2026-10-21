# silver-from-schema.py: a Lakeflow Spark Declarative Pipelines source file that builds silver from the canonical
# schema (statschema's schema.yaml, from the lfc-source-statschema skill) in a Unity Catalog Volume. The one generator
# for every source and every model: nothing in it names a table, a column or a type.
#
# For every table in <volume>/_schema/schema.yaml it defines, when the pipeline starts:
#   <table>_snapshot        the snapshot as of T, from <volume>/<table>/ (Parquet or CSV), sequenced by T
#   <table>_changes         the table's events in cdc_log, sequenced by the event's ts_ns
#   <table>_changes_dedup   the same, from cdc_log_dedup (producer replays removed)
#   <table>                 current rows (AUTO CDC, SCD type 1)
#   <table>_history         every version (AUTO CDC, SCD type 2), replays removed
# and, for the table in cdc.nodedup_table, <table>_history_nodedup (SCD type 2 with the replays). A table without a
# primary key (TPC-B's and TPC-C's history) is append-only: <table> gets the snapshot rows and the inserts, appended.
# Dates, timestamps and times are decoded from either form a producer sends: text (CockroachDB's changefeed, the
# snapshot) or a number (Debezium's PostgreSQL connector: days, epoch milli- or microseconds, microseconds of the day).
# A time is kept as text, HH:mm:ss.SSSSSS.
# A column that isn't in <volume>/_schema/schema-at-T.yaml (added after the snapshot) is NULL in the snapshot rows.
# So a schema change is: upload the new schema.yaml, then full-refresh the changed tables. Nothing is regenerated.
#
# Pipeline configuration: cdc.volume (/Volumes/<catalog>/<schema>/<volume>), cdc.t_ns, cdc.dest_prefix (the change
# log's destination is <prefix>.<table>), cdc.snapshot_format (parquet or csv), cdc.nodedup_table (optional).
import re

import yaml
from pyspark import pipelines as dp
from pyspark.sql import functions as F

VOL = spark.conf.get("cdc.volume")
T_NS = int(spark.conf.get("cdc.t_ns"))
DEST = spark.conf.get("cdc.dest_prefix")
FMT = spark.conf.get("cdc.snapshot_format", "parquet")
NODEDUP = spark.conf.get("cdc.nodedup_table", "")
BRONZE = spark.conf.get("cdc.bronze", "zerobus")   # zerobus: Debezium Server's sink; kafka: Kafka Connect, Kafka API


# the type names the TPC schema files use besides statschema's canonical ones (ddl.py takes the same)
ALIAS = {"int": "integer", "smallint": "integer", "tinyint": "integer", "bigint": "long", "numeric": "decimal",
         "varchar": "string", "text": "string", "real": "float", "double precision": "double", "bool": "boolean"}


def ctype(c):
    return ALIAS.get(c["type"], c["type"])


def spark_type(c):
    """statschema's canonical type -> a Databricks SQL type (char, string, time and the rest: STRING)."""
    t = ctype(c)
    if t == "decimal":
        return f"DECIMAL({c.get('precision') or 38},{c.get('scale') or 0})"
    return {"integer": "INT", "long": "BIGINT", "float": "FLOAT", "double": "DOUBLE", "boolean": "BOOLEAN",
            "date": "DATE", "timestamp": "TIMESTAMP_NTZ", "timestamptz": "TIMESTAMP", "binary": "BINARY"}.get(t, "STRING")


def path(base, n):
    """A VARIANT field: the plain form for simple names, brackets for the rest (TPC-DI's mixed-case names)."""
    return f"{base}:{n}" if re.fullmatch(r"[a-z_][a-z0-9_]*", n) else f"{base}['{n}']"


def decode(c, s):
    """s, a STRING expression with the value as text or a number -> the column's type. A number is Debezium's: days
    for a date; for a timestamp, epoch milliseconds when the column holds 3 digits of fraction or fewer, else
    microseconds (without a precision, a value under 10^14, before 1973 in microseconds, is taken as milliseconds);
    microseconds of the day for a time."""
    t, ty = ctype(c), spark_type(c)
    num = f"{s} RLIKE '^-?[0-9]+$'"
    p = c.get("precision")
    n = f"CAST({s} AS BIGINT)"
    if p is None:
        us = f"CASE WHEN ABS({n}) < 100000000000000 THEN {n} * 1000 ELSE {n} END"
    else:
        us = f"{n} * 1000" if int(p) <= 3 else n
    if t == "date":
        return f"CASE WHEN {num} THEN date_add(DATE'1970-01-01', CAST({s} AS INT)) ELSE CAST({s} AS DATE) END"
    if t == "timestamp":
        return f"CASE WHEN {num} THEN timestampadd(MICROSECOND, {us}, TIMESTAMP_NTZ'1970-01-01 00:00:00') ELSE CAST({s} AS TIMESTAMP_NTZ) END"
    if t == "timestamptz":   # text from PostgreSQL ends +00; Spark takes +00:00
        return (f"CASE WHEN {num} THEN timestamp_micros({us}) "
                f"ELSE CAST(regexp_replace({s}, '([+-][0-9]{{2}})$', '$1:00') AS TIMESTAMP) END")
    if t in ("time", "timetz"):
        tus = f"{n} * 1000" if p is not None and int(p) <= 3 else n
        return (f"date_format(CASE WHEN {num} THEN timestampadd(MICROSECOND, {tus}, TIMESTAMP_NTZ'1970-01-01 00:00:00') "
                f"ELSE CAST(concat('1970-01-01 ', {s}) AS TIMESTAMP_NTZ) END, 'HH:mm:ss.SSSSSS')")
    return f"CAST({s} AS {ty})"


TEMPORAL = ("date", "timestamp", "timestamptz", "time", "timetz")


def load(name):
    with open(f"{VOL}/_schema/{name}") as f:
        return {t["name"]: t["columns"] for t in yaml.safe_load(f)["tables"]}


SCHEMA, AT_T = load("schema.yaml"), load("schema-at-T.yaml")


@dp.temporary_view(name="cdc_log_norm")
def cdc_log_norm():
    """The change log in one shape for both sinks: destination, operation, idempotency_key, key, value, _seq, _event_ns.
    Kafka Connect's records carry only the event: the operation comes from op, the key from after or before, and the
    sequence from the slot's LSN (commit order)."""
    log = spark.readStream.table("cdc_log")
    if BRONZE == "kafka":
        return log.select(
            "destination",
            F.expr("CASE value:op::STRING WHEN 'c' THEN 'create' WHEN 'u' THEN 'update' WHEN 'd' THEN 'delete' "
                   "WHEN 'r' THEN 'read' END").alias("operation"),
            F.expr("value:source:lsn::STRING").alias("idempotency_key"),
            F.expr("CASE value:op::STRING WHEN 'd' THEN value:before ELSE value:after END").alias("key"), "value",
            F.expr("value:source:lsn::BIGINT").alias("_seq"), F.expr("value:ts_ms::BIGINT * 1000000").alias("_event_ns"))
    return log.withColumn("_seq", F.expr("value:ts_ns::BIGINT")).withColumn("_event_ns", F.expr("value:ts_ns::BIGINT"))


@dp.temporary_view(name="cdc_log_dedup")
def cdc_log_dedup():
    # a replay has the same key and the same row image as the original; the key alone may be shared by two changes
    return (spark.readStream.table("cdc_log_norm")
            .withColumn("_event_time", F.timestamp_micros(F.expr("_event_ns DIV 1000")))
            .withColumn("_after", F.expr("TO_JSON(value:after)"))
            .withWatermark("_event_time", "10 minutes")
            .dropDuplicatesWithinWatermark(["destination", "idempotency_key", "operation", "_after"])
            .drop("_event_time", "_after"))


def define(table, cols):
    keys = [c["name"] for c in cols if c.get("primary_key")]
    in_snap = {c["name"] for c in AT_T.get(table, [])}
    # A column added after T is in neither the snapshot nor the changes made before it was added. A PostgreSQL-protocol
    # source doesn't resend old rows when a column is added, so they hold the column's default (a SQL literal in
    # schema.yaml): use it where the field is missing (SQL NULL from the path), not where it's a JSON null.
    def dflt(c):
        return c.get("default") or "NULL"

    def get(base, c):   # a field of the event, as the column's type
        v = path(base, c["name"])
        return decode(c, f"{v}::STRING") if ctype(c) in TEMPORAL else f"{v}::{spark_type(c)}"

    def change(c):
        n, ty = c["name"], spark_type(c)
        if n in keys:
            return get("key", c)
        if c.get("default"):
            return (f"CASE WHEN value:after IS NOT NULL AND NOT is_variant_null(value:after) AND {path('value:after', n)} IS NULL "
                    f"THEN CAST({c['default']} AS {ty}) ELSE {get('value:after', c)} END")
        return get("value:after", c)

    def snap(c):
        if c["name"] not in in_snap:
            return f"CAST({dflt(c)} AS {spark_type(c)})"
        x = f"`{c['name']}`"
        return decode(c, f"CAST({x} AS STRING)") if ctype(c) in TEMPORAL else f"CAST({x} AS {spark_type(c)})"
    snap_cols = [F.expr(snap(c)).alias(c["name"]) for c in cols]
    chg_cols = [F.expr(change(c)).alias(c["name"]) for c in cols]

    @dp.temporary_view(name=f"{table}_snapshot")
    def snapshot():
        reader = spark.readStream.format("cloudFiles").option("cloudFiles.format", FMT)
        if FMT == "csv":
            reader = reader.option("header", "true")
        return reader.load(f"{VOL}/{table}").select(*snap_cols, F.lit(T_NS).cast("BIGINT").alias("_seq"),
                                                    F.lit("read").alias("_op"))

    def changes(source):
        return (spark.readStream.table(source).where(F.col("destination") == f"{DEST}.{table}")
                .select(*chg_cols, F.col("_seq"), F.col("operation").alias("_op")))

    dp.temporary_view(name=f"{table}_changes")(lambda: changes("cdc_log_norm"))
    if not keys:   # append-only: the snapshot rows, then each insert (a table without a key gets no updates or deletes)
        dp.create_streaming_table(name=table)
        dp.append_flow(target=table, name=f"{table}_from_snapshot")(
            lambda: spark.readStream.table(f"{table}_snapshot").drop("_seq", "_op"))
        dp.append_flow(target=table, name=f"{table}_from_changes")(
            lambda: spark.readStream.table(f"{table}_changes").where("_op = 'create'").drop("_seq", "_op"))
        return
    dp.temporary_view(name=f"{table}_changes_dedup")(lambda: changes("cdc_log_dedup"))

    targets = [(table, 1, f"{table}_changes"), (f"{table}_history", 2, f"{table}_changes_dedup")]
    if table == NODEDUP:
        targets.append((f"{table}_history_nodedup", 2, f"{table}_changes"))
    for target, scd, change_view in targets:
        dp.create_streaming_table(name=target, cluster_by=keys)
        dp.create_auto_cdc_flow(name=f"{target}_from_snapshot", target=target, source=f"{table}_snapshot", keys=keys,
                                sequence_by="_seq", except_column_list=["_seq", "_op"], stored_as_scd_type=scd)
        dp.create_auto_cdc_flow(name=f"{target}_from_changes", target=target, source=change_view, keys=keys,
                                sequence_by="_seq", apply_as_deletes=F.expr("_op = 'delete'"),
                                except_column_list=["_seq", "_op"], stored_as_scd_type=scd)


for name, columns in SCHEMA.items():
    define(name, columns)
