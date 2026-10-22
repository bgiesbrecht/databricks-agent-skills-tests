# Salesforce: common questions

Answers from the [Databricks Salesforce docs](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/salesforce-concepts) and the Salesforce facts in [vendor/salesforce.yaml](vendor/salesforce.yaml) (each checked against its Salesforce page). None of these is tested end to end yet; a free Salesforce Developer Edition org makes questions 2 to 4 testable.

Parent: [lfc-saas-answer](../SKILL.md).

## 1. What does the Salesforce side need before a connection works?

A Salesforce user who can authenticate the Databricks connected app. Since September 2025 Salesforce restricts uninstalled connected apps, so either a Salesforce admin installs the Databricks connected app, or the authenticating user gets heightened permissions: with API Access Control on, `Customize Application` and either `Modify All Data` or `Manage Connected Apps`; without it, `Approve Uninstalled Connected Apps`. OAuth (sign in through the Databricks connected app) and mutual TLS are supported. The docs disagree on pasting a refresh token by hand: the concepts page marks "OAuth (manual refresh token)" not supported, while the limits page says the connector supports it but doesn't pick up a token Salesforce rotates or revokes. Use the sign-in flow, and re-authenticate the connection if Salesforce revokes its token.

Use a dedicated integration user, and restrict objects and fields with Salesforce permissions: the pipeline ingests what that user can read.

- Databricks: [authentication methods](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/salesforce-concepts), [connected app and permissions](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/salesforce-faq), [create a connection](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/salesforce-connection), [authentication limits](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/salesforce-limits).
- Customer can check: Salesforce **Setup > Connected Apps OAuth Usage** lists the Databricks connected app after the first authentication.

## 2. Will the pipeline use up our Salesforce API limits?

It uses the same daily allocation as every other integration in the org. The connector reads small amounts of changed data through the REST API and large amounts (an initial load, a very active object) through Bulk API 2.0, to limit load on Salesforce.

The allocations it draws on:

- REST calls: an Enterprise Edition org gets 100,000 a day plus 1,000 per Salesforce license; a Developer Edition org 15,000. A REST query returns at most 2,000 records per call, so each object's changed rows read through REST cost at least one call per 2,000 rows, every run.
- Bulk API 2.0: 10,000 query jobs and 1 TB of query results per rolling 24 hours, shared with other tools.
- At most 25 concurrent requests running 20 seconds or longer in a production org (5 in Developer Edition); past that, Salesforce returns `REQUEST_LIMIT_EXCEEDED`.

When Salesforce refuses a call for a limit, the update fails with an API quota error that asks you to check the org's API usage, raise the quota, or run this pipeline (and other Salesforce readers) less often. Retries back off exponentially (1 s, 2 s, 4 s, ...), then stop until the next update.

So: the more objects, the more frequent the schedule, and the more other integrations, the closer the org gets. A pipeline is limited to 250 objects; split larger sets across pipelines, and stagger their schedules.

- Databricks: [which APIs the connector uses; retries](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/salesforce-faq), [limits](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/salesforce-limits).
- Salesforce rows: daily API requests, concurrent long-running requests, Bulk API 2.0 query jobs and results, records per QueryAll response.
- Customer can check: **Setup > System Overview** (API requests in the last 24 hours); the `Sforce-Limit-Info: api-usage=<used>/<limit>` header on any REST response; the `/services/data/vXX.X/limits` resource (`DailyApiRequests`, `DailyBulkV2QueryJobs`) before and after a pipeline update.

## 3. Are deleted records removed from the destination, and when are they missed?

Soft deletes (records in the Recycle Bin) are applied at the next update: removed from the table, or closed with `__END_AT` when history tracking (SCD type 2) is on. The connector can see a deleted record only while Salesforce still returns it: Salesforce returns soft-deleted records until they are purged from the Recycle Bin, and keeps its delete log for at most 15 days (less if an admin empties the Recycle Bin). So a delete is missed when the record is purged before the pipeline's next update, for example while a pipeline is paused for more than two weeks. Hard deletes are never seen. Both need a full refresh of the table.

Some objects, such as history objects, don't support soft deletes.

- Databricks: [soft and hard deletes](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/salesforce-faq), [full refresh](https://docs.databricks.com/aws/en/ldp/updates).
- Salesforce rows: soft-deleted records readable until purged; delete log lookback.
- Customer can check: the org's Recycle Bin settings and who empties it; the longest gap between pipeline updates.

## 4. Why does every incremental update rewrite every row?

Formula fields. Salesforce doesn't update the cursor column when a formula's result changes (`SystemModstamp` doesn't capture changes to values derived from another record), so by default the connector re-reads formula fields in full on every update, and the update count equals the row count. Turn on incremental formula field ingestion to avoid it, within its documented limits.

The connector's cursor is `SystemModstamp`, else `LastModifiedDate`, `CreatedDate`, `LoginTime`. `SystemModstamp` also moves for automated changes (triggers), which `LastModifiedDate` doesn't. Objects with none of these columns can't be ingested incrementally.

- Databricks: [incremental updates](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/salesforce-faq), [formula fields](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/salesforce-formula-fields).
- Salesforce rows: SystemModstamp scope; SystemModstamp misses some changes; LastModifiedDate scope.
- Customer can check: the object's formula fields in **Object Manager**; the pipeline's per-table update counts in the event log.

## 5. Is it real time? And is there a Marketing Cloud connector?

Not real time: the connector runs on the pipeline's schedule, as batches of changes. Salesforce Marketing Cloud is a separate connector, in Beta.

- Databricks: [real-time ingestion](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/salesforce-faq), [Salesforce Marketing Cloud](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/sfmc-overview), [which Salesforce connector to use](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/salesforce-faq) (the ingestion connector copies data; the Data 360 connectors query it in place).
