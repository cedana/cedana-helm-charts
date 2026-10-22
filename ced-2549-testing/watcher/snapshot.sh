#!/bin/sh
# snapshot.sh -- CED-2549. Capture point-in-time state while the engine is HUNG, not after.
#
# WHAT CHANGED FROM 2538. That investigation chased a latency tail and triggered off sglang's TTFT
# histogram: a slow request that COMPLETED moved a bucket, and the snapshot followed. Here nothing
# completes -- 6 of 8 requests never return, and vLLM tears the engine down after 300 s. A
# histogram-based trigger would fire never, and then once, on the wreckage.
#
# So the trigger is "a request is outstanding and no KV transfer has progressed in STALL_S", and
# it is evaluated BY THE RUNNER, not here. The runner already samples vllm:nixl_* from both pods
# for nixl.csv, it holds the installer kubeconfig, and -- the deciding reason -- this pod is not a
# member of the cedana-glm53-pd group that the cluster's egress policy allows, so it cannot be
# assumed to reach decode:9090 at all. The runner writes $OUTDIR/trigger; this watches for it.
# Set METRICS_URL to also poll locally where the network does allow it.
#
# TIMING IS THE WHOLE GAME. vLLM's RPC timeout is 300 s and it kills the engine. Every snapshot
# must land inside that window while the process is still wedged and dumpable, which is why the
# bench's per-request deadline is 120 s: the hang is recorded, the trigger fires, and there is
# still minutes of headroom before the engine dies.
#
# WHAT IT DELIBERATELY DOES NOT DO: attach gdb by default. SIGSTOPping engine processes mid-hang
# can change the thing being observed and can take the pair down in a way that looks like a cedana
# fault. py-spy --nonblocking and /proc/<pid>/stack answer "where is it stuck" without stopping
# anything. ALLOW_GDB=1 only on a node with nothing else to lose.
#
# py-spy AND THE EGRESS POLICY. There is no egress here, so pip will fail. Side-load it once:
#   kubectl -n cedana-systems cp ./py-spy ced2549-watcher-decode:/var/tmp/ced2549/py-spy -c snap
# Without it the Python frame -- which is the single most valuable artifact for this hang -- is
# missing, and all that is left is the kernel side. The script says so loudly rather than
# producing a quiet, useless snapshot.
#
# Env: ROLE OUTDIR STALL_S COOLDOWN_S MAX_SNAPS POLL_S METRICS_URL ALLOW_GDB
set -u

ROLE="${ROLE:-decode}"
OUTDIR="${OUTDIR:-/var/tmp/ced2549}"
STALL_S="${STALL_S:-30}"
COOLDOWN_S="${COOLDOWN_S:-60}"
MAX_SNAPS="${MAX_SNAPS:-20}"
POLL_S="${POLL_S:-2}"
METRICS_URL="${METRICS_URL:-}"
ALLOW_GDB="${ALLOW_GDB:-0}"

mkdir -p "$OUTDIR/snapshots"
log() { echo "[snapshot] $(date -u +%H:%M:%S) $*" >&2; }

proc_match() {
  for _d in /proc/[0-9]*; do
    [ -r "$_d/cmdline" ] || continue
    if tr '\0' ' ' < "$_d/cmdline" 2>/dev/null | grep -qE -- "$1"; then
      echo "${_d#/proc/}"
    fi
  done
}

# Side-loaded binary first, then whatever the image happens to have.
PYSPY=""
if [ -x "$OUTDIR/py-spy" ]; then PYSPY="$OUTDIR/py-spy"
elif command -v py-spy >/dev/null 2>&1; then PYSPY="py-spy"
else
  pip install --quiet --disable-pip-version-check py-spy >/dev/null 2>&1 \
    && PYSPY="py-spy"
fi
if [ -z "$PYSPY" ]; then
  log "WARNING: no py-spy, and no egress to install one. Python stacks will be MISSING from every"
  log "         snapshot, which for this hang is most of the evidence. Side-load it:"
  log "           kubectl -n cedana-systems cp ./py-spy <this-pod>:$OUTDIR/py-spy -c snap"
fi

collect() {
  reason="$1"
  d="$OUTDIR/snapshots/$(date -u +%Y%m%dT%H%M%SZ)-$ROLE-$reason"
  mkdir -p "$d"
  # Written first so a snapshot that dies half way is still joinable to the bench records.
  {
    echo "role=$ROLE"
    echo "reason=$reason"
    echo "wall_epoch=$(date -u +%s.%N)"
    echo "mono_uptime=$(awk '{print $1; exit}' /proc/uptime)"
    echo "stall_s=$STALL_S"
  } > "$d/when.txt"
  log "SNAPSHOT $reason -> $d"

  EN=$(proc_match 'dynamo\.vllm|VLLM::EngineCore|VllmWorker' | tr '\n' ' ')
  WK=$(proc_match 'cedana-gpu-controller' | tr '\n' ' ')
  { echo "engine: $EN"; echo "engine_count: $(echo $EN | wc -w)"; echo "controller: $WK"; } \
    > "$d/pids.txt"

  # --- where is each engine stuck ---
  for p in $EN; do
    # --nonblocking never pauses the target: a paused rank would perturb the very stall being
    # observed, and on a DP8 decode it can desync the others.
    [ -n "$PYSPY" ] && "$PYSPY" dump --nonblocking --pid "$p" > "$d/pyspy-$p.txt" 2>&1 &
    cat "/proc/$p/stack"        > "$d/kstack-$p.txt"  2>&1
    cat "/proc/$p/wchan"        > "$d/wchan-$p.txt"   2>&1
    cat "/proc/$p/status"       > "$d/status-$p.txt"  2>&1
    cat "/proc/$p/smaps_rollup" > "$d/smaps-$p.txt"   2>&1
    command -v eu-stack >/dev/null 2>&1 && eu-stack -p "$p" > "$d/eustack-$p.txt" 2>&1
    [ "$ALLOW_GDB" = "1" ] && gdb -p "$p" --batch -ex 'thread apply all bt' > "$d/gdb-$p.txt" 2>&1
    # Per-thread run state. D (uninterruptible) threads during the stall point at the kernel; S on
    # a futex points at a lock, which is the deadlock hypothesis inflight.bt is testing.
    for t in /proc/"$p"/task/*; do
      [ -d "$t" ] || continue
      printf '%s state=%s wchan=%s\n' "$(basename "$t")" \
        "$(awk '{print $3}' "$t/stat" 2>/dev/null)" \
        "$(cat "$t/wchan" 2>/dev/null)"
    done > "$d/threads-$p.txt" 2>/dev/null
    # Kernel stack per thread, which is where a blocked ioctl to the GPU driver shows up.
    for t in /proc/"$p"/task/*; do
      [ -d "$t" ] || continue
      echo "=== tid $(basename "$t")"; cat "$t/stack" 2>/dev/null
    done > "$d/kstack-threads-$p.txt" 2>&1
    echo "fd_count=$(ls /proc/$p/fd 2>/dev/null | wc -l)" > "$d/fds-$p.txt" 2>&1
  done

  # --- the controller side, which lives outside the pod cgroup ---
  # If an engine is stuck in the interceptor AND the controller is stuck in the driver underneath,
  # the driver is genuinely blocked. If the engine is stuck and the controller is idle, the stall
  # is in cedana's own round trip. inflight.bt says the same thing from the other direction.
  for p in $WK; do
    cat "/proc/$p/stack"  > "$d/kstack-controller-$p.txt"  2>&1
    cat "/proc/$p/status" > "$d/status-controller-$p.txt"  2>&1
    cat "/proc/$p/wchan"  > "$d/wchan-controller-$p.txt"   2>&1
    for t in /proc/"$p"/task/*; do
      [ -d "$t" ] || continue
      printf '%s state=%s wchan=%s\n' "$(basename "$t")" \
        "$(awk '{print $3}' "$t/stat" 2>/dev/null)" "$(cat "$t/wchan" 2>/dev/null)"
    done > "$d/threads-controller-$p.txt" 2>/dev/null
    command -v eu-stack >/dev/null 2>&1 && eu-stack -p "$p" > "$d/eustack-controller-$p.txt" 2>&1
  done

  # --- the NIXL side channel: is the handshake TCP connection to the peer even up? ---
  # VLLM_NIXL_SIDE_CHANNEL_PORT is 5600. A consumer blocked on a handshake that never completes
  # looks like a SYN-SENT or an ESTABLISHED socket with a full receive queue, and nothing else in
  # this harness would show it.
  if command -v ss >/dev/null 2>&1; then
    ss -tanp > "$d/sockets.txt" 2>&1
    ss -tanp 2>/dev/null | grep -E ':5600|:20081' > "$d/sockets-nixl.txt" 2>&1
  else
    cat /proc/net/tcp /proc/net/tcp6 > "$d/sockets-proc.txt" 2>&1
    log "no ss in this image; raw /proc/net/tcp saved instead (port 5600 is 0x15E0)"
  fi

  # --- did anything move on the wire? ---
  # The cheapest discriminator in the whole harness: reads posted but never completed leave these
  # counters flat, while a lost notification leaves them climbing. Snapshot both sides.
  for c in /sys/class/infiniband/*/ports/*/counters/*; do
    [ -r "$c" ] && echo "$c $(cat "$c" 2>/dev/null)"
  done > "$d/ib-counters.txt" 2>&1
  for c in /sys/class/infiniband/*/ports/*/hw_counters/*; do
    [ -r "$c" ] && echo "$c $(cat "$c" 2>/dev/null)"
  done >> "$d/ib-counters.txt" 2>&1

  # --- host and GPU state ---
  cat /proc/meminfo > "$d/meminfo.txt" 2>&1
  cat /proc/pressure/memory /proc/pressure/io /proc/pressure/cpu > "$d/pressure.txt" 2>&1
  nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total,pcie.link.gen.current,pcie.link.width.current \
    --format=csv > "$d/nvidia-smi.csv" 2>&1
  nvidia-smi pmon -c 1 > "$d/nvidia-pmon.txt" 2>&1
  [ -n "$METRICS_URL" ] && curl -sf --max-time 5 "$METRICS_URL" > "$d/metrics.txt" 2>&1

  wait   # let the backgrounded py-spy dumps finish
  log "snapshot $reason complete"
}

# ---------------------------------------------------------------------------- the IB sampler
# Continuous and cheap. Deltas across a hang answer the one question no CUDA-side probe can:
# whether anything moved on the wire at all. Flat port_rcv_data on decode while requests are
# outstanding means the reads never landed; climbing counters with no completions means they did
# and the notification path is where this breaks.
ib_sample() {
  _f="$OUTDIR/ib-$ROLE.csv"
  [ -s "$_f" ] || echo "wall,device,port,counter,value" > "$_f"
  while :; do
    _w=$(date +%s)
    for _c in /sys/class/infiniband/*/ports/*/counters/port_rcv_data \
              /sys/class/infiniband/*/ports/*/counters/port_xmit_data \
              /sys/class/infiniband/*/ports/*/counters/port_rcv_errors \
              /sys/class/infiniband/*/ports/*/counters/port_xmit_discards; do
      [ -r "$_c" ] || continue
      echo "$_w,$(echo "$_c" | cut -d/ -f5),$(echo "$_c" | cut -d/ -f7),$(basename "$_c"),$(cat "$_c" 2>/dev/null)" \
        >> "$_f"
    done
    sleep 5
  done
}
ib_sample &
log "IB counter sampler running into $OUTDIR/ib-$ROLE.csv"

# A reference snapshot before any load, to diff every later one against. Taken while idle so it
# perturbs nothing, and it runs even at MAX_SNAPS=0.
log "role=$ROLE; waiting on $OUTDIR/trigger (runner-driven), stall_s=$STALL_S"
collect baseline

SNAPS=0
PREV_XFER=-1
STALLED_FOR=0
while [ "$SNAPS" -lt "$MAX_SNAPS" ]; do
  if [ -f "$OUTDIR/trigger" ]; then
    REASON=$(cat "$OUTDIR/trigger" 2>/dev/null | tr -cd 'a-zA-Z0-9_-' | cut -c1-32)
    rm -f "$OUTDIR/trigger"
    SNAPS=$((SNAPS + 1)); collect "${REASON:-triggered}"
    sleep "$COOLDOWN_S"; continue
  fi
  # Local fallback, only where the network allows this pod to reach the engine.
  if [ -n "$METRICS_URL" ]; then
    M=$(curl -sf --max-time 5 "$METRICS_URL" 2>/dev/null || true)
    RUNNING=$(echo "$M" | awk '/^vllm:num_requests_running/ {s+=$NF} END {printf "%d", s}')
    XFER=$(echo "$M" | awk '/^vllm:nixl_xfer_time_seconds_count/ {s+=$NF} END {printf "%d", s}')
    if [ "${RUNNING:-0}" -gt 0 ] && [ "$XFER" = "$PREV_XFER" ]; then
      STALLED_FOR=$((STALLED_FOR + POLL_S))
    else
      STALLED_FOR=0
    fi
    PREV_XFER="$XFER"
    if [ "$STALLED_FOR" -ge "$STALL_S" ]; then
      log "local stall detector: ${RUNNING} running, nixl xfer count flat for ${STALLED_FOR}s"
      SNAPS=$((SNAPS + 1)); collect "stall"
      STALLED_FOR=0
      sleep "$COOLDOWN_S"; continue
    fi
  fi
  sleep "$POLL_S"
done
log "MAX_SNAPS=$MAX_SNAPS reached; stopping. Raise MAX_SNAPS to keep going."
sleep infinity
