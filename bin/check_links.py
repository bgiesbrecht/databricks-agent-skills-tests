#!/usr/bin/env python3
"""bin/check_links.py [skills]: every relative markdown link in the skills points at a file or directory that exists.
Prints the broken ones and exits 1 if there are any. External (http) links aren't fetched."""
import os, re, sys

root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "skills")
bad = n = 0
for d, _, files in os.walk(root):
    for f in files:
        if not f.endswith(".md"): continue
        p = os.path.join(d, f)
        text = re.sub(r"```.*?```", "", open(p).read(), flags=re.S)        # links inside code blocks aren't links
        for target in re.findall(r"\]\(([^)\s]+)\)", text):
            if re.match(r"[a-z]+:", target) or target.startswith("#"): continue
            n += 1
            if not os.path.exists(os.path.normpath(os.path.join(d, target.split("#")[0]))):
                bad += 1; print(f"{os.path.relpath(p, root)}: {target}")
print(f"{n} links, {bad} broken")
sys.exit(1 if bad else 0)
