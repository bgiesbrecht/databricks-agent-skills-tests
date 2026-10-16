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
| Workspace **classic** compute egress | Not published. It's the workspace's NAT / egress IP, set per workspace (see [Classic compute egress](#classic-compute-egress)) | Standard CDC gateways on classic compute, integrated CDC with `serverless: false`, anything else running on classic clusters |

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
| Does the pipeline use classic compute? | Standard CDC gateway on classic, integrated CDC with `serverless: false`, or classic query-based (Beta) |
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

The DuckDB steps are files in [`scripts/`](scripts/): [`lib.sql`](scripts/lib.sql) (the IPv4 and port macros every step uses), [`missing.sql`](scripts/missing.sql), [`plan.sql`](scripts/plan.sql), and the per-cloud [`sg_pick.sql`](scripts/sg_pick.sql), [`nsg_cover.sql`](scripts/nsg_cover.sql), [`fw_cover.sql`](scripts/fw_cover.sql). They run with **shell-json-scripting**'s runner, `q.sh` (or `q.py` from Python), which reads `lib.sql` from the query's directory:

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
echo "laptop $MYIP, serverless: $(echo $SERVERLESS | wc -w) CIDRs"
```

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
- **Can't determine it:** add the laptop and serverless IPs anyway, and **warn the user** that any part of the pipeline that runs on classic compute (for example a standard CDC gateway) may not be able to reach the database until its egress IP is added. Serverless parts will still work.

Then record the full wanted list:

```bash
set -a; . ./fw.env
echo "WANT='$MYIP/32 $SERVERLESS ${CLASSIC:-}'" >> fw.env
```

## Step 2: reuse what's already there, then add only what's missing

Shared test accounts usually already have security groups, firewall rules, or NSGs that allow a workspace's serverless ranges and some laptops. **Search for them before creating anything**, especially on AWS, where rule and security-group limits are tight. Each cloud reference shows how to set `HAVE` (the CIDRs or `start-end` ranges existing rules already allow on the database port); then:

```bash
set -a; . ./fw.env
eval "$($Q $FW/missing.sql | tee -a fw.env)"
echo "missing: $(echo $MISSING | wc -w)"      # 0 means existing rules already cover everything
```

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

- **Laptop IPs change** (new network, VPN). Rerun Step 1 and replace the `lfc-myip-*` rule when setup commands start timing out.
- **VPN egress:** behind a corporate VPN, `api.ipify.org` returns the VPN's egress IP, which other people share. Prefer the narrowest IP that works, and remove it when you're done.
- **`ip-ranges.json` changes** as Databricks adds regions and capacity. Rerun the sync before a demo rather than trusting old rules.
- **GCP Cloud SQL `--authorized-networks` replaces the whole list.** Always include the existing entries you want to keep.
- **AWS limits:** 60 inbound rules per security group and 5 groups per instance by default (about 300 CIDRs), and AWS caps the product of the two. Reuse existing groups first and check quotas before adding a large list (see [references/aws.md](references/aws.md)).
- **Private connectivity instead of public IPs:** a Databricks network connectivity configuration (NCC) with private endpoints avoids public firewall rules entirely, but it's set up on the account and per workspace; it's out of scope here.
