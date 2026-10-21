#!/usr/bin/env bash
# compute_report.sh <profile> <name-prefix> [<since>]: for each pipeline whose name starts with <name-prefix> (and,
# with <since>, an ISO UTC time such as 2026-10-18T02:47:00Z, whose latest update started after it), what the run set
# serverless to, what its latest update ran on, whether that compute started, and whether it then reached the source,
# for the records' "compute" field (lfc-test-results). Read-only.
#   Prints TSV:
#     name, kind      gateway | pipeline
#     serverless      unset | true | false: spec.serverless, which echoes what was sent
#     ran_on          serverless | classic: the latest update's config.serverless; not-started without an update
#     started         yes: the update got past WAITING_FOR_RESOURCES (INITIALIZING, or Extractor STARTED); no; unknown
#     reached_source  no: a connection error from the source (with the compute up, usually the firewall); yes: the
#                     update reached RUNNING or COMPLETED with no connection error; unknown otherwise
#     update_state, error (the first ERROR event's error code, if any)
#
#   bin/compute_report.sh <profile> janedoe-mssql-azvm
set -uo pipefail
P=$1; PREFIX=$2; SINCE=${3:-}; T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
printf 'name\tkind\tserverless\tran_on\tstarted\treached_source\tupdate_state\terror\n'
databricks pipelines list-pipelines --filter "name LIKE '$PREFIX%'" --profile "$P" -o json \
  | yq -p json -o tsv '.[] | .pipeline_id' | while read -r id; do
  databricks pipelines get "$id" --profile "$P" -o json > "$T/p.json" 2> /dev/null || continue
  eval "$(yq -p json -o shell '{"name": .name, "set": (.spec.serverless | tostring),
          "upd": (.latest_updates[0].update_id // ""), "st": (.latest_updates[0].state // ""),
          "created": (.latest_updates[0].creation_time // "")}' "$T/p.json")"
  if [ -n "$SINCE" ] && [[ "$created" < "$SINCE" ]]; then continue; fi     # ISO UTC times compare as strings
  [ "$set" = null ] && set=unset             # tostring keeps false (yq's // would turn false into the default)
  kind=pipeline; [ "$(yq -p json -o tsv '.spec.gateway_definition.connection_name // ""' "$T/p.json")" ] && kind=gateway
  ran=not-started; started=unknown; reached=unknown; err=
  if [ -n "$upd" ]; then
    v=$(databricks pipelines get-update "$id" "$upd" --profile "$P" -o json 2> /dev/null | yq -p json -o tsv '.update.config.serverless | tostring')
    case $v in true) ran=serverless;; false) ran=classic;; esac
    # this update's events only (origin.update_id)
    databricks pipelines list-pipeline-events "$id" --profile "$P" --max-results 250 -o json 2> /dev/null \
      | U="$upd" yq -p json -o json '[.[] | select(.origin.update_id == strenv(U))]' > "$T/ev.json"
    yq -p json -e '.[] | select(.message | test("is INITIALIZING|Extractor STARTED|is RUNNING|is COMPLETED"))' "$T/ev.json" > /dev/null 2>&1 && started=yes
    [ $started = unknown ] && [ "$st" != RUNNING ] && [ -n "$st" ] && started=no
    err=$(yq -p json -o tsv '.[] | select(.level == "ERROR") | (.error.exceptions[0].message // .message | tostring)' "$T/ev.json" \
          | grep -oE '[A-Z_]+_ERROR(\.[A-Z_]+)?|You must use serverless compute|not supported in your workspace' | head -1)
    if yq -p json -e '.[] | select((.error.exceptions[0].message // "") | test("CONNECTION_ERROR|Could not connect to the source"))' "$T/ev.json" > /dev/null 2>&1; then reached=no
    elif yq -p json -e '.[] | select(.message | test("is RUNNING|is COMPLETED"))' "$T/ev.json" > /dev/null 2>&1; then reached=yes; fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$kind" "$set" "$ran" "$started" "$reached" "$st" "$err"
done
