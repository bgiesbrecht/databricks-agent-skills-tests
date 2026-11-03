---
name: lfc-pipeline-diagram
description: Draw a Lakeflow Connect database pipeline as a text diagram and a Mermaid flowchart, from what was actually created (gateway or integrated CDC, serverless or classic, staging volume, UC connection and the host it points at, destination tables and SCD type) plus flags for what the API can't see (where the source runs, primary/secondary, firewall, secret store). Use right after creating a pipeline, in a test report or a customer write-up, or to check which node a connection points at.
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

`--format text|mermaid|both` (default both). With `-o <file>.md` each diagram goes in a fenced block, ready for a report; the Mermaid renders on GitHub as is.

The pipeline-creation helper in `lfc-schema-change-test` (`lib.sh` `pipelines_create`) prints the text diagram after each create and saves both in the run's work directory as `diagram.md`; set `DIAGRAM=0` to skip it. `SRC_CLOUD`, `SRC_HOST`, `SRC_PRIMARY`, `SRC_SECONDARY`, `SRC_FIREWALL`, `SECRET_STORE` and `SECRET_KIND` feed the flags.

Tests: `tests/test_pipeline_diagram.py` runs the script on saved JSON (placeholder names) for a gateway pipeline on an availability group and an integrated one.
