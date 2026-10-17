#!/usr/bin/env bash
# inventory.sh <profile>...: every UC connection in each workspace, one tab-separated line each:
#   profile  name  connection_type  host  port  owner  created_at (epoch ms)  (passwords are never returned by the API)
# (the list goes to a variable first: piped straight into yq, a failed list was silent, since yq exits 0 on empty input)
for p in "$@"; do
  if ! j=$(databricks connections list --profile "$p" -o json 2>/dev/null); then
    echo -e "$p\t(failed to list: check the profile's login)"; continue
  fi
  P="$p" yq -p json -o tsv '.[] | [strenv(P), .name, .connection_type, (.options.host // ""), (.options.port // ""), .owner, (.created_at // "")]' <<< "$j"
done
