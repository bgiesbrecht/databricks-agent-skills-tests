# Errors and fixes

| Error | Cause | What to do |
|---|---|---|
| column or table doesn't exist; column count or type mismatch | DDL after the plan was made | Re-plan and rerun |
| deadlock, lock timeout, connection lost | concurrency, a restart | Rerun: each INSERT is atomic and resumes from the current max |
| `NOT NULL` violation on a column the planner filled with `NULL` | a column of a type the cast file doesn't handle | Add the type to the cast file (with a check for the audit, if it can decode), re-plan |
| value too long, out of range, or a `CHECK` violation | a column narrowed or constrained outside the planner | Look at the new definition; if the cast can't fit it, change the cast or leave the column to its default, then re-plan |
| a foreign key violation | a foreign key added, or a parent changed, outside the planner | Re-plan (levels and foreign-key ranges come from the catalog); if the parent is empty, fill it first |
| the table no longer shows up in the plan | its primary key was dropped or changed | Run the skipped-tables query and report it; the planner can only fill tables with a one-column key |
| anything else | | Read the message, inspect the table (`\d` or `SHOW CREATE TABLE`), decide, and say what you changed |
