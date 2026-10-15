---
name: lfc-source-datagen
description: "Create and fill Lakeflow Connect source tables with large amounts of test data generated inside the database (INSERT ... SELECT from generate_series or a seed table, with a tested per-type cast of an integer), so no row data crosses the network. Handles requests like 'create 100 tables with up to 1 million rows each and a variety of data types', resumes after an interruption, deletes from either end of the key range, and reports fast min/max/row counts across 10,000+ tables. Also the quick reference for each engine's limits (max columns, row size, rows per VALUES list) and every data type's range and cast."
parent: lfc-source-setup
---

# Generate test data inside the source database

Loading 100 GB from a laptop or a notebook means pushing 100 GB over the network. This skill sends **only SQL text**: the database generates every row itself, from an integer.

## How it works

- **Every row comes from one integer `n`.** Each column's value is a cast of `n` to its type, for example `n % 32767` for `smallint`, `date '1970-01-01' + n % 2932896` for `date`, or a zero-padded `n` followed by MD5 filler for text. Every cast in the engine references has been run at `n` = 1, 2, 10⁶, 10¹², 2⁶², and 2⁶³ − 2 on the live engine, and stays valid for all of them.
- **A planner query reads the catalog once and writes the SQL.** For every table in a schema it emits one `INSERT ... SELECT` with the right cast for each column. That's one round trip, even for 10,000 tables.
- **Each INSERT resumes by itself.** It reads the table's min and max key (two index probes) and continues above the max. After an interruption, **rerun the same file**: each INSERT is one statement, so a killed one rolls back completely and nothing is duplicated.
- **Keys only change at the ends.** Inserts append above the max, and deletes remove keys from the head (lowest) or the tail (highest), never the middle. The keys stay contiguous, so **rows = max − min + 1**, with no `COUNT(*)`.
- **Key order and column data don't have to be sequential.** Each INSERT adds its keys in `random` (default), `asc`, or `desc` order; the range is still exactly max + 1 … max + need, so resume and rows = max − min + 1 still hold. Non-key columns are `seq` (plain `n`), `scramble` (a non-linear function of `n` with a random multiplier and start per column, fixed when the SQL is planned, so a rerun regenerates the same rows), or `random` (one per-row random value, scrambled per column). Key and `UNIQUE` columns always keep plain `n`.
- **Plain values can be audited from the key alone.** Every cast with plain `n` can be decoded back: text starts with the zero-padded `n` (and, from 38 characters, ends with it, at the exact column length), binary starts with `n`'s 8 bytes (and ends with them from 16 bytes), a uuid holds `n` in its last 16 hex digits, dates and timestamps count days or seconds from 1970, and so on. So a row whose columns hold plain values can be checked on its own: decode each column and compare it with the key. `plain_every = k` with `block = B` keeps every k-th block of B keys plain while the rest are scrambled or random, so a mixed dataset still has rows to audit; the audit planner checks exactly those blocks. Scrambled and random rows can't be audited.
- **Foreign keys stay valid, dimension first.** A one-column foreign key to a parent's primary key gets `parent_min + scramble(n) mod (parent_max − parent_min + 1)`, cast to the parent key's type, with the parent's range probed when the statement runs: since a key range is always contiguous, every value is an existing key. The planners order tables by level (dimensions 0, a table referencing them one higher; each statement is tagged `/* lfc level N */`): inserts fill the dimensions before the facts, and before a delete trims a dimension's head or tail, it re-points the fact rows that reference those keys into the range that stays (an UPDATE of a non-key column, so the facts' own key ranges don't change). A delete never empties a table, so a dimension always has keys left to point at.
- **Spec formulas, composite keys, and tables without a key** are described by comment tags, not code: a column's `lfc:v={...}` gives its value as an integer formula in `n` (a sparse key, a value range, a key that follows another table's), a table's `lfc:n={...}` gives `n` back from a row, `lfc:by={...}` names the column `n` rises with, and a column's `lfc:len={L}` sets its string length (a source's average width instead of the declared maximum). That's how the TPC schemas ([references/tpc.md](references/tpc.md)) and copies shaped from a customer's statistics (**lfc-source-statschema**) are built.
- **A table's target row count lives in its comment** (`lfc:rows=500000`). The planner's `fill` mode tops every table up to its target, at most `rows` per statement, so rerunning it until nothing is left to add finishes the load.

## Why generated values instead of realistic fake data

Tools like Faker make rows that **look** real (names, addresses, sentences), but nothing about a row says what it should be, so after a snapshot and CDC the only check left is "the row counts match". Values derived from the key are different:

- **Every value can be checked from the key alone.** A plain row's columns all decode back to its key, so the target can be audited row by row after the pipeline: a wrong, shifted, or mixed-up value is caught, not just a missing row. Truncation is caught too: long strings and binaries carry the key at **both ends** and have an exact length.
- **No reference copy is needed.** The audit doesn't compare the target with the source; it recomputes what each value must be. It works on 10,000 tables and after the source has moved on.
- **Reproducible.** The same plan writes the same rows on every run (except `data=random`), so a failure can be reproduced and a resume never duplicates.
- **Generated in the database.** Only SQL text crosses the network, and each type's whole valid range can be exercised on purpose (wrapping, 9999-12-31, `bit(64)`, full-length `varchar`), which realistic samples rarely reach.

Where realism matters (non-sequential keys, values with no visible pattern), use `order=random` and `data=scramble` or `random`, and keep `plain_every` blocks so part of every table stays auditable.

## Make a dataset

A typical request: *"Create 100 tables, rows uniformly distributed up to 1 million, with a variety of data types."*

**If the user doesn't know what schema they want, offer a standard one**: TPC-B (4 tables, the banking schema pgbench uses, including a table with no primary key) or TPC-H (8 tables, composite keys and foreign keys, 8.66M rows at scale factor 1), with the spec's sizes, keys, foreign keys, and constraints. See [references/tpc.md](references/tpc.md); TPC-C, TPC-DS, and others are planned there. **If they have a database of their own but can't share its data**, build a copy with its shape from its statistics: **lfc-source-statschema**. Otherwise:

| Choice | Default | Options |
|---|---|---|
| Tables | as asked | Names `t001` … `t100` in the schema (or database) the user names |
| Rows per table | `even`: table *k* of *N* gets ⌈*k* × max ÷ *N*⌉ rows (10,000, 20,000, … 1,000,000) | `random`: a uniform pseudo-random count in 1 … max, the same on every run |
| Columns | 12 per table, plus a `bigint` key | Each table starts at a different place in the engine's type menu, so every type is covered |
| Type menu | About 20 common types per engine: integers, decimals, floats, text, dates and times, boolean, binary, uuid, JSON, a spatial type | Any type in the engine's cast table |
| Dimensions and facts | none | `dims=D, fks=K`: the first D tables (the smallest, with `even`) are dimensions; every other table gets K `NOT NULL` foreign-key columns pointing at them in turn |
| Key order | `random`: shuffled within each INSERT (about 55% slower and a 40% larger key index on Postgres than ascending, as with real random keys) | `asc`, `desc` |
| Long values | `varchar(L)`, `char(L)`, `binary(L)` are filled to their full length L; unbounded types (`text`, `bytea`, blobs) to `lob_len` = 100 | Any `lob_len` up to the type's maximum, to test how long values survive the pipeline |
| Column data | `scramble`, with every 4th block of 1,000 keys plain (`plain_every=4`, `block=1000`): no visible sequence, reproducible, and a quarter of the rows auditable | `seq`: every row plain and auditable; `random`: per-row random, different on every run; any `plain_every` (0 = no plain blocks) |

1. **Estimate the size and check the disk first.** Plan on about **400 bytes per row** for 12 columns of the default menu (measured: 50.5M rows took 20 GB on Postgres; 300 to 570 bytes per row on MySQL), plus the same again for WAL or binlog if logs are kept for CDC. 100 tables up to 1M rows (`even`) is 50.5M rows, about 20 GB of table data. **Stop and say so if that's more than about 70% of the free disk** — a full disk crashed MySQL in testing.
2. **Show the plan and wait for a yes:** tables, total rows, size estimate, and where it will be created.
3. **Create the tables** with the engine's `make-dataset` query.
4. **Build the seed table** once (any table above 10,000 rows needs it on MySQL; on Postgres it's optional).
5. **Fill:** plan with `mode=fill` (and the key order and column data asked for), then **run the levels in order**, each split across the calibrated number of sessions (4 on Postgres, 2 on MySQL, for 4 vCPUs), and **rerun until status shows every table at its target.** Measured on 4 vCPUs: 50.5M rows in 2 min 48 s on Postgres.
6. **Report** the status: each table's min, max, rows, and the total. Run the **audit** on the source too: it should show 0 bad rows.
7. **After the pipeline has run** (snapshot and CDC), audit the target the same way: decode each plain-block column from the key. The checks are in each engine's `cast` file (`lfc_check` / `chk`); the target's Databricks SQL forms depend on how Lakeflow Connect maps each type and aren't written yet.

### Fill level by level

When columns have formulas that point at a parent (`lfc:v`), the parent must be complete before its children start. `fill.sh` fills one level at a time and moves on only when every table of the level is at its target; it re-plans every round, so a rerun resumes. It reads the planner files from the directory the engine reference creates them in.

```bash
cat > fill.sh <<'FILL_EOF'
# fill.sh <pg|my> <schema>: fill every table of the schema to its target (lfc:rows), one level at a time: a level starts
# only when every table of the level before is complete, which formulas that point at a parent (lfc:v) need. At most
# ROWS per statement and SESSIONS tables at once; it re-plans every round, so a rerun resumes.
# The planner files are in DIR (default: this directory), as postgres.md / mysql.md create them; the client is PSQL or
# MYSQL (default psql / mysql, connection from the usual environment: PGHOST... or MYSQL_HOST, MYSQL_PWD...).
E=$1; D=$2; DIR=${DIR:-.}; SESSIONS=${SESSIONS:-4}
if [ "$E" = pg ]; then
  ROWS=${ROWS:-1000000}; SQL="${PSQL:-psql} -X -At -q -v ON_ERROR_STOP=1"; T="$D.%s"
  plan() { cat "$DIR/cast.sql" "$DIR/plan-insert.sql" | $SQL -v schema=$D -v rows=$ROWS -v src=seed -v mode=fill -v order=${ORDER:-random} -v data=scramble -v plain_every=4; }
  status() { $SQL -v schema=$D < "$DIR/plan-status.sql" | $SQL; }
else
  ROWS=${ROWS:-100000}; SQL="${MYSQL:-mysql} -N -B -r $D"; T="\`$D\`.\`%s\`"
  plan() { { echo "SET @db='$D', @rows=$ROWS, @src='seed', @mode='fill', @order='${ORDER:-random}', @data='scramble', @plain_every=4;"; cat "$DIR/cast.sql" "$DIR/plan-insert.sql"; } | $SQL; }
  status() { { echo "SET @db='$D';"; cat "$DIR/plan-status.sql"; } | $SQL | $SQL | tr '\t' '|'; }
fi
for l in $(plan | grep -o '^/\* lfc level [0-9]*' | awk '{ print $4 }' | sort -un); do
  while :; do
    todo=$(status | awk -F'|' '$5 != "" && $4 < $5 { print $1 }')        # tables below target; their statements at this level
    plan | grep "^/\* lfc level $l \*/" | grep -F "$(printf "INSERT INTO $T (\n" $todo)" > run.sql || break
    split -n r/$SESSIONS run.sql part-; pids=
    for f in part-*; do $SQL < $f & pids="$pids $!"; done; wait $pids; rm -f part-*
  done
done
status
FILL_EOF
DIR=pg bash fill.sh pg tpch                                    # Postgres: psql, connection from PGHOST, PGUSER, ...
DIR=my MYSQL="mysql -h db.example.com -u lfc" bash fill.sh my tpch   # MySQL: password from MYSQL_PWD
```

## Random values per row

A random function in an `INSERT ... SELECT` isn't always evaluated once per row, and the planner needs **one** random value per row: a cast can use its input twice (a range needs `v` and `v + 1`, a string pads and hashes `n`), and two different random values there would break it. So `data=random` draws the value once in a subquery the optimizer can't merge away (`OFFSET 0` on Postgres, `NO_MERGE` on MySQL), and every column scrambles that value.

| Engine | Per-row random | Notes |
|---|---|---|
| PostgreSQL | `random()` | Per row ✓ |
| MySQL | `RAND()` | Per row ✓. `RAND(<constant>)` repeats the same sequence |
| SQL Server | `ABS(CHECKSUM(NEWID()))` (or `RAND(CHECKSUM(NEWID()))` for a float in 0 … 1) | `RAND()` is evaluated **once per statement**, so every row gets the same value (from the docs, not tested yet) |
| Oracle | `DBMS_RANDOM.VALUE` | Per row (from the docs, not tested yet) |

## Schema changes during a load

Pipelines must survive DDL, so the skill can apply random DDL while it loads, and the load **recovers by re-planning**: nothing in the SQL files is saved state, so after any schema change the next plan reads the new catalog and continues. Each engine's `plan-ddl` writes N random operations, weighted like real schema changes:

| Weight | Operation | What the planner picks | Effect on the load |
|---|---|---|---|
| 25% | Add column | a random table and type; nullable, tagged `lfc:added` in its column comment | New rows get values; older rows are NULL, which the audit accepts for tagged columns |
| 20% | Modify column | widen a `varchar(L ≥ 38)` to 2L, `int` to `bigint`, or drop `NOT NULL` | Values written before stay valid under the new type (strings from 38 characters are audited by both ends, not length) |
| 15% | Create index | a column without one, of an indexable type | None |
| 15% | Truncate table | a table no foreign key points at | The next fill refills it, keys starting again at 1 |
| 10% | Create table | a new table with 6 columns and a random `lfc:rows=` target | The next fill picks it up |
| 10% | Drop column | not the key, not a foreign key, and the table keeps at least 2 columns | An INSERT already planned with the column fails and rolls back; the next plan leaves it out |
| 5% | Drop table | a table no foreign key points at | Its planned INSERTs fail; the next plan no longer has it |

Operations planned together can clash (one drops a column another modifies), and the database may reject some: run the DDL file **without stopping on errors**, then keep filling.

**Fill until done:** plan with `mode=fill`, run the levels, read the status (it shows each table's target), and repeat until no table is below its target. A failed INSERT rolls back, so every round can simply be planned again. Tested with 4 rounds of 8 random operations running during the fill: on Postgres one INSERT failed (a column dropped under it) and the next round recovered; on MySQL the DDL waited for running INSERTs (metadata locks), and none failed. On both, every table ended at its target, including the tables created mid-load, with no key gaps, every foreign key valid, and 0 bad rows in the audit.

### When a statement fails

Read the error and the table, then fix the cause **in the planner's input** (the cast file, or the table itself), not in the generated SQL, so the fix survives the next plan. This is why the skill is markdown: no fixed program could anticipate every failure.

| Error | Cause | What to do |
|---|---|---|
| column or table doesn't exist; column count or type mismatch | DDL after the plan was made | Re-plan and rerun |
| deadlock, lock timeout, connection lost | concurrency, a restart | Rerun: each INSERT is atomic and resumes from the current max |
| `NOT NULL` violation on a column the planner filled with `NULL` | a column of a type the cast file doesn't handle | Add the type to the cast file (with a check for the audit, if it can decode), re-plan |
| value too long, out of range, or a `CHECK` violation | a column narrowed or constrained outside the planner | Look at the new definition; if the cast can't fit it, change the cast or leave the column to its default, then re-plan |
| a foreign key violation | a foreign key added, or a parent changed, outside the planner | Re-plan (levels and foreign-key ranges come from the catalog); if the parent is empty, fill it first |
| the table no longer shows up in the plan | its primary key was dropped or changed | Run the skipped-tables query and report it; the planner can only fill tables with a one-column key |
| anything else | | Read the message, inspect the table (`\d` or `SHOW CREATE TABLE`), decide, and say what you changed |

## Quick limits

Answer from this table; don't look the docs up. ✓ = tested on the engine (Postgres 16, MySQL 8.4); the rest come from the vendor docs and aren't tested yet.

| Limit | PostgreSQL | MySQL (InnoDB) | SQL Server | Oracle |
|---|---|---|---|---|
| Columns per table | **1,600** ✓ (dropped columns still count) | **1,017** ✓ (the server's 4,096 is unreachable with InnoDB) | 1,024; 30,000 with sparse columns | 1,000; 4,096 with `MAX_COLUMNS = EXTENDED` (recent releases, 23ai/26ai) |
| Row size | Must fit an 8 KB page: **8,160 bytes** ✓ in-row; long values move out of row (TOAST) | **65,535** bytes declared ✓; about **8,126** in-page ✓ (16 KB pages) | 8,060 bytes in-row; `varchar(max)` and row overflow move off-row | Rows larger than a block chain across blocks |
| Rows in one `INSERT ... VALUES` | No fixed limit: 1M rows (8.9 MB of SQL) ✓ | Bounded by `max_allowed_packet` (**64 MB** default ✓, 1 GB max): 1M rows ✓ | **1,000** (more only in a `VALUES` derived table) | One row per `VALUES` before 23ai (use `INSERT ALL` or `UNION ALL` from `DUAL`); 23ai allows several |
| Bind parameters | 65,535 | 65,535 | 2,100 per call | — |
| Identifier length | 63 bytes | 64 characters | 128 characters | 128 bytes (30 before 12.2) |
| Row generator | `generate_series` | Recursive CTE (`cte_max_recursion_depth`, default 1,000) | `GENERATE_SERIES` (2022+, compatibility level 160); recursive CTE (`MAXRECURSION` 100 default, up to 32,767 or 0) | `CONNECT BY LEVEL <= n` from `DUAL`; recursive `WITH` |
| Seed table for big loads | Optional (same speed as `generate_series`) ✓ | Recommended: 1,000-row `VALUES` list, then double with `INSERT ... SELECT` ✓ | Same (`VALUES` limit is 1,000) | Same |
| Longest exact decimal | `numeric`: 1,000 declared digits | `DECIMAL(65,30)` ✓ | `decimal(38)` | `NUMBER(38)` |
| Longest in-row string | `varchar(10485760)`; `text` up to 1 GB | `VARCHAR(16383)` in utf8mb4 (but the 65,535-byte row limit applies) ✓ | `varchar(8000)`; `varchar(max)` 2 GB | `VARCHAR2(4000)` bytes; 32,767 with `MAX_STRING_SIZE = EXTENDED` |

## Rows per statement

| Rows | Source | Notes |
|---|---|---|
| Up to about 10,000 | `generate_series` (Postgres), recursive CTE (MySQL) | Nothing to set up |
| 100,000 and more | `INSERT ... SELECT` from a seed table of keys `1..N` (`lfc_seed.seed`), built once per database | SQL Server and Oracle can run this in parallel |
| More than the seed holds | Rerun: each run continues from the new max | `fill` mode does this by itself |

**On Postgres and MySQL one INSERT runs on one core** whichever source you use (1M rows: about 3 s on Postgres, 5.5 s on MySQL, either way). Speed comes from **loading several tables at once**, up to a limit: past it, bulk inserts only flood the CPU or the disk.

**Calibrate before a big load** (about 100M rows or more): sweep the statement size, then the session count, on the actual server, watching the run queue and disk await, and use the winners for the whole load. The best size differs a lot by engine: **1M–2M rows per statement and 4 sessions on Postgres 16, 100k rows and 1–2 sessions on MySQL 8.4 (more sessions only raised iowait)** (4 vCPUs). See [references/calibrate.md](references/calibrate.md) for the script and the results.

## Rules

- **Tables need a one-column primary key** that maps back to `n` (an integer, an integer-valued `numeric`, a text key of at least 19 characters, or a `uuid` on Postgres), **or an `lfc:n` tag** for a composite key or no key at all. The planner skips other tables; the engine's "skipped tables" query lists them. Keyless tables stay keyless; on Postgres, CDC needs `REPLICA IDENTITY FULL` for them.
- **Only plain values can be audited.** Use `seq`, or keep `plain_every` blocks, if the target's values must be checked after CDC.
- **Run the levels in order.** A fact's INSERT probes its dimensions' ranges; if a dimension is still empty, a `NOT NULL` foreign key fails. Run delete files in one session, in order: each dimension's re-point UPDATEs come before its DELETE.
- **Foreign keys that aren't one column referencing the parent's primary key** (composite foreign keys, or ones referencing a non-key unique column) get the column's ordinary cast, and the database may reject the rows. Postgres needs an index on each foreign-key column for the re-point UPDATEs to be fast (`make-dataset` creates them; InnoDB always does).
- **Never delete from the middle** of the key range, and **never change a key** in an update: either breaks rows = max − min + 1 and the resume point.
- **Columns the database numbers are left out:** non-key identity, `serial`, and `AUTO_INCREMENT` columns. Generated (computed) columns too.
- **Unsupported column types get `NULL`.** A `NOT NULL` column of such a type makes that table's INSERT fail: add a cast for it, or change the table.
- **Show the plan and the size estimate before running it** on a shared database.

## Engines

| Engine | Reference | Status |
|---|---|---|
| PostgreSQL | [references/postgres.md](references/postgres.md) | Tested on 16: every type family, 10,000 tables, 50.5M-row dataset |
| MySQL | [references/mysql.md](references/mysql.md) | Tested on 8.4: every type, 10,000 tables, interrupt and resume (MariaDB not yet) |
| SQL Server | [references/sqlserver.md](references/sqlserver.md) | Limits and types from the docs; casts not tested yet (on macOS: Lima VM, Rosetta) |
| Oracle | [references/oracle.md](references/oracle.md) | Limits and types from the docs; casts not tested yet (on macOS: Lima VM, arm64 image) |

## Gotchas

- **Long loads:** run them in the background and check for progress early, then less often (**watch-progress**): a 1M-row MySQL statement shows no new rows until it commits, so watch its age in `processlist` and the table's size too.
- **Disk:** check free space against the estimate before a big load. Dropping 10,000 tables in one statement fails on Postgres (`out of shared memory`, lock limit): drop them in batches of 500.
- **CDC sees every generated row.** A large load writes a matching amount of WAL or binlog. Load before the pipeline starts if you only need a snapshot, and make sure log retention and disk can hold it.
- **Sequences and counters:** MySQL moves `AUTO_INCREMENT` past the inserted keys. Postgres `serial` and identity sequences don't move: run `setval` if anything else inserts into the table.
- **`int` keys wrap** at 2,147,483,647; use `bigint` keys for bigger tables.
- **A large database to start from:** generate it once, stop it, and keep its data directory as a master to clone from (see **lfc-source-podman** for local, or **lfc-source-cloud-vm** `references/master-snapshots.md` for cloud VMs).
