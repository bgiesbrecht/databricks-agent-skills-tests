#!/usr/bin/env bash
# classic-egress.sh <profile> [--warehouse <id> [--days N]] [--runs N]: the public IP a workspace's classic compute
# leaves from.
#
# Classic clusters leave through the workspace's NAT, which isn't in ip-ranges.json. Two ways to find it:
#   --warehouse <id>  (seconds, nothing started) read the audit log: the public source IPs of API calls that classic
#                     cluster drivers made in the last N days (default 7). Needs SELECT on system.access.audit and a
#                     SQL warehouse; shows every NAT IP in use, not just one. A workspace with no classic activity in
#                     that window returns nothing: use the job instead.
#   (default)         submit a one-off single-node notebook job that asks api.ipify.org for its address, then delete
#                     the notebook. 5-10 min while the cluster starts. --runs N submits N jobs and keeps the distinct
#                     IPs: a cluster in another subnet can leave from a second NAT IP.
# Prints one IP per line, then a CLASSIC='<ip>/32 ...' line for fw.env:
#
#   skills/lfc-source-firewall/scripts/classic-egress.sh <PROFILE> --warehouse <WAREHOUSE_ID> | tail -1 >> fw.env
#
# Node type for the job: m5d.large on AWS, Standard_D4ds_v5 on Azure, n2-standard-4 on GCP (NODE_TYPE overrides). The
# IP is a workspace detail: keep it in private files, never in a public repository.
set -euo pipefail
[ $# -ge 1 ] || { sed -n 2,19p "$0"; exit 2; }
P=$1; shift; RUNS=1 WH="" DAYS=7
while [ $# -gt 0 ]; do
  case $1 in --runs) RUNS=$2;; --warehouse) WH=$2;; --days) DAYS=$2;; *) echo "unknown option $1" >&2; exit 2;; esac
  shift 2
done
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
public() { grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -vE '^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)'; }
finish() { local ips; ips=$(public | sort -u); [ -n "$ips" ] || { echo "no public IP found" >&2; exit 1; }
  echo "$ips"; echo "CLASSIC='$(echo "$ips" | sed 's|$|/32|' | paste -sd' ' -)'"; }

if [ -n "$WH" ]; then
  WS=$(databricks metastores current --profile "$P" -o json | jq -r '.workspace_id')
  SQL="SELECT DISTINCT source_ip_address FROM system.access.audit WHERE event_date >= current_date() - $DAYS AND workspace_id = $WS AND user_agent LIKE '%Databricks-Service/driver%'"
  jq -n --arg w "$WH" --arg s "$SQL" '{warehouse_id: $w, wait_timeout: "50s", statement: $s}' > "$W/q.json"
  databricks api post /api/2.0/sql/statements --profile "$P" --json @"$W/q.json" > "$W/r.json"
  [ "$(jq -r '.status.state' "$W/r.json")" = SUCCEEDED ] || { jq -r '.status' "$W/r.json" >&2; exit 1; }
  jq -r '.result.data_array // [] | .[][0]' "$W/r.json" | finish
  exit
fi

HOST=$(databricks auth describe --profile "$P" -o json | jq -r '.details.host')
case $HOST in
  *azuredatabricks.net*) NODE=${NODE_TYPE:-Standard_D4ds_v5};;
  *gcp.databricks.com*) NODE=${NODE_TYPE:-n2-standard-4};;
  *) NODE=${NODE_TYPE:-m5d.large};;
esac
U=$(databricks current-user me --profile "$P" -o json | jq -r '.userName')
SV=$(databricks clusters spark-versions --profile "$P" -o json | jq -r \
  '[.versions[] | select(.name | test("LTS")) | select(.key | test("^[0-9]+\\.[0-9]+\\.x-scala"))] | sort_by(.key | split(".") | .[0] | tonumber) | .[-1].key')
NB=/Users/$U/lfc-classic-egress-ip
printf '# Databricks notebook source\nimport urllib.request\ndbutils.notebook.exit(urllib.request.urlopen("https://api.ipify.org", timeout=10).read().decode())\n' > "$W/egress.py"
databricks workspace import "$NB" --file "$W/egress.py" --format SOURCE --language PYTHON --overwrite --profile "$P" >&2
trap 'databricks workspace delete "$NB" --profile "$P" >/dev/null 2>&1 || true; rm -rf "${W:?}"' EXIT
cat > "$W/run.json" <<EOF
{"run_name": "lfc-classic-egress-ip", "tasks": [{"task_key": "ip", "notebook_task": {"notebook_path": "$NB"},
 "new_cluster": {"spark_version": "$SV", "node_type_id": "$NODE", "num_workers": 0, "data_security_mode": "SINGLE_USER",
  "spark_conf": {"spark.databricks.cluster.profile": "singleNode", "spark.master": "local[*]"},
  "custom_tags": {"ResourceClass": "SingleNode"}}}]}
EOF
for _ in $(seq "$RUNS"); do
  databricks jobs submit --json @"$W/run.json" --profile "$P" --timeout 30m -o json > "$W/out.json"
  RID=$(jq -r '.tasks[0].run_id' "$W/out.json")
  databricks jobs get-run-output "$RID" --profile "$P" -o json | jq -r '.notebook_output.result'; echo
done | finish
