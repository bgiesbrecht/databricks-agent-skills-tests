# merge-silver.py: silver without a pipeline. A serverless job (spark_python_task) builds the same silver tables as
# silver-from-schema.py, from the same volume (_sources.yaml, _schema/, _snapshot.tsv, the snapshot files) and the same
# change log, with MERGE instead of AUTO CDC. A pipeline declares every table, view and flow when each update starts,
# so its start-up grows with the number of tables, and a pipeline holds only so many; here nothing is declared per
# table: one stream reads the change log, and each micro-batch MERGEs only the tables that changed in it.
#
#   merge-silver.py --volume /Volumes/<c>/<s>/<v> --source <c>.<s>.cdc_log --target <c>.<s> --checkpoint <dir>
#                   [--bronze zerobus|kafka] [--shard i/n] [--history-suffix _history] [--threads 16]
#                   [--create eager|lazy] [--once]
#
# Tables: <t> (current rows, SCD type 1) and <t><history-suffix> (every version, SCD type 2, __START_AT/__END_AT: the
# version's sequence and the next one's) for a table with a key; <t> append-only for one without. Each row has _source
# and, in <t>, _seq (its change's sequence: AUTO CDC keeps it hidden, MERGE needs it in the row). --create eager
# creates every table at the start (with its snapshot rows); lazy creates a table when it first has rows.
# Ordering, as AUTO CDC's: a change applies only when its sequence is newer than the row's; a delete leaves a
# tombstone (_cdc_tombstones: table, source, key, sequence), so a replayed older change can't bring the row back.
# SCD type 2: replays (same key and sequence) are dropped; each new version closes the open one. Not handled yet: a
# version older than one already in the history (out of order across batches), and schema drift (schema_drift).
# --shard i/n: only the tables with crc32(name) % n == i (silver-from-schema.py's rule), so n jobs share the work.
# The helpers below are silver-from-schema.py's (types, VARIANT paths, temporal decoding), so both build the same rows.
import argparse
import os
import re
import time
import zlib
from concurrent.futures import ThreadPoolExecutor

import yaml
from pyspark.sql import SparkSession
from pyspark.sql import functions as F

ap = argparse.ArgumentParser()
ap.add_argument("--volume", required=True)
ap.add_argument("--source", required=True)
ap.add_argument("--target", required=True)
ap.add_argument("--checkpoint", required=True)
ap.add_argument("--bronze", default="zerobus")
ap.add_argument("--shard", default="")
ap.add_argument("--history-suffix", default="_history")
ap.add_argument("--threads", type=int, default=16)
ap.add_argument("--create", default="eager", choices=["eager", "lazy"])
ap.add_argument("--once", action="store_true")
a = ap.parse_args()
spark = SparkSession.builder.getOrCreate()
VOL, TGT, HIST = a.volume, a.target, a.history_suffix
log = lambda *m: print(time.strftime("%H:%M:%S"), *m, flush=True)   # noqa: E731

ALIAS = {"int": "integer", "smallint": "integer", "tinyint": "integer", "bigint": "long", "numeric": "decimal",
         "varchar": "string", "text": "string", "real": "float", "double precision": "double", "bool": "boolean"}
TEMPORAL = ("date", "timestamp", "timestamptz", "time", "timetz")


def ctype(c):
    return ALIAS.get(c["type"], c["type"])


def spark_type(c):
    t = ctype(c)
    if t == "decimal":
        return f"DECIMAL({c.get('precision') or 38},{c.get('scale') or 0})"
    return {"integer": "INT", "long": "BIGINT", "float": "FLOAT", "double": "DOUBLE", "boolean": "BOOLEAN",
            "date": "DATE", "timestamp": "TIMESTAMP_NTZ", "timestamptz": "TIMESTAMP", "binary": "BINARY"}.get(t, "STRING")


def path(base, n):
    return f"{base}:{n}" if re.fullmatch(r"[a-z_][a-z0-9_]*", n) else f"{base}{'' if ':' in base else ':'}['{n}']"


def decode(c, s, cast="CAST"):
    t, ty = ctype(c), spark_type(c)
    num = f"{s} RLIKE '^-?[0-9]+$'"
    p = c.get("precision")
    n = f"CAST({s} AS BIGINT)"
    us = (f"CASE WHEN ABS({n}) < 100000000000000 THEN {n} * 1000 ELSE {n} END" if p is None
          else f"{n} * 1000" if int(p) <= 3 else n)
    if t == "date":
        return f"CASE WHEN {num} THEN date_add(DATE'1970-01-01', CAST({s} AS INT)) ELSE {cast}({s} AS DATE) END"
    if t == "timestamp":
        return (f"CASE WHEN {num} THEN timestampadd(MICROSECOND, {us}, TIMESTAMP_NTZ'1970-01-01 00:00:00') "
                f"ELSE {cast}({s} AS TIMESTAMP_NTZ) END")
    if t == "timestamptz":
        return (f"CASE WHEN {num} THEN timestamp_micros({us}) "
                f"ELSE {cast}(regexp_replace({s}, '([+-][0-9]{{2}})$', '$1:00') AS TIMESTAMP) END")
    if t in ("time", "timetz"):
        tus = f"{n} * 1000" if p is not None and int(p) <= 3 else n
        return (f"date_format(CASE WHEN {num} THEN timestampadd(MICROSECOND, {tus}, TIMESTAMP_NTZ'1970-01-01 00:00:00') "
                f"ELSE {cast}(concat('1970-01-01 ', {s}) AS TIMESTAMP_NTZ) END, 'HH:mm:ss.SSSSSS')")
    return f"{cast}({s} AS {ty})"


def typed(c, v, cast):
    return decode(c, f"{v}::STRING", cast) if ctype(c) in TEMPORAL else f"{cast}({v} AS {spark_type(c)})"


def load():
    with open(f"{VOL}/_schema/schema.yaml") as f:
        out = {t["name"]: t["columns"] for t in yaml.safe_load(f)["tables"]}
    d = f"{VOL}/_schema/tables"
    for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if name.endswith(".yaml"):
            with open(f"{d}/{name}") as f:
                out.update({t["name"]: t["columns"] for t in yaml.safe_load(f)["tables"]})
    return out


with open(f"{VOL}/_sources.yaml") as f:
    _S = yaml.safe_load(f)
SOURCES = _S["sources"]
SOURCE_KEY = bool(_S.get("source_key", len(SOURCES) > 1))
T_NS = {s["prefix"]: int(s["t_ns"]) for s in SOURCES}
SCHEMA = load()
if a.shard:
    _i, _n = (int(x) for x in a.shard.split("/"))
    SCHEMA = {t: c for t, c in SCHEMA.items() if zlib.crc32(t.encode()) % _n == _i}
LOWER = {t.lower(): t for t in SCHEMA}
SNAP = set()
if os.path.exists(f"{VOL}/_snapshot.tsv"):
    with open(f"{VOL}/_snapshot.tsv") as f:
        SNAP = {(r[0], r[1], r[2]) for r in (x.rstrip("\n").split("\t") for x in f) if len(r) == 4 and int(r[3]) > 0}


def q(n):
    return f"`{n}`"


def pk(table):
    return [c["name"] for c in SCHEMA[table] if c.get("primary_key")]


def keys(table):
    k = pk(table)
    return (["_source"] + k) if SOURCE_KEY and k else k


def ddl(table):
    """CREATE TABLE IF NOT EXISTS statements for the table's silver tables."""
    cols = ", ".join(f"{q(c['name'])} {spark_type(c)}" for c in SCHEMA[table])
    # row tracking and deletion vectors: a materialized view over the table can refresh incrementally (MERGE updates
    # and deletes rows, so the view needs to know which)
    props = ("TBLPROPERTIES ('delta.feature.timestampNtz' = 'supported', 'delta.enableRowTracking' = 'true', "
             "'delta.enableDeletionVectors' = 'true')")
    k = keys(table)
    if not k:
        return [f"CREATE TABLE IF NOT EXISTS {TGT}.{q(table)} ({cols}, _source STRING) {props}"]
    cb = ", ".join(q(x) for x in k)
    return [f"CREATE TABLE IF NOT EXISTS {TGT}.{q(table)} ({cols}, _source STRING, _seq BIGINT) CLUSTER BY ({cb}) {props}",
            f"CREATE TABLE IF NOT EXISTS {TGT}.{q(table + HIST)} ({cols}, _source STRING, __START_AT BIGINT, __END_AT BIGINT) "
            f"CLUSTER BY ({cb}) {props}"]


def snapshot(table):
    """The table's snapshot rows from every source, typed, with _source, _seq (the source's T) and _op 'read'."""
    parts = []
    for s in SOURCES:
        fmt = s.get("format", "parquet")
        if (table, s["prefix"], fmt) not in SNAP:
            continue
        r = spark.read.format(fmt)
        if fmt == "csv":
            r = r.option("header", "true")
        df = r.load(f"{VOL}/{table}/{s['prefix']}/*.{fmt}")
        have = set(df.columns)
        sel = []
        for c in SCHEMA[table]:
            if c["name"] not in have:
                sel.append(F.expr(f"CAST({c.get('default') or 'NULL'} AS {spark_type(c)})").alias(c["name"]))
            elif ctype(c) in TEMPORAL:
                sel.append(F.expr(decode(c, f"CAST({q(c['name'])} AS STRING)")).alias(c["name"]))
            else:
                sel.append(F.expr(f"CAST({q(c['name'])} AS {spark_type(c)})").alias(c["name"]))
        parts.append(df.select(*sel, F.lit(s["prefix"]).alias("_source"), F.lit(T_NS[s["prefix"]]).alias("_seq"),
                               F.lit("read").alias("_op")))
    out = None
    for p in parts:
        out = p if out is None else out.unionByName(p)
    return out


def changes(batch, table):
    """The table's events in a normalized batch, typed (TRY_CAST: a value that doesn't fit becomes NULL)."""
    k = pk(table)
    sel = []
    for c in SCHEMA[table]:
        n = c["name"]
        if n in k:
            sel.append(F.expr(typed(c, path("key", n), "CAST")).alias(n))
        elif c.get("default"):
            sel.append(F.expr(f"CASE WHEN value:after IS NOT NULL AND NOT is_variant_null(value:after) AND {path('value:after', n)} "
                              f"IS NULL THEN CAST({c['default']} AS {spark_type(c)}) ELSE {typed(c, path('value:after', n), 'TRY_CAST')} END").alias(n))
        else:
            sel.append(F.expr(typed(c, path("value:after", n), "TRY_CAST")).alias(n))
    return (batch.where(F.col("_table") == table)
            .select(*sel, F.expr(f"substring(destination, 1, length(destination) - {len(table) + 1})").alias("_source"),
                    "_seq", F.col("operation").alias("_op")))


def apply(table, rows):
    """MERGE the table's rows (snapshot or changes: columns, _source, _seq, _op) into its silver tables."""
    k = keys(table)
    cols = [c["name"] for c in SCHEMA[table]]
    if not k:   # append-only: the snapshot rows and the inserts
        rows.where("_op IN ('read', 'create')").drop("_seq", "_op").write.mode("append").saveAsTable(f"{TGT}.{q(table)}")
        return
    on = " AND ".join(f"t.{q(x)} <=> s.{q(x)}" for x in k)
    kj = f"to_json(named_struct({', '.join(f'{chr(39)}{x}{chr(39)}, {q(x)}' for x in pk(table))}))"
    # replays: the same key, sequence and operation once; tombstones: a change no newer than the key's delete goes
    rows = rows.dropDuplicates(k + ["_seq", "_op"]).withColumn("_k", F.expr(kj))
    tomb = spark.table(f"{TGT}._cdc_tombstones").where(F.col("tbl") == table)
    rows = (rows.alias("r").join(tomb.alias("x"), (F.col("r._source") == F.col("x._source")) & (F.col("r._k") == F.col("x.k")), "left")
            .where("x._seq IS NULL OR r._seq > x._seq").select("r.*"))
    rows.createOrReplaceTempView(f"_r_{abs(hash(table))}")
    v = f"_r_{abs(hash(table))}"
    # SCD type 1: each key's newest change, applied when newer than the row
    last = f"(SELECT * FROM {v} QUALIFY ROW_NUMBER() OVER (PARTITION BY {', '.join(q(x) for x in k)} ORDER BY _seq DESC) = 1)"
    sets = ", ".join(f"t.{q(c)} = s.{q(c)}" for c in cols + ["_source", "_seq"])
    ins = ", ".join(q(c) for c in cols + ["_source", "_seq"])
    spark.sql(f"""MERGE INTO {TGT}.{q(table)} t USING {last} s ON {on}
      WHEN MATCHED AND s._seq > t._seq AND s._op = 'delete' THEN DELETE
      WHEN MATCHED AND s._seq > t._seq THEN UPDATE SET {sets}
      WHEN NOT MATCHED AND s._op <> 'delete' THEN INSERT ({ins}) VALUES ({', '.join('s.' + q(c) for c in cols + ['_source', '_seq'])})""")
    # tombstones: each key's newest delete
    spark.sql(f"""MERGE INTO {TGT}._cdc_tombstones t
      USING (SELECT '{table}' AS tbl, _source, _k AS k, MAX(_seq) AS _seq FROM {v} WHERE _op = 'delete' GROUP BY _source, _k) s
      ON t.tbl = s.tbl AND t._source = s._source AND t.k = s.k
      WHEN MATCHED AND s._seq > t._seq THEN UPDATE SET t._seq = s._seq
      WHEN NOT MATCHED THEN INSERT (tbl, _source, k, _seq) VALUES (s.tbl, s._source, s.k, s._seq)""")
    # SCD type 2: the batch's versions (each ends at the key's next change), then the open version closed by the
    # key's first change in the batch; versions already there (a replayed batch) aren't inserted again
    pkeys = ", ".join(q(x) for x in k)
    hv = (f"(SELECT *, LEAD(_seq) OVER (PARTITION BY {pkeys} ORDER BY _seq) AS __END_AT, "
          f"MIN(_seq) OVER (PARTITION BY {pkeys}) AS _first FROM {v})")
    hc = ", ".join(q(c) for c in cols + ["_source"])
    spark.sql(f"""MERGE INTO {TGT}.{q(table + HIST)} t
      USING (SELECT DISTINCT {pkeys}, _first FROM {hv}) s ON {on} AND t.__END_AT IS NULL AND s._first > t.__START_AT
      WHEN MATCHED THEN UPDATE SET t.__END_AT = s._first""")
    spark.sql(f"""MERGE INTO {TGT}.{q(table + HIST)} t
      USING (SELECT * FROM {hv} WHERE _op <> 'delete') s ON {on} AND t.__START_AT = s._seq
      WHEN NOT MATCHED THEN INSERT ({hc}, __START_AT, __END_AT) VALUES ({', '.join('s.' + q(c) for c in cols + ['_source'])}, s._seq, s.__END_AT)""")
    spark.catalog.dropTempView(v)


def each(fn, items):
    """fn over items, --threads at a time; the first error is raised after all have run."""
    errs = []

    def run(x):
        try:
            fn(x)
        except Exception as e:   # noqa: BLE001
            errs.append((x, e))
    with ThreadPoolExecutor(a.threads) as ex:
        list(ex.map(run, items))
    if errs:
        log(f"{len(errs)} failed; first: {errs[0][0]}: {str(errs[0][1])[:500]}")
        raise errs[0][1]


# --- start: the state tables, the silver tables (eager), the snapshot (once per table, recorded in _cdc_loaded) -----
t0 = time.time()
spark.sql(f"CREATE TABLE IF NOT EXISTS {TGT}._cdc_tombstones (tbl STRING, _source STRING, k STRING, _seq BIGINT) CLUSTER BY (tbl)")
spark.sql(f"CREATE TABLE IF NOT EXISTS {TGT}._cdc_loaded (tbl STRING, at TIMESTAMP)")
existing = {r[0].lower() for r in spark.sql(f"SHOW TABLES IN {TGT}").select("tableName").collect()}
loaded = {r[0] for r in spark.table(f"{TGT}._cdc_loaded").collect()}
todo = [t for t in SCHEMA if t not in loaded]
has_rows = {t for t, _, _ in SNAP}
create = [t for t in todo if a.create == "eager" or t in has_rows]
log(f"{len(SCHEMA)} tables in this shard; {len(existing)} tables in {TGT}; snapshot to load for {len(todo)}, "
    f"tables to create {len(create)} ({a.create})")


def start(table):
    for s in ddl(table):
        if s.split(" (")[0].split(".")[-1].strip("`").lower() not in existing:
            spark.sql(s)
    rows = snapshot(table)
    if rows is not None:
        apply(table, rows)


each(start, create)
if todo:
    spark.createDataFrame([(t,) for t in todo], "tbl STRING").withColumn("at", F.current_timestamp()) \
        .write.mode("append").saveAsTable(f"{TGT}._cdc_loaded")
log(f"start: {len(create)} table(s) created and loaded in {time.time() - t0:.0f}s")


# --- the change log: one stream; each micro-batch MERGEs the tables it has events for ------------------------------
def norm(log_df):
    if a.bronze == "kafka":
        return log_df.select(
            "destination",
            F.expr("CASE value:op::STRING WHEN 'c' THEN 'create' WHEN 'u' THEN 'update' WHEN 'd' THEN 'delete' "
                   "WHEN 'r' THEN 'read' END").alias("operation"),
            F.expr("CASE value:op::STRING WHEN 'd' THEN value:before ELSE value:after END").alias("key"), "value",
            F.expr("value:source:lsn::BIGINT").alias("_seq"))
    return log_df.select("destination", "operation", "key", "value", F.expr("value:ts_ns::BIGINT").alias("_seq"))


def batch_fn(batch, batch_id):
    b = norm(batch).withColumn("_table", F.substring_index("destination", ".", -1))
    names = [r[0] for r in b.select("_table").distinct().collect()]
    tables = [LOWER.get(n.lower(), n) for n in names]
    tables = [t for t in tables if t in SCHEMA]
    if not tables:
        return
    t1 = time.time()
    for t in tables:   # a table first seen in the log (lazy, or new since the start)
        if t not in loaded and t not in create:
            for s in ddl(t):
                spark.sql(s)
    each(lambda t: apply(t, changes(b.withColumn("_table", F.expr(f"CASE WHEN lower(_table) = '{t.lower()}' THEN '{t}' ELSE _table END")), t)), tables)
    log(f"batch {batch_id}: {len(tables)} table(s) in {time.time() - t1:.0f}s")


q_ = spark.readStream.table(a.source).writeStream.foreachBatch(batch_fn).option("checkpointLocation", a.checkpoint)
q_ = q_.trigger(availableNow=True) if a.once else q_.trigger(processingTime="10 seconds")
q_.start().awaitTermination()
log(f"done in {time.time() - t0:.0f}s")
