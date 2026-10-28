#!/usr/bin/env python3
"""server-fw.py sql|pg|mysql <server> --nsg <shared-nsg> [--profiles p1,p2] [--regions cloud:region,...] [--cidrs c1,c2] [--no-my-ip] [--no-drop] [--apply]:
give an Azure SQL Database server or a Flexible Server the same sources as the shared NSG, scoped to fit its rule cap
(SQL Database 128, MySQL 500, Postgres 500). Needs RG (resource group of both) and SUBSCRIPTION (the subscription_id from the server's IDENTITY line; az's default
isn't used). Optional TENANT_ID: checked against the login.

The list: every inbound Allow rule of the shared NSG except the all-region ones (names matching --skip, default
^Allow_(serverless|workspace)_): the VPN, office and known hosts; plus the serverless egress ranges of each
--profiles workspace's cloud and region, and of each --regions entry (aws:us-west-2), from ip-ranges.json; plus --cidrs (for example classic egress, from
classic-egress.sh); plus this machine's public IP. Adjacent and overlapping CIDRs merge into one start-end rule.
Rules this script owns are named lfc-<n>; other rules are left alone. Prints the plan (keep, add, drop); changes
nothing without --apply. --no-drop keeps lfc- rules outside the list: add the test workspaces' ranges first
(--skip . --profiles <test workspaces>), then the full list later, without deleting what is already there. Exits 1 when the list is over the cap: name fewer workspaces.

  RG=<resource-group> python3 skills/lfc-source-firewall/scripts/server-fw.py pg <server> --nsg <shared-nsg> --profiles <p1>,<p2>
"""
from __future__ import annotations

import ipaddress
import json
import os
import re
import subprocess
import sys
import urllib.request

CAP = {"sql": 128, "mysql": 500, "pg": 500}
FW = {"sql": ["sql", "server", "firewall-rule"], "pg": ["postgres", "flexible-server", "firewall-rule"],
      "mysql": ["mysql", "flexible-server", "firewall-rule"]}
SRV = {"sql": "--server", "pg": "--server-name", "mysql": "--name"}
RULE = {"sql": "--name", "pg": "--name", "mysql": "--rule-name"}
IPR = "https://www.databricks.com/networking/v1/ip-ranges.json"


def az(*args: str) -> object:
    sub = os.environ.get("SUBSCRIPTION", "")
    if not sub:
        sys.exit("SUBSCRIPTION is required: the subscription_id from the server's IDENTITY line (az's default isn't used)")
    out = subprocess.run(["az", *args, "-g", os.environ["RG"], "--subscription", sub, "-o", "json"],
                         capture_output=True, text=True)
    if out.returncode:
        fix = f"; az login --tenant {os.environ['TENANT_ID']}" if os.environ.get("TENANT_ID") else ""
        sys.exit(f"az {' '.join(args[:4])}: {out.stderr.strip()[:300]}{fix}")
    return json.loads(out.stdout or "null")


def opt(name: str, default: str = "") -> str:
    a = sys.argv
    return a[a.index(name) + 1] if name in a else default


def merged(cidrs: list[str]) -> list[tuple[str, str]]:
    iv = sorted((int(n.network_address), int(n.broadcast_address))
                for n in (ipaddress.ip_network(c, strict=False) for c in cidrs))
    out: list[list[int]] = []
    for a, b in iv:
        if out and a <= out[-1][1] + 1:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return [(str(ipaddress.IPv4Address(a)), str(ipaddress.IPv4Address(b))) for a, b in out]


def region(profile: str) -> tuple[str, str]:
    out = subprocess.run(["databricks", "metastores", "summary", "--profile", profile, "-o", "json"],
                         capture_output=True, text=True)
    if out.returncode:
        sys.exit(f"{profile}: can't read the metastore ({out.stderr.strip()[:200]}); log in: databricks auth login --profile {profile}")
    cloud, reg, _ = json.loads(out.stdout)["global_metastore_id"].split(":", 2)
    return cloud, reg


def main() -> int:
    if len(sys.argv) < 3 or sys.argv[1] not in CAP or "--nsg" not in sys.argv:
        print(__doc__)
        return 2
    kind, server = sys.argv[1], sys.argv[2]
    skip = re.compile(opt("--skip", r"^Allow_(serverless|workspace)_"))
    want: dict[str, list[str]] = {}
    for r in az("network", "nsg", "rule", "list", "--nsg-name", opt("--nsg")):
        if r["direction"] == "Inbound" and r["access"] == "Allow" and not skip.search(r["name"]):
            src = (r.get("sourceAddressPrefixes") or []) + ([r["sourceAddressPrefix"]] if r.get("sourceAddressPrefix") else [])
            want[r["name"]] = [s for s in src if re.fullmatch(r"[\d.]+(/\d+)?", s)]
    regions = {f"{c}:{r}": label for label, (c, r) in ((p, region(p)) for p in opt("--profiles").split(",") if p)}
    regions.update({x: "--regions" for x in opt("--regions").split(",") if x and x not in regions})
    if regions:
        ipr = json.load(urllib.request.urlopen(IPR, timeout=30))
        for cr, label in regions.items():
            cloud, reg = cr.split(":", 1)
            got = sorted({c for x in ipr["prefixes"] if x["type"] == "outbound" and x["platform"] == cloud
                          and x["region"] == reg for c in x["ipv4Prefixes"]})
            if not got:
                sys.exit(f"no serverless ranges for {cr} in {IPR}: don't guess the IPs")
            want[f"serverless {cloud} {reg} ({label})"] = got
    if opt("--cidrs"):
        want["--cidrs"] = opt("--cidrs").split(",")
    if "--no-my-ip" not in sys.argv:
        want["this machine"] = [urllib.request.urlopen("https://api.ipify.org", timeout=10).read().decode().strip() + "/32"]
    for k, v in want.items():
        print(f"source  {k}: {len(v)} CIDRs")
    plan = merged([c for v in want.values() for c in v])
    print(f"{len(plan)} rules (cap {CAP[kind]})")
    if len(plan) > CAP[kind]:
        print(f"over the cap for {kind}: name fewer workspaces in --profiles")
        return 1
    have = {r["name"]: (r["startIpAddress"], r["endIpAddress"])
            for r in az(*FW[kind], "list", SRV[kind], server) or []}
    mine = {n: v for n, v in have.items() if n.startswith("lfc-")}
    keep = {n for n, v in mine.items() if v in plan}
    add = [rg for rg in plan if rg not in mine.values()]
    drop = [] if "--no-drop" in sys.argv else sorted(set(mine) - keep)
    others = sorted(set(have) - set(mine))
    print(f"keep {len(keep)}, add {len(add)}, drop {len(drop)}; not ours, left alone: {', '.join(others) or 'none'}")
    if "AllowAllWindowsAzureIps" in have or any(v == ("0.0.0.0", "0.0.0.0") for v in have.values()):
        print("WARN  a 0.0.0.0 rule opens the server to every Azure tenant: remove it")
    if "--apply" not in sys.argv:
        print("plan only: rerun with --apply")
        return 0
    for n in drop:
        az(*FW[kind], "delete", SRV[kind], server, RULE[kind], n, "--yes")
    used = set(keep)
    i = 0
    for start, end in add:
        while f"lfc-{i}" in used:
            i += 1
        used.add(f"lfc-{i}")
        az(*FW[kind], "create", SRV[kind], server, RULE[kind], f"lfc-{i}",
           "--start-ip-address", start, "--end-ip-address", end)
    print(f"applied: {len(plan)} lfc- rules on {server}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
