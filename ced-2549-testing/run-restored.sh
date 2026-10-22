#!/bin/sh
# run-restored.sh -- CED-2549: the cedana P/D pair, CHECKPOINTED AND RESTORED, under concurrent load.
#
# THE REPORT. Concurrent KV transfers hang on the restored pair. One request works; with 8
# concurrent 5.8k-token prompts, 2 return in 0.9 s and 6 hang. Decode's workers stop in
# execute_model right after issuing NIXL reads, prefill later frees those blocks as "retrieved by
# 0 remote worker(s)", and after 300 s vLLM raises "RPC call to execute_model timed out" and the
# engine dies. The same deployments without cedana pass 8/8 and 2x16/16.
#
# WHAT THIS RUN IS FOR, IN ORDER OF VALUE:
#
#   1. THE CONTROL COMES FIRST. Before any checkpoint, it puts 8 concurrent requests through the
#      COLD cedana pair. If that already hangs, this is not a restore bug at all -- it is an
#      interception bug, and the entire checkpoint/restore machinery drops out of the repro. That
#      is the cheapest experiment here and it reshapes everything downstream, so it runs before
#      an hour is spent on a checkpoint. SKIP_CONTROL=1 skips it; it stays on by default.
#   2. Then the pair is checkpointed and restored -- BOTH pods, which is what "the restored pair"
#      in the report means -- and the same ladder runs again: c=1 (must pass), c=8 (the repro),
#      c=16 (the reported 2x16 case).
#
# THE WATCHERS ARE RESTARTED ACROSS THE RESTORE, deliberately. A uprobe attaches to an inode, and
# restore deletes and recreates both engine pods: probes placed before the checkpoint point at
# processes that no longer exist and would report a silent, total absence of events. They come
# down before the checkpoint and go back up after Ready.
#
# The checkpoint/restore follows cedana-bench's restore-time runner, RESTORE_MODE=path: cold start
# -> Ready -> POST /v1/checkpoint/pod -> poll -> delete -> re-apply with CEDANA_CHECKPOINT_PATH ->
# Ready. If the chart has fallbackColdStart=true a failed restore silently cold-starts, so the
# restored pods' logs are checked for load markers and the run stops if they cold-started.
#
# Needs the daemon's checkpoint dir on a volume that can hold two engine pods:
#   helm upgrade cedana ... --reuse-values --set config.checkpointDir=/scratch
#
#   OUT=out-cedana/run-2 ./run-restored.sh
#
# Env: see lib.sh, plus SKIP_CONTROL RESUME
set -eu
RUN=restored
SIDE=cedana
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
OUT="${OUT:-out-cedana}"
SKIP_CONTROL="${SKIP_CONTROL:-0}"
# RESUME=1 starts at the control, from cold pods that are already Ready; RESUME=restore starts at
# the restore, from the checkpoints recorded in $OUT. Both keep $OUT.
RESUME="${RESUME:-0}"
. ./lib.sh

if [ "$RESUME" = 0 ] && [ -e "$OUT" ]; then
  die "$HERE/$OUT already exists; move it away, or set OUT elsewhere"
fi
mkdir -p "$OUT"
phase init
write_run_manifest

ki get runtimeclass cedana >/dev/null 2>&1 || die "no 'cedana' runtimeclass on this cluster"
DIR=$(ki get cm cedana-config -o jsonpath='{.data.checkpoint-dir}' 2>/dev/null || true)
[ -n "$DIR" ] || die "no cedana-config in $NS_WATCH; is the installer kubeconfig right?"
log "cedana checkpoint dir: $DIR"
case "$DIR" in /scratch*) ;; *) log "WARNING: checkpoint dir is '$DIR'. Two engine pods will not \
fit on a root disk; set config.checkpointDir=/scratch if this run dies mid-checkpoint." ;; esac

# The cluster's own Cedana URL and token, as the helpers use them. Never printed.
URL=$(ki get cm cedana-config -o jsonpath='{.data.url}'); URL=${URL%/}; URL=${URL%/v1}
TOKEN=$(ki get secret cedana-secrets -o jsonpath='{.data.auth-token}' | base64 -d)
prop() { # method path [json] -> body, then the HTTP code on the last line.
         # Strip that last line with `sed '$d'`, not `head -n -1`: the latter is GNU-only and BSD
         # head rejects a negative count, which hangs the poll loops below on a mac.
  curl -s -X "$1" "$URL$2" -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
    ${3:+-d "$3"} -w '\n%{http_code}'
}
CRIU_OPTS='{"leave_running": true, "tcp_established": true, "tcp_skip_in_flight": true, "link_remap": true, "manage_cgroups": true, "manage_cgroups_mode": 1, "file_locks": true}'
# vLLM's cold start is unmistakable in the log. A restored pod that logs any of these fell back.
LOAD_MARKERS='Loading safetensors|Starting to load model|Loading weights took|Capturing CUDA graph|torch.compile|Memory profiling'

preflight

if [ "$RESUME" = 0 ]; then
  guard_running_baseline
  log "clearing previous experiment pods"
  kt delete pod "$PREFILL_POD" "$DECODE_POD" "$FRONTEND_POD" --ignore-not-found --wait=true >/dev/null
  ki delete pod ced2549-watcher-prefill ced2549-watcher-decode --ignore-not-found --wait=true >/dev/null

  phase cold-start
  python3 11-pd-cedana.patch.py 10-pd-native.yaml > "$OUT/11-pd-cedana.yaml"
  kt apply -f "$OUT/11-pd-cedana.yaml" >/dev/null
  for p in "$FRONTEND_POD" "$PREFILL_POD" "$DECODE_POD"; do
    wait_ready "$p" "$READY_TIMEOUT"
    log "cold $p Ready"
  done
  for r in prefill decode; do kt logs "$(pod_for "$r")" > "$OUT/$r-cold.log" 2>&1; done
fi

verify_metrics
sample_loop & SAMPLER_PID=$!
trap 'kill $SAMPLER_PID 2>/dev/null || true' EXIT

# ------------------------------------------------------------------- 1. the control, before any
# checkpoint. If this hangs, restore is not involved and the investigation moves immediately.
if [ "$SKIP_CONTROL" = 0 ] && [ "$RESUME" != restore ]; then
  phase control
  start_watchers
  run_bench control-cold "1x2,8x2"
  HUNG=$(cat "$OUT/.hung-control-cold" 2>/dev/null || echo 0)
  if [ "${HUNG:-0}" -gt 0 ]; then
    log "========================================================================"
    log "THE COLD CEDANA PAIR ALREADY HANGS: $HUNG requests never returned, with"
    log "no checkpoint and no restore anywhere in the run. This is an"
    log "interception bug, not a restore bug, and the whole checkpoint/restore"
    log "machinery drops out of the repro. The restored run below still proceeds"
    log "so both datasets come from one model load -- but read this first."
    log "========================================================================"
  else
    log "control passed: the cold cedana pair handled 8 concurrent with no hang"
  fi
  stop_watchers
  ki delete pod ced2549-watcher-prefill ced2549-watcher-decode --wait=true >/dev/null 2>&1 || true
fi

# --------------------------------------------------------------------------- 2. checkpoint both
if [ "$RESUME" = restore ]; then
  RESTORE_PREFILL=$(jq -r '.restore_path // empty' "$OUT/checkpoint-action-prefill.json" 2>/dev/null || true)
  RESTORE_DECODE=$(jq -r '.restore_path // empty' "$OUT/checkpoint-action-decode.json" 2>/dev/null || true)
  [ -n "$RESTORE_PREFILL" ] && [ -n "$RESTORE_DECODE" ] \
    || die "RESUME=restore needs checkpoint-action-{prefill,decode}.json with a restore_path in $OUT"
  log "resuming at the restore from the checkpoints recorded in $OUT"
else
  phase checkpoint
  for r in prefill decode; do
    POD=$(pod_for "$r")
    UID_=$(kt get pod "$POD" -o jsonpath='{.metadata.uid}')
    # pod_name and namespace too: the propagator may not have the pod's UID yet.
    PAYLOAD=$(jq -n --arg p "$UID_" --arg n "$POD" --arg ns "$NS_WORK" --arg c "$CRIU_OPTS" \
      '{pod_id: $p, pod_name: $n, namespace: $ns, runc_root: "/run/containerd/runc/k8s.io", overrides: {criu_opts: $c}}')
    for try in $(seq 12); do
      R=$(prop POST /v1/checkpoint/pod "$PAYLOAD")
      [ "$(echo "$R" | tail -1)" = 200 ] && break
      log "$r checkpoint not accepted yet (try $try): $(echo "$R" | sed '$d' | head -c 300)"
      sleep 10
    done
    [ "$(echo "$R" | tail -1)" = 200 ] || die "$r checkpoint not accepted: $(echo "$R" | head -c 500)"
    ACTION=$(echo "$R" | sed '$d' | tr -d '"[:space:]')
    log "$r checkpoint action $ACTION"
    t0=$(date +%s)
    while :; do
      R=$(prop GET "/v1/checkpoint/status/$ACTION")
      ST=$(echo "$R" | sed '$d' | jq -r '.status // empty' 2>/dev/null || true)
      case "$ST" in
        ready|success|completed) break ;;
        error|failed) echo "$R" > "$OUT/checkpoint-status-$r.json"; die "$r checkpoint failed: $(echo "$R" | head -c 800)" ;;
      esac
      [ $(( $(date +%s) - t0 )) -gt 5400 ] && die "$r checkpoint not done after 90 min (last status '$ST')"
      sleep 10
    done
    log "$r checkpoint done in $(( $(date +%s) - t0 )) s"
    prop GET "/v1/actions/$ACTION" | sed '$d' > "$OUT/checkpoint-action-$r.json"
    RP=$(jq -r '.restore_path // empty' "$OUT/checkpoint-action-$r.json")
    [ -n "$RP" ] || die "no restore_path for $r; see $OUT/checkpoint-action-$r.json"
    case "$r" in
      prefill) RESTORE_PREFILL="$RP" ;;
      decode)  RESTORE_DECODE="$RP" ;;
    esac
    log "$r restore_path $RP"
  done
fi

# ------------------------------------------------------------------------------ 3. restore both
phase restore
kt delete pod "$PREFILL_POD" "$DECODE_POD" --ignore-not-found --wait=true >/dev/null
python3 11-pd-cedana.patch.py 10-pd-native.yaml \
  --restore "prefill=$RESTORE_PREFILL" --restore "decode=$RESTORE_DECODE" \
  > "$OUT/11-pd-cedana-restore.yaml"
t0=$(date +%s)
kt apply -f "$OUT/11-pd-cedana-restore.yaml" >/dev/null
for r in prefill decode; do wait_ready "$(pod_for "$r")" "$READY_TIMEOUT"; done
log "restored pair Ready in $(( $(date +%s) - t0 )) s"

for r in prefill decode; do
  kt logs "$(pod_for "$r")" > "$OUT/$r-init.log" 2>&1
  M=$(grep -cE "$LOAD_MARKERS" "$OUT/$r-init.log" || true)
  [ "$M" -eq 0 ] || die "the restored $r logged $M cold-start markers: it fell back to a cold start"
done
log "restore verified: neither pod logged a cold-start marker"

# Did the restored pair re-establish its identity, or come back holding pre-checkpoint state? A
# decode that still believes in the OLD prefill's podIP:5600 would issue reads nobody answers --
# which is the reported shape exactly, and it is visible here and nowhere else in this harness.
phase post-restore-state
{
  echo "=== pod IPs now ==="
  kt get pod "$PREFILL_POD" "$DECODE_POD" "$FRONTEND_POD" -o wide --no-headers
  echo
  echo "=== NIXL side-channel / remote-agent mentions in the restored logs ==="
  for r in prefill decode; do
    echo "--- $r"
    grep -iE 'nixl|side.?channel|remote agent|handshake|5600' "$OUT/$r-init.log" | tail -40 || true
  done
} > "$OUT/post-restore-state.txt" 2>&1
log "post-restore state in $OUT/post-restore-state.txt"

log "settling ${IDLE_S}s before load"
phase idle
sleep "$IDLE_S"

# --------------------------------------------------------------------------- 4. the real thing
phase watcher
start_watchers
phase bench
run_bench restored "$STAGES"

phase collect
kill $SAMPLER_PID 2>/dev/null || true
SIDE="$SIDE" OUT="$OUT" NS_WORK="$NS_WORK" NS_WATCH="$NS_WATCH" \
  KUBECONFIG_TESTER="$KUBECONFIG_TESTER" KUBECONFIG_INSTALLER="$KUBECONFIG_INSTALLER" \
  CONTEXT_TESTER="$CONTEXT_TESTER" CONTEXT_INSTALLER="$CONTEXT_INSTALLER" \
  sh collect.sh cedana
rm -f "$OUT/.phase" "$OUT"/.hung-*
log "done: $HERE/$OUT"
