---
name: lfc-pipeline-diagram
description: Draw a Lakeflow Connect pipeline as a text diagram and a Mermaid flowchart, from what was actually created (gateway or integrated CDC, serverless or classic, staging volume, UC connection and the host it points at, how changes are captured: SQL Server CDC or change tracking, Oracle LogMiner, MySQL binlog, PostgreSQL slot and publication, query-based, SaaS API; destination tables and SCD type) plus flags for what the API can't see (where the source runs, primary/secondary, firewall, secret store). Use right after creating a pipeline, in a test report or a customer write-up, or to check which node a connection points at.
---

# Pipeline diagram

`scripts/pipeline-diagram.py` (prints its usage with no arguments) reads the ingestion pipeline, its gateway and its UC connection with the Databricks CLI and prints both diagrams. Python 3 standard library only.

```bash
scripts/pipeline-diagram.py --pipeline <ingestion pipeline id> [--profile <profile>]
scripts/pipeline-diagram.py --pipeline <id> --source-cloud azure --source-host "VM + Podman" \
  --primary <host>,<port> --secondary <host>,<port> --firewall NSG \
  --secret-store "Azure Key Vault" --secret-kind uc -o diagram.md
```

| From the workspace | From flags |
|---|---|
| Gateway (serverless or classic cluster) or integrated CDC (one pipeline: extract, staging, apply) | `--source-cloud aws\|azure\|gcp\|laptop`, `--source-host` |
| Staging volume `__databricks_ingestion_gateway_staging_data-<id>` and its schema | `--primary` / `--secondary`: both nodes, the connection's target marked |
| UC connection name, type and `host:port` (the password is dropped as soon as it is read) | `--firewall` |
| Destination tables (first few, then a count) and SCD type | `--secret-store`, `--secret-kind uc\|workspace\|inline` |
| The workspace's cloud, from its URL | `--hide-host` leaves host names and ports out |
| How changes leave the source (below) | `--capture cdc\|ct\|cdc+ct` for SQL Server before its first run |
| | `--source-facts <file>` from `vm-facts.sh`, or `--vm "<text>"`: the source VM (below) |

## Source VM, container and object storage

`scripts/vm-facts.sh azure <resource-group> <vm> [--subscription S]` or `vm-facts.sh aws <instance-id> [--region R] [--aws-profile P]` prints one JSON line: VM type, vCPU, RAM and each disk (size, type, IOPS, MB/s) from the cloud CLI. With `--ssh <user@host> [--key <file>] [--container <name>]` it also reads the VM: JuiceFS mounts (object storage behind them: Azure Blob or Amazon S3) and the database container's CPU and memory limits, SQL Server's memory cap and the data directory's size and whether it is on JuiceFS. Pass the file with `--source-facts` (or `SRC_FACTS` to `show-diagram.sh`); the diagram adds a VM, a container and a JuiceFS line under the source. Tested on Azure; the AWS path is written from the EC2 API and not run yet.

## Change capture per source

| Source | Shown as | Where it comes from |
|---|---|---|
| SQL Server | CDC (change tables `cdc.<capture instance>_CT`, utility objects for schema changes), change tracking (`CHANGETABLE`), or both | The pipeline's event `Replication tables: <n> CT tables, <m> CDC tables` (gateway or integrated pipeline); before the first run, `--capture` |
| Oracle | LogMiner on redo and archived redo logs | Connection type |
| MySQL, MariaDB | binlog in ROW format | Connection type |
| PostgreSQL | logical replication: slot and publication (pgoutput) | The pipeline's `source_configurations` |
| Query-based | a SELECT per run on a cursor column | `connector_type` other than `CDC` |
| SaaS | the connector's API, one pipeline | Connection type not a database |

The capture step is drawn on the node the connection points at (the secondary, when `--secondary` is the target).

`--format text|mermaid|both` (default both). With `-o <file>.md` each diagram goes in a fenced block, ready for a report; the Mermaid renders on GitHub as is.

## After every create

`scripts/show-diagram.sh <ingestion pipeline id>` prints "Components created for pipeline <id>:" and the text diagram to stderr (stdout stays free for scripts that print the id), saves text + Mermaid to `$DIAGRAM_MD` when set, and never fails the caller. `DIAGRAM=0` skips it. The flags come from `SRC_CLOUD`, `SRC_HOST`, `SRC_PRIMARY`, `SRC_SECONDARY`, `SRC_FIREWALL`, `SECRET_STORE`, `SECRET_KIND`, `CAPTURE`, `SRC_FACTS`, `SRC_VM`.

Called right after the create in `lfc-schema-change-test` (`lib.sh` `pipelines_create`, which also saves `$W/diagram.md`; `sqlserver-add-column.sh`; `integrated-scd2-ct.sh`) and `lfc-meta-ads` (`pipeline.sh`). A new script that creates an ingestion pipeline calls it the same way.

Tests: `tests/test_pipeline_diagram.py` runs the script on saved JSON (placeholder names): a gateway pipeline on an availability group, an integrated one, and the capture line per source.
