# silver-from-schema.py: a Lakeflow Spark Declarative Pipelines source file that builds silver from the canonical
# schema (statschema's schema.yaml, from the lfc-source-statschema skill) in a Unity Catalog Volume. The one generator
# for every source, every model and every bronze layout: nothing in it names a table, a column or a type.
#
# Sources: <volume>/_sources.yaml lists every source database (host) feeding this silver, each with the change log's
# destination prefix (destination = <prefix>.<table>, e.g. crdb1.public.orders), its T, and its snapshot format. The
# same logical table from many sources merges into one silver table; with source_key: true the key is (_source, the
# primary key), so identical keys from different hosts stay apart, and each key's changes are ordered within its own
# source only. Every silver row carries _source (the destination prefix).
#
# For every table in <volume>/_schema/schema.yaml (or _schema/tables/<table>.yaml, which wins: one table's evolved
# schema, written without touching the others) it defines, when the pipeline starts:
#   <table>_snapshot        every source's snapshot as of its T, from <volume>/<table>/<prefix>/ (Parquet or CSV); a
#                           table with no files there (CockroachDB writes none for an empty table) has an empty one.
#                           <volume>/_snapshot.tsv (table, prefix, format, files), when there is one, says which do,
#                           so 10,000s of folders aren't listed when the pipeline starts
#   <table>_changes         the table's events in the change log, sequenced by the event's position in its source
#   <table>_changes_dedup   the same, producer replays removed
#   <table>                 current rows (AUTO CDC, SCD type 1)
#   <table>_history         every version (AUTO CDC, SCD type 2), replays removed; the suffix is cdc.history_suffix
#                           (default _history; TPC-E has both holding and holding_history, so there it can't be)
# and, for the table in cdc.nodedup_table, <table>_history_nodedup (SCD type 2 with the replays). A table without a
# primary key (TPC-B's and TPC-C's history) is append-only: <table> gets the snapshot rows and the inserts, appended.
# Dates, timestamps and times are decoded from either form a producer sends: text (CockroachDB's changefeed, the
# snapshot) or a number (Debezium's PostgreSQL connector: days, epoch milli- or microseconds, microseconds of the day).
# A time is kept as text, HH:mm:ss.SSSSSS.
#
# Schema drift (cdc.on_drift = record, the default): silver keeps flowing on the columns it knows. A value that doesn't
# fit its column's type becomes NULL, a column that's gone gets its default (or NULL), a new column waits; and each one
# is recorded once per (table, source, kind, column) in schema_drift (kind: type, missing, new; with the last position
# and a sample). Evolution is asynchronous and per table: write that table's new schema to _schema/tables/<table>.yaml
# and full-refresh it (the change log is append-only VARIANT, so it catches up from bronze); the other tables never
# stop, and neither does the change log: a new column or a new table needs no DDL there. cdc.on_drift = fail casts
# strictly, so an update stops at the first value that doesn't fit.
#
# Pipeline configuration:
#   cdc.volume            /Volumes/<catalog>/<schema>/<volume>
#   cdc.bronze            the change log's shape: zerobus (Debezium Server's sink) or kafka (Kafka Connect, Kafka API)
#   cdc.bronze_table      the change-log table each silver table reads: cdc_log (one log for every table, the default),
#                         cdc_log_{table} (one per table) or cdc_log_s{shard} (cdc.bronze_shards logs, by table)
#   cdc.bronze_table.<t>  one table's own bronze table, over cdc.bronze_table: a table moved out of the shared log
#                         (fanout.py --tables <t>, or a producer routing it), while the others stay; changing it
#                         takes a full refresh of that table, from a bronze table that holds its history from T
#   cdc.bronze_shards     for {shard}: how many (fanout.py writes them with the same rule)
#   cdc.shard             i/n: this pipeline builds only the tables with crc32(name) % n == i, so 10,000s of tables
#                         spread over n pipelines (default: every table)
#   cdc.history_suffix    the SCD type 2 tables' suffix (default _history); a source table with that name stops the start
#   cdc.nodedup_table, cdc.on_drift (record | fail), cdc.drift_sample (check one event in n for drift, default 1)
import functools
import os
import re
import zlib

import yaml
from pyspark import pipelines as dp
from pyspark.sql import functions as F

VOL = spark.conf.get("cdc.volume")
BRONZE = spark.conf.get("cdc.bronze", "zerobus")
BRONZE_TABLE = spark.conf.get("cdc.bronze_table", "cdc_log")
BRONZE_SHARDS = int(spark.conf.get("cdc.bronze_shards", "1"))
SHARD = spark.conf.get("cdc.shard", "")
NODEDUP = spark.conf.get("cdc.nodedup_table", "")
ON_DRIFT = spark.conf.get("cdc.on_drift", "record")
DRIFT_SAMPLE = int(spark.conf.get("cdc.drift_sample", "1"))
TRY = ON_DRIFT == "record"
HIST = spark.conf.get("cdc.history_suffix", "_history")
GROUP = spark.conf.get("cdc.placement_group", "")   # composite: only this group's tables, from <volume>/_placement.tsv

# the type names the TPC schema files use besides statschema's canonical ones (ddl.py takes the same)
ALIAS = {"int": "integer", "smallint": "integer", "tinyint": "integer", "bigint": "long", "numeric": "decimal",
         "varchar": "string", "text": "string", "real": "float", "double precision": "double", "bool": "boolean"}
TEMPORAL = ("date", "timestamp", "timestamptz", "time", "timetz")


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
    # a bracket right after a column is a map's; on a VARIANT column it follows a colon (key:['SK_TimeID'])
    return f"{base}:{n}" if re.fullmatch(r"[a-z_][a-z0-9_]*", n) else f"{base}{'' if ':' in base else ':'}['{n}']"


def shard_of(name, n):
    """The shard of a table: the same rule in fanout.py, so both agree on where a table's events are."""
    return zlib.crc32(name.encode()) % n


def decode(c, s, cast="CAST"):
    """s, a STRING expression with the value as text or a number -> the column's type. A number is Debezium's: days
    for a date; for a timestamp, epoch milliseconds when the column holds 3 digits of fraction or fewer, else
    microseconds (without a precision too: PostgreSQL's and CockroachDB's default is 6 digits);
    microseconds of the day for a time. cast: CAST, or TRY_CAST (NULL where the text doesn't fit)."""
    t, ty = ctype(c), spark_type(c)
    num = f"{s} RLIKE '^-?[0-9]+$'"
    p = c.get("precision")
    n = f"CAST({s} AS BIGINT)"
    # no precision: 6 digits, as PostgreSQL and CockroachDB default to, so microseconds (a guess by size took a
    # date near 1970 for milliseconds: 1 s after the epoch, 1000000 us, read as 1000 s)
    us = n if p is None or int(p) > 3 else f"{n} * 1000"
    if t == "date":
        return f"CASE WHEN {num} THEN date_add(DATE'1970-01-01', CAST({s} AS INT)) ELSE {cast}({s} AS DATE) END"
    if t == "timestamp":
        return (f"CASE WHEN {num} THEN timestampadd(MICROSECOND, {us}, TIMESTAMP_NTZ'1970-01-01 00:00:00') "
                f"ELSE {cast}({s} AS TIMESTAMP_NTZ) END")
    if t == "timestamptz":   # text from PostgreSQL ends +00; Spark takes +00:00
        return (f"CASE WHEN {num} THEN timestamp_micros({us}) "
                f"ELSE {cast}(regexp_replace({s}, '([+-][0-9]{{2}})$', '$1:00') AS TIMESTAMP) END")
    if t in ("time", "timetz"):
        tus = f"{n} * 1000" if p is not None and int(p) <= 3 else n
        return (f"date_format(CASE WHEN {num} THEN timestampadd(MICROSECOND, {tus}, TIMESTAMP_NTZ'1970-01-01 00:00:00') "
                f"ELSE {cast}(concat('1970-01-01 ', {s}) AS TIMESTAMP_NTZ) END, 'HH:mm:ss.SSSSSS')")
    return f"{cast}({s} AS {ty})"


def typed(c, v, cast):
    """A VARIANT field v as the column's type."""
    return decode(c, f"{v}::STRING", cast) if ctype(c) in TEMPORAL else f"{cast}({v} AS {spark_type(c)})"


def load():
    """The canonical schema: schema.yaml, then any _schema/tables/<table>.yaml (a table's evolved schema) over it."""
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
SOURCES = _S["sources"]                     # [{prefix, t_ns, format}]
SOURCE_KEY = bool(_S.get("source_key", len(SOURCES) > 1))
SCHEMA = load()
if SHARD:
    _i, _n = (int(x) for x in SHARD.split("/"))
    SCHEMA = {t: c for t, c in SCHEMA.items() if shard_of(t, _n) == _i}
OWN = set()
if GROUP:
    with open(f"{VOL}/_placement.tsv") as f:
        _p = [r.rstrip("\n").split("\t") for r in f if r.strip()]
    SCHEMA = {t: c for t, c in SCHEMA.items() if any(r[0] == t and r[1] == GROUP for r in _p)}
    OWN = {r[0] for r in _p if r[1] == GROUP and r[2] == "own"}   # own bronze: cdc_log_<table>, from the fan-out
_clash = sorted(t for t in SCHEMA if (t + HIST).lower() in {x.lower() for x in SCHEMA})
if _clash:
    raise ValueError(f"cdc.history_suffix {HIST}: {', '.join(t + HIST for t in _clash[:5])} would be a source table too; set another")
DRIFT = "schema_drift" + (f"_s{SHARD.replace('/', '_of_')}" if SHARD else "")
_views = set()


def _snapshot_files():
    """{(table, format)} with snapshot files: from _snapshot.tsv, else by listing the volume."""
    m = f"{VOL}/_snapshot.tsv"
    if os.path.exists(m):
        with open(m) as f:
            return {(r[0], r[2]) for r in (line.rstrip("\n").split("\t") for line in f) if len(r) == 4 and int(r[3]) > 0}
    out = set()
    for s in SOURCES:
        fmt = s.get("format", "parquet")
        for table in SCHEMA:
            d = f"{VOL}/{table}/{s['prefix']}"
            if os.path.isdir(d) and any(n.endswith(f".{fmt}") for n in os.listdir(d)):
                out.add((table, fmt))
    return out


SNAPSHOT_FILES = _snapshot_files()


def bronze_of(table):
    default = "cdc_log_{table}" if table in OWN else BRONZE_TABLE
    return spark.conf.get(f"cdc.bronze_table.{table}", default).format(table=table, shard=shard_of(table, BRONZE_SHARDS))


def norm_view(bronze):
    """The change log in one shape for both sinks: destination, operation, idempotency_key, key, value, _seq, _event_ns.
    Kafka Connect's records carry only the event: the operation comes from op, the key from after or before, and the
    sequence from the slot's LSN (commit order, within its source). One view per bronze table, shared by its tables."""
    name = f"_norm_{bronze}"
    if name in _views:
        return name
    _views.add(name)

    @dp.temporary_view(name=name)
    def norm():
        log = spark.readStream.table(bronze)
        if BRONZE == "kafka":
            return log.select(
                "destination",
                F.expr("CASE value:op::STRING WHEN 'c' THEN 'create' WHEN 'u' THEN 'update' WHEN 'd' THEN 'delete' "
                       "WHEN 'r' THEN 'read' END").alias("operation"),
                F.expr("value:source:lsn::STRING").alias("idempotency_key"),   # none from CockroachDB: replays match on the row
                F.expr("CASE value:op::STRING WHEN 'd' THEN value:before ELSE value:after END").alias("key"), "value",
                F.expr("COALESCE(value:source:lsn::BIGINT, value:ts_ns::BIGINT)").alias("_seq"), F.expr("value:ts_ms::BIGINT * 1000000").alias("_event_ns"))
        return log.withColumn("_seq", F.expr("value:ts_ns::BIGINT")).withColumn("_event_ns", F.expr("value:ts_ns::BIGINT"))

    @dp.temporary_view(name=f"_dedup_{bronze}")
    def dedup():
        # a replay has the same key and the same row image as the original; the key alone may be shared by two changes
        return (spark.readStream.table(name)
                .withColumn("_event_time", F.timestamp_micros(F.expr("_event_ns DIV 1000")))
                .withColumn("_after", F.expr("TO_JSON(value:after)"))
                .withWatermark("_event_time", "10 minutes")
                .dropDuplicatesWithinWatermark(["destination", "idempotency_key", "operation", "_after"])
                .drop("_event_time", "_after"))
    return name


def define(table, cols):
    pk = [c["name"] for c in cols if c.get("primary_key")]
    keys = (["_source"] + pk) if SOURCE_KEY and pk else pk
    names = [c["name"] for c in cols]
    norm = norm_view(bronze_of(table))
    # A column added after T is in neither the snapshot nor the changes made before it was added. A PostgreSQL-protocol
    # source doesn't resend old rows when a column is added, so they hold the column's default (a SQL literal in
    # schema.yaml): use it where the field is missing (SQL NULL from the path), not where it's a JSON null.
    def dflt(c):
        return c.get("default") or "NULL"

    def get(base, c, strict=False):   # a field of the event, as the column's type (record: NULL where it doesn't fit)
        return typed(c, path(base, c["name"]), "TRY_CAST" if TRY and not strict else "CAST")

    def change(c):
        n, ty = c["name"], spark_type(c)
        if n in pk:
            return get("key", c, strict=True)
        if c.get("default"):
            return (f"CASE WHEN value:after IS NOT NULL AND NOT is_variant_null(value:after) AND {path('value:after', n)} IS NULL "
                    f"THEN CAST({c['default']} AS {ty}) ELSE {get('value:after', c)} END")
        return get("value:after", c)

    def snap(c, have):   # a snapshot column: missing from that table's files (added after T) -> its default
        if c["name"] not in have:
            return f"CAST({dflt(c)} AS {spark_type(c)})"
        x = f"`{c['name']}`"
        return decode(c, f"CAST({x} AS STRING)") if ctype(c) in TEMPORAL else f"CAST({x} AS {spark_type(c)})"
    chg_cols = [F.expr(change(c)).alias(c["name"]) for c in cols]
    # the source: everything in destination before the table's name (crdb1.public.orders -> crdb1.public)
    src = F.expr(f"substring(destination, 1, length(destination) - {len(table) + 1})").alias("_source")
    mine = F.expr(f"substring_index(destination, '.', -1) = '{table}'")

    @dp.temporary_view(name=f"{table}_snapshot")
    def snapshot():
        # one Auto Loader stream per format over <volume>/<table>/<prefix>/: the source from the folder, T from _sources
        parts = []
        for fmt in sorted({s.get("format", "parquet") for s in SOURCES if (table, s.get("format", "parquet")) in SNAPSHOT_FILES}):
            r = (spark.readStream.format("cloudFiles").option("cloudFiles.format", fmt)
                 .option("pathGlobFilter", f"*.{fmt}"))
            if fmt == "csv":
                r = r.option("header", "true")
            df = r.load(f"{VOL}/{table}")
            have = set(df.columns)
            parts.append(df.select(*[F.expr(snap(c, have)).alias(c["name"]) for c in cols],
                                   F.regexp_extract(F.col("_metadata.file_path"), f"/{re.escape(table)}/([^/]+)/", 1)
                                   .alias("_source")))
        if not parts:   # no snapshot files: no rows at T; an empty stream of the view's columns (no join: it folds away)
            return spark.readStream.table(norm).where("false").select(
                *[F.expr(f"CAST(NULL AS {spark_type(c)})").alias(c["name"]) for c in cols], F.lit(None).cast("string").alias("_source"),
                F.lit(0).cast("bigint").alias("_seq"), F.lit("read").alias("_op"))
        t = spark.createDataFrame([(s["prefix"], int(s["t_ns"])) for s in SOURCES], "_source STRING, _seq BIGINT")
        return (functools.reduce(lambda a, b: a.unionByName(b), parts).join(F.broadcast(t), "_source")
                .select(*names, "_source", "_seq", F.lit("read").alias("_op")))

    def changes(view):
        return spark.readStream.table(view).where(mine).select(*chg_cols, src, F.col("_seq"), F.col("operation").alias("_op"))

    # a TIMESTAMP_NTZ column needs its Delta table feature enabled (an append-only table's create fails without it)
    props = {"delta.feature.timestampNtz": "supported"} if any(spark_type(c) == "TIMESTAMP_NTZ" for c in cols) else {}
    dp.temporary_view(name=f"{table}_changes")(lambda: changes(norm))
    if TRY:
        drift(table, cols, pk, norm, mine, src)
    if not pk:   # append-only: the snapshot rows, then each insert (a table without a key gets no updates or deletes)
        dp.create_streaming_table(name=table, table_properties=props)
        dp.append_flow(target=table, name=f"{table}_from_snapshot")(   # not once: a once append flow takes a batch only
            lambda: spark.readStream.table(f"{table}_snapshot").drop("_seq", "_op"))
        # the inserts with producer replays removed (the dedup view): without a key, a replay would be a second row.
        # Two identical rows inserted within the dedup watermark count as one
        dp.temporary_view(name=f"{table}_changes_dedup")(lambda: changes(f"_dedup_{bronze_of(table)}"))
        dp.append_flow(target=table, name=f"{table}_from_changes")(
            lambda: spark.readStream.table(f"{table}_changes_dedup").where("_op = 'create'").drop("_seq", "_op"))
        return
    dp.temporary_view(name=f"{table}_changes_dedup")(lambda: changes(f"_dedup_{bronze_of(table)}"))

    targets = [(table, 1, f"{table}_changes"), (f"{table}{HIST}", 2, f"{table}_changes_dedup")]
    if table == NODEDUP:
        targets.append((f"{table}{HIST}_nodedup", 2, f"{table}_changes"))
    for target, scd, change_view in targets:
        dp.create_streaming_table(name=target, cluster_by=keys, table_properties=props)
        # once: the snapshot is loaded on the first update only (and again on a full refresh), so later updates don't
        # start a snapshot stream per table
        dp.create_auto_cdc_flow(name=f"{target}_from_snapshot", target=target, source=f"{table}_snapshot", keys=keys,
                                sequence_by="_seq", except_column_list=["_seq", "_op"], stored_as_scd_type=scd, once=True)
        dp.create_auto_cdc_flow(name=f"{target}_from_changes", target=target, source=change_view, keys=keys,
                                sequence_by="_seq", apply_as_deletes=F.expr("_op = 'delete'"),
                                except_column_list=["_seq", "_op"], stored_as_scd_type=scd)


def drift(table, cols, pk, norm, mine, src):
    """What doesn't fit the table's schema, from its events (one in cdc.drift_sample): a value its type can't hold
    (type), a known column without a default missing from the row (missing: dropped at the source), a column the
    schema doesn't have (new). AUTO CDC keeps one row per (table, source, kind, column): the last position, a sample."""
    items = []
    for c in cols:
        if c["name"] in pk:
            continue
        v = path("value:after", c["name"])
        items.append(f"IF({v} IS NOT NULL AND NOT is_variant_null({v}) AND {typed(c, v, 'TRY_CAST')} IS NULL, "
                     f"named_struct('kind', 'type', 'col', '{c['name']}'), NULL)")
        if not c.get("default"):
            items.append(f"IF({v} IS NULL, named_struct('kind', 'missing', 'col', '{c['name']}'), NULL)")
    known = ", ".join(f"'{c['name']}'" for c in cols)
    new = (f"transform(array_except(json_object_keys(to_json(value:after)), array({known})), "
           f"x -> named_struct('kind', 'new', 'col', x))")
    none = "CAST(NULL AS STRUCT<kind: STRING, col: STRING>)"
    found = f"filter(concat(array({', '.join(items) or none}), {new}), x -> x IS NOT NULL)"

    @dp.temporary_view(name=f"{table}_drift")
    def view():
        return (spark.readStream.table(norm).where(mine)
                .where("value:after IS NOT NULL AND NOT is_variant_null(value:after)").where(f"_seq % {DRIFT_SAMPLE} = 0")
                .select(src, "_seq", F.expr("substr(to_json(value:after), 1, 500)").alias("sample"),
                        F.explode(F.expr(found)).alias("d"))
                .select(F.lit(table).alias("tbl"), "_source", F.col("d.kind").alias("kind"), F.col("d.col").alias("col"),
                        "_seq", "sample"))
    if DRIFT not in _views:
        _views.add(DRIFT)
        dp.create_streaming_table(name=DRIFT, comment="Schema drift seen in the change log, one row per table, source, "
                                  "kind (type, missing, new) and column: what an evolution (the table's new schema, "
                                  "then its full refresh) resolves")
    # named after the bronze table it reads: a table moved to its own bronze gets a new drift flow (a new checkpoint)
    dp.create_auto_cdc_flow(name=f"{DRIFT}_{table}_{bronze_of(table)}", target=DRIFT, source=f"{table}_drift",
                            keys=["tbl", "_source", "kind", "col"], sequence_by="_seq", stored_as_scd_type=1)


for name, columns in SCHEMA.items():
    define(name, columns)
