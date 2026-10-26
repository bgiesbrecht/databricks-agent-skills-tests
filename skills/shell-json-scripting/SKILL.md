---
name: shell-json-scripting
description: "Turn CLI JSON output (databricks, aws, az, gcloud) into shell variables and scripts that are easy to maintain, choosing the simplest tool per step: yq -o shell + eval for values and one-input filters, plain shell for short list loops, and DuckDB SQL only for IP math, multi-input joins, and ranking, with one SQL file shared between shell and Python. Use when writing shell in a skill or script that reads JSON from a CLI or API."
---

# Shell scripting with CLI JSON

Cloud and Databricks CLIs all speak JSON. Ask for it every time, then use **the simplest tool that does the job**, in this order:

| Job | Tool |
|---|---|
| One value into a variable: `X=$(<cli> -o json \| jq -r '.path')` | `jq -r` |
| Several values into shell variables at once; filter, map, `unique`, `join`, `group_by` over **one** JSON input | `yq -p json -o shell` + `eval` (yq's expressions are jq's; `-o shell` sets many variables in one pass) |
| Loop over a short list, check membership, split a list into chunks, call a CLI per item | Plain shell (`for`, `case`, `xargs -n`, `paste`) |
| IP-range math, joins across two or more inputs, "A not covered by B" with ranges, ranking or greedy picks, window functions | DuckDB SQL in a `.sql` file |
| An SDK, retries, auth flows, or the caller is already Python | Python, calling DuckDB for the logic |

Move to a later row only when the simpler tool gets awkward: a yq expression you can't read in one pass, or a shell loop nested inside another loop. Moving back is just as good: if a DuckDB file only filters one array, a yq one-liner is shorter. A rough guide is that one input and no math means yq or shell, while two inputs or IP math means DuckDB.

Plain set operations on strings (lists of IDs or names, not IP ranges) are yq, not DuckDB: `(strenv(A) | split(" ")) - (strenv(B) | split(" "))`.

Avoid `--query ... -o tsv`, `--format="value(...)"`, `awk`, `cut`, and `read` on CLI output: they split on whitespace, lose `null` vs empty, and break when a field order or a value changes.

Needs [`yq`](https://github.com/mikefarah/yq) v4 (the Go one, not the Python wrapper) and `duckdb`: `brew install yq duckdb` (see **lfc-source-setup** "Tools"). For Python, run the script with uv instead of installing into a shared Python: `uv run --no-project --with duckdb python3 q.py`.

## Values into shell variables: `yq -o shell` + `eval`

```bash
eval "$(databricks current-user me -o json \
  | yq -p json -o shell '{"ME": (.userName // ""), "ME_ID": (.id // "")}')"
echo "$ME"
```

- yq single-quotes every value (`X='a'"'"'b'`), so `eval` can't run anything hidden in the data.
- **Always add `// ""`.** For a missing path yq prints the string `null`, which then looks like a real value.
- **Lists become one space-separated variable:** `{"IDS": ([.items[].id] | join(" "))}`, then `for id in $IDS`. Fine for IDs, IPs, and names; not for values that contain spaces.
- **Always give `-o`.** `yq -p json '<expr>'` without `-o` warns and prints YAML; use `-o json -r` to print plain strings, one per line.
- yq has `select`, `map`, `test`, `group_by`, `unique`, `join`, and `strenv(NAME)` for env vars, but no `floor`: strip a `.0` in the shell (`${N%.*}`).
- Several variables from one call cost one API request, not one each.

## State between commands: an env file

An agent's shell usually doesn't keep variables from one command to the next. Keep them in a file and load it at the top of every block:

```bash
set -a; . ./state.env                       # set -a: export everything assigned from here on
eval "$(<cli> ... -o json | yq -p json -o shell '{"NAME": (.path // "")}' | tee -a state.env)"
```

- `set -a` exports every variable assigned after it, including the ones `eval` sets, so DuckDB can read them. **Don't `set +a` mid-block:** anything set afterwards is invisible to it.
- `tee -a` appends; a later line for the same name wins when the file is sourced.
- Only IDs, names, and IPs go in the file. **Never secrets:** keep a password in a shell variable and pass it through the client's env var (`PGPASSWORD`, `MYSQL_PWD`, `SQLCMDPASSWORD`). If it must outlive the shell, use its own `umask 077` file, and delete the file when the work is done. To move a secret to another host, see [Profiles and secrets](#profiles-and-secrets-through-the-cli).

## Profiles and secrets: through the CLI

**Read Databricks profile fields from the CLI, never from its config file.** The CLI knows the file's rules (sections, defaults, `DATABRICKS_CONFIG_FILE`), and a parser of your own drifts from them. Some agent setups also block any command that names the file.

```bash
PROFILES=$(databricks auth profiles --skip-validate -o json)            # name, host, account_id, auth_type per profile
field() { printf '%s' "$PROFILES" | yq -p json -o tsv ".profiles[] | select(.name == \"$1\") | .$2 // \"\""; }
HOST=$(field my-ws host); AID=$(field my-ws account_id)
# account profiles for that account: an accounts.* host and the same account_id
printf '%s' "$PROFILES" | yq -p json -o tsv ".profiles[] | select(.account_id == \"$AID\" and ((.host // \"\") | test(\"^https://accounts[.]\"))) | .name"
```

- Leave out `--skip-validate` only when you need `valid`: validating every profile takes seconds per dozen.
- To add a profile: `databricks auth login --host <host> --profile <name>`. To remove one: `databricks auth logout <profile> --auto-approve --delete`.
- To use another config file, pass it to the CLI as `DATABRICKS_CONFIG_FILE`. Don't read it yourself.

**Move a secret straight to where it's used.** Hold it in a shell variable, pipe it into a root-only file on the remote host, and `unset` it. Nothing is written on the laptop, and nothing is printed:

```bash
SAS=$(az storage container generate-sas ... -o tsv)
printf 'SAS_URL=https://<account>.blob.core.windows.net/<container>?%s\n' "$SAS" \
  | ssh <host> 'sudo sh -c "umask 077; cat > /etc/<tool>/<name>.env"'
unset SAS
```

To check whether a token has expired, read only its expiry field (a SAS's `se=`), not the token itself.

## Logic: DuckDB SQL files, run from shell or Python

Each step is a `.sql` file that:

- reads scalar inputs with `getvariable('NAME')` (lists as space-separated strings),
- reads JSON files with `read_json('<file>', columns = {...})`,
- and returns **exactly one row**, whose columns become shell variables.

A runner fills every `getvariable('NAME')` from the env var of the same name and prints the row as shell assignments: [`scripts/q.sh`](scripts/q.sh). It first runs `lib.sql` from the query's own directory, if there is one, for shared macros (`CREATE MACRO ...`). Use it as `eval "$(scripts/q.sh dir/step.sql | tee -a state.env)"`.

The same files from Python: [`scripts/q.py`](scripts/q.py) (`uv run scripts/q.py dir/step.sql`, or `import q; q.run("dir/step.sql")` for a dict). Its first lines declare its one package (`duckdb`, as PEP 723 script metadata), so `uv run` builds the environment itself. `getenv()` exists only in the DuckDB CLI, which is why the SQL uses `getvariable()`.

### Example: the same job at each level

Filter a long nested array (one input, no math): yq.

```bash
curl -fsSL -o ip-ranges.json https://www.databricks.com/networking/v1/ip-ranges.json
set -a; CLOUD=aws REGION=us-east-1
eval "$(yq -p json -o shell '{"SERVERLESS": ([.prefixes[] | select(.type == "outbound" and .platform == strenv(CLOUD)
  and .region == strenv(REGION)) | .ipv4Prefixes[]] | unique | join(" "))}' ip-ranges.json)"
```

What's in one list but not another, as plain strings: yq.

```bash
set -a; WANT="a b c"; HAVE="b"
eval "$(yq -n -o shell '{"MISSING": ((strenv(WANT) | split(" ")) - (strenv(HAVE) | split(" ")) | join(" "))}')"
echo "$MISSING"       # a c
```

Pick the items of `MISSING` that are in a second list, and split them into chunks of 400: shell.

```bash
sel() { for w in $MISSING; do case " $1 " in *" $w "*) echo "$w";; esac; done; }
sel "$SERVERLESS" | xargs -n 400 | awk '{ print "rule-" NR-1, $0 }'
```

What's not covered, when "covered" means "inside an allowed IP range": DuckDB, because it needs IP math. Here `lib.sql` holds integer macros `lo()`, `hi()`, and `covers()`, as in **lfc-source-firewall**:

```bash
cat > missing.sql <<'EOF'
SELECT coalesce(string_agg(w, ' '), '') AS MISSING FROM unnest(words(getvariable('WANT'))) t(w)
WHERE NOT EXISTS (SELECT 1 FROM unnest(words(getvariable('HAVE'))) h(h) WHERE covers(h, w));
EOF
set -a; WANT="10.0.0.0/28 10.9.0.0/24"; HAVE="10.0.0.0/16"
eval "$(scripts/q.sh missing.sql)"; echo "$MISSING"       # 10.9.0.0/24
```

The `inet` extension's `<<=` also works for plain CIDRs, but it has to be installed for each DuckDB version (CLI and Python are often different); the integer macros need nothing.

## Gotchas

- **`yq` prints `null`** for missing paths: always `// ""`.
- **Reserved names.** Bash: `GROUPS`, `RANDOM`, `SECONDS`, `PWD`, `UID`, `HOSTNAME`, `PATH` are taken; pick prefixed names (`SG_IDS`, not `GROUPS`). SQL: `DROP`, `ADD`, `GROUP` need quoting as column names; prefer `TO_DROP`, `TO_ADD`.
- **Give `read_json` explicit `columns`** for CLI output. Auto-detection fails when a field is absent from every row (the column doesn't exist) or empty everywhere (`[]` has no type).
- **One row, always.** Aggregate with `string_agg` and wrap it in `coalesce(..., '')`: an empty input gives `NULL`, not `''`. The runner fails on no row.
- **SQL doesn't short-circuit `AND`.** `is_ip(s) AND lo(s) = 0` still evaluates `lo('*')`; put the guard inside the macro (`CASE WHEN NOT is_ip(s) THEN NULL ...`) or use `TRY_CAST`.
- **Filter on an `unnest` in a subquery.** `SELECT unnest(x) AS p ... WHERE p.f = 1` fails; wrap it: `SELECT * FROM (SELECT unnest(x) AS p ...) WHERE p.f = 1`.
- **No `->` lambdas.** DuckDB 1.5 prints a deprecation warning to stdout for them, which breaks the JSON the runner reads. Use list comprehensions: `[x FOR x IN list IF x <> '']`.
- **`grep -q` in a pipeline under `set -o pipefail` can fail on a match.** `grep -q` exits at the first match, the writer gets SIGPIPE, and `pipefail` reports the pipeline as failed, so `until podman logs c | grep -q READY; do sleep 5; done` never ends when the writer prints more after the match. Use `grep PATTERN > /dev/null`, which reads to the end.
- **`duckdb -bail`** stops at the first error; without it, later statements still run and print misleading results.
- **Extensions are per version.** The CLI and the Python module can be different versions; put `INSTALL <ext>; LOAD <ext>;` in the SQL file if you use one (`inet`, `httpfs`). Downloading inputs with `curl` first avoids needing `httpfs`.
- **Numbers from APIs can be floats** (`60.0`): shell arithmetic rejects them.
- **`-o json` flags differ:** `databricks ... -o json`, `aws ... --output json`, `az ... -o json`, `gcloud ... --format=json`.
- **Show before you change.** Scripts that compute a plan (rules to add or remove, resources to delete) should print it and wait for a "yes" before applying.

## Where this is used

**lfc-source-firewall**: an env file and yq for every CLI call and the serverless IP list; shell for per-purpose splits and NSG chunking; DuckDB SQL files (with a shared `lib.sql` of IPv4 macros) only for rule coverage, rule plans, and the AWS security-group pick.
