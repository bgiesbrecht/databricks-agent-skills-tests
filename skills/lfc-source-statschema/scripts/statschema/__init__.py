"""The parts of statschema (https://github.com/rsleedbx/statschema) the lfc-source-statschema skill uses: the canonical
schema.yaml / stats.yaml model and I/O, the DDL emitter, and top-query collection and replay. The row generators, stats
injection, and the server stay in statschema; lfc-source-datagen generates rows inside the database instead."""
from .core.model import expand_table_instances  # noqa: F401  (schema_io imports it from the package)
