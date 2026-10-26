# MySQL and an application's schema

`SOURCE=mysql` runs MySQL 8.4 (`SRC_IMAGE`) with Debezium Server's MySQL connector. `APP=mautic` installs Mautic, an open-source marketing application, into each source database (**mautic-source**). The test collects the installed schema back as the model, and **cdc-table-plan** guesses each table's silver, written to `<volume>/_plan.yaml`. The rounds are the application's own traffic (`ROUNDS=app`). Silver orders events by binlog file, position and row (`cdc.seq=binlog`). The snapshot is taken as of a binlog position T, in one consistent-snapshot transaction.

**Foreign key actions aren't in the binlog through MySQL 9.5.** InnoDB carries out `ON DELETE CASCADE` and `SET NULL` itself and doesn't log the child rows it changes, so a binlog reader never sees those changes. The MySQL manual, "Replication and CASCADE": "the cascading deletes are handled internally by the InnoDB storage engine, which means that none of the changes are logged." From 9.6 the server handles foreign keys and logs those rows, unless `innodb_native_foreign_keys=ON`. Waiting doesn't help: the changes never arrive. [scripts/fk-cascade-check.sh](../scripts/fk-cascade-check.sh) tests an engine. Each engine deletes a parent and changes a referenced key, and the script reads the change log right away and again after a wait:

| Engine | Change log | CASCADE child deletes | SET NULL child updates | ON UPDATE CASCADE |
|---|---|---|---|---|
| MySQL 8.4 | binlog | missing | missing | missing |
| MariaDB 11.4 | binlog | missing | missing | missing |
| MySQL 9.7 | binlog | logged | logged | logged |
| PostgreSQL 16 | logical decoding | logged | logged | logged |
| SQL Server 2022 | CDC, Change Tracking | logged | logged | logged |
| Oracle 23 | LogMiner | logged | logged | (no such action) |

So on MySQL 8.4 a contact deleted in Mautic leaves its segment memberships and event-log rows in silver. Mautic's schema has 125 CASCADE and 65 SET NULL foreign keys.

How silver handles it (the harness turns it on for MySQL before 9.6 and MariaDB):
- **The rules:** the collector records each foreign key's `on_delete` in the canonical schema.
- **After each silver update** ([scripts/fk-actions.py](../scripts/fk-actions.py)): the source enforces its foreign keys, so at a consistent point no child row references a parent that's gone. For each CASCADE or SET NULL foreign key, the child rows whose key matches no current parent row are deleted (CASCADE) or get the columns NULL (SET NULL), in current rows and in the history (the open version closed at the parent's delete, a new one opened for SET NULL). One query first counts every key's such rows, so a pass runs only the statements of the keys with some; passes repeat until one finds none (chains).
- **The trace:** each change is first a row in `fk_actions`: the table, source, key, operation, the foreign key, and when.
- **In the pipeline instead** (`FK_IN_PIPELINE=1`, silver's `cdc.fk_actions=apply`): the changes derived from each parent delete in the change log, at its sequence, into the child's own change views, with each child's versions computed once per update (`_fkv_<child>`). Exact to the parent's sequence, but it made Mautic's first update run past an hour.
- **The plan:** a table such a foreign key changes can't be `[append]`. `classify.py` makes it `[scd1]`, and `plan.py` warns about an edit that appends it.
