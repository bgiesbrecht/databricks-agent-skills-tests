#!/usr/bin/env python3
"""pipeline-diagram.py: draw a Lakeflow Connect database pipeline as text and/or Mermaid.

The pipeline, its gateway and its UC connection are read with the Databricks CLI (or from saved JSON), so the
diagram shows what was created: gateway or integrated CDC, serverless or classic, staging, the connection and the
host:port it points at, the destination tables and their SCD type. What the API can't see (where the source runs,
replicas, the firewall, a secret store) comes from flags.

usage: pipeline-diagram.py --pipeline <ingestion pipeline id> [--profile P] [options]
       pipeline-diagram.py --pipeline-json ap.json [--gateway-json gw.json] [--connection-json conn.json] [options]
  --format text|mermaid|both     default both
  --source-cloud aws|azure|gcp|laptop      where the source database runs
  --source-host TEXT             e.g. "VM + Podman", "Azure SQL Managed Instance", "RDS"
  --primary HOST,PORT --secondary HOST,PORT   draw both nodes; the one the connection points at is marked
  --firewall TEXT                e.g. "NSG", "security group", "pg_hba"
  --secret-store TEXT            e.g. "Azure Key Vault", "AWS Secrets Manager"
  --secret-kind uc|workspace|inline         where the connection's password comes from (default inline)
  --hide-host                    don't print host names or ports
  -o FILE                        write there instead of stdout (a .md file gets the Mermaid in a fenced block)
"""
import argparse
import json
import subprocess
import sys

CLOUD_NAMES = {"aws": "AWS", "azure": "Azure", "gcp": "Google Cloud", "laptop": "Laptop"}
SECRET_KIND = {"uc": "UC secret", "workspace": "Workspace secret scope", "inline": "stored in the connection"}


def cli(args, profile):
    cmd = ["databricks", *args, "-o", "json"] + (["-p", profile] if profile else [])
    return json.loads(subprocess.run(cmd, check=True, capture_output=True, text=True).stdout)


def load(path):
    with open(path) as f:
        return json.load(f)


def workspace_cloud(host):
    h = (host or "").lower()
    return "Azure" if "azuredatabricks" in h else "Google Cloud" if "gcp.databricks" in h else "AWS" if h else ""


def model(a, ap, gw, conn, host):
    """Everything the two renderers need, as plain values."""
    spec = ap.get("spec", ap)
    idef = spec.get("ingestion_definition") or {}
    gspec = (gw or {}).get("spec", gw or {})
    gdef = gspec.get("gateway_definition") or {}
    integrated = not idef.get("ingestion_gateway_id")
    opts = (conn or {}).get("options") or {}
    target = f"{opts.get('host', '?')},{opts.get('port', '?')}" if opts else ""
    tables, scd = [], set()
    for o in idef.get("objects") or []:
        t = o.get("table") or o.get("schema") or {}
        cat = t.get("destination_catalog") or spec.get("catalog")
        sch = t.get("destination_schema") or spec.get("schema")
        name = t.get("destination_table") or t.get("source_table") or "*"
        tables.append(f"{cat}.{sch}.{name}")
        scd.add(((t.get("table_configuration") or {}).get("scd_type") or "SCD_TYPE_1").replace("SCD_TYPE_", "SCD "))
    ap_id = ap.get("pipeline_id") or spec.get("id") or "<pipeline>"
    if integrated:
        staging = f"{spec.get('catalog')}.{spec.get('schema')}  volume __databricks_ingestion_gateway_staging_data-{ap_id}"
        gw_compute = "serverless" if spec.get("serverless") else "classic"
    else:
        gid = idef.get("ingestion_gateway_id")
        staging = (f"{gdef.get('gateway_storage_catalog')}.{gdef.get('gateway_storage_schema')}"
                   f"  volume __databricks_ingestion_gateway_staging_data-{gid}")
        gw_compute = "serverless" if gspec.get("serverless") else "classic cluster"
    nodes = []
    if a.primary or a.secondary:
        for role, hp in (("primary", a.primary), ("secondary", a.secondary)):
            if hp:
                nodes.append({"role": role, "hp": hp, "active": hp.replace(":", ",") == target})
    else:
        nodes.append({"role": "database", "hp": target, "active": True})
    return {
        "integrated": integrated,
        "source_cloud": CLOUD_NAMES.get(a.source_cloud or "", a.source_cloud or "source"),
        "source_host": a.source_host or "database host",
        "engine": (conn or {}).get("connection_type", "database").title().replace("Sqlserver", "SQL Server")
                  .replace("Postgresql", "PostgreSQL").replace("Mysql", "MySQL"),
        "nodes": nodes,
        "firewall": a.firewall,
        "secret_store": a.secret_store,
        "secret_kind": SECRET_KIND[a.secret_kind],
        "workspace_cloud": workspace_cloud(host),
        "connection": (conn or {}).get("name") or gdef.get("connection_name") or idef.get("connection_name") or "?",
        "target": "" if a.hide_host else target.replace(",", ":"),
        "gw_compute": gw_compute,
        "gw_name": (gw or {}).get("name") or gdef.get("gateway_storage_name") or "gateway",
        "ap_name": ap.get("name") or spec.get("name") or "ingestion pipeline",
        "ap_compute": "serverless" if spec.get("serverless") else "classic",
        "staging": staging,
        "tables": tables,
        "scd": ", ".join(sorted(scd)) or "SCD 1",
        "hide_host": a.hide_host,
    }


def tables_line(m, n=3):
    t = m["tables"]
    return ", ".join(t[:n]) + (f" (+{len(t) - n} more)" if len(t) > n else "") if t else "(no tables)"


def text(m):
    L = []
    nodes = "   ".join(f"[{d['role']}{'*' if d['active'] else ''}]" for d in m["nodes"])
    L.append(f"{m['source_cloud']}: {m['source_host']}, {m['engine']}")
    L.append(f"  {nodes}" + ("   (* = the connection's target)" if len(m["nodes"]) > 1 else ""))
    L.append("        |")
    if m["firewall"]:
        L.append(f"  firewall: {m['firewall']}")
        L.append("        |")
    L.append(f"Databricks ({m['workspace_cloud'] or 'workspace'})")
    secret = f"  <-- {m['secret_kind']}" + (f" <-- {m['secret_store']}" if m["secret_store"] else "")
    target = f" -> {m['target']}" if m["target"] else ""
    L.append(f"  connection {m['connection']}{target}{secret}")
    L.append("        |")
    if m["integrated"]:
        L.append(f"  ingestion pipeline {m['ap_name']} (integrated CDC, {m['ap_compute']}): extract -> staging -> apply")
        L.append(f"    staging: {m['staging']}")
    else:
        L.append(f"  gateway {m['gw_name']} ({m['gw_compute']}, continuous)")
        L.append(f"    staging: {m['staging']}")
        L.append("        |")
        L.append(f"  ingestion pipeline {m['ap_name']} (applier, {m['ap_compute']})")
    L.append("        |")
    L.append(f"  streaming tables ({m['scd']}): {tables_line(m)}")
    return "\n".join(L) + "\n"


def q(s):
    return '"' + str(s).replace('"', "'") + '"'


def mermaid(m):
    L = ["flowchart TD"]
    L.append(f"  subgraph SRC[{q(m['source_cloud'] + ': ' + m['source_host'])}]")
    for i, d in enumerate(m["nodes"]):
        hp = "" if m["hide_host"] or not d["hp"] else "<br/>" + d["hp"].replace(",", ":")
        L.append(f"    N{i}[({q(m['engine'] + ' ' + d['role'] + hp)})]")
    if len(m["nodes"]) == 2:
        L.append("    N0 -. availability group .-> N1")
    L.append("  end")
    if m["firewall"]:
        L.append(f"  FW{{{{{q('firewall: ' + m['firewall'])}}}}}")
    L.append(f"  subgraph DBX[{q('Databricks workspace' + (' (' + m['workspace_cloud'] + ')' if m['workspace_cloud'] else ''))}]")
    conn = f"UC connection<br/>{m['connection']}" + (f"<br/>{m['target']}" if m["target"] else "")
    L.append(f"    C[{q(conn)}]")
    L.append(f"    SEC[/{q(m['secret_kind'])}/]")
    if m["integrated"]:
        L.append(f"    subgraph AP[{q('ingestion pipeline ' + m['ap_name'] + ' (integrated CDC, ' + m['ap_compute'] + ')')}]")
        L.append("      X[extract] --> STG[(staging volume)] --> APL[apply]")
        L.append("    end")
        first, last = "X", "APL"
    else:
        L.append(f"    G[{q('gateway ' + m['gw_name'] + '<br/>' + m['gw_compute'] + ', continuous')}]")
        L.append(f"    STG[({q('staging volume<br/>' + m['staging'].split('  ')[0])})]")
        L.append(f"    A[{q('ingestion pipeline ' + m['ap_name'] + '<br/>applier, ' + m['ap_compute'])}]")
        L.append("    G --> STG --> A")
        first, last = "G", "A"
    L.append(f"    T[({q('streaming tables (' + m['scd'] + ')<br/>' + tables_line(m, 2))})]")
    L.append(f"    {last} --> T")
    L.append(f"    C --> {first}")
    L.append("    SEC --> C")
    L.append("  end")
    if m["secret_store"]:
        L.append(f"  KV[/{q(m['secret_store'])}/] --> SEC")
    active = next((i for i, d in enumerate(m["nodes"]) if d["active"]), 0)
    if m["firewall"]:
        L.append(f"  N{active} --- FW --- C")
    else:
        L.append(f"  N{active} --- C")
    return "\n".join(L) + "\n"


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--pipeline"); p.add_argument("--profile")
    p.add_argument("--pipeline-json"); p.add_argument("--gateway-json"); p.add_argument("--connection-json")
    p.add_argument("--workspace-host", help="with --pipeline-json: the workspace URL, for its cloud")
    p.add_argument("--format", choices=["text", "mermaid", "both"], default="both")
    p.add_argument("--source-cloud"); p.add_argument("--source-host")
    p.add_argument("--primary"); p.add_argument("--secondary")
    p.add_argument("--firewall"); p.add_argument("--secret-store")
    p.add_argument("--secret-kind", choices=list(SECRET_KIND), default="inline")
    p.add_argument("--hide-host", action="store_true")
    p.add_argument("-o", dest="out")
    a = p.parse_args()
    if not (a.pipeline or a.pipeline_json):
        print(__doc__, file=sys.stderr); sys.exit(2)
    if a.pipeline_json:
        ap = load(a.pipeline_json)
        gw = load(a.gateway_json) if a.gateway_json else None
        conn = load(a.connection_json) if a.connection_json else None
        host = a.workspace_host or ""
    else:
        ap = cli(["pipelines", "get", a.pipeline], a.profile)
        gid = (ap.get("spec", {}).get("ingestion_definition") or {}).get("ingestion_gateway_id")
        gw = cli(["pipelines", "get", gid], a.profile) if gid else None
        cname = ((gw or {}).get("spec", {}).get("gateway_definition") or {}).get("connection_name") \
            or (ap.get("spec", {}).get("ingestion_definition") or {}).get("connection_name")
        conn = cli(["connections", "get", cname], a.profile) if cname else None
        if conn:  # never keep a secret, even in memory
            (conn.get("options") or {}).pop("password", None)
        host = cli(["auth", "describe"], a.profile).get("details", {}).get("host", "")
    m = model(a, ap, gw, conn, host)
    md = bool(a.out and a.out.endswith(".md"))
    parts = []
    if a.format in ("text", "both"):
        parts.append(("```text\n" + text(m) + "```\n") if md else text(m))
    if a.format in ("mermaid", "both"):
        parts.append(("```mermaid\n" + mermaid(m) + "```\n") if md else mermaid(m))
    out = "\n".join(parts)
    if a.out:
        with open(a.out, "w") as f:
            f.write(out)
    else:
        sys.stdout.write(out)


if __name__ == "__main__":
    main()
