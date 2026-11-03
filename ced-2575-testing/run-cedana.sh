#!/bin/sh
# run-cedana.sh -- CED-2575: GLM-5.2 under cedana, with the watcher in place before the cold start.
#
#   NODE=gpu-dp-ckck8-zl9zz OUT=out-cedana/run-1 ./run-cedana.sh COLD-START
#       cold start -> NCCL Init COMPLETE on every rank -> collect -> tear down. The reported case,
#       nothing else: the topology is decided there, so the pod never has to reach Ready.
#   NODE=... OUT=out-cedana/run-1 ./run-cedana.sh
#       cold start -> Ready, then checkpoint -> restore -> collect, as Together serves it.
#   NODE=... TOPO_FILE=out-native/run-1/nccl-topo.xml OUT=out-cedana/run-2 ./run-cedana.sh COLD-START
#       the workaround as a controlled run: a native dump fed back as NCCL_TOPO_FILE.
#
# The checkpoint/restore follows cedana-bench's restore-time runner, RESTORE_MODE=path: Ready ->
# POST /v1/checkpoint/pod -> poll -> delete -> re-apply with CEDANA_CHECKPOINT_PATH -> Ready. The
# chart has fallbackColdStart=true, so the restored pod's log is checked for load markers.
# RESUME=1 starts at the checkpoint from a cold pod that is already Ready (no watcher then);
# RESUME=restore starts at the restore from $OUT/checkpoint-action.json.
#
# The server log is streamed from the apply onward and any failure salvages what exists (lib.sh).
#
# Env: see lib.sh, plus OUT RESUME
set -eu
RUN=cedana
SIDE=cedana
POD=glm52-cedana
MODE="${1:-CR}"
case "$MODE" in COLD-START|CR) ;; *) echo "usage: $0 [COLD-START]" >&2; exit 2 ;; esac
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
OUT="${OUT:-out-cedana}"
RESUME="${RESUME:-0}"
. ./lib.sh

[ "$RESUME" != 0 ] || { [ -e "$OUT" ] && die "$HERE/$OUT already exists; move it away or set OUT"; }
mkdir -p "$OUT"
write_run_manifest
preflight
k get runtimeclass cedana >/dev/null 2>&1 || die "no 'cedana' runtimeclass on this cluster"

if [ "$MODE" = CR ]; then
  DIR=$(k get cm cedana-config -o jsonpath='{.data.checkpoint-dir}')
  [ "$DIR" = /scratch ] || die "cedana checkpoint dir is '$DIR', not /scratch; set config.checkpointDir=/scratch first"
  # Propagator: the cluster's own Cedana URL and token, as the helpers use them. Never printed.
  URL=$(k get cm cedana-config -o jsonpath='{.data.url}'); URL=${URL%/}; URL=${URL%/v1}
  TOKEN=$(k get secret cedana-secrets -o jsonpath='{.data.auth-token}' | base64 -d)
  prop() { # method path [json] -> body, then the HTTP code on the last line (strip with sed '$d')
    curl -s -X "$1" "$URL$2" -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
      ${3:+-d "$3"} -w '\n%{http_code}'
  }
  CRIU_OPTS='{"leave_running": true, "tcp_established": true, "tcp_skip_in_flight": true, "link_remap": true, "manage_cgroups": true, "manage_cgroups_mode": 1, "file_locks": true}'
  LOAD_MARKERS='Load weight|Loading safetensors|Capture cuda graph|Launching server|Loading model'
fi

if [ "$RESUME" = 0 ]; then
  clear_pods
  phase watcher
  start_watcher
  phase cold-start
  render 11-glm52-cedana.yaml "$OUT/11-glm52-cedana.as-run.yaml" ${TOPO_FILE:+--topo-file}
  k apply -f "$OUT/11-glm52-cedana.as-run.yaml" >/dev/null
  stream_log "$POD" cold
  t0=$(date +%s)
  if [ "$MODE" = COLD-START ]; then
    wait_nccl_init "$POD" cold "$INIT_TIMEOUT"
    log "cold $POD: all $NRANKS ranks at NCCL Init COMPLETE in $(( $(date +%s) - t0 )) s"
  else
    wait_ready "$POD" "$READY_TIMEOUT"
    log "cold $POD Ready in $(( $(date +%s) - t0 )) s"
  fi
  snap_links cold
  collect_server "$POD" cold
elif [ "$RESUME" = 1 ]; then
  [ "$(k get pod "$POD" -o jsonpath='{.status.containerStatuses[0].ready}')" = true ] || die "RESUME=1 needs $POD Ready"
  log "RESUME=1: using the running cold $POD (no watcher covered its start)"
  collect_server "$POD" cold
fi

if [ "$MODE" = COLD-START ]; then
  phase collect
  collect_watcher
  teardown
  log "done: $HERE/$OUT"
  exit 0
fi

if [ "$RESUME" = restore ]; then
  RESTORE_PATH=$(jq -r '.restore_path // empty' "$OUT/checkpoint-action.json")
  [ -n "$RESTORE_PATH" ] || die "RESUME=restore needs $OUT/checkpoint-action.json with a restore_path"
  log "resuming at the restore from $RESTORE_PATH"
else
  phase checkpoint
  UID_=$(k get pod "$POD" -o jsonpath='{.metadata.uid}')
  # pod_name + namespace too: the propagator may not have the pod's UID yet right after it starts.
  PAYLOAD=$(jq -n --arg p "$UID_" --arg n "$POD" --arg ns "$NS" --arg c "$CRIU_OPTS" \
    '{pod_id: $p, pod_name: $n, namespace: $ns, runc_root: "/run/containerd/runc/k8s.io", overrides: {criu_opts: $c}}')
  for try in $(seq 12); do
    R=$(prop POST /v1/checkpoint/pod "$PAYLOAD")
    [ "$(echo "$R" | tail -1)" = 200 ] && break
    log "checkpoint not accepted yet (try $try): $(echo "$R" | sed '$d' | head -c 300)"
    sleep 10
  done
  [ "$(echo "$R" | tail -1)" = 200 ] || die "checkpoint not accepted: $(echo "$R" | head -c 500)"
  ACTION=$(echo "$R" | sed '$d' | tr -d '"[:space:]')
  log "checkpoint action $ACTION"
  t0=$(date +%s)
  while :; do
    R=$(prop GET "/v1/checkpoint/status/$ACTION")
    ST=$(echo "$R" | sed '$d' | jq -r '.status // empty' 2>/dev/null || true)
    case "$ST" in
      ready|success|completed) break ;;
      error|failed) echo "$R" > "$OUT/checkpoint-status.json"; die "checkpoint failed: $(echo "$R" | head -c 800)" ;;
    esac
    [ $(( $(date +%s) - t0 )) -gt 3600 ] && die "checkpoint not done after 1 h (last status '$ST')"
    sleep 10
  done
  log "checkpoint done in $(( $(date +%s) - t0 )) s"
  prop GET "/v1/actions/$ACTION" | sed '$d' > "$OUT/checkpoint-action.json"
  RESTORE_PATH=$(jq -r '.restore_path // empty' "$OUT/checkpoint-action.json")
  [ -n "$RESTORE_PATH" ] || die "no restore_path in the checkpoint action; see $OUT/checkpoint-action.json"
  log "restore_path $RESTORE_PATH, size $(jq -r '.checkpoint_size // .total_io // "?"' "$OUT/checkpoint-action.json")"
fi

phase restore
k delete pod "$POD" --ignore-not-found --wait=true >/dev/null
render 11-glm52-cedana.yaml "$OUT/11-glm52-cedana-restore.yaml" --restore "$RESTORE_PATH" ${TOPO_FILE:+--topo-file}
t0=$(date +%s)
k apply -f "$OUT/11-glm52-cedana-restore.yaml" >/dev/null
stream_log "$POD" init
wait_ready "$POD" "$READY_TIMEOUT"
log "restored $POD Ready in $(( $(date +%s) - t0 )) s"
collect_server "$POD" init
MARKERS=$(grep -cE "$LOAD_MARKERS" "$OUT/server-init.log" || true)
[ "$MARKERS" -eq 0 ] || die "the restored pod logged $MARKERS cold-start markers: it fell back to a cold start"
log "restore verified: no cold-start markers"
snap_links restored

phase collect
collect_watcher
teardown
log "done: $HERE/$OUT (checkpoint left at $RESTORE_PATH on $NODE)"
