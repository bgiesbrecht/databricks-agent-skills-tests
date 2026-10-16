# AWS classic workspace: four engines, every mode, 2026-10-16

AWS FEVM workspace, classic compute allowed, us-east-2; target catalog with its own managed storage. Sources: MySQL 8.4, PostgreSQL 16, SQL Server 2022 Developer, Oracle 23ai Free in Podman on a new EC2 VM in the same region (m6i.xlarge, XFS on a gp3 volume, [aws-vm.md](../skills/lfc-source-cloud-vm/references/aws-vm.md)), built with the same doc-extracted scripts as the Azure VM. Connections `<firstname><lastname>-<engine>-awsvm`. Records: `recall.py --run 2026-10-16-aws-classic-workspace --all`.

| Engine | Connection | QBC | QBC via foreign catalog | Integrated CDC | Standard CDC |
|---|---|---|---|---|---|
| MySQL 8.4 | ✅ | ✅ | ✅ | ✅ | ⛔ not enabled on the workspace |
| PostgreSQL 16 | ✅ | ✅ | ✅ | — (none) | ⛔ not enabled on the workspace |
| SQL Server 2022 | ✅ | ✅ | ✅ | ✅ | ✅ classic gateway |
| Oracle 23ai Free | ✅ | ✅ | ✅ | ✅ | — (none) |

- **QBC (both ways):** snapshot 10/10; after 3 inserts, 2 updates and 2 hard deletes per table, run 2 gave `intpk` (SCD1) 13 rows with 2 updated (a cursor can't see hard deletes) and `dtix` (APPEND_ONLY) 15 rows.
- **Integrated CDC:** snapshot 10/10, then 11/11 with every insert, update and delete.
- **Standard CDC (SQL Server):** the classic gateway first failed with `INGESTION_GATEWAY_CONNECTION_ERROR.INCORRECT_SOURCE_HOSTNAME_OR_PORT_SPECIFIED_FAILURE`: classic compute leaves through the workspace's NAT, which the security group didn't allow and which isn't in an AWS account we could read. A one-off single-node classic job reported the NAT IP; with it in the security group the gateway connected, the applier's snapshot was 11/11, and a second change set arrived in one applier run (12/12).
- **Cross-cloud:** the same workspace also reached the Azure VM's sources through the Azure NSG once it allowed every serverless range (760 CIDRs).

Skill fixes from this run: AWS VM creation (new aws-vm.md), the default connection name (`<firstname><lastname>-<engine>-<target>`), `collapse.sql` for overlapping serverless ranges (Azure rejects overlaps in a rule), the classic-egress probe job, Oracle foreign catalog option `service_name`.
