#!/usr/bin/env bash
# keep-catalogs.sh <profile> [--connection N]... [catalog]...: set the RemoveAfter tag on test catalogs to a month from today.
#   Some workspaces tag a catalog that has no RemoveAfter tag with a date a couple of weeks out and delete it on that
#   date. This sets RemoveAfter to today + 1 month (KEEP_UNTIL=YYYY-MM-DD for another date) on each catalog named, and
#   with --connection N on every foreign catalog made from connection N. It never moves a later date earlier.
#   One line per catalog: kept (already later), set or updated, or failed with the CLI's error; none for a --connection
#   with no foreign catalog. Exit 1 if any failed (a failed catalogs list too).
#   Runs from the harness (bin/run_batch.sh) on $LFC_CATALOG and the env's connections, and after a script creates a
#   connection. Needs APPLY TAG on the catalog (or ownership); a governed RemoveAfter tag also needs ASSIGN on its policy.
set -uo pipefail
P=${1:?usage: keep-catalogs.sh <profile> [--connection N]... [catalog]...}; shift
CONNS=(); CATS=()
while [ $# -gt 0 ]; do case $1 in --connection) CONNS+=("${2:?--connection needs a name}"); shift 2;; -*) echo "unknown $1"; exit 2;; *) CATS+=("$1"); shift;; esac; done
UNTIL=${KEEP_UNTIL:-$(date -v+1m +%Y-%m-%d 2>/dev/null || date -u -d '+1 month' +%Y-%m-%d)}
bad=0
if [ ${#CONNS[@]} -gt 0 ]; then
  E=$(mktemp); trap 'rm -f "${E:?}"' EXIT
  if ! all=$(databricks catalogs list --profile "$P" -o json 2> "$E"); then
    echo "failed  catalogs list: $(head -c 200 "$E" | tr '\n' ' ')"; bad=1; all='[]'; fi
  for c in "${CONNS[@]}"; do
    if ! found=$(echo "$all" | jq -r --arg c "$c" '.[] | select(.catalog_type == "FOREIGN_CATALOG" and .connection_name == $c) | .name' 2> "$E"); then
      echo "failed  foreign catalogs of $c: catalogs list isn't a JSON list ($(head -c 120 "$E" | tr '\n' ' '))"; bad=1; continue; fi
    [ -n "$found" ] || { [ $bad = 0 ] && echo "none    foreign catalogs of $c"; }
    while IFS= read -r n; do [ -n "$n" ] && CATS+=("$n"); done <<< "$found"
  done
fi
[ ${#CATS[@]} -gt 0 ] || exit $bad
for n in "${CATS[@]}"; do
  cur=$(databricks entity-tag-assignments get catalogs "$n" RemoveAfter --profile "$P" -o json 2>/dev/null | jq -r '.tag_value // ""')
  if [ -n "$cur" ] && [[ ! "$cur" < "$UNTIL" ]]; then echo "kept    $n RemoveAfter=$cur"; continue; fi
  if [ -n "$cur" ]; then verb=updated; out=$(databricks entity-tag-assignments update catalogs "$n" RemoveAfter tag_value --json "{\"tag_value\": \"$UNTIL\"}" --profile "$P" -o json 2>&1)
  else verb=set; out=$(databricks entity-tag-assignments create "$n" RemoveAfter catalogs --tag-value "$UNTIL" --profile "$P" -o json 2>&1); fi
  if [ $? -eq 0 ]; then printf "%-7s %s RemoveAfter=%s%s\n" "$verb" "$n" "$UNTIL" "${cur:+ (was $cur)}"
  else echo "failed  $n: $(echo "$out" | head -c 200 | tr '\n' ' ')"; bad=1; fi
done
exit $bad
