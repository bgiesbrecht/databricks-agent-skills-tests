#!/usr/bin/env python3
"""split-check.py <skill> <commit>: after moving SKILL.md sections into references/, list every line of the skill's
SKILL.md at <commit> that is no longer anywhere in skills/<skill>/ (any .md file), ignoring link targets, which change
when a section moves. Prints the SKILL.md tokens (characters / 4) before and after. Exits 1 if a line is missing.

  python3 skills/skill-token-budget/scripts/split-check.py zerobus-debezium-test a8d8cb0
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

if len(sys.argv) != 3:
    sys.exit(__doc__)
skill, commit = sys.argv[1], sys.argv[2]
root = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip())
folder = root / "skills" / skill
before = subprocess.run(["git", "-C", str(root), "show", f"{commit}:skills/{skill}/SKILL.md"],
                        capture_output=True, text=True, check=True).stdout


def norm(line: str) -> str:
    return re.sub(r"\]\([^)]*\)", "](...)", line.strip())


now = {norm(line) for p in folder.rglob("*.md") for line in p.read_text().splitlines()}
missing = [line.strip() for line in before.splitlines() if len(line.strip()) > 3 and norm(line) not in now]
after = (folder / "SKILL.md").read_text()
print(f"{skill}: SKILL.md ~{len(before) // 4:,} -> ~{len(after) // 4:,} tokens; "
      f"{len(before.splitlines())} -> {len(after.splitlines())} lines; old lines missing: {len(missing)}")
for line in missing:
    print("  missing:", line[:160])
sys.exit(1 if missing else 0)
