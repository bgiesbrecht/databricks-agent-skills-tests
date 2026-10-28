# Databricks notebook source
# audit: history of an SCD type 1 Lakeflow Connect destination table, kept in its own pipeline from the table's change
# data feed.
#   audit_log:  every change event (append-only). Flow `live` reads the change feed. With backfill_from set (the schema
#               of an audit pipeline that broke on a full refresh of the table), two one-time flows also run:
#               `backfill_old` copies the old audit_log, and `reconcile_deletes` writes a delete for every id still open
#               in the old log but missing from the table now (deleted between the old pipeline's last run and the
#               refresh; the reload after a full refresh carries inserts only).
#   audit_scd2: AUTO CDC SCD type 2 over audit_log, keyed on id, ordered by the table's commit version. The version
#               keeps counting up across a full refresh of the same table, so old and new events sort correctly.
# Settings: src (the table), backfill_from (optional). `spark` comes from the pipeline runtime.
# ruff: noqa: F821
import dlt
from pyspark.sql import Window
from pyspark.sql import functions as F

SRC = spark.conf.get("src")
OLD = spark.conf.get("backfill_from", "")
META = ["_change_type", "_commit_version", "_commit_timestamp", "_origin"]

dlt.create_streaming_table("audit_log")


@dlt.append_flow(target="audit_log", name="live")
def live():
    return (
        spark.readStream.option("readChangeFeed", "true")
        .table(SRC)
        .withColumn("_origin", F.lit("live"))
    )


if OLD:

    @dlt.append_flow(target="audit_log", name="backfill_old", once=True)
    def backfill_old():
        return spark.read.table(f"{OLD}.audit_log").withColumn("_origin", F.lit("old"))

    @dlt.append_flow(target="audit_log", name="reconcile_deletes", once=True)
    def reconcile_deletes():
        old = spark.read.table(f"{OLD}.audit_log").where(
            "_change_type != 'update_preimage'"
        )
        cols = [c for c in old.columns if c not in META]
        last = (
            old.withColumn(
                "_rn",
                F.row_number().over(
                    Window.partitionBy("id").orderBy(F.col("_commit_version").desc())
                ),
            )
            .where("_rn = 1 AND _change_type != 'delete'")
            .select(*cols)
        )
        v = spark.sql(f"DESCRIBE HISTORY {SRC} LIMIT 1").first()["version"]
        return (
            last.join(spark.read.table(SRC).select("id"), "id", "left_anti")
            .withColumn("_change_type", F.lit("delete"))
            .withColumn("_commit_version", F.lit(v).cast("long"))
            .withColumn("_commit_timestamp", F.current_timestamp())
            .withColumn("_origin", F.lit("reconcile"))
        )


@dlt.view
def log_events():
    return dlt.read_stream("audit_log").where("_change_type != 'update_preimage'")


dlt.create_streaming_table("audit_scd2")
dlt.apply_changes(
    target="audit_scd2",
    source="log_events",
    keys=["id"],
    sequence_by=F.col("_commit_version"),
    apply_as_deletes=F.expr("_change_type = 'delete'"),
    except_column_list=META,
    stored_as_scd_type=2,
)
