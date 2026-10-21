#!/usr/bin/env bash
# grant.sh <profile> <principal> --level login|qbc|cdc [--catalog C] [--connection N] [--foreign-catalogs] [--create-connections] [--apply]
#   Give <principal> (a user's email, a group's name, or "account users") exactly what Lakeflow Connect needs in this
#   workspace, and no more. Prints the plan; changes nothing without --apply. Then run check.sh to confirm.
#     login: workspace assignment (USER) + workspace-access, databricks-sql-access on the principal itself
#     qbc:   login + USE CONNECTION on the connection + USE CATALOG, USE SCHEMA, CREATE SCHEMA, CREATE TABLE, SELECT, MODIFY on the catalog
#     cdc:   qbc + CREATE VOLUME on the catalog (staging volumes)
#     --foreign-catalogs:   + CREATE FOREIGN CATALOG on the connection, CREATE CATALOG on the metastore
#     --create-connections: + CREATE CONNECTION on the metastore
#   Run as a workspace admin who owns (or can manage) the catalog and the connection. Grants are made with the Unity Catalog
#   REST API, so no SQL warehouse is needed. A user, rather than a group, gets the entitlements on the user itself.
set -uo pipefail
P=$1; WHO=$2; shift 2; LEVEL=; CAT=; CONN=; FC=; CC=; APPLY=
while [ $# -gt 0 ]; do case $1 in --level) LEVEL=$2; shift 2;; --catalog) CAT=$2; shift 2;; --connection) CONN=$2; shift 2;;
  --foreign-catalogs) FC=1; shift;; --create-connections) CC=1; shift;; --apply) APPLY=1; shift;; *) echo "unknown $1"; exit 2;; esac; done
case $LEVEL in login|qbc|cdc) ;; *) echo "--level login|qbc|cdc"; exit 2;; esac
[ $LEVEL != login ] && [ -z "$CAT" ] && { echo "--catalog is needed for $LEVEL"; exit 2; }
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
q() { printf '%s' "$1" | jq -sRr @uri; }
do_() { echo "  $1"; [ -n "$APPLY" ] || return 0; shift; "$@" > "$T/out" 2>&1 && echo "    done" || { echo "    FAILED: $(grep -m1 -i error "$T/out" | cut -c1-200)"; }; }
grant() { # securable-type name privileges...
  local ty=$1 nm=$2; shift 2; printf '{"changes": [{"principal": "%s", "add": [%s]}]}' "$WHO" "$(printf '"%s",' "$@" | sed 's/,$//')" > "$T/g-$ty.json"
  do_ "GRANT $(printf '%s, ' "$@" | sed 's/, $//' | tr '_' ' ') ON $(echo $ty | tr a-z A-Z) $nm TO \`$WHO\`" databricks grants update $ty "$nm" --json @"$T/g-$ty.json" --profile $P; }
case "$WHO" in
  *@*) ID=$(databricks api get "/api/2.0/account/scim/v2/Users?filter=$(q "userName eq \"$WHO\"")&attributes=id" --profile $P -o json | yq -p json -o tsv '.Resources[0].id // ""'); KIND=Users ;;
  *)   ID=$(databricks api get "/api/2.0/account/scim/v2/Groups?filter=$(q "displayName eq \"$WHO\"")&attributes=id" --profile $P -o json | yq -p json -o tsv '.Resources[0].id // ""'); KIND=Groups ;;
esac
[ -n "$ID" ] || { echo "$WHO not found in this workspace's account"; exit 1; }
echo "== $([ -n "$APPLY" ] && echo Applying || echo "Plan (add --apply to make these changes)") for $WHO in $P: level $LEVEL${CAT:+, catalog $CAT}${CONN:+, connection $CONN}"
echo '{"permissions": ["USER"]}' > "$T/pa.json"
cur=$(databricks api get /api/2.0/preview/permissionassignments --profile $P -o json | I="$ID" yq -p json -o tsv '[.permission_assignments[] | select((.principal.principal_id | tostring) == strenv(I)) | .permissions[]] | join(",")')
if [ -n "$cur" ]; then echo "  workspace assignment: already $cur"; else do_ "assign $WHO to the workspace as USER" databricks api put /api/2.0/preview/permissionassignments/principals/$ID --json @"$T/pa.json" --profile $P; fi
echo '{"schemas": ["urn:ietf:params:scim:api:messages:2.0:PatchOp"], "Operations": [{"op": "add", "path": "entitlements", "value": [{"value": "workspace-access"}, {"value": "databricks-sql-access"}]}]}' > "$T/ent.json"
do_ "entitlements workspace-access, databricks-sql-access on $WHO" databricks api patch /api/2.0/preview/scim/v2/$KIND/$ID --json @"$T/ent.json" --profile $P
MS=$(databricks metastores current --profile $P -o json | yq -p json -o tsv '.metastore_id')
if [ $LEVEL != login ]; then
  [ -n "$CONN" ] && grant connection "$CONN" USE_CONNECTION
  privs="USE_CATALOG USE_SCHEMA CREATE_SCHEMA CREATE_TABLE SELECT MODIFY"; [ $LEVEL = cdc ] && privs="$privs CREATE_VOLUME"
  grant catalog "$CAT" $privs
fi
[ -n "$FC" ] && { [ -n "$CONN" ] && grant connection "$CONN" CREATE_FOREIGN_CATALOG; grant metastore "$MS" CREATE_CATALOG; }
[ -n "$CC" ] && grant metastore "$MS" CREATE_CONNECTION
[ -n "$APPLY" ] && echo "now check: bash $(dirname "$0")/check.sh $P \"$WHO\"${CAT:+ --catalog $CAT}${CONN:+ --connection $CONN}"
