#!/usr/bin/env bash
# add-account.sh <account-id> <aws|azure|gcp> [--dry-run] [--free-port]: the one standard way to add an account profile to
#   ~/.databrickscfg, so ws-token.sh can mint tokens for every workspace in that account.
#   Standard name: account-<cloud>-<account-id>. If a valid account profile for this account already exists (any
#   name), it's reused and nothing is added; if only expired ones exist, one of them is logged in to again (no
#   duplicate). Otherwise adds the standard one. Either way runs `databricks auth login` for the cloud's account host,
#   which opens a browser: run it in your own terminal (in Claude Code: ! bash add-account.sh ...).
#   --dry-run prints what it would do. The browser login returns to 127.0.0.1:8020; when another process holds that port,
#   it uses the first free port from 8021 (DATABRICKS_OAUTH_CALLBACK_PORT) and leaves the process alone. --free-port
#   stops that process instead (ask its owner first) and keeps 8020.
set -uo pipefail
AID=${1:?account id}; CLOUD=${2:?aws, azure or gcp}; shift 2; DRY=; FREE=
while [ $# -gt 0 ]; do case $1 in --dry-run) DRY=1; shift;; --free-port) FREE=1; shift;; *) echo "unknown $1" >&2; exit 2;; esac; done
case $CLOUD in
  aws) AH=https://accounts.cloud.databricks.com;; azure) AH=https://accounts.azuredatabricks.net;;
  gcp) AH=https://accounts.gcp.databricks.com;; *) echo "cloud must be aws, azure or gcp" >&2; exit 2;; esac
[[ $AID =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "not an account id: $AID" >&2; exit 2; }
NAME=account-$CLOUD-$AID
# an existing valid account profile for this account wins, whatever its name
have=$(databricks auth profiles -o json 2> /dev/null | A="$AID" H="$AH" yq -p json -o tsv \
  '[.profiles[] | select(.account_id == strenv(A) and .host == strenv(H)) | .name + "|" + (.valid | tostring)] | .[]')
for x in $have; do [ "${x#*|}" = true ] && { echo "account $AID already has a valid profile: ${x%|*} (nothing added)"; exit 0; }; done
# only expired profiles: log in to one of them again (the standard name if there is one), rather than add a duplicate
if [ -n "$have" ]; then
  names=$(echo $have | sed 's/|false//g'); case " $names " in *" $NAME "*) ;; *) NAME=${names%% *};; esac
  echo "account $AID has profile(s) whose login expired: $names; logging in to $NAME again (no new profile)"
fi
cmd="databricks auth login --host $AH --account-id $AID --profile $NAME"
# the browser login comes back to 127.0.0.1:8020. If another program holds it (even one that a launch agent restarts
# when stopped), the login would hang: use the first free port from 8021 (DATABRICKS_OAUTH_CALLBACK_PORT),
# and leave that program alone. --free-port stops it instead and keeps 8020.
busy() { lsof -nP -iTCP:"$1" -sTCP:LISTEN > /dev/null 2>&1; }
holder=$(lsof -nP -iTCP:8020 -sTCP:LISTEN 2> /dev/null | awk 'NR>1 {print $1 " (pid " $2 ")"; exit}')
if [ -n "$holder" ] && [ -n "$FREE" ] && [ -z "$DRY" ]; then
  # start the login right after stopping it, before a launch agent restarts it and takes the port back
  echo "stopping $holder, which holds port 8020, and starting the login right away"; kill $(lsof -nP -t -iTCP:8020 -sTCP:LISTEN | sort -u) 2> /dev/null; sleep 0.3
elif [ -n "$holder" ]; then
  for port in $(seq 8021 8030); do busy $port || break; done
  busy $port && { echo "ports 8020-8030 are all in use: free one, or rerun with --free-port to stop $holder (ask first)" >&2; exit 3; }
  echo "port 8020 is held by $holder: the login will come back to port $port instead"
  export DATABRICKS_OAUTH_CALLBACK_PORT=$port; cmd="DATABRICKS_OAUTH_CALLBACK_PORT=$port $cmd"
fi
if [ -n "$DRY" ]; then echo "would run: $cmd"; exit 0; fi
databricks auth login --host "$AH" --account-id "$AID" --profile "$NAME" || exit 1
databricks auth describe --profile "$NAME" > /dev/null 2>&1 && echo "ready: $NAME logs in" || { echo "logged in, but $NAME doesn't authenticate" >&2; exit 1; }
