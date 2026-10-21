---
name: zerobus-workspace-setup
description: "Prepare a Databricks workspace for Zerobus Ingest tests: check and enable the Zerobus previews through the Settings API (core, the Kafka-compatible and MQTT endpoints, Default Storage writes, the JSON rescue column), check the target table, grant a service principal directly on it, mint a table-scoped token the way a producer would, and check the network path from where the producer runs. Use on a new test workspace, or when a producer is refused (error 4062: an endpoint preview is off; 4024: grants not on the table)."
parent: lfc-workspace-setup
---

# Prepare a workspace for Zerobus Ingest

The Zerobus counterpart of **lfc-workspace-setup**. Before a producer (Debezium Server's Zerobus sink, Kafka Connect on the Kafka-compatible endpoint, an SDK, MQTT) can write, the workspace needs the right previews on, a managed table, a service principal granted directly on it, and an open network path. Three scripts check and fix each, all with the Databricks CLI:

| Script | Does | Changes anything |
|---|---|---|
| [`scripts/check.sh`](scripts/check.sh) | One line per requirement, `PASS` / `FAIL` / `WARN`, with the fix for each `FAIL` | No |
| [`scripts/enable.sh`](scripts/enable.sh) | Lists the Zerobus settings, or turns on the ones named | Only with `--apply` (workspace admin) |
| [`scripts/sp.sh`](scripts/sp.sh) | For whoever can create service principals, to hand one to a tester who can't: creates it (or reuses one with that name), writes an OAuth secret into a 0600 file (never printed), and, with `--table`, grants it there | Only with `--apply` (workspace admin) |
| [`scripts/grant.sh`](scripts/grant.sh) | Grants a service principal `USE CATALOG`, `USE SCHEMA`, and `SELECT` and `MODIFY`, each directly on its securable | Only with `--apply` (the table's owner, or `MANAGE`) |

```bash
S=skills/zerobus-workspace-setup/scripts; P=<PROFILE>
bash $S/enable.sh $P                                              # every Zerobus setting and its value
bash $S/check.sh $P --table <catalog.schema.table> --sp <application id> --secret-file <0600 file> \
  --interfaces grpc,kafka --from "ssh azureuser@<vm>"             # or --from "limactl shell <instance> --"; default: here
bash $S/enable.sh $P kafka --apply                                # a FAIL's fix
bash $S/grant.sh $P --table <catalog.schema.table> --sp <application id> --apply
```

`grant.sh` and `sp.sh` print a link to the table (its Permissions tab) and to the service principal, to check the result.

## 1. The Zerobus previews (Settings API)

Each Zerobus feature in preview is a workspace setting, read and changed with `workspace-settings-v2`, like the Lakeflow Connect connectors (**lfc-workspace-setup** step 1). On an Azure serverless test workspace (2026-10-21):

| Setting | Display name | Needed for | Value found |
|---|---|---|---|
| `zerobus_ingest_core` | Lakeflow Connect Zerobus Ingest | everything: gRPC, the SDKs, REST, Debezium's Zerobus sink | on |
| `zerobus_kafka_endpoint` | Zerobus Ingest Kafka Endpoint | the Kafka-compatible endpoint (port 9092): Kafka producers, Kafka Connect | **off** |
| `zerobus_mqtt_endpoint` | Zerobus Ingest MQTT Endpoint | the MQTT endpoint (port 8883) | off |
| `zerobus_default_storage_write` | Zerobus Ingest Default Storage | tables on Default Storage | on |
| `zerobus_rescue_column_json` | Zerobus Ingest Rescue Column JSON | a rescue column for JSON records that don't match the table | off |

With an endpoint's setting off, every connection fails at SASL authentication, even with a valid token and grants: `SaslAuthenticationException: Access denied: feature "Zerobus Ingest Kafka Endpoint" is not enabled for workspace "<id>". Error Code: 4062`. `enable.sh <profile> kafka --apply` turned it on through the public API (`patch-public-workspace-setting`, `boolean_val: true`), and the same Kafka Connect worker got through on its next start. Read a value from `boolean_val` (set on this workspace) or `effective_boolean_val` (inherited), not with a `//` fallback: `false` counts as missing in `yq` and `jq`.

## 2. The target table

Zerobus writes only to an existing **managed Delta** table (or a streaming table). It doesn't create tables. On Default Storage, the table also needs `zerobus_default_storage_write`. `check.sh` reads `databricks tables get` and compares the table's location with `__databricks_managed_storage_location`. A managed table in a catalog you can create schemas in is enough: no storage credential or external location (see **zerobus-debezium-test**, "Without cloud storage or service principal permissions").

## 3. The service principal

Zerobus authenticates only with a service principal's OAuth secret (Debezium's sink and Kafka Connect's login callback take `client.id` / `clientId` and the secret). If you can't create one, someone who can runs `sp.sh <profile> --name <name> --secret-file <file> --apply` once and gives you the application ID and the file. Then:

- **Grant directly on each securable**: `USE CATALOG` on the catalog, `USE SCHEMA` on the schema, `SELECT` and `MODIFY` on the table. The token is table-scoped (`authorization_details`), and inherited grants may not satisfy it (error 4024). `grant.sh` checks what's there and adds only what's missing.
- **Mint a token as the producer will.** With `--secret-file`, `check.sh` requests a table-scoped token from `<workspace>/oidc/v1/token` (`client_credentials`, `resource=api://databricks/workspaces/<id>/zerobusDirectWriteApi`, `authorization_details` for the catalog, schema and table). A minted token proves the secret and the grants; it doesn't prove the endpoint previews (step 1).

## 4. The network, from where the producer runs

Outbound TCP from the producer's host to `<workspace-id>.zerobus.<region>.<cloud domain>`: 443 for gRPC, the SDKs and REST, 9092 for Kafka, 8883 for MQTT. `--from` runs the check there: `ssh <user>@<vm>`, or `limactl shell <instance> --` for a laptop VM.

## Tested

On an Azure serverless sandbox (2026-10-21), for the table a Kafka Connect worker writes to: every check passed except `zerobus_kafka_endpoint`, which failed with its fix. `enable.sh kafka --apply` turned it on, `check.sh` passed, and YugabyteDB changes flowed through Kafka Connect into the table (**zerobus-debezium-test**, `SOURCE=yb`).
