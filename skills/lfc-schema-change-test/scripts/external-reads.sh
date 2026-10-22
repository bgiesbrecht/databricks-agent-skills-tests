#!/usr/bin/env bash
# external-reads.sh: who else can read a Lakeflow Connect destination streaming table? Answers lfc-faq #3 (dbt and
# external engines). Runs against a destination table a test kept (KEEP=1, e.g. sqlserver-cdf.sh):
#
#   dbt             dbt-databricks on a SQL warehouse: a table model and an incremental model from the streaming table
#                   (declared as a dbt source), and a view over its table_changes()
#   uniform         ALTER TABLE, then ALTER STREAMING TABLE ... SET TBLPROPERTIES for Iceberg reads (UniForm)
#   vending         temporary table credentials for READ (what an external engine with Unity Catalog credential vending,
#                   such as DuckDB or Spark outside Databricks, asks for)
#   iceberg-rest    load the table through the Unity Catalog Iceberg REST catalog (what an Iceberg reader asks for)
#   sharing         add the table to a new Delta Sharing share (dropped at the end)
#
#   Needs: TABLE (catalog.schema.table of the kept destination table), and lib.sh's PROFILE CONNECTION CATALOG SRC_SQL
#          CONN_USER (only used for the run record); WAREHOUSE (default: the first serverless one); uv (for dbt).
#   Creates and drops a schema <prefix>_dbt_<epoch> next to the table and a share <prefix>_share_<epoch>.
#   Prints an OBSERVED row per case; nothing has a claimed answer yet.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
: "${TABLE:?catalog.schema.table of a kept destination table}"
IFS=. read -r TC TS TT <<< "$TABLE"
ME=$(dbx current-user me -o json | yq '.userName'); PREFIX=${PREFIX:-$(echo "$ME" | cut -d@ -f1 | tr -d '.-' | tr 'A-Z' 'a-z')}
WAREHOUSE=${WAREHOUSE:-$(dbx warehouses list -o json | yq '[.[] | select(.enable_serverless_compute)][0].id')}; export WAREHOUSE
E=$(date +%s); W=$(mktemp -d); FT="\`$TC\`.\`$TS\`.\`$TT\`"
DS=${PREFIX}_dbt_$E; SHARE=${PREFIX}_share_$E
AP=$(dbx tables get "$TC.$TS.$TT" -o json | yq '.pipeline_id // ""')
echo "run $E: table $TABLE (pipeline ${AP:-none}), dbt schema $TC.$DS, share $SHARE"
done_() { q "DROP SCHEMA IF EXISTS \`$TC\`.\`$DS\` CASCADE" >/dev/null 2>&1; q "DROP SHARE IF EXISTS \`$SHARE\`" >/dev/null 2>&1; rm -rf "${W:?}"; }
trap done_ EXIT
api_err() { yq -p json '(.error_code // "") + " " + (.message // "" | .[0:220])' 2>/dev/null; }

# --- dbt -------------------------------------------------------------------------------------------------------------
HOST=$(dbx auth describe -o json 2>/dev/null | yq '.details.host // .host // ""' | sed 's#^https://##; s#/$##')
mkdir -p "$W/dbt/models"
cat > "$W/dbt/dbt_project.yml" <<EOF
name: lfc_reads
version: "1.0"
profile: lfc_reads
model-paths: [models]
EOF
cat > "$W/dbt/profiles.yml" <<EOF
lfc_reads:
  target: t
  outputs:
    t:
      type: databricks
      host: $HOST
      http_path: /sql/1.0/warehouses/$WAREHOUSE
      token: "{{ env_var('DBT_DATABRICKS_TOKEN') }}"
      catalog: $TC
      schema: $DS
EOF
cat > "$W/dbt/models/sources.yml" <<EOF
version: 2
sources:
  - name: lfc
    database: $TC
    schema: $TS
    tables:
      - name: $TT
EOF
V=$(q "SELECT MAX(version) FROM (DESCRIBE HISTORY $FT)" 2>&1)
printf "{{ config(materialized='table') }}\nselect * from {{ source('lfc', '%s') }}\n" "$TT" > "$W/dbt/models/lfc_copy.sql"
printf "{{ config(materialized='incremental', unique_key='id', incremental_strategy='merge') }}\nselect * from {{ source('lfc', '%s') }}\n" "$TT" > "$W/dbt/models/lfc_incr.sql"
printf "{{ config(materialized='view') }}\nselect * from table_changes('%s', %s)\n" "\`$TC\`.\`$TS\`.\`$TT\`" "$((V > 1 ? V - 1 : 1))" > "$W/dbt/models/lfc_changes.sql"
export DBT_DATABRICKS_TOKEN; DBT_DATABRICKS_TOKEN=$(dbx auth token -o json | yq '.access_token')
dbt() { (cd "$W/dbt" && uvx --quiet --from dbt-databricks dbt "$@" --profiles-dir . > "$W/dbt.out" 2>&1); }
dbt_err() { sed 's/\x1b\[[0-9;]*m//g' "$W/dbt.out" | grep -A3 -E 'Database Error|Runtime Error|Compilation Error' | grep -v -E '^--$|Error in model|^ *$' | tr -s ' ' | head -3 | paste -sd' ' - | cut -c1-300; }
for m in lfc_copy lfc_incr lfc_changes; do
  if dbt run --select "$m"; then observe "dbt-$m" "dbt run passed; rows $(q "SELECT COUNT(*) FROM \`$TC\`.\`$DS\`.$m" 2>&1) (streaming table $(q "SELECT COUNT(*) FROM $FT" 2>&1))"
  else observe "dbt-$m" "dbt run failed: $(dbt_err)"; fi
done
dbt run --select lfc_incr && observe dbt-incremental-rerun "a second run of the incremental model passed; rows $(q "SELECT COUNT(*) FROM \`$TC\`.\`$DS\`.lfc_incr" 2>&1)" \
  || observe dbt-incremental-rerun "failed: $(dbt_err)"
observe dbt-version "$(uvx --quiet --from dbt-databricks python -c 'import importlib.metadata as m; print("dbt-core", m.version("dbt-core") + ", dbt-databricks", m.version("dbt-databricks"))' 2>&1)"

# --- UniForm (Iceberg reads) on the pipeline's table --------------------------------------------------------------------
UF="('delta.enableIcebergCompatV2' = 'true', 'delta.universalFormat.enabledFormats' = 'iceberg')"
for kind in TABLE "STREAMING TABLE"; do
  r=$(q "ALTER $kind $FT SET TBLPROPERTIES $UF" 2>&1) \
    && { observe "uniform-alter-${kind// /-}" "accepted; delta.universalFormat.enabledFormats now: $(q "SHOW TBLPROPERTIES $FT ('delta.universalFormat.enabledFormats')" 2>&1 | cut -f2)"; break; } \
    || observe "uniform-alter-${kind// /-}" "refused: $(echo "$r" | head -1 | cut -c1-260)"
done

# --- credential vending and the Iceberg REST catalog --------------------------------------------------------------------
TID=$(dbx tables get "$TC.$TS.$TT" -o json | yq '.table_id')
observe metastore-external-access "external_access_enabled: $(dbx metastores summary -o json | yq '.external_access_enabled')"
if out=$(dbx api post /api/2.1/unity-catalog/temporary-table-credentials --json "{\"table_id\":\"$TID\",\"operation\":\"READ\"}" 2>&1); then
  observe vending "credentials issued ($(echo "$out" | yq -p json 'keys | join(",")')); not printed"
else observe vending "refused: $(echo "$out" | grep -o 'Error: .*' | head -1 | cut -c1-260)"; fi
if out=$(dbx api get "/api/2.1/unity-catalog/iceberg-rest/v1/catalogs/$TC/namespaces/$TS/tables/$TT" 2>&1); then
  observe iceberg-rest "loadTable answered: metadata-location $(echo "$out" | yq -p json '."metadata-location" // "none"' | sed 's#.*/##')"
else observe iceberg-rest "refused: $(echo "$out" | grep -o 'Error: .*' | head -1 | cut -c1-260)"; fi

# --- Delta Sharing ------------------------------------------------------------------------------------------------------
if r=$(q "CREATE SHARE \`$SHARE\`" 2>&1); then
  r=$(q "ALTER SHARE \`$SHARE\` ADD TABLE $FT" 2>&1) \
    && observe sharing "the streaming table was added to a share: $(q "SHOW ALL IN SHARE \`$SHARE\`" 2>&1 | cut -f1,2 | head -2 | paste -sd' ' -)" \
    || observe sharing "ALTER SHARE ADD TABLE refused: $(echo "$r" | head -1 | cut -c1-260)"
else observe sharing "CREATE SHARE refused: $(echo "$r" | head -1 | cut -c1-200)"; fi

MODE=${MODE:-standard}; GW=""
result_md external-reads
exit $FAILED
