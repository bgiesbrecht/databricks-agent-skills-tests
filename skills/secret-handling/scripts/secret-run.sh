#!/usr/bin/env bash
# secret-run.sh <file> <field|-> <ENV_NAME> -- <command> [args...]: run one command with a secret in an environment
#   variable, without printing it. <file> is JSON or YAML (field is a yq path, for example .dba.password) or a plain
#   password file (field -: the whole file, trailing newline removed). The value goes only into ENV_NAME for that one
#   command; nothing is echoed, logged or written.
#   Examples:
#     secret-run.sh creds.json .dba.password SQLCMDPASSWORD -- sqlcmd -S host,1433 -U admin -Q "SELECT 1"
#     secret-run.sh ~/.secrets/pg.pw - PGPASSWORD -- psql -h host -U admin -c 'SELECT 1'
set -euo pipefail
[ $# -ge 5 ] && [ "$4" = -- ] || { sed -n '2,9p' "$0" >&2; exit 2; }
F=$1 K=$2 N=$3; shift 4
[ -r "$F" ] || { echo "secret-run: can't read $F" >&2; exit 2; }
[[ "$N" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "secret-run: $N isn't a variable name" >&2; exit 2; }
if [ "$K" = - ]; then V=$(cat "$F"); else V=$(yq -r "$K // \"\"" "$F"); fi
[ -n "$V" ] || { echo "secret-run: $F has no value at $K" >&2; exit 2; }
export "$N=$V"; unset V
exec "$@"
