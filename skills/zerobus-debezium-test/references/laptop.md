# The laptop route

Many users can't create object storage (an S3 bucket, an Azure storage account), can't get the Databricks permissions that reach it (a storage credential, an external location), or can't create service principals. They can still run the whole test:

| Piece | On a cloud VM (above) | On the laptop |
|---|---|---|
| Source and Debezium | Podman on a VM over SSH (`VM_IP`) | Podman in a local Lima VM (`LIMA=<instance>`). Images and the Zerobus native library exist for arm64 |
| Change log | Zerobus | Zerobus, the same. Zerobus authenticates only with a service principal's OAuth secret, and Debezium's sink takes only `client.id` and `client.secret`. So someone who can create one makes it once and hands over its application ID and secret: `SP_CLIENT_ID` and `SP_SECRET_FILE` (a 0600 file). The script then creates no service principal; as the owner of `cdc_log`, you grant it `SELECT` and `MODIFY` |
| Snapshot | `databricks fs cp` into a Volume | The same: dumped on the laptop, then `databricks fs cp` into a **managed** Volume. A managed Volume uses the catalog's own storage, so it needs no storage credential or external location: only `CREATE SCHEMA` (or a schema you own) in a catalog you can use |
| Schema | `remote_query` through a UC connection (serverless must reach the database) | **Through the Volume too** (`SCHEMA_VIA=volume`, the default with `LIMA`). The source's DDL becomes statschema's canonical `schema.yaml` with the **lfc-source-statschema** skill's `ddl-to-schema.py`, and goes to `<volume>/_schema/schema.yaml`, with a copy as at T, `schema-at-T.yaml` |
| Silver | The same: [scripts/silver-from-schema.py](../scripts/silver-from-schema.py) | The same |

Passed all 30 claims on 2026-10-20, run 1792541354 (a Lima VM `<lima-vm>`, Ubuntu 25.10 arm64, Podman 5.4.2), the same claims as on the VM (run 1792541366 after the `SOURCE` change, also 30). The schema changes in rounds 4 and 5 went through a new `schema.yaml` in the Volume and a full refresh.

`ddl-to-schema.py` runs with `uv`. sqlglot's postgres dialect rejects two things in CockroachDB's `SHOW CREATE ALL TABLES`: `PRIMARY KEY (id ASC)` and typed literals such as `DEFAULT 'none':::STRING`. So the script removes `ASC`, `DESC` and `:::<type>` first. When the dump fails, the round fails (`schema-refetch`), rather than checking against the old schema. `SCHEMA_VIA=volume` dumps DDL for `SOURCE=crdb` only, so far.
