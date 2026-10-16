#!/usr/bin/env bash
# inventory.sh <profile>...: every UC connection in each workspace, one tab-separated line each:
#   profile  name  connection_type  host  port  owner  created_at (epoch ms)  (passwords are never returned by the API)
for p in "$@"; do
  databricks connections list --profile "$p" -o json 2>/dev/null | P="$p" yq -p json -o tsv \
    '.[] | [strenv(P), .name, .connection_type, (.options.host // ""), (.options.port // ""), .owner, (.created_at // "")]' \
    || echo -e "$p\t(failed to list: check the profile's login)"
done
