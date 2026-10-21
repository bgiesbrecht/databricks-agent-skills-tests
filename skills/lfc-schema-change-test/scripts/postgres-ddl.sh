#!/usr/bin/env bash
# postgres-ddl.sh: what each PostgreSQL DDL does to Lakeflow Connect CDC: applied in place, or which error, and does a
# full refresh (asked for, or by auto_full_refresh_policy) recover the table? Answers lfc-faq #10, #11, #12 (Postgres)
# and #13. One table per case, each gets its DDL and then one new row (Postgres sends a table's new shape with its next
# change). Every table has a primary key and REPLICA IDENTITY DEFAULT unless the case says otherwise.
#
#   add_null      ADD COLUMN c INT                          (#10)
#   add_def       ADD COLUMN c INT DEFAULT 5                (#10, #12)
#   afr_add_def   the same, with auto_full_refresh_policy   (#12)
#   add_text      ADD COLUMN c TEXT                         (#11: a TOAST-able column, replica identity DEFAULT)
#   add_text_full ADD COLUMN c TEXT, replica identity FULL  (#11)
#   dropcol       DROP COLUMN x                             (#11)
#   ri_to_default replica identity FULL -> DEFAULT          (#11, with a TEXT column)
#   ri_nothing    replica identity DEFAULT -> NOTHING       (#11)
#   narrow        ALTER COLUMN n TYPE INT (from BIGINT)     (#12)
#   widen         ALTER COLUMN n TYPE NUMERIC(30)           (#12)
#   rename        RENAME COLUMN x TO x2                     (#12)
#   pk            primary key (id) -> (id, n)               (#12)
#   truncate      TRUNCATE, then the row                    (#12)
#   afr_truncate  the same, with auto_full_refresh_policy   (#12)
#   collate       ADD COLUMN c TEXT COLLATE "C"             (#13)
#   multi_a/b     ALTER TABLE a ...; ALTER TABLE b ... sent as one query string (#13)
#
#   Needs: PROFILE CONNECTION (a POSTGRESQL connection) CATALOG CONN_USER (a role with REPLICATION),
#          SRC_SQL (SQL from stdin as a superuser, first arg the database: scripts/vm-psql.sh); SRC_ENV, MODE, KEEP, OUT
#   Prints one row per case (OBSERVED: what happened) and per recovery claim (PASS/FAIL); exits 1 if a claim failed.
set -uo pipefail
ENGINE=postgres
. "$(dirname "$0")/lib.sh"
lfc_init pgddl
TABLES="add_null add_def afr_add_def add_text add_text_full dropcol ri_to_default ri_nothing narrow widen rename pk truncate afr_truncate collate multi_a multi_b"
FP_TABLES=$TABLES

{ for t in $TABLES; do
    echo "CREATE TABLE lfcddemo.$t (id INT NOT NULL PRIMARY KEY, v VARCHAR(20), x INT, n BIGINT NOT NULL DEFAULT 1$( [ $t = ri_to_default ] && echo ', tx TEXT'));"
  done
  echo "ALTER TABLE lfcddemo.add_text_full REPLICA IDENTITY FULL;"
  echo "ALTER TABLE lfcddemo.ri_to_default REPLICA IDENTITY FULL;"; } | src_db
for t in $TABLES; do fill $t 10; done
SEEN=$(rq "SELECT COUNT(*) AS n FROM lfcddemo.add_null" 2>&1)
[ "$SEEN" = 10 ] || { echo "serverless can't read the source through $CONNECTION: $SEEN"; exit 2; }

OBJS=""; for t in $TABLES; do case $t in afr_*) OBJS+="${OBJS:+,}$(obj $t "$AFR")";; *) OBJS+="${OBJS:+,}$(obj $t)";; esac; done
pipelines_create "$OBJS"
allrows() { q "SELECT $(for t in $TABLES; do printf '(SELECT COUNT(*) FROM %s.%s),' "$T" "$t"; done | sed 's/,$//')" 2>&1 | tr '\t' ' '; }
WANT=$(for t in $TABLES; do printf '10 '; done | sed 's/ $//')
update; R=$(allrows); [ "$R" = "$WANT" ] || { update; R=$(allrows); }
[ "$R" = "$WANT" ] || { echo "baseline rows wrong: $R; $ERRS"; exit 1; }

# --- the DDL, then one row each ------------------------------------------------------------------------------------
ddl() {
  case $1 in
    add_null)        echo "ALTER TABLE lfcddemo.$1 ADD COLUMN c INT;";;
    add_def|afr_add_def) echo "ALTER TABLE lfcddemo.$1 ADD COLUMN c INT DEFAULT 5;";;
    add_text|add_text_full) echo "ALTER TABLE lfcddemo.$1 ADD COLUMN c TEXT;";;
    dropcol)         echo "ALTER TABLE lfcddemo.$1 DROP COLUMN x;";;
    ri_to_default)   echo "ALTER TABLE lfcddemo.$1 REPLICA IDENTITY DEFAULT;";;
    ri_nothing)      echo "ALTER TABLE lfcddemo.$1 REPLICA IDENTITY NOTHING;";;
    narrow)          echo "ALTER TABLE lfcddemo.$1 ALTER COLUMN n TYPE INT;";;
    widen)           echo "ALTER TABLE lfcddemo.$1 ALTER COLUMN n TYPE NUMERIC(30);";;
    rename)          echo "ALTER TABLE lfcddemo.$1 RENAME COLUMN x TO x2;";;
    pk)              echo "ALTER TABLE lfcddemo.$1 DROP CONSTRAINT $1_pkey; ALTER TABLE lfcddemo.$1 ADD PRIMARY KEY (id, n);";;
    truncate|afr_truncate) echo "TRUNCATE lfcddemo.$1;";;
    collate)         echo "ALTER TABLE lfcddemo.$1 ADD COLUMN c TEXT COLLATE \"C\";";;
    multi_a)         echo 'ALTER TABLE lfcddemo.multi_a ADD COLUMN c INT \; ALTER TABLE lfcddemo.multi_b ADD COLUMN c INT;';;   # \; : one query string
    multi_b)         ;;
  esac
}
for t in $TABLES; do
  out=$(ddl $t | src 2>&1) || echo "source DDL on $t failed: $(echo "$out" | head -2)"
done
# ri_nothing: an UPDATE/DELETE can't be replicated, so only an insert (allowed); the rest insert too
for t in $TABLES; do echo "INSERT INTO lfcddemo.$t (id, v) VALUES (11, 'after');" | src >/dev/null 2>&1 || echo "insert into $t failed"; done
want_rows() { case $1 in truncate|afr_truncate) echo 1;; *) echo 11;; esac; }
for _ in 1 2 3 4; do
  sleep "$WAIT"; update
  n=0; for t in $TABLES; do { [ -n "$(errs_for $t)" ] || [ "$(q "SELECT COUNT(*) FROM $T.$t" 2>&1)" = "$(want_rows $t)" ]; } && n=$((n + 1)); done
  [ $n -eq $(echo $TABLES | wc -w) ] && break
done
cols() { q "SELECT CONCAT_WS(',', COLLECT_LIST(CONCAT(column_name, ':', data_type))) FROM \`$CATALOG\`.information_schema.columns WHERE table_schema = '$S' AND table_name = '$1'" 2>&1; }
ERRF=$W/errs.tsv; : > "$ERRF"
for t in $TABLES; do
  e=$(errs_for $t); printf '%s\t%s\n' "$t" "$e" >> "$ERRF"
  observe "$t" "errors: ${e:-none}$( [ -n "${e// /}" ] && echo "; $(msgs_for $t | head -1 | cut -c1-180)"); rows $(q "SELECT COUNT(*) FROM $T.$t" 2>&1) (source $(want_rows $t)); columns $(cols $t)"
done
err_of() { awk -F'\t' -v t="$1" '$1 == t { print $2 }' "$ERRF"; }

# --- the policy: afr_* recover with no refresh asked for (up to 3 more updates) ----------------------------------------
for _ in 1 2 3; do
  [ "$(q "SELECT COUNT(*) FROM $T.afr_add_def" 2>&1)" = 11 ] && [ "$(q "SELECT COUNT(*) FROM $T.afr_truncate" 2>&1)" = 1 ] && break; update
done
for p in add_def:afr_add_def truncate:afr_truncate; do
  off=${p%%:*} on=${p##*:}; r=$(q "SELECT COUNT(*) FROM $T.$on" 2>&1)
  if [ -n "$(err_of $off | tr -d ' ')" ]; then
    [ "$r" = "$(want_rows $on)" ] && claim "$on-recovers" PASS "$off asked for a full refresh ($(err_of $off)); $on recovered on its own: $r rows" \
      || claim "$on-recovers" FAIL "$off: $(err_of $off); $on rows $r (source $(want_rows $on)), errors $(errs_for $on)"
  else observe "$on" "$off had no error; $on rows $r"; fi
done

# --- a requested full refresh recovers each table that stopped ------------------------------------------------------
FR=""; for t in $TABLES; do [[ $t == afr_* ]] && continue; [ "$(q "SELECT COUNT(*) FROM $T.$t" 2>&1)" = "$(want_rows $t)" ] || FR+="${FR:+,}$t"; done
if [ -n "$FR" ]; then
  update "$FR"
  bad=""; for t in ${FR//,/ }; do [ "$(q "SELECT COUNT(*) FROM $T.$t" 2>&1)" = "$(want_rows $t)" ] || bad+=" $t($(errs_for $t | tr -d ' '))"; done
  [ -z "$bad" ] && claim full-refresh-recovers PASS "full refresh of $FR: each matches the source" || claim full-refresh-recovers FAIL "after refreshing $FR, still off:$bad"
fi
# then one more change on every table arrives incrementally
for t in $TABLES; do echo "INSERT INTO lfcddemo.$t (id, v) VALUES (12, 'last');" | src >/dev/null 2>&1; done
settle_rows "SELECT SUM(c) FROM ($(for t in $TABLES; do printf 'SELECT COUNT(*) AS c FROM %s.%s WHERE id = 12 UNION ALL ' "$T" "$t"; done | sed 's/ UNION ALL $//'))" "$(echo $TABLES | wc -w | tr -d ' ')"
[ "$SETTLED" = 1 ] && claim then-incremental PASS "a new row in every table arrived after the recovery" \
  || claim then-incremental FAIL "tables missing the last row: $(for t in $TABLES; do [ "$(q "SELECT COUNT(*) FROM $T.$t WHERE id = 12" 2>&1)" = 1 ] || printf '%s ' $t; done); errors: ${ERRS:-none}"

result_md postgres-ddl
exit $FAILED
