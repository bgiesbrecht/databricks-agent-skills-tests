# fill.sh <pg|my|ms|ora> <schema>: fill every table of the schema to its target (lfc:rows), one level at a time: a level
# starts only when every table of the level before is complete, which formulas that point at a parent (lfc:v) need. At most
# ROWS per statement and SESSIONS tables at once; it re-plans every round, so a rerun resumes, and stops if a round
# adds no rows (a statement keeps failing).
# The planner files are in DIR (scripts/postgres, scripts/mysql, scripts/sqlserver, or scripts/oracle; default: this
# directory). The client is a command that reads SQL on stdin: PSQL or MYSQL (default psql / mysql, connection from the
# usual environment: PGHOST... or MYSQL_HOST, MYSQL_PWD...), MSSQL (sqlcmd, connected to the database, with -y 0; give it
# the SQL as a file with -i: sqlcmd splits stdin lines longer than 4,096 bytes, even inside a string), or ORACLE (sqlplus
# -s, connected to the schema's PDB as the schema's owner or a user that can insert into it).
# The rows' shape: ORDER (random | asc | desc), DATA (scramble | seq | random), PLAIN_EVERY and BLOCK (plain, auditable
# blocks), LOB_LEN (length of unbounded strings and binaries); defaults as in the skill. On Postgres, SRC=series reads
# generate_series instead of the seed table lfc_seed.seed.
# Engine names: pg (also postgres or yugabytedb or yb: the Postgres planners through psql, SRC=series for YugabyteDB, PSQL="psql -h ... -p ... -U ..."), my (also mysql, mariadb or
# maria: the MySQL planners through mysql), ms (SQL Server), ora (Oracle). Db2 (db2) and Informix (informix or ifx) have no
# SQL planner: they fill through scripts/python/fill.py (--database, the connection options, one schema per workload).
# CockroachDB (cockroachdb, crdb) too: this planner's functions live in pg_temp, which it refuses: fill.py postgres. fill.py's
# statements still make every row in the database (generate_series, a recursive CTE on Db2, CONNECT BY LEVEL on Informix).
E=$1; D=$2; DIR=${DIR:-.}; SESSIONS=${SESSIONS:-4}
ORDER=${ORDER:-random}; DATA=${DATA:-scramble}; PLAIN_EVERY=${PLAIN_EVERY:-4}; BLOCK=${BLOCK:-1000}; LOB_LEN=${LOB_LEN:-100}
GO=; HEAD=                                           # a line after every statement (SQL Server batches); a line before each file
case $E in
db2|informix|ifx|cockroachdb|crdb) echo "fill.sh: $E has no SQL planner here (CockroachDB can't create the planners' pg_temp functions; Db2 and Informix have no SQL form): use scripts/python/fill.py $E $D (references/python-drivers.md)" >&2; exit 2 ;;
pg|postgres|yugabytedb|yb)
  ROWS=${ROWS:-1000000}; SQL="${PSQL:-psql} -X -At -q -v ON_ERROR_STOP=1"; P="INSERT INTO $D.%s (\n"
  plan() { cat "$DIR/cast.sql" "$DIR/plan-insert.sql" | $SQL -v schema=$D -v rows=$ROWS -v src=${SRC:-seed} -v mode=fill -v order=$ORDER -v data=$DATA \
                -v plain_every=$PLAIN_EVERY -v block=$BLOCK -v lob_len=$LOB_LEN; }
  status() { $SQL -v schema=$D < "$DIR/plan-status.sql" | $SQL; } ;;
my|mysql|mariadb|maria)
  ROWS=${ROWS:-100000}; SQL="${MYSQL:-mysql} -N -B -r $D"; P="INSERT INTO \`$D\`.\`%s\` (\n"
  plan() { { echo "SET @db='$D', @rows=$ROWS, @src='seed', @mode='fill', @order='$ORDER', @data='$DATA', @plain_every=$PLAIN_EVERY, @block=$BLOCK, @lob_len=$LOB_LEN;"; cat "$CASTF" "$DIR/plan-insert.sql"; } | $SQL; }
  status() { { echo "SET @db='$D';"; cat "$DIR/plan-status.sql"; } | $SQL | $SQL | tr '\t' '|'; } ;;
ms)                                                  # sqlcmd prints a header (a blank line and dashes) before each result
  ROWS=${ROWS:-1000000}; SQL="${MSSQL:-sqlcmd -y 0}"; P="INSERT INTO [$D].[%s] WITH (TABLOCK) (\n"; GO=GO
  ms() { $SQL | grep -v -E '^ *-* *$' | grep -v -E '^\([0-9]+ rows? affected\)$'; }
  H="DECLARE @schema sysname = N'$D', @rows bigint = $ROWS, @mode varchar(10) = 'fill', @order varchar(10) = '$ORDER', @data varchar(10) = '$DATA', @plain_every int = $PLAIN_EVERY, @block int = $BLOCK, @lob_len int = $LOB_LEN;"
  plan() { { echo "$H"; cat "$DIR/cast.sql" "$DIR/plan-insert.sql"; } | ms; }
  status() { { echo "$H"; cat "$DIR/cast.sql" "$DIR/plan-status.sql"; } | ms | ms; } ;;
ora)                                                 # SQL*Plus takes lines of at most 2,499 characters: statements span lines
  ROWS=${ROWS:-1000000}; SQL="${ORACLE:-sqlplus -s /nolog}"; D=$(echo "$D" | tr a-z A-Z); P="INTO \"$D\".\"%s\" (\n"
  HEAD="SET AUTOCOMMIT ON FEEDBACK OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMOUT ON TRIMSPOOL ON SQLBLANKLINES ON DEFINE OFF"   # (& in a value is no variable)
  OH="SET FEEDBACK OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMOUT ON TRIMSPOOL ON VERIFY OFF SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
DEFINE schema = '$D'
DEFINE rows = $ROWS
DEFINE mode = fill
DEFINE order = $ORDER
DEFINE data = $DATA
DEFINE plain_every = $PLAIN_EVERY
DEFINE block = $BLOCK
DEFINE lob_len = $LOB_LEN"
  plan() { { echo "$OH"; cat "$DIR/cast.sql" "$DIR/plan-insert.sql"; } | $SQL; }
  status() { { echo "$OH"; cat "$DIR/cast.sql" "$DIR/plan-status.sql"; } | $SQL | { echo "$HEAD"; cat; } | $SQL | grep '|'; } ;;
*) echo "engine: pg (postgres, cockroachdb, yugabytedb), my (mysql, mariadb), ms, or ora; db2 and informix: fill.py" >&2; exit 2 ;;
esac
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT              # scratch files
# a status query that fails prints its error: stop, rather than read "no tables below target" as done
checked_status() { local o; o=$(status 2>&1) || { echo "$o" >&2; return 1; }
                   case $o in *ERROR*|*Traceback*) echo "$o" >&2; return 1 ;; esac; printf '%s\n' "$o"; }
CASTF=$DIR/cast.sql                                       # MariaDB has no information_schema srs_id: its spatial SRID is 0
if [ "$E" = my ] && echo "SELECT VERSION();" | $SQL | grep -qi mariadb; then sed 's/c\.srs_id/0/g' "$DIR/cast.sql" > "$W/cast.sql"; CASTF=$W/cast.sql; fi
# one statement per record: a statement starts at its '/* lfc level N */' line; continuation lines join it with \001
records() { awk '/^\/\* lfc level [0-9]+ \*\// { if (s != "") print s; s = $0; next } s != "" { s = s "\001" $0 } END { if (s != "") print s }'; }
levels=$(plan | tee "$W/plan.out" | grep -o '^/\* lfc level [0-9]*' | awk '{ print $4 }' | sort -un)
[ -n "$levels" ] || { echo "the planner wrote no statements:" >&2; head -20 "$W/plan.out" >&2; exit 1; }
for l in $levels; do
  while :; do
    st=$(checked_status) || exit 1
    todo=$(echo "$st" | awk -F'|' '$5 != "" && $4 < $5 { print $1 }')        # tables below target; their statements at this level
    [ -n "$todo" ] || break                                                # (an empty pattern would match every statement)
    pats=$(for t in $todo; do printf "$P" "$t"; [ "$E" = pg ] && printf "INSERT INTO $D.\"%s\" (\n" "$t"; done)
    plan | records | grep "^/\* lfc level $l \*/" | grep -F "$pats" > "$W/run.sql" || break       # (Postgres quotes mixed-case names)
    before=$(checked_status) || exit 1
    rm -f "$W"/part-*                                                      # round robin (BSD and GNU awk)
    awk -v n=$SESSIONS -v w="$W" -v go="$GO" -v head="$HEAD" '{ f = w "/part-" NR % n; if (!(f in seen) && head != "") print head > f; seen[f] = 1
                                                               gsub("\001", "\n"); print > f; if (go != "") print go > f }' "$W/run.sql"
    pids=; for f in "$W"/part-*; do $SQL < "$f" & pids="$pids $!"; done; wait $pids
    # a round that adds nothing would repeat forever: stop and show why (the errors are above)
    now=$(checked_status) || exit 1
    [ "$now" = "$before" ] && { echo "level $l: no rows added; fix the failing statements above, then rerun" >&2; exit 1; }
  done
done
checked_status || exit 1
