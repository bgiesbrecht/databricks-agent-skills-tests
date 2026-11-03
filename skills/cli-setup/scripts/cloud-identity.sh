#!/usr/bin/env bash
# cloud-identity.sh: sourced by the cloud scripts, not run. A cloud resource belongs to one identity: an Azure
# subscription (in its tenant), an AWS profile (in its account), a GCP account and project. One login can reach many of
# them, and the CLI's default is whichever was set last, so every later call for a resource names its identity.
#   az_record <subscription>                print the record: IDENTITY azure tenant_id=.. subscription_id=.. subscription_name=..
#   az_require <subscription> [tenant_id]   stop (exit 1) unless this az login reaches the subscription in that tenant
# A create prints its record next to its other outputs. Keep that line's values in your private env file (SUBSCRIPTION=,
# TENANT_ID=) with the resource's other settings, and source the file for every later call. Never commit it.
az_record() {
  az account show --subscription "$1" -o json \
    | jq -r '"IDENTITY azure tenant_id=\(.tenantId) subscription_id=\(.id) subscription_name=\(.name)"'
}

az_require() {
  local got
  got=$(az account show --subscription "$1" --query tenantId -o tsv 2>/dev/null) || {
    echo "subscription $1 isn't in this az login: az login --tenant ${2:-<tenant_id>}" >&2; return 1; }
  if [ -n "${2:-}" ] && [ "$got" != "$2" ]; then
    echo "subscription $1 is in tenant $got, not $2: az login --tenant $2" >&2; return 1
  fi
}
