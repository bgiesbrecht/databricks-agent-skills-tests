---
name: lfc-saas-answer
description: "Answer a Lakeflow Connect SaaS connector question (Salesforce, SharePoint, ServiceNow, Workday, Dynamics 365, Google Analytics, HubSpot, Zendesk and the rest) when the source can't be stood up for a test: from the Databricks docs, from the vendor's public docs (facts checked word for word against their pages), and from what the customer can see in their own org. Per-connector question sets, the vendor facts behind them, and how to add a connector."
---

# Answer a Lakeflow Connect SaaS question

A database source can be stood up, filled and tested ([lfc-source-setup](../lfc-source-setup/SKILL.md)). A SaaS source mostly can't: there is no container for Salesforce or Workday, and a customer's org is theirs. So a SaaS answer is assembled from evidence, in this order:

1. **The Databricks docs** for the connector (`docs.databricks.com/aws/en/ingestion/lakeflow-connect/<connector>-*`): concepts, connection, pipeline, limits, FAQ, troubleshoot, reference. They state what the connector does. Quote them; don't restate them from memory.
2. **The vendor's public docs**, for what the docs above assume: API allocations, how deletes and modification timestamps work, permissions. These facts live in `references/vendor/<connector>.yaml`, one row per fact with the page and an exact quote, and every row is checked against its page (below). Most "why does the connector do X" questions are answered by a vendor fact: deletes are missed after the Recycle Bin is purged because the vendor's API can no longer return them.
3. **What the customer can check in their own org**: the vendor's usage pages and response headers, the pipeline's event log, the destination table. Each answer ends with these, so the customer can confirm it.
4. **A test**, where the vendor offers a free developer org or sandbox (Salesforce Developer Edition, ServiceNow Personal Developer Instance, HubSpot developer test accounts). Then the answer becomes a tested one, like the database answers. Start the pipeline from the notebook the docs publish for the connector ([connectors.md](references/connectors.md)).

What the connector does internally, beyond the Databricks docs, is not in this repository.

## Connectors, most asked first

| Connector | Question set | Vendor facts | Free test org (to confirm, except Salesforce) |
|---|---|---|---|
| Salesforce | [salesforce.md](references/salesforce.md) | [vendor/salesforce.yaml](references/vendor/salesforce.yaml) | Developer Edition |
| SharePoint | to do | to do | Microsoft 365 developer tenant (eligibility varies) |
| ServiceNow | to do | to do | Personal Developer Instance |
| Workday (Reports, HCM) | to do | to do | none public |
| Dynamics 365 | to do | to do | trial |
| Google Analytics | to do | to do | free property |
| HubSpot | to do | to do | developer test account |
| Zendesk Support | to do | to do | trial |

The order follows the questions field teams ask most. Every connector the docs cover, with its doc pages and published pipeline notebook, is in [references/connectors.md](references/connectors.md), generated from the docs sitemap by `scripts/connector-index.sh` (rerun it, or `--check`, after a docs release). Add the next connector the same way (below).

## Answer a question

1. Find the connector's question set in `references/<connector>.md`. If the question is there, start from its answer and re-check the links.
2. Otherwise read the connector's Databricks doc pages. The FAQ and limits pages answer most questions.
3. Find the vendor facts the answer depends on in `references/vendor/<connector>.yaml`. Missing a fact? Add it (below) before using it.
4. Write the answer for the customer: what happens, why (the vendor fact), what they can check in their org, and what is not tested. Then add the question and answer to the connector's question set.

## Vendor facts, checked against their pages

The rows use the format of [lfc-source-sizing's limits](../lfc-source-sizing/references/limits.md) (product, limit, value, kind, url, quote, ask, checked), plus `text_url` when the page renders with JavaScript and its text comes from a docs API (Salesforce). Check every row before relying on it:

```bash
python3 skills/lfc-source-sizing/scripts/limits-check.py skills/lfc-saas-answer/references/vendor/*.yaml
python3 skills/lfc-source-sizing/scripts/limits-check.py --find <text_url or url> "<words>"   # page text to quote from
```

Copy quotes from `--find` output, never from a summary: a paraphrased quote fails the check, and that's the point. A row whose page moved or changed fails too; fix the row, don't drop the check.

## Add a connector

1. Find its row in [connectors.md](references/connectors.md): its Databricks doc pages and pipeline notebook. Read the FAQ and limits pages.
2. Collect the field's common questions about it, and answer each from step 1. Where an answer depends on how the vendor's API behaves (allocations, deletes, timestamps, pagination, permissions, token lifetime), find the vendor page, add the fact to `references/vendor/<connector>.yaml`, and run the check.
3. Write `references/<connector>.md`: one section per question, with the answer, the Databricks doc link, the vendor rows used, and what the customer can check.
4. Add the connector's row to the table above.
