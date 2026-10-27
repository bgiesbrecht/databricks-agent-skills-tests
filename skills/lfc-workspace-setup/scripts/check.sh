#!/usr/bin/env bash
# check.sh <profile> <principal> [--catalog C] [--connection N] [--modes qbc,fcqbc,icdc,scdc]
#   Can <principal> (a user's email, a group's name, or "account users") run Lakeflow Connect in this workspace?
#   Read-only. One line per requirement: PASS / FAIL / WARN, and for each FAIL the command or SQL that fixes it
#   (run those as a workspace admin or the securable's owner; or use grant.sh). Exit code 1 if anything FAILs.
set -uo pipefail
P=$1; WHO=$2; shift 2; CAT=; CONN=; MODES=qbc,icdc
while [ $# -gt 0 ]; do case $1 in --catalog) CAT=$2; shift 2;; --connection) CONN=$2; shift 2;; --modes) MODES=$2; shift 2;; *) echo "unknown $1"; exit 2;; esac; done
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT; fails=0
api() { databricks api get "$1" --profile $P -o json 2>/dev/null; }
row() { printf "%-5s %-44s %s\n" "$1" "$2" "$3"; [ "$1" = FAIL ] && fails=$((fails + 1)); [ -n "${4:-}" ] && printf "      fix: %s\n" "$4"; return 0; }
has() { case ",$MODES," in *,$1,*) return 0;; esac; return 1; }
q() { printf '%s' "$1" | jq -sRr @uri; }
eff() { databricks grants get-effective "$1" "$2" --principal "$WHO" --profile $P -o json 2>/dev/null \
        | yq -p json -o tsv '[.privilege_assignments[]?.privileges[]?.privilege] | unique | join(" ")'; }
inp() { case " $1 " in *" $2 "*|*" ALL_PRIVILEGES "*) return 0;; esac; return 1; }
# $1 is the principal or one of its groups; or the workspace's admins group (_workspace_admins_<name>_<workspace id>,
# which owns the catalog a workspace is created with) when the principal is a workspace admin
mine() { [ -n "$1" ] && { [ "$1" = "$WHO" ] || case "|$PGROUPS|" in *"|$1|"*) true;; *) case "$1" in _workspace_admins_*_"$WSID") [ "${WSADMIN:-no}" = yes ];; *) false;; esac;; esac; }; }

echo "== $WHO in $P (modes: $MODES${CAT:+, catalog $CAT}${CONN:+, connection $CONN})"
# --- the principal, and the groups it's in (users: from the account; a group or "account users": itself)
case "$WHO" in
  *@*) api "/api/2.0/account/scim/v2/Users?filter=$(q "userName eq \"$WHO\"")&attributes=id,groups" > $T/u.json
       KIND=user; ID=$(yq -p json -o tsv '.Resources[0].id // ""' $T/u.json); PGROUPS="$(yq -p json -o tsv '[.Resources[0].groups[]?.display] | join("|")' $T/u.json)|account users" ;;
  *)   api "/api/2.0/account/scim/v2/Groups?filter=$(q "displayName eq \"$WHO\"")&attributes=id" > $T/g.json
       KIND=group; ID=$(yq -p json -o tsv '.Resources[0].id // ""' $T/g.json); PGROUPS= ;;
esac
[ -n "$ID" ] && row PASS "principal exists in the account ($KIND)" "id $ID" || { row FAIL "principal exists in the account" "$WHO not found"; exit 1; }

# --- workspace: Unity Catalog, connector previews
databricks metastores current --profile $P -o json 2>/dev/null > $T/ms.json; MS=$(yq -p json -o tsv '.metastore_id // ""' $T/ms.json); WSID=$(yq -p json -o tsv '.workspace_id // ""' $T/ms.json)
[ -n "$MS" ] && row PASS "Unity Catalog metastore assigned" "" || row FAIL "Unity Catalog metastore assigned" "none" "assign the workspace to a metastore (account admin)"
# the database connectors in the CDC overview (MySQL, PostgreSQL, Microsoft SQL Server, Oracle). PostgreSQL has no setting
# on a workspace whose rollout hasn't reached it yet: the API says "not yet available", and that is an INFO, not a WARN
for e in sql_server mysql oracle postgres; do has icdc || break
  v=$(api /api/2.1/settings/integrated_cdc_${e}_connector | yq -p json -o tsv 'with(select(has("boolean_val")); .v = .boolean_val.value) | with(select(has("boolean_val") | not); .v = .effective_boolean_val.value) | .v')
  [ "$e" = postgres ] && [ -z "$v" -o "$v" = null ] && { row INFO "integrated CDC preview: $e" "no setting on this workspace (rolled out in phases)"; continue; }
  [ "$v" = true ] && row PASS "integrated CDC preview: $e" "on" || row WARN "integrated CDC preview: $e" "${v:-not found}" "enable it (lfc-workspace-setup step 1), or ask the account team"
done

CALLER=$(databricks current-user me --profile $P -o json 2>/dev/null | yq -p json -o tsv '.userName // ""'); SELF=no; [ "$CALLER" = "$WHO" ] && SELF=yes
WSADMIN=no                                                       # in the workspace's own admins group
if [ $SELF = yes ]; then api /api/2.0/preview/scim/v2/Me | yq -p json -e '.groups[]? | select(.display == "admins")' > /dev/null 2>&1 && WSADMIN=yes
elif [ $KIND = user ]; then api "/api/2.0/preview/scim/v2/Users?filter=$(q "userName eq \"$WHO\"")&attributes=groups" | yq -p json -e '.Resources[0].groups[]? | select(.display == "admins")' > /dev/null 2>&1 && WSADMIN=yes; fi
# --- login: assigned (directly or through a group), and entitlements. Fields are joined with '|': read collapses empty tab-separated ones
api /api/2.0/preview/permissionassignments > $T/pa.json
assigned=$(yq -p json -o tsv '.permission_assignments[] | (.principal.display_name // .principal.user_name // "") + "|" + (.principal.user_name // "") + "|" + (.permissions | join(","))' $T/pa.json \
  | while IFS='|' read -r n u perm; do if mine "$n" || [ "$u" = "$WHO" ]; then printf '%s:%s ' "$n" "$perm"; fi; done)
READABLE=yes; yq -p json -e '.permission_assignments' $T/pa.json > /dev/null 2>&1 || READABLE=no      # non-admins get nothing back
if [ -n "$assigned" ]; then row PASS "assigned to the workspace" "$assigned"
elif [ $SELF = yes ]; then row PASS "assigned to the workspace" "you're logged in, so through a group ($(api /api/2.0/preview/scim/v2/Me | yq -p json -o tsv '[.groups[]?.display] | .[0:4] | join(", ")'))"
elif [ $READABLE = no ]; then row WARN "assigned to the workspace" "can't read assignments without workspace admin"
else row FAIL "assigned to the workspace" "not directly or through a group" "databricks api put /api/2.0/preview/permissionassignments/principals/$ID --json '{\"permissions\": [\"USER\"]}' --profile $P"; fi
admin=no; case "$assigned" in *ADMIN*) admin=yes;; esac
ents=$( { [ $KIND = user ] && api "/api/2.0/preview/scim/v2/Users?filter=$(q "userName eq \"$WHO\"")&attributes=entitlements" | yq -p json -o tsv '[.Resources[0].entitlements[]?.value] | join(" ")'
          for g in $( [ $KIND = group ] && echo "$ID" ); do api "/api/2.0/preview/scim/v2/Groups/$g?attributes=entitlements" | yq -p json -o tsv '[.entitlements[]?.value] | join(" ")'; done
          yq -p json -o tsv '.permission_assignments[] | select(.principal.group_name != null) | (.principal.principal_id | tostring) + "|" + .principal.display_name' $T/pa.json \
          | while IFS='|' read -r a n; do mine "$n" && api "/api/2.0/preview/scim/v2/Groups/$a?attributes=entitlements" | yq -p json -o tsv '[.entitlements[]?.value] | join(" ")'; done; } | tr '\n' ' ')
[ $SELF = yes ] && ents="$ents $(api /api/2.0/preview/scim/v2/Me | yq -p json -o tsv '[.entitlements[]?.value] | join(" ")') $(api /api/2.0/preview/scim/v2/Me | yq -p json -o tsv '.groups[]?.value' | while read g; do api "/api/2.0/preview/scim/v2/Groups/$g?attributes=entitlements" | yq -p json -o tsv '[.entitlements[]?.value] | join(" ")'; done | tr '\n' ' ')"
for e in workspace-access databricks-sql-access; do
  if [ $admin = yes ] || inp "$ents" $e; then row PASS "entitlement $e" "$([ $admin = yes ] && echo 'as workspace admin' || echo granted)"
  elif [ $SELF = yes ] && [ $e = workspace-access ]; then row PASS "entitlement $e" "you're logged in"
  elif [ $READABLE = no ] || [ $SELF = yes ]; then row WARN "entitlement $e" "not visible to a non-admin; try it (open a SQL editor) or ask an admin"
  else row FAIL "entitlement $e" "missing" "PATCH it onto $WHO's group (lfc-workspace-setup step 3; built-in users/admins may be locked)"; fi; done

# --- Unity Catalog: metastore, connection, catalog
m=$(eff metastore "$MS"); MSOWN=$(databricks metastores get "$MS" --profile $P -o json 2>/dev/null | yq -p json -o tsv '.owner // ""'); mine "$MSOWN" && m="$m ALL_PRIVILEGES"
inp "$m" CREATE_CONNECTION && row PASS "CREATE CONNECTION on the metastore" "$(mine "$MSOWN" && echo "metastore owner: $MSOWN")" || row WARN "CREATE CONNECTION on the metastore" "no: can only use existing connections" "GRANT CREATE CONNECTION ON METASTORE TO \`$WHO\`"
if has fcqbc; then inp "$m" CREATE_CATALOG && row PASS "CREATE CATALOG on the metastore (foreign catalog)" "" || row WARN "CREATE CATALOG on the metastore (foreign catalog)" "no: needs an existing foreign catalog to use" "GRANT CREATE CATALOG ON METASTORE TO \`$WHO\`, or GRANT USE CATALOG on an existing foreign catalog"; fi
if [ -n "$CONN" ]; then c=$(eff connection "$CONN"); own=$(databricks connections get "$CONN" --profile $P -o json 2>/dev/null | yq -p json -o tsv '.owner // ""')
  if mine "$own" || inp "$c" USE_CONNECTION; then row PASS "USE CONNECTION on $CONN" "${own:+owner $own}"; else row FAIL "USE CONNECTION on $CONN" "no" "GRANT USE CONNECTION ON CONNECTION \`$CONN\` TO \`$WHO\`"; fi
  if has fcqbc; then { inp "$c" CREATE_FOREIGN_CATALOG || mine "$own"; } && row PASS "CREATE FOREIGN CATALOG on $CONN" "" || row FAIL "CREATE FOREIGN CATALOG on $CONN" "no" "GRANT CREATE FOREIGN CATALOG ON CONNECTION \`$CONN\` TO \`$WHO\`"; fi
fi
if [ -n "$CAT" ]; then k=$(eff catalog "$CAT"); cown=$(databricks catalogs get "$CAT" --profile $P -o json 2>/dev/null | yq -p json -o tsv '.owner // ""'); mine "$cown" && k="$k ALL_PRIVILEGES"
  for pv in USE_CATALOG CREATE_SCHEMA USE_SCHEMA CREATE_TABLE; do
    inp "$k" $pv && row PASS "$pv on $CAT" "" || row FAIL "$pv on $CAT" "no" "GRANT ${pv//_/ } ON CATALOG \`$CAT\` TO \`$WHO\`"; done
  if has icdc || has scdc; then
    inp "$k" CREATE_VOLUME && row PASS "CREATE VOLUME on $CAT (CDC staging)" "" || row FAIL "CREATE VOLUME on $CAT (CDC staging)" "no" "GRANT CREATE VOLUME ON CATALOG \`$CAT\` TO \`$WHO\`"
    root=$(databricks catalogs get "$CAT" --profile $P -o json 2>/dev/null | yq -p json -o tsv '.storage_root // ""'); ds=$(databricks external-locations get __databricks_managed_storage_location --profile $P -o json 2>/dev/null | yq -p json -o tsv '.url // ""')
    if [ -n "$ds" ] && [ "${root#"$ds"}" != "$root" ]; then row FAIL "$CAT not on Default Storage (CDC)" "it is" "use a catalog with its own managed location"; else row PASS "$CAT not on Default Storage (CDC)" ""; fi; fi
  iso=$(databricks catalogs get "$CAT" --profile $P -o json 2>/dev/null | yq -p json -o tsv '.isolation_mode // ""')
  if [ "$iso" = ISOLATED ]; then bound=$(databricks workspace-bindings get "$CAT" --profile $P -o json 2>/dev/null | W="$WSID" yq -p json -o tsv '[.workspaces[]? | select(tostring == strenv(W))] | length')
    [ "${bound:-0}" -gt 0 ] && row PASS "$CAT visible here (ISOLATED, bound to this workspace)" "" || row FAIL "$CAT visible here (ISOLATED)" "not bound to workspace $WSID" "databricks workspace-bindings update $CAT --json '{\"assign_workspaces\": [$WSID]}' --profile $P"
  else row PASS "$CAT visible here" "${iso:-OPEN}"; fi
fi
echo; [ $fails -eq 0 ] && echo "ready: nothing failed" || echo "$fails requirement(s) failed"; exit $((fails > 0))
