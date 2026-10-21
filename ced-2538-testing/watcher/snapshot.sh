#!/bin/sh
# snapshot.sh -- CED-2538. Watch for a TTFT tail event and capture point-in-time state when one
# happens, instead of sampling blindly and hoping a burst was in the window.
#
# WHY TRIGGERED AND NOT CONTINUOUS. py-spy dumps, kernel stacks and smaps_rollup are too expensive
# and too voluminous to take continuously for the hours a GLM-5.2 run takes, and a snapshot taken
# at a random moment almost certainly lands in an idle gap. The bpftrace scripts are the continuous
# layer (cheap, always on, 10 s windows); this is the expensive layer, fired only when the thing
# being investigated is actually happening.
#
# TRIGGER. sglang's own Prometheus histogram, which --enable-metrics turns on. The number of
# requests whose TTFT exceeded TRIGGER_S is
#     time_to_first_token_seconds_bucket{le="+Inf"} - time_to_token_bucket{le="<TRIGGER_S>"}
# and any increase in it means a slow request just completed. That is exact, needs no coordination
# with the load generator, and works even if the bench is on another node. A file at
# $OUTDIR/trigger also fires one by hand:  touch /out/trigger
#
# WHAT IT DELIBERATELY DOES NOT DO: attach gdb. SIGSTOPping eight TP ranks mid-forward can itself
# stall the server and can trip the NCCL watchdog into tearing the engine down, which would destroy
# the run and look like a cedana fault. py-spy --nonblocking and /proc/<pid>/stack give the same
# "where is it stuck" answer without stopping anything. Set ALLOW_GDB=1 only on a node with no
# other purpose, and expect to lose the server.
#
# Env: HOST PORT OUTDIR TRIGGER_S COOLDOWN_S MAX_SNAPS POLL_S ALLOW_GDB
set -u

HOST="${HOST:-localhost}"
PORT="${PORT:-30000}"
OUTDIR="${OUTDIR:-/out}"
TRIGGER_S="${TRIGGER_S:-8}"
COOLDOWN_S="${COOLDOWN_S:-60}"
MAX_SNAPS="${MAX_SNAPS:-20}"
POLL_S="${POLL_S:-2}"
ALLOW_GDB="${ALLOW_GDB:-0}"

mkdir -p "$OUTDIR/snapshots"
log() { echo "[snapshot] $(date -u +%H:%M:%S) $*" >&2; }

# Match processes by full argv without pgrep: the bpftrace images are minimal and procps is not
# guaranteed. tr + grep are in busybox, so this works everywhere.
proc_match() {
  for _d in /proc/[0-9]*; do
    [ -r "$_d/cmdline" ] || continue
    if tr '\0' ' ' < "$_d/cmdline" 2>/dev/null | grep -qE -- "$1"; then
      echo "${_d#/proc/}"
    fi
  done
}

command -v py-spy >/dev/null 2>&1 || {
  log "py-spy not found; installing (needs egress, or bake it into the image)"
  pip install --quiet --disable-pip-version-check py-spy 2>/dev/null \
    || log "py-spy install FAILED -- python stacks will be missing from every snapshot"
}

# Number of requests so far whose TTFT exceeded TRIGGER_S. Prints "-1" when the server is not
# serving metrics yet, which the loop treats as "not ready" rather than as a change.
slow_count() {
  curl -sf --max-time 5 "http://$HOST:$PORT/metrics" 2>/dev/null | python3 -c '
import sys, re
thresh = float("'"$TRIGGER_S"'")
inf = None
best_le, best_val = None, None
pat = re.compile(r"^\S*time_to_first_token_seconds_bucket\{([^}]*)\}\s+([0-9.eE+]+)")
for line in sys.stdin:
    m = pat.match(line)
    if not m:
        continue
    le = re.search(r'"'"'le="([^"]+)"'"'"', m.group(1))
    if not le:
        continue
    v = float(m.group(2))
    if le.group(1) == "+Inf":
        inf = v
        continue
    b = float(le.group(1))
    # The largest bucket boundary at or below the threshold: counting above it is conservative,
    # so the trigger never fires on a request that was faster than TRIGGER_S.
    if b <= thresh and (best_le is None or b > best_le):
        best_le, best_val = b, v
print(int(inf - best_val) if inf is not None and best_val is not None else -1)
' 2>/dev/null || echo -1
}

collect() {
  reason="$1"
  ts=$(date -u +%Y%m%dT%H%M%S.%NZ)
  mono=$(awk '{print $1; exit}' /proc/uptime)
  d="$OUTDIR/snapshots/$(date -u +%Y%m%dT%H%M%SZ)-$reason"
  mkdir -p "$d"
  # Written first so a snapshot that dies half way is still joinable to the bench records.
  {
    echo "reason=$reason"
    echo "wall_epoch=$(date -u +%s.%N)"
    echo "mono_uptime=$mono"
    echo "iso=$ts"
    echo "trigger_s=$TRIGGER_S"
  } > "$d/when.txt"
  log "SNAPSHOT $reason -> $d"

  SG=$(proc_match 'sglang\.launch_server|sglang::' | tr '\n' ' ')
  WK=$(proc_match 'cedana-gpu-controller' | tr '\n' ' ')
  echo "sglang: $SG" > "$d/pids.txt"
  echo "worker: $WK" >> "$d/pids.txt"

  # --- where is each rank stuck ---
  for p in $SG; do
    # --nonblocking: never pauses the target. A paused rank would perturb the very stall we are
    # trying to observe, and can desync the collective.
    py-spy dump --nonblocking --pid "$p" > "$d/pyspy-$p.txt" 2>&1 &
    cat "/proc/$p/stack"  > "$d/kstack-$p.txt"  2>&1   # kernel side: page fault, mmap_sem, ioctl
    cat "/proc/$p/wchan"  > "$d/wchan-$p.txt"   2>&1
    cat "/proc/$p/status" > "$d/status-$p.txt"  2>&1   # voluntary vs nonvoluntary ctxt switches
    # Rss vs Pss answers the "1.2 TB pinned pool" question directly: the worker maps the SAME
    # physical pages at the same address (docs/cuMemHostRegister.md), so a pool that is shared
    # shows Pss ~= Rss/2 on each side, i.e. double-counted rather than double-allocated.
    cat "/proc/$p/smaps_rollup" > "$d/smaps_rollup-$p.txt" 2>&1
    command -v eu-stack >/dev/null 2>&1 && eu-stack -p "$p" > "$d/eustack-$p.txt" 2>&1
    if [ "$ALLOW_GDB" = "1" ]; then
      gdb -p "$p" --batch -ex 'thread apply all bt' > "$d/gdb-$p.txt" 2>&1
    fi
  done
  # Per-thread run state for the ranks: which threads are in D (uninterruptible) during the stall.
  for p in $SG; do
    for t in /proc/"$p"/task/*; do
      [ -d "$t" ] || continue
      printf '%s %s %s\n' "$(basename "$t")" \
        "$(awk '{print $3}' "$t/stat" 2>/dev/null)" \
        "$(cat "$t/wchan" 2>/dev/null)"
    done > "$d/threads-$p.txt" 2>/dev/null
  done

  # --- the controller side, which lives outside the pod cgroup ---
  for p in $WK; do
    cat "/proc/$p/smaps_rollup" > "$d/smaps_rollup-worker-$p.txt" 2>&1
    cat "/proc/$p/status"       > "$d/status-worker-$p.txt"        2>&1
    cat "/proc/$p/stack"        > "$d/kstack-worker-$p.txt"        2>&1
    command -v eu-stack >/dev/null 2>&1 && eu-stack -p "$p" > "$d/eustack-worker-$p.txt" 2>&1
  done

  # --- host memory pressure: the pinned pool's effect on everything else ---
  cat /proc/meminfo > "$d/meminfo.txt" 2>&1
  grep -E 'compact|pgscan|pgsteal|nr_free_pages|thp|numa' /proc/vmstat > "$d/vmstat.txt" 2>&1
  command -v numastat >/dev/null 2>&1 && numastat -m > "$d/numastat.txt" 2>&1
  cat /proc/pressure/memory /proc/pressure/io /proc/pressure/cpu > "$d/pressure.txt" 2>&1

  # --- GPU: link state and per-process utilisation at the moment of the stall ---
  nvidia-smi --query-gpu=index,utilization.gpu,utilization.memory,memory.used,memory.total,pcie.link.gen.current,pcie.link.width.current,clocks_throttle_reasons.active \
    --format=csv > "$d/nvidia-smi.csv" 2>&1
  nvidia-smi pmon -c 1 > "$d/nvidia-pmon.txt" 2>&1
  nvidia-smi topo -m   > "$d/nvidia-topo.txt" 2>&1

  # --- sglang's own view, which says whether this was queueing or prefill ---
  curl -sf --max-time 5 "http://$HOST:$PORT/metrics" > "$d/metrics.txt" 2>&1

  wait   # let the backgrounded py-spy dumps finish
  log "snapshot $reason complete"
}

log "watching http://$HOST:$PORT/metrics; trigger at TTFT > ${TRIGGER_S}s, cooldown ${COOLDOWN_S}s"
# One snapshot before any load, as the reference to diff every later one against.
BASELINE_DONE=0
PREV=-1
SNAPS=0
while [ "$SNAPS" -lt "$MAX_SNAPS" ]; do
  if [ -f "$OUTDIR/trigger" ]; then
    rm -f "$OUTDIR/trigger"
    SNAPS=$((SNAPS + 1)); collect "manual"
    sleep "$COOLDOWN_S"; continue
  fi
  CUR=$(slow_count)
  case "$CUR" in
    ''|*[!0-9-]*) CUR=-1 ;;    # guard against a partial metrics scrape
  esac
  if [ "$CUR" -ge 0 ] && [ "$BASELINE_DONE" -eq 0 ]; then
    BASELINE_DONE=1; collect "baseline"
  fi
  if [ "$CUR" -ge 0 ] && [ "$PREV" -ge 0 ] && [ "$CUR" -gt "$PREV" ]; then
    log "slow-request count $PREV -> $CUR"
    SNAPS=$((SNAPS + 1)); collect "tail"
    PREV=$(slow_count)
    sleep "$COOLDOWN_S"
    continue
  fi
  [ "$CUR" -ge 0 ] && PREV="$CUR"
  sleep "$POLL_S"
done
log "MAX_SNAPS=$MAX_SNAPS reached; stopping. Raise MAX_SNAPS to keep going."
sleep infinity
