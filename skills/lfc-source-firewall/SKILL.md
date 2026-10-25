---
name: lfc-source-firewall
description: "Open a Lakeflow Connect source database's firewall to the caller's laptop IP and the Databricks workspace's serverless egress IPs (and classic compute egress when known), on Azure, AWS, or GCP. Use after creating a source with an lfc-source-* skill, or when a Lakeflow Connect pipeline or remote_query can't reach the database."
parent: lfc-source-setup
---

# Firewall rules for a Lakeflow Connect source

A source database has to accept connections from two places: **your laptop**, so you can set it up, and **the Databricks workspace**, so Lakeflow Connect can read it. This skill finds both sets of IPs and adds them to the database's firewall, nothing more. Use it after any `lfc-source-*` skill creates a database, or to repair one that pipelines can't reach.

## What gets allowed

| Source of traffic | How to find it | When it's needed |
|---|---|---|
| Your laptop | `curl -fsS https://api.ipify.org` (fallback `https://ifconfig.me/ip`), as a `/32` | Setting up the database, seeding, running test DML |
| Workspace **serverless** egress | Databricks' public [ip-ranges.json](https://www.databricks.com/networking/v1/ip-ranges.json), outbound IPv4 for the workspace's cloud and region | Query-based pipelines, integrated CDC on serverless, `remote_query`, serverless gateways |
| Workspace **classic** compute egress | Not published. It's the workspace's NAT / egress IP, set per workspace (see [Classic compute egress](#classic-compute-egress)) | Standard CDC gateways and integrated CDC that run on classic compute: `serverless: false`, or `serverless` unset on a workspace with classic (seen on Azure), and anything else running on classic clusters. The test prompts set `serverless: true` so this isn't needed |

Open only the database port, only to these addresses. Never open `0.0.0.0/0`.

## Which cloud: the workspace's first

Put the source in **the workspace's cloud and region** (Step 1 finds them as `CLOUD` and `REGION`). Lakeflow Connect's reads then stay in one region, so there's no cross-cloud or inter-region egress charge, and only that region's serverless ranges are needed, which fit every target below.

Firewall rule limits matter only for a source shared by workspaces in many regions:

| Target | Limit | Serverless list for one region | Every region (all clouds) |
|---|---|---|---|
| Azure VM, NSG | 400 CIDRs per rule, many rules | fits | fits (about 760 CIDRs) |
| Azure Postgres Flexible Server | 500 rules | fits (up to about 40) | doesn't fit |
| Azure MySQL Flexible Server | 250 rules | fits | doesn't fit |
| Azure SQL Database | 128 rules | fits | doesn't fit |
| AWS RDS / Aurora security group | 60 inbound rules (default quota) | fits (1 to 5) | doesn't fit |
| GCP Cloud SQL authorized networks | no published limit | fits (3 to 4) | test before relying on it |
| GCP VM, VPC firewall | 5,000 per rule | fits | fits |

Counts are from `ip-ranges.json` at the time of writing; recount with the commands below. For a source that serves **one workspace**, any target in its cloud and region works. For a source shared by workspaces in **many regions**, an Azure VM with an NSG can hold every serverless range; reads from other clouds or regions are billed as egress either way.

**On Azure, keep one shared NSG per region** and attach every test VM (and the subnets of the shared VNet) to it: the rules are synced once and every new VM reuses them, including all Podman engines on the VM's port range `30000-30063`. The NSG can't front a Flexible Server or Azure SQL that serverless must reach: those need public access and their own server firewall rules, synced from the same IP lists. See [references/azure.md](references/azure.md).

## Inputs

| Input | How to get it |
|---|---|
| Databricks CLI profile | Ask; never pick one (see **databricks-core**) |
| Target type and name | From the `lfc-source-*` skill that created it: Flexible Server / Azure SQL server / NSG / security group / Cloud SQL instance / VPC network |
| Database port | 5432 Postgres, 3306 MySQL, 1433 SQL Server, 1521 Oracle, 3342 SQL Managed Instance public endpoint |
| Azure resource group and NSG | Ask whether the user has their own resource group. If not, use the shared test group `forgedb-rg` (check it exists: `az group show -n forgedb-rg`) and its shared NSG for the VM's region (`az network nsg list -g forgedb-rg`). The user is free to choose a different group. Don't create resource groups or NSGs without asking |
| Scope | This workspace's region (default), or every serverless region for a shared source |
| Does the pipeline use classic compute? | A standard CDC gateway or integrated CDC with `serverless: false`, or unset on a workspace with classic compute; or classic query-based (Beta). Read `update.config.serverless` from `pipelines get-update` |
| Classic egress IPs | Only if classic compute is used: from the user, or found as below |

Shared resource groups can hit their quotas. If creation fails with a quota or limit error in the shared group, ask for another resource group rather than deleting someone else's resources.

## Shell conventions

These follow **shell-json-scripting**. The agent's shell doesn't keep variables between commands, so:

- **Every value lives in `fw.env`.** Start every command block with `set -a; . ./fw.env`. `set -a` exports every variable assigned from then on, including the ones `eval` sets, so DuckDB can read them. Don't `set +a` mid-block.
- **CLI JSON → shell variables** with yq, keeping the `// ""` (for a missing value yq prints `null`):

  ```bash
  eval "$(<cli> ... -o json | yq -p json -o shell '{"NAME": (.path.to.value // "")}' | tee -a fw.env)"
  ```

- **Lists are space-separated** variables (`SERVERLESS`, `CLASSIC`, `WANT`, `HAVE`, `MISSING`): CIDRs never contain spaces, and `for c in $MISSING` just works.
- **Use the simplest tool for each step.** A filter or reshape of one JSON input is a yq expression. A loop or membership test over a short list is plain shell. Only the steps that need IP-range math, joins across inputs, or ranking are DuckDB SQL: coverage (`missing.sql`, and the per-cloud cover queries), the rule plan (`plan.sql`), and the AWS group pick.
- **DuckDB steps** are `.sql` files that read inputs with `getvariable('NAME')` and JSON files with `read_json`, and return one row. `q.sh` fills every `getvariable` from the env var of the same name and prints the row as shell assignments: `eval "$($Q $FW/<step>.sql | tee -a fw.env)"`. `q.py` does the same when the caller is Python (`uv run q.py`), so the SQL files are shared.
- **Never put passwords in `fw.env`:** it holds IPs and resource names only.

The DuckDB steps are files in [`scripts/`](scripts/): [`lib.sql`](scripts/lib.sql) (the IPv4 and port macros every step uses), [`collapse.sql`](scripts/collapse.sql), [`missing.sql`](scripts/missing.sql), [`plan.sql`](scripts/plan.sql), and the per-cloud [`sg_pick.sql`](scripts/sg_pick.sql), [`nsg_cover.sql`](scripts/nsg_cover.sql), [`fw_cover.sql`](scripts/fw_cover.sql). They run with **shell-json-scripting**'s runner, `q.sh` (or `q.py` from Python), which reads `lib.sql` from the query's directory:

```bash
Q=skills/shell-json-scripting/scripts/q.sh; FW=skills/lfc-source-firewall/scripts     # adjust to where the skills are
```

## Step 1: collect the IPs

```bash
set -a; umask 077; : > fw.env
# Laptop
eval "$({ curl -fsS --max-time 5 'https://api.ipify.org?format=json' || curl -fsS --max-time 5 https://ifconfig.me/all.json; } \
  | yq -p json -o shell '{"MYIP": (.ip // .ip_addr)}' | tee -a fw.env)"

# Workspace cloud and region: global_metastore_id is <cloud>:<region>:<id>
eval "$(databricks metastores summary --profile <PROFILE> -o json \
  | yq -p json -o shell '(.global_metastore_id | split(":")) as $g | {"CLOUD": $g[0], "GREGION": $g[1], "REGION": .region}' \
  | tee -a fw.env)"
[ "$GREGION" = "$REGION" ] || echo "WARN: metastore region mismatch ($GREGION vs $REGION): check the workspace region by hand"

# Serverless egress (outbound, IPv4). SCOPE=all takes every cloud and region, for a source shared by many workspaces.
echo "SCOPE=region" >> fw.env
set -a; . ./fw.env
eval "$(curl -fsSL https://www.databricks.com/networking/v1/ip-ranges.json | yq -p json -o shell '{"SERVERLESS": ([.prefixes[]
  | select(.type == "outbound" and (strenv(SCOPE) == "all" or (.platform == strenv(CLOUD) and .region == strenv(REGION))))
  | .ipv4Prefixes[]] | unique | join(" "))}' | tee -a fw.env)"
eval "$($Q $FW/collapse.sql | tee -a fw.env)"     # drop ranges inside other ranges: they overlap across regions
echo "laptop $MYIP, serverless: $(echo $SERVERLESS | wc -w) CIDRs"
```

`collapse.sql` matters for `SCOPE=all`: the file has ranges that sit inside others from another region (763 → 760 when this was written), and an Azure NSG rule rejects overlapping prefixes (`OverlappingSubnetsNotPermittedInSecurityRule`). It's harmless for one region.

If `SERVERLESS` is empty, the region isn't in the file: stop and tell the user, don't guess.

## Classic compute egress

Classic clusters leave the workspace through its own NAT / egress IP, which isn't in `ip-ranges.json`. It differs per workspace and is often set by hand when the workspace is created.

- **The user knows it:** ask for it, and add it as `CLASSIC='<ip>/32'` (or the NAT range) to `fw.env`.
- **Azure workspace with a Databricks-managed VNet, in a subscription you can read:** the egress is the NAT gateway's public IP in the workspace's managed resource group:

  ```bash
  eval "$(az databricks workspace show -g <workspace-rg> -n <workspace-name> -o json \
    | yq -p json -o shell '{"MRG": ((.managedResourceGroupId | split("/") | .[-1]) // "")}')"
  eval "$(az network public-ip list -g "$MRG" -o json \
    | yq -p json -o shell '{"CLASSIC": ([.[].ipAddress | select(. != null) | . + "/32"] | join(" "))}' | tee -a fw.env)"
  ```

- **VNet-injected (Azure) or customer-managed VPC (AWS, GCP):** it's the customer's NAT; ask the user.
- **Not in an account you can read:** ask classic compute itself. A one-off single-node job reports the address it leaves from (tested on an AWS classic workspace, where the gateway then connected):
  ```bash
  printf '# Databricks notebook source\nimport urllib.request\ndbutils.notebook.exit(urllib.request.urlopen("https://api.ipify.org", timeout=10).read().decode())\n' > egress.py
  databricks workspace import /Users/<user>/lfc-egress-ip --file egress.py --format SOURCE --language PYTHON --overwrite --profile <PROFILE>
  # submit with a small single-node new_cluster (a node type with local disk, e.g. m5d.large on AWS), then:
  databricks jobs get-run-output <task-run-id> --profile <PROFILE> -o json | yq -p json -oy '.notebook_output.result' > classic.ip   # private file
  databricks workspace delete /Users/<user>/lfc-egress-ip --profile <PROFILE>
  ```
  A workspace normally has one NAT IP, but a cluster in another subnet can leave from a second one: if a gateway still can't connect (`INCORRECT_SOURCE_HOSTNAME_OR_PORT_SPECIFIED_FAILURE`), run the job again and compare.
- **Can't determine it:** add the laptop and serverless IPs anyway, and **warn the user** that any part of the pipeline that runs on classic compute (for example a standard CDC gateway) may not be able to reach the database until its egress IP is added. Serverless parts will still work.

**When a pipeline on classic can't reach the source.** In the event log it shows as `Extractor STARTED`, then about a minute later `Extractor FAILED` with `INGESTION_GATEWAY_CONNECTION_ERROR.INCORRECT_SOURCE_HOSTNAME_OR_PORT_SPECIFIED_FAILURE`. `bin/compute_report.sh` reads it as `ran_on classic`, `started yes`, `reached_source no`. There are two fixes, and the records keep them apart (lfc-test-results, `compute`):

1. **Allow the classic egress IP**, found with one of the ways above, then rerun with the same setting (`serverless` unset). If the rerun reaches the source, record it as such: no `switched_from`, plus `notes` saying the classic IP was added.
2. **Switch to serverless**, which the test matrix does by default (`LFC_SERVERLESS=true`): record `switched_from: unset`, `switch_reason: firewall`.

Use 1 to test what the default does on a classic workspace, and 2 when only the data path matters.

## Private paths instead of allowlisting (not tested yet)

Two Databricks features let serverless reach a source without the published ranges in its firewall. Both are set up by an **account admin** on an NCC (network connectivity configuration) attached to the workspace, so `ready.sh` can't see them as a workspace admin. Ask the user whether the workspace has either.

| | Private network gateway | PrivateLink to a load balancer |
|---|---|---|
| Clouds | Azure: Public Preview (25 regions, centralus included). AWS: Private Preview, through the account team. GCP: in development (2026-10) | AWS (Enterprise plan) |
| What you set up | One subnet (`/28` or larger) delegated to `Microsoft.Databricks/workspaces`; Databricks runs the gateway in it. Serverless then reaches whatever that subnet can, including peered VNets and on-premises over ExpressRoute or VPN | An internal NLB in front of the database, a VPC endpoint service that allows the Databricks role, and a private endpoint rule on the NCC for the database's FQDN |
| What the source's firewall allows | The gateway subnet's private range: one stable range you own, nothing to refresh | The NLB's traffic, from inside the VPC |
| Routing | `SPECIFIC_DESTINATIONS` routes DNS names only (`destination_type: DNS_NAME`), so a connection on an IP address needs a DNS name (an Azure private DNS zone linked to the VNet), or `ALL_TRAFFIC`, which sends all serverless egress through it | the FQDNs in the rule |
| Lakeflow Connect | Database ingestion is named in the announcement; serverless only, so not for a classic gateway | not stated in the docs |
| Other requirements | Premium plan; the VNet's subscription in the same Entra ID tenant as the workspace's; billed from 2026-12-01 | one NLB and endpoint service per target |

Docs: [private network gateway](https://learn.microsoft.com/en-us/azure/databricks/security/network/serverless-network-security/private-network-gateway), [configure it](https://learn.microsoft.com/en-us/azure/databricks/security/network/serverless-network-security/private-network-gateway/configure-private-network-gateway), [announcement](https://www.databricks.com/blog/introducing-private-network-gateway), [AWS PrivateLink to your VPC](https://docs.databricks.com/aws/en/security/network/serverless-network-security/pl-to-internal-network).

The FEVM test workspaces can't use either today: the account APIs refused a non-admin (`This API is disabled for users without account admin status`). Testing needs a Databricks account where the tester is account admin, or an admin to set up the NCC. The plan is in lfc-test-results [test-matrix.md](../lfc-test-results/references/test-matrix.md#planned).

Then record the full wanted list:

```bash
set -a; . ./fw.env
echo "WANT='$MYIP/32 $SERVERLESS ${CLASSIC:-}'" >> fw.env
```

## Step 2: reuse what's already there, then add only what's missing

Shared test accounts usually already have security groups, firewall rules, or NSGs that allow a workspace's serverless ranges and some laptops. **Search for them before creating anything**, especially on AWS, where rule and security-group limits are tight. Each cloud reference shows how to set `HAVE` (the CIDRs or `start-end` ranges existing rules already allow on the database port); then:

```bash
set -a; . ./fw.env
[ -n "${WANT:-}" ] || echo "STOP: WANT is empty; run the last block of Step 1 first"
eval "$($Q $FW/missing.sql | tee -a fw.env)"
echo "missing: $(echo $MISSING | wc -w)"      # 0 means existing rules already cover everything
```

An empty `WANT` (Step 1's last block skipped) also gives 0 missing, so check it before trusting a 0.

A CIDR counts as covered when it falls inside an existing allowed range. Rules open to everyone (`0.0.0.0/0`, `*`, `Internet`) never count: don't rely on them, and point them out to the user.

**Leave your own `lfc-` rules out of `HAVE`.** They're recomputed from `MISSING` on every run; counting them as existing coverage would make the next step remove them.

## Step 3: apply the rules

Add only `MISSING`. Every rule you create gets an `lfc-` name (or description, on AWS) so it can be found, updated, and removed without touching anyone else's. Where a rule holds one CIDR, `rule_name` in `lib.sql` gives a stable name from its purpose and value (`lfc-myip-203-0-113-7-32`, `lfc-serverless-198-51-100-0-28`), so reruns are idempotent. Compare against your existing `lfc-` rules (`LFC_RULES`, as `<name>` or `<rule-id>=<name>`) to get what to add and what to drop:

```bash
set -a; . ./fw.env
eval "$($Q $FW/plan.sql | tee -a fw.env)"
```

`TO_ADD_SPEC` gives each new rule as `<cidr>,<name>,<first-ip>,<last-ip>`, for clouds that want names or IP ranges: `for s in $TO_ADD_SPEC; do IFS=, read -r cidr name first last <<< "$s"; ...; done`.

Then follow the cloud reference:

| Target | Commands |
|---|---|
| Azure Flexible Server (Postgres, MySQL), Azure SQL, NSG on a VM | [references/azure.md](references/azure.md) |
| AWS RDS and Aurora security groups | [references/aws.md](references/aws.md) |
| GCP Cloud SQL, VPC firewall on a VM | [references/gcp.md](references/gcp.md) |

Show the user the full list of rules you'll add or remove (counts per group, the laptop IP, any classic IPs) and wait for a "yes" before applying.

## Step 4: verify

- **From the laptop:** connect with the SQL client (`psql`, `mysql`, `sqlcmd`).
- **From Databricks serverless:** run a read-only `remote_query` through the UC connection:

  ```bash
  cat > ping.sql <<'EOF'
  SELECT * FROM remote_query('<connection>', database => '<database>', query => "SELECT 1 AS ok")
  EOF
  databricks experimental aitools tools query --file ping.sql --profile <PROFILE> -o csv
  ```

  (MySQL: leave out `database =>`.) A timeout here means serverless still can't reach the database: recheck the region, the port, and that the rules applied.
- **From classic compute:** only the pipeline itself proves it. If the classic egress IP wasn't added, say so in the result.

## Gotchas

- **The laptop's IP changes, even without moving.** A corporate VPN hands out a different egress IP from a pool from one session to the next: seen on the same day, `203.0.113.82` then `203.0.113.16`, and SSH to the AWS VM timed out until the rule moved. So **check the laptop IP at the start of every session**, before the first SSH or SQL connection: rerun Step 1, and if it changed, add the new IP and remove the old one in each `lfc-myip-*` rule, keeping the rule's name or description (on AWS, authorize the new CIDR with the same description, then revoke the old one). A timeout on SSH or the database port, where it worked before, usually means this.
- **VPN egress is shared:** behind a corporate VPN, `api.ipify.org` returns the VPN's egress IP, which other people share. Prefer the narrowest IP that works, and remove it when you're done.
- **A VPN may not reach every cloud.** On one corporate VPN (full tunnel), SSH from the laptop reached AWS and Azure VMs, but packets to a GCP VM's public IP never arrived. A logged firewall rule for the laptop's egress IP saw nothing, while SSH to GitHub over the same VPN worked. There was also no VPN route into the VPC's private range. Either connect without the VPN for setup, use the cloud's own tunnel (GCP: `gcloud compute ssh --tunnel-through-iap`, which needs `roles/iap.tunnelResourceAccessor` and an ingress rule from `35.235.240.0/20`), or drive the VM without SSH (a startup script, read back through the serial console). Lakeflow Connect itself doesn't care: serverless reaches the database from the workspace's egress ranges, not through your laptop.
- **To see whether packets arrive at all**, turn on logging for the rule that should allow them (GCP `--enable-logging`; AWS and Azure flow logs). A log with no entry from you means the traffic never reached the cloud, so no rule change will help. A low-priority logged deny rule only sees what higher rules didn't match.
- **`ip-ranges.json` changes**: as often as every 30 days, and new ranges become active as soon as 60 days after they're published ([docs](https://learn.microsoft.com/en-us/azure/databricks/resources/ip-domain-region)). Rerun the sync at least monthly and before a demo. To see whether it changed without syncing, keep the list with the public skill's `serverless-egress.sh <cloud> <region> --state <file>` (databricks-lakeflow-connect `scripts/`, also run by `ready.sh --egress-file <file>`): it lists added (`+`) and removed (`-`) ranges and exits 3 when there are any.
- **Azure service tags don't fit these sources.** `AzureDatabricksServerless` (regional: `AzureDatabricksServerless.CentralUS`) is supported only in a network security perimeter for Azure Storage, not in the shared NSG or a Flexible Server / Azure SQL firewall, and it isn't the published list: in centralus (2026-10) it held 70 prefixes and covered 11 of the 31 published egress ranges. `AzureDatabricks` covers classic compute's traffic to the control plane. So the sync keeps using `ip-ranges.json`.
- **GCP Cloud SQL `--authorized-networks` replaces the whole list.** Always include the existing entries you want to keep.
- **AWS limits:** 60 inbound rules per security group and 5 groups per instance by default (about 300 CIDRs), and AWS caps the product of the two. Reuse existing groups first and check quotas before adding a large list (see [references/aws.md](references/aws.md)).
- **Private connectivity instead of public IPs:** a Databricks network connectivity configuration (NCC) with private endpoints avoids public firewall rules entirely, but it's set up on the account and per workspace; it's out of scope here.
