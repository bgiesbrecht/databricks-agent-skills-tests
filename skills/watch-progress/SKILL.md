---
name: watch-progress
description: "Wait on a long-running job (benchmark, data load, database fill, build, migration) by checking for progress on a backoff schedule — often at the start, rarely once it's known to work — instead of a fixed timeout that kills a slow but healthy job or a blind wait that sits on a dead one. Covers jobs with no log, where progress has to be read from the system (row counts, database sessions, CPU and disk). Triggers on "run this benchmark", "load the data", "wait for it to finish", "why is this taking so long", or any command expected to take more than a few minutes."
---

# watch-progress

Waiting is the expensive part of a long job, and both easy ways to wait are wrong:

- **A fixed timeout** kills a benchmark that was slow but healthy, and the run is wasted.
- **A blind wait** sits for 20 minutes on a job that died, hung, or finished its useful work in the first two.

Instead, **decide from progress, not from elapsed time.** Check often at the start, when most failures happen, and back off once the job has shown it works. It works whether or not the job writes a log: when it doesn't, read progress from the system.

## Before starting: know what progress looks like

Write down, before launching, **one number that grows** while the job works and **how to tell it's done**. If the job writes no log, pick the number from the system:

| Job | Progress signal | Busy signal |
|---|---|---|
| Database load / fill | Max key or row count of the table being filled; bytes on disk (`pg_total_relation_size`, `information_schema.tables.data_length`) | Running statements and their age: `pg_stat_activity` (`state`, `wait_event`), MySQL `information_schema.processlist` (`time`, `state`) |
| Benchmark loop | Lines of results written; iterations done | Process CPU time (`ps -o time= -p PID`) increasing |
| Build, download, copy | Output size (`du -s`, `stat`), files written | Process state (`R`/`D` vs `S`), network or disk bytes |
| Anything in a VM or container | The above, run inside it | `vmstat 5 2` (`r` run queue vs CPUs, `wa` iowait, `us`+`sy`), `/proc/diskstats` deltas (await, util) |

**Liveness is a separate check from progress**: is the process or container still running? A readiness loop that only asks "is it ready yet?" polls a container that has already exited forever. Check `ps -p PID`, `podman inspect -f '{{.State.Running}}'`, or the job's exit status on every check.

## The schedule

| When | Check | Decide |
|---|---|---|
| **30–60 s** after launch | Alive? Did the first unit of work start (statement running, first output line, file created)? | Not started or already dead → read the error and fix it now; don't wait longer |
| **2 min** | The progress number moved? Rate per minute? | Moved → compute an ETA from the rate. Not moved and not busy → stuck; busy with no progress → look at what it's waiting on (lock, `wait_event`, `D` state) |
| **5 min** | Rate steady? Resources saturated (run queue ≫ CPUs, iowait high, disk await rising)? | Rate known → switch to backoff. Overloaded → reduce parallelism rather than wait it out |
| Then at **~25%, 50%, 75% of the ETA** (at most every 10–20 min) | Progress still moving at about the same rate? | Slowing sharply → find out why. Same rate → keep waiting |
| **ETA + 50%** | Not done | This is a check, **not a kill**: if progress is still moving, extend; if it stopped, investigate |

Run the checks from a background poller that **exits** when something needs a decision (done, stalled, died), so the exit wakes you up — never a foreground `sleep` and never `nohup`.

```bash
# PID: the job; progress: prints the number that grows; finished: succeeds when the job has exited
PID=$1
progress() { psql -XAtc "SELECT coalesce(max(id), 0) FROM t" 2>/dev/null; }
finished() { ! kill -0 "$PID" 2>/dev/null; }
prev=$(progress); same=0
for wait in 30 30 60 120 180 300 300 600 600 600 900 900 900 900; do
  sleep "$wait"
  now=$(progress)
  if finished; then echo "DONE (or exited) at $(date +%T); progress $now"; exit 0; fi
  if [ "$now" = "$prev" ]; then same=$((same + 1)); else same=0; fi
  echo "$(date +%T) progress $now (+$((now - prev)) in ${wait}s)"
  [ "$same" -ge 2 ] && { echo "STALLED: no progress in two checks"; command -v vmstat > /dev/null && vmstat 1 2 | tail -1; exit 1; }
  prev=$now
done
echo "STILL RUNNING after the schedule; progress $now"; exit 2
```

On exit: read the reason, decide, and start the next poller. `STALLED` and `STILL RUNNING` mean "look", not "kill": a stall with the busy signal moving (a long statement still running, CPU time growing) is fine, so restart the poller with a progress command that sees it, such as bytes on disk.

## Stop early when the answer is already known

A benchmark sweep doesn't have to finish to be useful. If the first points already decide the question (for example a statement-size sweep where each larger size was slower than the last), stop, report it, and spend the time on the points that matter (smaller sizes, in that example). Say what was skipped and why.

## Pitfalls seen in practice

- **Bare `wait` waits for every child**, including background monitors (`vmstat 5 &`, `tail -f &`) that never exit: a script hung 24 minutes after its work was done. Collect the job PIDs and `wait $pids`; kill monitors explicitly.
- **Polling something that already exited**: a readiness loop waited 10 minutes for a container that crashed on start. Every check includes liveness.
- **`pkill -f name`** matches the shell or `ssh` command that's running it, killing the caller. Kill by PID, or match something only the target has.
- **"Busy" isn't progress**: 100% CPU or a long-running statement can be a lock wait, a retry loop, or a plan gone wrong. Only the progress number counts.
- **Silence isn't failure**: a single huge statement shows no row-count change until it commits. Watch its age and resource use in the session list, and bytes on disk, instead of rows.
- **Timeouts on the tool call**: a command that might outlive the tool's timeout belongs in the background from the start, so the timeout never cuts the job.

## Report

Each time the poller exits, tell the user what happened in one or two lines: progress, rate, ETA, and anything you changed. Report results as each part finishes; don't wait to batch them.
