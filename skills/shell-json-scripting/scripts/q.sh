#!/bin/bash
# q.sh <query.sql>: run the query in DuckDB (after lib.sql from the query's directory, if there is one), filling each
# getvariable('X') from env var X, and print the query's single result row as shell assignments for eval:
#   eval "$(q.sh dir/step.sql)"
set -eo pipefail
lib="$(dirname "$1")/lib.sql"; [ -f "$lib" ] || lib=/dev/null
vars=$(cat "$lib" "$1" | grep -o "getvariable('[A-Za-z_][A-Za-z0-9_]*')" | sed "s/getvariable('\(.*\)')/\1/" | sort -u)
out=$({ for v in $vars; do echo "SET VARIABLE $v = getenv('$v');"; done; cat "$lib" "$1"; } | duckdb -bail -json)
[ -n "$out" ] || { echo "q.sh: $1 returned no row" >&2; exit 1; }
yq -p json -o shell '.[0]' <<< "$out"
