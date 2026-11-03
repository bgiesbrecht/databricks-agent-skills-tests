---
name: cli-setup
description: "Check which command-line tools the tests use are installed (Databricks CLI, az, aws, gcloud, Podman, uv, jq, yq, DuckDB, SQL clients), with the install command for any that are missing; and record which Azure subscription and tenant a resource belongs to, and check that the current login still reaches it. Use before the first test on a laptop, or when a cloud command reaches the wrong subscription, account or project."
---

# Tools and cloud identities

Shared by the source and Lakeflow skills (common layer: any skill may use these scripts).

## Tools

Run [`check-tools.sh`](scripts/check-tools.sh) with a group: `base` (default), `local`, `clients`, `aws`, `azure`, `gcp`, or `all`. It prints each tool's version and the install command for anything missing, and exits 1 if something asked for is missing. It installs nothing.

```bash
bash scripts/check-tools.sh local
```

The group table and the install commands per platform are in the "Tools" section of lfc-source-setup.

## Cloud identity

Source the helper; it doesn't run on its own. [`cloud-identity.sh`](scripts/cloud-identity.sh) defines:

- `az_record <subscription>`: prints one `IDENTITY azure tenant_id=... subscription_id=... subscription_name=...` line to keep with the resource's settings.
- `az_require <subscription> [tenant_id]`: stops unless this `az login` reaches that subscription in that tenant.

Every later cloud call for the resource names its identity, because the CLI's default is whichever login or subscription was set last. Keep the record in the private env file, never in the repo.
