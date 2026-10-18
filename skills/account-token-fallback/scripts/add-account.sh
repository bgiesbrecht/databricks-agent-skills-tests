#!/usr/bin/env bash
# add-account.sh <account-id> <aws|azure|gcp> [--dry-run]: the one standard way to add an account profile to
#   ~/.databrickscfg, so ws-token.sh can mint tokens for every workspace in that account.
#   Standard name: account-<cloud>-<account-id>. If a valid account profile for this account already exists (any
#   name), it's reused and nothing is added; if only expired ones exist, one of them is logged in to again (no
#   duplicate). Otherwise adds the standard one. Either way runs `databricks auth login` for the cloud's account host,
#   which opens a browser: run it in your own terminal (in Claude Code: ! bash add-account.sh ...).
#   --dry-run prints what it would do.
set -uo pipefail
AID=${1:?account id}; CLOUD=${2:?aws, azure or gcp}; DRY=; [ "${3:-}" = --dry-run ] && DRY=1
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
if [ -n "$DRY" ]; then echo "would run: $cmd"; exit 0; fi
$cmd || exit 1
databricks auth describe --profile "$NAME" > /dev/null 2>&1 && echo "ready: $NAME logs in" || { echo "logged in, but $NAME doesn't authenticate" >&2; exit 1; }
