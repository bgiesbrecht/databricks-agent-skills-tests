#!/usr/bin/env bash
# lfc-runtime.sh <profile> <pipeline-id> [update-id]: which Lakeflow runtime a pipeline update ran on, and which of its
# settings changed since the last time you looked at this workspace.
#
# Settings appear, disappear and change from release to release, and differ between workspaces on different releases,
# so record them with every test run. Reads the update's runtime_details event (the latest update if none is given) and
# (a full update ID or its first characters) prints the runtime: DBR version, channel, image build, cloud and region. Then it saves every pipelines.* setting the
# update ran with and compares them with the previous snapshot for this profile and pipeline kind (gateway,
# standard-applier, integrated, query-based: their settings differ by kind, so comparing across kinds is noise):
# added (+), removed (-), changed (~).
#
# --summary prints only the runtime line (for a test's result file). Snapshots stay on this machine, in
# ${LFC_RUNTIME_DIR:-~/.lfc-test/runtime}/<profile>/, never in a repository: they carry workspace details.
set -euo pipefail
SUMMARY=0; [ "${1:-}" = --summary ] && { SUMMARY=1; shift; }
[ $# -ge 2 ] || { sed -n 2,13p "$0"; exit 2; }
PROFILE=$1 PIPE=$2 UPD=${3:-}
export PATH=/opt/homebrew/bin:$PATH
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
# The REST call, not `databricks pipelines list-pipeline-events`: the CLI drops each event's details.
echo '[]' > "$W/events.json"; tok=""
for _ in $(seq 1 40); do
  databricks api get "/api/2.0/pipelines/$PIPE/events?max_results=250${tok:+&page_token=$tok}" --profile "$PROFILE" -o json > "$W/page.json"
  yq -o json -i ". + load(\"$W/page.json\").events" "$W/events.json"
  tok=$(yq -r '.next_page_token // ""' "$W/page.json"); [ -n "$tok" ] || break
done
export UPD
yq -o json '[.[] | select(.event_type == "runtime_details") | select(strenv(UPD) == "" or (.origin.update_id | test("^" + strenv(UPD))))]
  | sort_by(.timestamp) | (.[length - 1] // {})' "$W/events.json" > "$W/rt.json"
[ "$(yq -r '.event_type // ""' "$W/rt.json")" = runtime_details ] || { echo "no runtime_details event for ${UPD:-any update} of $PIPE"; exit 1; }

eval "$(yq -o shell '{"dbr": .details.runtime_details.runtime_version.dbr_version, "channel": .details.runtime_details.runtime_version.channel,
  "image": .details.runtime_details.runtime_version.image_key, "cloud": .origin.cloud, "region": .origin.region,
  "update": .origin.update_id, "ts": .timestamp, "source": (.origin.ingestion_source_type // "")}' "$W/rt.json")"
build=$(echo "$image" | grep -oE 'dp-[0-9]{8}' | head -1 || true)
echo "Lakeflow runtime: DBR $dbr, channel $channel, image ${image%%-*} build ${build#dp-} ($image), $cloud $region${source:+, source $source}"
[ "$SUMMARY" = 1 ] && exit 0
echo "Update $update at $ts"

kind=$(databricks pipelines get "$PIPE" --profile "$PROFILE" -o json | yq -r '.spec |
  (select(.gateway_definition) | "gateway") // (select(.ingestion_definition.ingestion_gateway_id) | "standard-applier")
  // (select(.ingestion_definition.connector_type == "CDC") | "integrated") // (select(.ingestion_definition) | "query-based") // "other"')
D=${LFC_RUNTIME_DIR:-$HOME/.lfc-test/runtime}/$PROFILE; mkdir -p "$D"; chmod 700 "$D"
SNAP="$D/${ts%%T*}_dbr${dbr}_${build:-nobuild}_${kind}_${update:0:8}.txt"
yq -r '.details.runtime_details.runtime_configuration.configuration | to_entries | .[] | .key + "\t" + .value' "$W/rt.json" > "$W/cfg.txt"
printf '_runtime.dbr\t%s\n_runtime.channel\t%s\n_runtime.image\t%s\n' "$dbr" "$channel" "$image" | cat - "$W/cfg.txt" | sort -t$'\t' -k1,1 > "$W/now.txt"
PREV=$(ls -t "$D"/*_"${kind}"_*.txt 2>/dev/null | grep -v -F "$SNAP" | head -1 || true)
cp "$W/now.txt" "$SNAP"
echo "$(wc -l < "$W/now.txt" | tr -d ' ') settings saved to $SNAP"
[ -n "$PREV" ] || { echo "no earlier $kind snapshot for $PROFILE to compare with"; exit 0; }
echo "Compared with $(basename "$PREV"):"
join -t$'\t' -a1 -a2 -e '<none>' -o 0,1.2,2.2 "$PREV" "$W/now.txt" | awk -F'\t' '
  $2 == "<none>" { print "  + " $1 " = " ($3 == "<none>" ? "(empty)" : $3); n++; next }
  $3 == "<none>" { print "  - " $1 " (was " $2 ")"; n++; next }
  $2 != $3       { print "  ~ " $1 ": " $2 " -> " $3; n++ }
  END            { if (!n) print "  no changes" }'
