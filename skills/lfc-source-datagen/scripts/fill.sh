# fill.sh <pg|my> <schema>: fill every table of the schema to its target (lfc:rows), one level at a time: a level starts
# only when every table of the level before is complete, which formulas that point at a parent (lfc:v) need. At most
# ROWS per statement and SESSIONS tables at once; it re-plans every round, so a rerun resumes, and stops if a round
# adds no rows (a statement keeps failing).
# The planner files are in DIR (scripts/postgres or scripts/mysql; default: this directory); the client is PSQL or
# MYSQL (default psql / mysql, connection from the usual environment: PGHOST... or MYSQL_HOST, MYSQL_PWD...).
# The rows' shape: ORDER (random | asc | desc), DATA (scramble | seq | random), PLAIN_EVERY and BLOCK (plain, auditable
# blocks), LOB_LEN (length of unbounded strings and binaries); defaults as in the skill.
E=$1; D=$2; DIR=${DIR:-.}; SESSIONS=${SESSIONS:-4}
ORDER=${ORDER:-random}; DATA=${DATA:-scramble}; PLAIN_EVERY=${PLAIN_EVERY:-4}; BLOCK=${BLOCK:-1000}; LOB_LEN=${LOB_LEN:-100}
if [ "$E" = pg ]; then
  ROWS=${ROWS:-1000000}; SQL="${PSQL:-psql} -X -At -q -v ON_ERROR_STOP=1"; T="$D.%s"
  plan() { cat "$DIR/cast.sql" "$DIR/plan-insert.sql" | $SQL -v schema=$D -v rows=$ROWS -v src=seed -v mode=fill -v order=$ORDER -v data=$DATA \
                -v plain_every=$PLAIN_EVERY -v block=$BLOCK -v lob_len=$LOB_LEN; }
  status() { $SQL -v schema=$D < "$DIR/plan-status.sql" | $SQL; }
else
  ROWS=${ROWS:-100000}; SQL="${MYSQL:-mysql} -N -B -r $D"; T="\`$D\`.\`%s\`"
  plan() { { echo "SET @db='$D', @rows=$ROWS, @src='seed', @mode='fill', @order='$ORDER', @data='$DATA', @plain_every=$PLAIN_EVERY, @block=$BLOCK, @lob_len=$LOB_LEN;"; cat "$DIR/cast.sql" "$DIR/plan-insert.sql"; } | $SQL; }
  status() { { echo "SET @db='$D';"; cat "$DIR/plan-status.sql"; } | $SQL | $SQL | tr '\t' '|'; }
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT              # scratch files
for l in $(plan | grep -o '^/\* lfc level [0-9]*' | awk '{ print $4 }' | sort -un); do
  while :; do
    todo=$(status | awk -F'|' '$5 != "" && $4 < $5 { print $1 }')        # tables below target; their statements at this level
    [ -n "$todo" ] || break                                                # (an empty pattern would match every statement)
    pats=$(for t in $todo; do printf "INSERT INTO $T (\n" "$t"; [ "$E" = pg ] && printf "INSERT INTO $D.\"%s\" (\n" "$t"; done)
    plan | grep "^/\* lfc level $l \*/" | grep -F "$pats" > "$W/run.sql" || break       # (Postgres quotes mixed-case names)
    before=$(status)
    rm -f "$W"/part-*; awk -v n=$SESSIONS -v w="$W" '{ print > (w "/part-" NR % n) }' "$W/run.sql"   # round robin (BSD and GNU)
    pids=; for f in "$W"/part-*; do $SQL < "$f" & pids="$pids $!"; done; wait $pids
    # a round that adds nothing would repeat forever: stop and show why (the errors are above)
    [ "$(status)" = "$before" ] && { echo "level $l: no rows added; fix the failing statements above, then rerun" >&2; exit 1; }
  done
done
status
