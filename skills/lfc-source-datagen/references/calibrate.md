# Calibrate statement size and sessions

Each engine and version has its own best statement size (rows per `INSERT ... SELECT`) and its own point where more sessions stop helping, and bulk inserts can flood the disk. **Before a big load (about 100M rows or more), measure both on the actual server**, then use the winners for the whole load. For smaller loads, start from the measured defaults below.

## Measured (4 vCPUs, Podman VM, local NVMe, 12 columns, `order=random`, `data=scramble`)

| Engine | Best rows per statement | Best sessions | Throughput | Bottleneck |
|---|---|---|---|---|
| PostgreSQL 16 | **1M–2M** (≈112k rows/s in one session; 4M dips slightly) | **4** (242,542 rows/s); 8 is 28% slower | CPU: run queue ≈ CPUs, disk util ≈ 20% | One core per INSERT |
| MySQL 8.4 | **100k** (33,383 rows/s; 25k: 14,529; 50k: 24,181; 250k: 27,353; 500k into a 4M-row table: 11,651) | **1–2**: 1, 2, and 4 sessions all ran about 30k rows/s (30,180; 29,849; 30,720); 8 dropped to 21,014 | ≈30k rows/s with 100k-row statements | Disk: from 1 to 8 sessions iowait rose 8% → 42% and util 23% → 67%, with no gain up to 4 and a 32% loss at 8; larger statements raise iowait too |

**MySQL slows down as the table grows**: 250k-row statements ran at 27,353 rows/s while the table stayed under 1M rows, and at 16,055 rows/s up to 4M rows (iowait 17% → 23%), once the table and its random-order key index outgrew the buffer pool. Calibrate with a table near the size the load will reach, not an empty one.

## What to watch while it runs

| Signal | Where | Healthy | Too much |
|---|---|---|---|
| Run queue `r` | `vmstat 1` (first column) | About the number of CPUs | Well above the CPUs: more sessions only queue |
| iowait `wa` | `vmstat 1` | Under about 20% | Rising with each added session: the disk is the limit |
| Disk await | `/proc/diskstats`: Δ(read ms + write ms) ÷ Δ(reads + writes) | Steady, low single-digit ms | Climbing: the device queue is full |
| Disk util | `/proc/diskstats`: Δ(io ms) ÷ 10 per second | Under about 80% | Near 100%: saturated |

Fedora CoreOS (the `podman machine` VM) has no `iostat`, so the script reads `/proc/diskstats` directly. Stop adding sessions at the first count that doesn't raise rows/s, and drop back one if `r` or await jumped there.

## Run it

Inside the database's VM (`podman machine ssh`, the Lima VM, or the cloud VM), with the engine's cast and insert planners from [postgres.md](postgres.md) or [mysql.md](mysql.md) in `/tmp` as `pg-cast.sql` / `pg-plan-insert.sql` or `my-cast.sql` / `my-plan-insert.sql`, a `cal` schema (database) of 8 tables made with `make-dataset`, and a seed table at least as large as the biggest statement size. Containers are named `dg-pg` and `dg-my`; change `SQL=` for others.

```bash
cat > /tmp/calib.sh <<'EOF'
# calib.sh <pg|my> <size|sessions>: rows/s for statement sizes, then for session counts, sampling vmstat (run queue r,
# iowait) and /proc/diskstats (await ms, util %) for the data disk during each run.
E=$1; PHASE=$2; cd /tmp; DEV=${DEV:-vda}; CPUS=$(nproc)
if [ "$E" = pg ]; then
  SQL="podman exec -i dg-pg psql -U postgres -At -q -v ON_ERROR_STOP=1"
  plan() { cat pg-cast.sql pg-plan-insert.sql | $SQL -v schema=cal -v rows=$1 -v src=seed -v order=random -v data=scramble -v plain_every=4 | grep "cal\.$2 "; }
  trunc() { echo "TRUNCATE cal.$1" | $SQL; }
else
  SQL="podman exec -i dg-my mysql -uroot -N -B -r cal"
  plan() { { echo "SET @db='cal', @rows=$1, @src='seed', @order='random', @data='scramble', @plain_every=4, @mode='append';"; cat my-cast.sql my-plan-insert.sql; } | $SQL | grep "\`cal\`.\`$2\`"; }
  trunc() { echo "TRUNCATE TABLE cal.$1" | $SQL; }
fi
mon_start() { vmstat 1 > vm.out & VM=$!; ( while sleep 1; do grep " $DEV " /proc/diskstats; done ) > ds.out & DS=$!; }
mon_stop() { kill $VM $DS 2>/dev/null; wait $VM $DS 2>/dev/null
  r=$(awk 'NR > 3 { s += $1; if ($1 + 0 > m + 0) m = $1 + 0; n++ } END { printf "r avg %.1f max %d", s / n, m }' vm.out)
  wa=$(awk 'NR > 3 { s += $16; n++ } END { printf "iowait %.0f%%", s / n }' vm.out)
  io=$(awk '{ ios = $4 + $8; ms = $7 + $11; if (NR > 1 && ios > pios) { a = (ms - pms) / (ios - pios); s += a; if (a > m + 0) m = a; u += ($13 - pio) / 10; n++ } pios = ios; pms = ms; pio = $13 }
            END { if (n) printf "await avg %.1f max %.1f ms, util %.0f%%", s / n, m, u / n }' ds.out)
  echo "$r (cpus $CPUS), $wa, $io"; }
if [ "$PHASE" = size ]; then           # same total rows for each statement size, so only the size changes
  TOTAL=${TOTAL:-4000000}
  for B in ${SIZES:-250000 500000 1000000 2000000 4000000}; do
    trunc t1; plan $B t1 > one.sql; n=$((TOTAL / B))
    mon_start; s=$(date +%s.%N); for i in $(seq 1 $n); do $SQL < one.sql > /dev/null; done; e=$(date +%s.%N); m=$(mon_stop)
    echo "rows/statement $B x $n: $(awk -v a=$s -v b=$e -v t=$TOTAL 'BEGIN { printf "%.0f rows/s (%.1f s)", t / (b - a), b - a }'); $m"
  done; trunc t1
else                                   # sessions: each loads PER rows into its own table, statement size B
  B=${B:-1000000}; PER=${PER:-2000000}
  for P in 1 2 4 8; do
    for k in $(seq 1 $P); do trunc t$k; plan $B t$k > s$k.sql; done
    mon_start; s=$(date +%s.%N)
    pids=; for k in $(seq 1 $P); do ( for i in $(seq 1 $((PER / B))); do $SQL < s$k.sql > /dev/null; done ) & pids="$pids $!"; done
    wait $pids                         # only the sessions: a bare wait would also wait for the monitors, which never exit
    e=$(date +%s.%N); m=$(mon_stop)
    echo "sessions $P x $PER rows: $(awk -v a=$s -v b=$e -v t=$((P * PER)) 'BEGIN { printf "%.0f rows/s (%.1f s)", t / (b - a), b - a }'); $m"
  done; for k in 1 2 3 4 5 6 7 8; do trunc t$k; done
fi
EOF
sudo bash /tmp/calib.sh pg size                                     # Postgres: 250k ... 4M rows per statement
sudo SIZES="25000 50000 100000 250000" TOTAL=1000000 bash /tmp/calib.sh my size   # MySQL: start small
sudo B=1000000 PER=2000000 bash /tmp/calib.sh pg sessions           # then sessions at the winning size
sudo B=100000 PER=1000000 bash /tmp/calib.sh my sessions
```

`DEV` is the data disk's name in `/proc/diskstats` (`vda` in `podman machine`; `sdc` or `nvme1n1` on a cloud VM: check `lsblk`).

**Run the sweeps in the background and check them early** (**watch-progress**): look at the first statement within a minute, and stop a sweep as soon as its points have decided the answer. If each larger size is slower than the last, the larger sizes won't win; sweep smaller ones instead.
