# lib.sh -- CED-2575. Shared by run-cedana.sh and run-native.sh. Sourced, not executed.
#
# The two runs must line up file for file, so everything they share is here and the entry points
# hold only what differs: the cedana side can checkpoint and restore, native cannot.
#
# Env: CONTEXT NS NODE IMAGE TOPO_FILE READY_TIMEOUT INIT_TIMEOUT NRANKS KEEP
CONTEXT="${CONTEXT:-}"
NS="${NS:-cedana-systems}"
NODE="${NODE:-}"                        # required: the 8xB200 node, e.g. NODE=gpu-dp-ckck8-zl9zz
IMAGE="${IMAGE:-}"                      # replaces the image in every manifest
TOPO_FILE="${TOPO_FILE:-}"              # a native run's nccl-topo.xml, fed back as NCCL_TOPO_FILE
READY_TIMEOUT="${READY_TIMEOUT:-10800}"  # CR: apply -> Ready
INIT_TIMEOUT="${INIT_TIMEOUT:-3600}"     # COLD-START: apply -> Init COMPLETE on every rank
NRANKS="${NRANKS:-8}"                    # the TP size: NCCL init is done when this many ranks say so
KEEP="${KEEP:-0}"                       # 1 = leave the pods up after collecting
WATCHER=ced2575-watcher
HOST_OUT=/var/tmp/ced2575

k() { kubectl ${CONTEXT:+--context "$CONTEXT"} -n "$NS" "$@"; }
log() { echo "[$RUN] $(date -u +%H:%M:%S) $*"; }
die() { log "FAIL: $*"; exit 1; }
phase() { echo "$1" > "$OUT/.phase"; log "phase: $1"; }

render() { # src dst [render.py args]
  _src=$1; _dst=$2; shift 2
  python3 render.py "$_src" --node "$NODE" ${IMAGE:+--image "$IMAGE"} "$@" > "$_dst"
}

write_run_manifest() {
  {
    echo "run=$RUN side=$SIDE mode=${MODE:-}"
    echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "git_commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "git_dirty=$(git status --porcelain . 2>/dev/null | wc -l | tr -d ' ')"
    for v in NODE IMAGE TOPO_FILE READY_TIMEOUT KEEP RESUME NS CONTEXT; do eval "echo \"$v=\${$v:-}\""; done
    echo "image=$(grep -m1 'image:' 10-glm52-native.yaml | sed 's/^ *image: //')"
  } > "$OUT/run.txt"
}

preflight() {
  log "preflight"
  [ -n "$NODE" ] || die "NODE is not set; e.g. NODE=gpu-dp-ckck8-zl9zz $0 ..."
  k get node "$NODE" >/dev/null 2>&1 || die "node $NODE not found; set NODE"
  k create configmap ced2575-bpf     --from-file=bpf/     --dry-run=client -o yaml | k apply -f - >/dev/null
  k create configmap ced2575-watcher --from-file=watcher/ --dry-run=client -o yaml | k apply -f - >/dev/null
  log "  configmaps updated from bpf/ and watcher/"
  if [ -n "$TOPO_FILE" ]; then
    [ -s "$TOPO_FILE" ] || die "TOPO_FILE $TOPO_FILE is missing or empty"
    k create configmap ced2575-topo --from-file=topo.xml="$TOPO_FILE" --dry-run=client -o yaml | k apply -f - >/dev/null
    cp "$TOPO_FILE" "$OUT/nccl-topo.injected.xml"
    log "  NCCL_TOPO_FILE will be $TOPO_FILE"
  fi
  _ph=$(k get pvc hf-models-rwx -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$_ph" = Bound ] || log "  WARNING: pvc hf-models-rwx is '${_ph:-absent}' in $NS; apply 00-model-volume.yaml"
}

wait_ready() { # pod timeout_s
  _t0=$(date +%s)
  while :; do
    _s=$(k get pod "$1" -o jsonpath='{.status.phase} {.status.containerStatuses[0].ready}' 2>&1 || true)
    case "$_s" in
      "Running true") return 0 ;;
      Running*|Pending*) ;;
      *) die "$1 is '$_s'" ;;
    esac
    [ $(( $(date +%s) - _t0 )) -gt "$2" ] && die "$1 not Ready after $2 s"
    sleep 15
  done
}

# Follows the pod's log into $OUT/server-<tag>.log from before its container starts, so a pod
# killed before collection (run-1 was, 2.5 h in) still leaves its log behind. Every reconnect
# re-sends the whole log, so the live copy is .part and it replaces the file only when non-empty.
stream_log() { # pod tag
  STREAM_TAG=$2; _f="$OUT/server-$2.log"
  ( while k get pod "$1" >/dev/null 2>&1; do
      k logs -f "$1" > "$_f.part" 2>/dev/null || true
      [ -s "$_f.part" ] && mv -f "$_f.part" "$_f"
      sleep 5
    done ) &
  STREAM_PID=$!
}
stop_stream() {
  [ -n "${STREAM_PID:-}" ] || return 0
  _kids=$(pgrep -P "$STREAM_PID" 2>/dev/null || true)
  kill "$STREAM_PID" 2>/dev/null || true
  [ -z "$_kids" ] || kill $_kids 2>/dev/null || true
  wait "$STREAM_PID" 2>/dev/null || true
  STREAM_PID=
}
server_log_now() { # tag -> the freshest copy of the streamed log
  [ -s "$OUT/server-$1.log.part" ] && echo "$OUT/server-$1.log.part" || echo "$OUT/server-$1.log"
}

# COLD-START's gate. NCCL's topology is decided when every rank logs Init COMPLETE, minutes into
# the start; Ready is hours later and the pod need not get there. Needs stream_log running.
wait_nccl_init() { # pod tag timeout_s
  _t0=$(date +%s)
  while :; do
    _s=$(k get pod "$1" -o jsonpath='{.status.phase}' 2>&1 || true)
    case "$_s" in Running|Pending) ;; *) die "$1 is '$_s'" ;; esac
    _n=$(grep -c "nranks $NRANKS .*Init COMPLETE" "$(server_log_now "$2")" 2>/dev/null || true)
    [ "${_n:-0}" -ge "$NRANKS" ] && { sleep 10; return 0; }  # let the rest of the INFO lines land
    [ $(( $(date +%s) - _t0 )) -gt "$3" ] && die "$1: ${_n:-0}/$NRANKS ranks at Init COMPLETE after $3 s"
    sleep 10
  done
}

clear_pods() {
  log "clearing previous experiment pods"
  k delete pod glm52-native glm52-cedana "$WATCHER" --ignore-not-found --wait=true >/dev/null
}

# The watcher goes up FIRST, and the server is not applied until it reports its stage-1 probes
# attached: the cold start's first NVML answers are the evidence, and a probe placed after them
# records nothing.
start_watcher() {
  render 30-watcher.yaml "$OUT/30-watcher.as-run.yaml" --side "$SIDE"
  k apply -f "$OUT/30-watcher.as-run.yaml" >/dev/null
  DEPLOYED=1
  _t0=$(date +%s)
  while :; do
    k logs "$WATCHER" -c bpf 2>/dev/null | grep -q 'watcher ready' && break
    [ $(( $(date +%s) - _t0 )) -gt 600 ] && {
      k logs "$WATCHER" -c bpf > "$OUT/attach.log" 2>&1 || true
      die "watcher not ready after 10 min; see $OUT/attach.log"; }
    sleep 5
  done
  k logs "$WATCHER" -c bpf > "$OUT/attach.log" 2>&1
  grep -E 'MISSING|FATAL|WARNING|EXITED|dropped' "$OUT/attach.log" | sed 's/^/      /' || true
  log "$(grep 'watcher ready' "$OUT/attach.log" | tail -1 | sed 's/.*\] //')"
}

snap_links() { # tag -- nvidia-smi link/topo state, only once NCCL has decided
  k exec "$WATCHER" -c snap -- sh -c "echo $1 > $HOST_OUT/snap-now" >/dev/null 2>&1 || true
}

# Server-side evidence: the log, and on a cold start NCCL's own dumps.
collect_server() { # pod tag
  stop_stream
  _f="$OUT/server-$2.log"
  [ -s "$_f.part" ] && mv -f "$_f.part" "$_f"; rm -f "$_f.part"
  { k logs "$1" > "$_f.tmp" 2>/dev/null && [ -s "$_f.tmp" ] && mv -f "$_f.tmp" "$_f"; } || true
  rm -f "$_f.tmp"
  if [ "$2" = cold ]; then
    for f in nccl-topo.xml nccl-graph.xml; do
      k cp "$1:/tmp/ced-2575/$f" "$OUT/$f" >/dev/null 2>&1 || log "  no /tmp/ced-2575/$f in $1"
    done
  fi
  _t=""; [ -s "$OUT/nccl-topo.xml" ] && _t="--topo $OUT/nccl-topo.xml"
  python3 nccl-verdict.py "$OUT/server-$2.log" $_t > "$OUT/nccl-verdict-$2.txt" 2>&1 || true
  sed 's/^/      /' "$OUT/nccl-verdict-$2.txt"
}

collect_watcher() {
  k get pod "$WATCHER" >/dev/null 2>&1 || { log "no watcher to collect"; return 0; }
  # TERM, not a pod delete: the END tables print only on a clean shutdown.
  k exec "$WATCHER" -c bpf -- pkill -TERM -f attach.sh >/dev/null 2>&1 || true
  sleep 8
  mkdir -p "$OUT/watcher"
  k cp "$WATCHER:$HOST_OUT" "$OUT/watcher" -c snap >/dev/null 2>&1 || log "  could not copy $HOST_OUT from the watcher"
  [ -d "$OUT/watcher/ced2575" ] && { mv "$OUT/watcher/ced2575"/* "$OUT/watcher"/ 2>/dev/null; rmdir "$OUT/watcher/ced2575"; }
  k logs "$WATCHER" -c bpf  > "$OUT/attach.log" 2>&1 || true
  k logs "$WATCHER" -c snap > "$OUT/nvlink-watch.log" 2>&1 || true
  _w=$(grep -E 'ranks appeared|stage 2|WARNING' "$OUT/attach.log" | sed 's/^/      /')
  [ -z "$_w" ] || echo "$_w"
  python3 nccl-verdict.py --watcher "$OUT/watcher" > "$OUT/watcher-summary.txt" 2>&1 || true
  sed 's/^/      /' "$OUT/watcher-summary.txt"
}

teardown() {
  rm -f "$OUT/.phase"
  stop_stream
  if [ "$KEEP" = 1 ]; then log "KEEP=1: leaving $POD and $WATCHER up"; return 0; fi
  k delete pod "$POD" "$WATCHER" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  log "deleted $POD and $WATCHER"
}

# Any failure once the pods are up (die, set -e, Ctrl-C) keeps what exists -- the streamed log,
# why the pod died, the watcher's output -- and tears down. run-1 lost all of it.
salvage() {
  trap - EXIT
  [ "${DEPLOYED:-0}" = 1 ] || return 0
  log "salvaging $OUT after a failure in phase '$(cat "$OUT/.phase" 2>/dev/null)'"
  if [ -n "${POD:-}" ] && k get pod "$POD" >/dev/null 2>&1; then
    k describe pod "$POD" > "$OUT/$POD-describe.txt" 2>&1 || true
    [ -z "${STREAM_TAG:-}" ] || collect_server "$POD" "$STREAM_TAG"
  fi
  collect_watcher
  teardown
}
trap '_rc=$?; [ "$_rc" -eq 0 ] || salvage' EXIT
