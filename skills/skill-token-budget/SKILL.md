---
name: skill-token-budget
description: "Write or change a skill (SKILL.md, its scripts and references) so an agent loads as few tokens as the task needs: SKILL.md under 5,000 tokens, detail in references/ read only at the step that needs it, scripts run from their usage line instead of read, short output. Use when creating a skill, adding to one, splitting one that bin/lint_scripts.py reports too large, or adding a script."
---

# Writing skills for a small token budget

An agent pays for a skill in three steps (the [Agent Skills spec](https://agentskills.io/specification)):

| What | When it's loaded | Budget |
|---|---|---|
| `name` + `description` | at startup, for every skill | ~100 tokens: what it does and when to use it, one or two sentences |
| The SKILL.md body | when the skill activates, all of it | under 5,000 tokens and 500 lines; here 20,000 characters, checked |
| `references/`, `scripts/`, `assets/` | only when a step opens them | no limit, but one step should need one file |

Tokens are about characters / 4. A script an agent reads instead of runs costs its whole length; a 2,000-line script is ~20k tokens.

## What goes where

**SKILL.md keeps:** when to use the skill, the steps in order with the commands an agent runs, the decisions it must make (and how), and a one-line pointer at each step that needs more: `Errors and fixes: [references/errors.md](references/errors.md).`

**references/ gets:** long tables, error catalogs and troubleshooting, per-engine or per-cloud detail, worked examples, measured results, background, trade-offs. Group by when an agent needs it, so one step opens one file; name files by topic (`errors.md`, `limits.md`, `engines.md`).

**scripts/ gets the logic.** A step says what to run, not how it works:
- Each runnable script starts with a usage header that names it: `# name.sh <arg> [--flag]: what it does, in one sentence.`, then the options. It prints that header when run with no arguments (`[ $# -ge 1 ] || { sed -n 2,12p "$0"; exit 2; }`).
- SKILL.md lists a script as one line: its path and what it does. The agent runs it with no arguments for the rest; it doesn't open the file.
- [SCRIPTS.md](../../SCRIPTS.md) at the repo root has one line per script, generated from the headers: `python3 bin/scripts_index.py` after adding or renaming a script.
- One copy of each piece of logic: a generic script lives once (the public repo), and an internal repo wraps it instead of copying it.

**Output stays short:** a script prints counts, pass/fail and the links to what it created, and writes the details to a file it names. Make the summary the default or a `--summary` flag. Tool output fills context as fast as SKILL.md does.

**Small rules that save tokens and errors:** one JSON value is `jq -r '.path'`, several are `yq -p json -o shell` + `eval` ([shell-json-scripting](../shell-json-scripting/SKILL.md)); `rm -r` on a variable is `"${VAR:?}/..."`; a flag a script reads only as `$1` is passed first.

## Check

```bash
python3 bin/lint_scripts.py                       # usage headers, SKILL.md size, rm guards, first-argument flags, jq for one value
python3 bin/scripts_index.py --check              # SCRIPTS.md matches the scripts' headers
python3 bin/check_links.py skills                 # every relative link, including the new references/ files
bash bin/test_scripts.sh                          # all of the above plus the scripts' own tests
```

`lint_scripts.py` parses .sh files and the bash blocks and inline script calls in markdown with ast-grep (`uvx --from ast-grep-cli==0.51.0`; `AST_GREP` names another binary).

## Splitting a skill that's too large

1. Measure: `wc -c skills/<skill>/SKILL.md` (÷ 4 for tokens) and note the commit.
2. Move sections into `references/<topic>.md` verbatim, by line range; write only the one-line pointers and fix relative links (a file one level down needs `../`).
3. Check nothing was lost: [`scripts/split-check.py`](scripts/split-check.py) `<skill> <commit before>` lists every old line that isn't in the skill's folder any more (link targets ignored), and prints the before and after tokens.
4. Run the checks above, then commit each skill on its own with the before and after sizes in the message.
