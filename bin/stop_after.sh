#!/usr/bin/env bash
# Stop each pipeline's latest update once it has run longer than a limit.
# Integrated CDC updates can run a long time on an idle source (smart closure waits
# for the lag to converge), so tests stop them by hand.
#
# Usage:
#   source env.sh
#   bin/stop_after.sh <minutes> <pipeline-id>...

LIMIT=${1:?usage: $0 <minutes> <pipeline-id>...}; shift
[ $# -gt 0 ] || { echo "usage: $0 <minutes> <pipeline-id>..."; exit 1; }
PROFILE="${PIPELINE_WS:-DEFAULT}"

pending=("$@")
while [ ${#pending[@]} -gt 0 ]; do
  still=()
  for p in "${pending[@]}"; do
    read -r st age < <(databricks pipelines list-updates "$p" --profile "$PROFILE" -o json \
      | jq -r '.updates[0] | "\(.state) \(((now*1000 - .creation_time)/60000)|floor)"')
    case $st in
      COMPLETED|FAILED|CANCELED) echo "$(date -u +%H:%M) $p $st after ${age}m";;
      *) if [ "$age" -ge "$LIMIT" ]; then
           databricks pipelines stop "$p" --profile "$PROFILE" >/dev/null && echo "$(date -u +%H:%M) $p STOPPED at ${age}m (was $st)"
         else
           still+=("$p")
         fi;;
    esac
  done
  pending=("${still[@]}")
  [ ${#pending[@]} -gt 0 ] && sleep 60
done
