---
name: git-topic-branches
description: "Start, name, push and clean up a branch in this repo: one topic branch per task from origin/main in its own worktree, a name that says what changes, a PR straight to main, and the branch gone after the merge. Use before the first commit of any task here, when choosing a branch name, when several agents work in parallel, and after a PR is merged."
---

# Topic branches

Several agents can work in this repo at the same time. Each task gets its own branch and worktree, so no one's commit
picks up another's files and no PR waits on another's. The repo deletes a branch when its PR merges, so branches don't
pile up and the name can describe the change instead of the person.

## Start

```bash
git fetch --prune origin
git branch -r | grep -vc HEAD                     # more than about 10: clean up first (below)
git ls-remote --heads origin <name>               # empty: the name is free
git worktree add ../<repo>-wt-<name> -b <name> origin/main
```

Always from `origin/main`, never from another topic branch or from `robertlee` (the owner's own work-in-progress
branch; agents don't commit there). A PR based on another branch can merge without its commits reaching main.

## Name

`<area>-<what changes>`: kebab-case, 2 to 5 words, the area first (a skill, script or folder), then the change.

| Good | Why it's good | Not |
|---|---|---|
| `slot-cpus-per-db` | area `slot` (slot.sh), the change | `fix`, `update`, `patch-2` |
| `aws-personal-vm` | the feature, as the PR title says it | `robertlee-aws`, `my-branch` |
| `statschema-crdb-cast` | skill, engine, the bug | `bug-123`, `issue-fix` |
| `ddl-matrix` | the test it adds | `wip`, `test`, `tmp` |

- **Say what changes, not who or when.** No user names, dates, session ids or tool prefixes (`claude/`, `codex/`):
  the PR already records the author and time.
- **It outlives the branch.** The merge commit keeps `Merge pull request #N from <owner>/<name>` in main's history,
  so the name is read long after the branch is deleted.
- **One task, one name.** A second change of the same area is a new branch with its own name (`slot-clone`, not
  `slot-cpus-per-db-2`).
- Match the PR title: someone scanning the open PRs or `git branch -r` should know what each holds.

## Push and PR

Stage explicit paths (never `git add -A` in a shared checkout), commit, push with `-u`, open the PR with
`--base main`. Merge commits only (the repo turns off squash); the owner merges.

## After the merge

The remote branch is deleted by the repo setting. Remove the local copy:

```bash
git worktree remove ../<repo>-wt-<name>
git branch -D <name>
git fetch --prune origin
```

A merged branch still on the remote (merged before auto-delete): delete it once `git cherry origin/main
origin/<name>` shows only `-` lines (every commit is in main). An unmerged branch with no recent commits: ask the owner.
