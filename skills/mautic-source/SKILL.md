---
name: mautic-source
description: "A real application's database as a CDC test source: Mautic 7.2 (open-source marketing automation) installed by itself into MySQL 8.4, with its own sample data, and its own traffic (tracking-pixel page hits, form posts, contacts and segments through its REST API, e-mails sent and opened, its cron jobs) to change it the way the app does. Used by zerobus-debezium-test (SOURCE=mysql APP=mautic) for the n:1 test: N copies of the app into one silver."
parent: zerobus-debezium-test
---

# Mautic: a real application's database as the source

The TPC models are shaped by hand; a customer's schema is shaped by an application. Mautic is an application with a
schema made by its ORM (128 tables, 199 foreign keys, a surrogate `id` on almost every table, generated columns,
serialized PHP in text columns, JSON, binary keys) and its own ways of changing it. The test runs it as it is.

| Step | Script | What it does |
|---|---|---|
| Install | [`scripts/setup.sh`](scripts/setup.sh) `<database> <web port>` | `CREATE DATABASE`, `mautic:install` (Mautic builds its tables from its Doctrine entities), `doctrine:fixtures:load` (its sample data, about 1,500 rows in 34 tables), then a web container on `127.0.0.1:<port>` with the REST API on |
| Traffic | [`scripts/traffic.sh`](scripts/traffic.sh) | one round: tracking-pixel hits, form posts, contacts created, edited, added to and removed from a segment, and deleted through the API, an e-mail sent to and opened by the newest contacts, and the cron jobs (`mautic:segments:update`, `mautic:campaigns:update`, `mautic:campaigns:trigger`, `mautic:messages:send`, `mautic:webhooks:process`) |

Both run on the host with the containers (the cloud VM of **lfc-source-cloud-vm**), from `zerobus-debezium-test`'s
harness: `SOURCE=mysql APP=mautic NSRC=<copies>`. Each copy is its own database (`mautic1` ... `mautic<N>`) on one
MySQL server, with its own web container; silver merges them, keyed by `_source`.

## What the app's own traffic showed

- **`page_hits` is updated after each insert** (40 inserts, 40 updates in two rounds). The code reads as append-only,
  so a plan that appended it would have dropped those updates: see **cdc-table-plan**.
- **Requests from curl's own user agent aren't tracked**: Mautic skips what it takes for a bot. `traffic.sh` sends a
  browser's.
- **`mautic:install` doesn't create the database**, and the web image won't start without `MAUTIC_DB_*` in its
  environment as well as `config/local.php`.
- **Segment e-mails (`mautic:broadcasts:send`) sent nothing** to the fixtures' segment; e-mails go through the API
  instead (`/api/emails/<id>/contact/<id>/send`).

## Trade-offs

- **The fixtures' admin password is Mautic's published development one** (`Maut1cR0cks!`, in its own
  `.ddev/local.config.php.dist`); the web container listens on 127.0.0.1 only.
- **The MySQL root password is on the host's process list while Mautic installs** (the installer takes it as an
  argument); it's a throwaway password of a test container, kept in a 0600 file otherwise.
- **Each round is the same traffic, seeded by its number**: realistic in kind, not in volume or mix.
