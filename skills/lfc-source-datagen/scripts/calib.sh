# calib.sh <pg|my> <size|sessions>: rows/s for statement sizes, then for session counts, sampling vmstat (run queue r,
# iowait) and /proc/diskstats (await ms, util %) for the data disk during each run.
E=$1; PHASE=$2; DEV=${DEV:-vda}; CPUS=$(nproc); DIR=${DIR:-.}   # DIR: scripts/postgres or scripts/mysql
if [ "$E" = pg ]; then
  SQL="podman exec -i dg-pg psql -U postgres -At -q -v ON_ERROR_STOP=1"
  plan() { cat $DIR/cast.sql $DIR/plan-insert.sql | $SQL -v schema=cal -v rows=$1 -v src=seed -v order=random -v data=scramble -v plain_every=4 | grep "cal\.$2 "; }
  trunc() { echo "TRUNCATE cal.$1" | $SQL; }
else
  SQL="podman exec -i dg-my mysql -uroot -N -B -r cal"
  plan() { { echo "SET @db='cal', @rows=$1, @src='seed', @order='random', @data='scramble', @plain_every=4, @mode='append';"; cat $DIR/cast.sql $DIR/plan-insert.sql; } | $SQL | grep "\`cal\`.\`$2\`"; }
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
