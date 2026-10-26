#!/usr/bin/env bash
# sp.sh <profile> --name <display name> --secret-file <file> [--table <catalog.schema.table>] [--apply]
#   For whoever can create service principals, to hand one to a tester who can't: create the service principal (or
#   reuse the one with that name), create an OAuth secret into <file> (0600; never printed), and, with --table, grant
#   it there directly (grant.sh). Prints the application ID to hand over with the file. Plan only without --apply.
#   The tester then runs: SP_CLIENT_ID=<application id> SP_SECRET_FILE=<file> (zerobus-debezium-test).
set -uo pipefail
P=$1; shift; NAME=; FILE=; TABLE=; APPLY=no
while [ $# -gt 0 ]; do case $1 in --name) NAME=$2; shift 2;; --secret-file) FILE=$2; shift 2;; --table) TABLE=$2; shift 2;;
  --apply) APPLY=yes; shift;; *) echo "unknown $1"; exit 2;; esac; done
[ -n "$NAME" ] && [ -n "$FILE" ] || { echo "--name and --secret-file are required"; exit 2; }
dbx() { databricks "$@" --profile "$P"; }
eval "$(dbx service-principals list --filter "displayName eq \"$NAME\"" -o json | yq -o shell '{"ID": (.[0].id // ""), "APP": (.[0].applicationId // "")}')"
if [ -n "$ID" ]; then echo "service principal $NAME exists: application ID $APP"
elif [ $APPLY = yes ]; then
  eval "$(dbx service-principals create --display-name "$NAME" -o json | yq -o shell '{"ID": .id, "APP": .applicationId}')"
  [ -n "$ID" ] && echo "created service principal $NAME: application ID $APP" || { echo "create refused: needs workspace admin"; exit 1; }
else echo "plan: create service principal $NAME"; fi
if [ -s "$FILE" ]; then echo "secret file $FILE exists: kept (delete it to make a new secret)"
elif [ $APPLY = yes ]; then
  (umask 077; dbx service-principal-secrets-proxy create "$ID" -o json | yq -r '.secret' > "$FILE") && [ -s "$FILE" ] \
    && echo "secret written to $FILE ($(stat -f %Lp "$FILE" 2>/dev/null || stat -c %a "$FILE"))" || { rm -f "$FILE"; echo "secret create failed"; exit 1; }
else echo "plan: create an OAuth secret into $FILE (0600)"; fi
[ -n "$TABLE" ] && bash "$(dirname "$0")/grant.sh" "$P" --table "$TABLE" --sp "${APP:-<application id>}" $([ $APPLY = yes ] && echo --apply)
HOST=$(databricks auth describe --profile "$P" -o json 2>/dev/null | jq -r '.details.host // ""' | sed 's:/*$::')
[ -n "$ID" ] && echo "LINK service principal $NAME: $HOST/settings/workspace/identity-and-access/service-principals/$ID"
[ $APPLY = yes ] && echo "hand over: SP_CLIENT_ID=$APP and the file $FILE" || echo "plan only: run again with --apply"
