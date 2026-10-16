# fill.sh <pg|my> <schema>: fill every table of the schema to its target (lfc:rows), one level at a time: a level starts
# only when every table of the level before is complete, which formulas that point at a parent (lfc:v) need. At most
# ROWS per statement and SESSIONS tables at once; it re-plans every round, so a rerun resumes, and stops if a round
# adds no rows (a statement keeps failing).
# The planner files are in DIR (scripts/postgres or scripts/mysql; default: this directory); the client is PSQL or
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
    [ -n "$todo" ] || break                                                # (an empty pattern would match every statement)
    pats=$(for t in $todo; do printf "INSERT INTO $T (\n" "$t"; [ "$E" = pg ] && printf "INSERT INTO $D.\"%s\" (\n" "$t"; done)
    plan | grep "^/\* lfc level $l \*/" | grep -F "$pats" > run.sql || break       # (Postgres quotes mixed-case names)
    before=$(status)
    split -n r/$SESSIONS run.sql part-; pids=
    for f in part-*; do $SQL < $f & pids="$pids $!"; done; wait $pids; rm -f part-*
    # a round that adds nothing would repeat forever: stop and show why (the errors are above)
    [ "$(status)" = "$before" ] && { echo "level $l: no rows added; fix the failing statements above, then rerun" >&2; exit 1; }
  done
done
status
