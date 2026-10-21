# silver-from-schema.py: a Lakeflow Spark Declarative Pipelines source file that builds silver from the canonical
# schema (statschema's schema.yaml, from the lfc-source-statschema skill) in a Unity Catalog Volume.
#
# For every table in <volume>/_schema/schema.yaml it defines, when the pipeline starts:
#   <table>_snapshot        the snapshot as of T, from <volume>/<table>/ (Parquet or CSV), sequenced by T
#   <table>_changes         the table's events in cdc_log, sequenced by the event's ts_ns
#   <table>_changes_dedup   the same, from cdc_log_dedup (producer replays removed)
#   <table>                 current rows (AUTO CDC, SCD type 1)
#   <table>_history         every version (AUTO CDC, SCD type 2), replays removed
# and, for the table in cdc.nodedup_table, <table>_history_nodedup (SCD type 2 with the replays).
# A column that isn't in <volume>/_schema/schema-at-T.yaml (added after the snapshot) is NULL in the snapshot rows.
# So a schema change is: upload the new schema.yaml, then full-refresh the changed tables. Nothing is regenerated.
#
# Pipeline configuration: cdc.volume (/Volumes/<catalog>/<schema>/<volume>), cdc.t_ns, cdc.dest_prefix (the change
# log's destination is <prefix>.<table>), cdc.snapshot_format (parquet or csv), cdc.nodedup_table (optional).
import yaml
from pyspark import pipelines as dp
from pyspark.sql import functions as F

VOL = spark.conf.get("cdc.volume")
T_NS = int(spark.conf.get("cdc.t_ns"))
DEST = spark.conf.get("cdc.dest_prefix")
FMT = spark.conf.get("cdc.snapshot_format", "parquet")
NODEDUP = spark.conf.get("cdc.nodedup_table", "")


def spark_type(c):
    """statschema's canonical type -> a Databricks SQL type."""
    t = c["type"]
    if t == "decimal":
        return f"DECIMAL({c.get('precision', 38)},{c.get('scale', 0)})"
    return {"integer": "INT", "long": "BIGINT", "float": "FLOAT", "double": "DOUBLE", "boolean": "BOOLEAN",
            "date": "DATE", "timestamp": "TIMESTAMP_NTZ", "timestamptz": "TIMESTAMP", "binary": "BINARY"}.get(t, "STRING")


def load(name):
    with open(f"{VOL}/_schema/{name}") as f:
        return {t["name"]: t["columns"] for t in yaml.safe_load(f)["tables"]}


SCHEMA, AT_T = load("schema.yaml"), load("schema-at-T.yaml")


@dp.temporary_view(name="cdc_log_dedup")
def cdc_log_dedup():
    # a replay has the same key and the same row image as the original; the key alone may be shared by two changes
    return (spark.readStream.table("cdc_log")
            .withColumn("_event_time", F.timestamp_micros(F.expr("value:ts_ns::BIGINT DIV 1000")))
            .withColumn("_after", F.expr("TO_JSON(value:after)"))
            .withWatermark("_event_time", "10 minutes")
            .dropDuplicatesWithinWatermark(["destination", "idempotency_key", "operation", "_after"])
            .drop("_event_time", "_after"))


def define(table, cols):
    keys = [c["name"] for c in cols if c.get("primary_key")]
    in_snap = {c["name"] for c in AT_T.get(table, [])}
    snap_cols = [F.expr(f"CAST({c['name'] if c['name'] in in_snap else 'NULL'} AS {spark_type(c)})").alias(c["name"])
                 for c in cols]
    chg_cols = [F.expr(f"{'key' if c['name'] in keys else 'value:after'}:{c['name']}::{spark_type(c)}").alias(c["name"])
                for c in cols]

    @dp.temporary_view(name=f"{table}_snapshot")
    def snapshot():
        reader = spark.readStream.format("cloudFiles").option("cloudFiles.format", FMT)
        if FMT == "csv":
            reader = reader.option("header", "true")
        return reader.load(f"{VOL}/{table}").select(*snap_cols, F.lit(T_NS).cast("BIGINT").alias("_seq"),
                                                    F.lit("read").alias("_op"))

    def changes(source):
        return (spark.readStream.table(source).where(F.col("destination") == f"{DEST}.{table}")
                .select(*chg_cols, F.expr("value:ts_ns::BIGINT").alias("_seq"), F.col("operation").alias("_op")))

    dp.temporary_view(name=f"{table}_changes")(lambda: changes("cdc_log"))
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
