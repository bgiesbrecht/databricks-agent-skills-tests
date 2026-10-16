#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pyyaml"]
# ///
# uv run validate.py schema.yaml [stats.yaml] [queries.yaml]
# Load each file with statschema's own model (the package next to this script), so a file this skill writes stays
# statschema's canonical format: schema.yaml (tables, columns, keys, foreign keys, generation rules), stats.yaml (column,
# index, and foreign-key statistics), queries.yaml (the top queries).
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import yaml
from statschema.core.schema_io import load_canonical
from statschema.core.stats_io import load_stats
from statschema.query.model import load_queries

for f in sys.argv[1:]:
    d = yaml.safe_load(open(f))
    if "queries" in d: w = load_queries(f); print(f"{f}: {len(w.queries)} queries ({w.source_dialect})")
    elif "source_dialect" in d or any("null_fraction" in str(t) for t in d.get("tables", [])[:1]):
        s = load_stats(f); print(f"{f}: statistics of {len(s.tables)} tables, {sum(len(t.columns) for t in s.tables)} columns")
    else:
        t = load_canonical(f); print(f"{f}: {len(t)} tables, {sum(len(x.columns) for x in t)} columns, "
                                     f"{sum(len(x.fk_constraints or []) for x in t)} foreign keys")
