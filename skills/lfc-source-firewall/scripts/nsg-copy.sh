#!/usr/bin/env bash
# nsg-copy.sh <from-nsg> <to-nsg> <port> [--apply]: give another NSG the same sources as the region's shared NSG, for one port.
#   Needs RG (both NSGs' resource group). Optional: SUBSCRIPTION (else az's default).
#   Every inbound Allow rule of <from-nsg> with a source list (serverless, VPN, workspace egress, known hosts) becomes a
#   rule of the same name and priority in <to-nsg>, allowing TCP <port> only (no SSH). Use it for an NSG that can't be the
#   shared one, such as a SQL Managed Instance subnet's (port 3342). Prints the plan; changes nothing without --apply.
#   Rerun after the shared NSG is synced: a rule whose sources, port and priority already match is left alone. Rules
#   are set from the highest priority down, so a resync that moved every rule up by one slot applies without a clash.
set -euo pipefail
FROM=${1:?from-nsg}; TO=${2:?to-nsg}; PORT=${3:?port}; APPLY=${4:-}
: "${RG:?}"; A=(--resource-group "$RG"); [ -n "${SUBSCRIPTION:-}" ] && A+=(--subscription "$SUBSCRIPTION")
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
az network nsg rule list "${A[@]}" --nsg-name "$FROM" -o json > "$T/from.json"
az network nsg rule list "${A[@]}" --nsg-name "$TO" -o json > "$T/to.json"
# highest priority first: a rule moved up by the shared NSG's resync vacates its old slot before the next rule needs it
yq -p json -o tsv '.[] | select(.direction == "Inbound" and .access == "Allow") | [.name, .priority]' "$T/from.json" | sort -t$'\t' -k2,2nr > "$T/rules"
while IFS=$'\t' read -r name prio; do
  N="$name" yq -p json -o tsv '.[] | select(.name == strenv(N)) | (.sourceAddressPrefixes + [.sourceAddressPrefix]) | .[] | select(. != null)' "$T/from.json" \
    | grep -vx -e '' -e '\*' | sort > "$T/src" || true   # yq treats "*" in a comparison as a wildcard: filter it here
  [ -s "$T/src" ] || { echo "skip  $name (no source list)"; continue; }
  N="$name" yq -p json -o tsv '.[] | select(.name == strenv(N)) | (.sourceAddressPrefixes + [.sourceAddressPrefix]) | .[] | select(. != null)' "$T/to.json" \
    | grep -vx '' | sort > "$T/have" || true
  have_port=$(N="$name" yq -p json -o tsv '.[] | select(.name == strenv(N)) | .destinationPortRange // ""' "$T/to.json")
  have_prio=$(N="$name" yq -p json -o tsv '.[] | select(.name == strenv(N)) | .priority // ""' "$T/to.json")
  if cmp -s "$T/src" "$T/have" && [ "$have_port" = "$PORT" ] && [ "$have_prio" = "$prio" ]; then echo "ok    $name ($(wc -l < "$T/src" | tr -d ' ') sources, port $PORT)"; continue; fi
  echo "set   $name priority $prio: $(wc -l < "$T/src" | tr -d ' ') sources -> TCP $PORT"
  [ "$APPLY" = --apply ] || continue
  # create overwrites a rule of the same name
  az network nsg rule create "${A[@]}" --nsg-name "$TO" -n "$name" --priority "$prio" --direction Inbound --access Allow \
    --protocol Tcp --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges "$PORT" \
    --source-address-prefixes $(tr '\n' ' ' < "$T/src") -o none
done < "$T/rules"
[ "$APPLY" = --apply ] || echo "plan only: rerun with --apply"
