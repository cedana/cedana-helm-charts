# lib.sh -- CED-2549. Shared by run-native.sh and run-restored.sh. Sourced, not executed.
#
# The two runs must be comparable file for file, so everything they have in common lives here and
# the entry points hold only what actually differs: the native side has no checkpoint/restore,
# and that asymmetry is the only asymmetry there should be.
#
# TWO KUBECONFIGS, ON PURPOSE. The baseline's README is explicit that the tester kubeconfig
# creates workload pods and cannot patch them, while the installer kubeconfig is the one that can
# port-forward and reach privileged namespaces. Rather than hide that, the helpers name it:
#   kt   workload namespace (default), TESTER   -- create/delete the engine pods and the bench
#   ki   watcher namespace (cedana-systems), INSTALLER -- the privileged watcher pods
#   kraw API-server proxy, INSTALLER -- reads engine /metrics WITHOUT crossing the namespace's
#        default-deny egress policy, which is why the stall detector lives in the runner.

CONTEXT_TESTER="${CONTEXT_TESTER:-}"
CONTEXT_INSTALLER="${CONTEXT_INSTALLER:-}"
KUBECONFIG_TESTER="${KUBECONFIG_TESTER:-}"
KUBECONFIG_INSTALLER="${KUBECONFIG_INSTALLER:-}"
NS_WORK="${NS_WORK:-default}"
NS_WATCH="${NS_WATCH:-cedana-systems}"
PREFILL_NODE="${PREFILL_NODE:-gpu-dp-ckck8-4pcmf}"
DECODE_NODE="${DECODE_NODE:-gpu-dp-ckck8-zl9zz}"
METRICS_PORT="${METRICS_PORT:-9090}"
STAGES="${STAGES:-1x4,8x3,16x2}"
IDLE_S="${IDLE_S:-120}"
SAMPLE_S="${SAMPLE_S:-2}"
STALL_S="${STALL_S:-30}"
READY_TIMEOUT="${READY_TIMEOUT:-10800}"
BENCH_TIMEOUT="${BENCH_TIMEOUT:-5400}"

PREFILL_POD=cedana-glm53-pd-prefill
DECODE_POD=cedana-glm53-pd-decode
FRONTEND_POD=cedana-glm53-pd-frontend

kt() { kubectl ${KUBECONFIG_TESTER:+--kubeconfig "$KUBECONFIG_TESTER"} \
       ${CONTEXT_TESTER:+--context "$CONTEXT_TESTER"} -n "$NS_WORK" "$@"; }
ki() { kubectl ${KUBECONFIG_INSTALLER:+--kubeconfig "$KUBECONFIG_INSTALLER"} \
       ${CONTEXT_INSTALLER:+--context "$CONTEXT_INSTALLER"} -n "$NS_WATCH" "$@"; }
kiw() { kubectl ${KUBECONFIG_INSTALLER:+--kubeconfig "$KUBECONFIG_INSTALLER"} \
        ${CONTEXT_INSTALLER:+--context "$CONTEXT_INSTALLER"} -n "$NS_WORK" "$@"; }
kraw() { kubectl ${KUBECONFIG_INSTALLER:+--kubeconfig "$KUBECONFIG_INSTALLER"} \
         ${CONTEXT_INSTALLER:+--context "$CONTEXT_INSTALLER"} get --raw "$1" 2>/dev/null; }

log() { echo "[$RUN] $(date -u +%H:%M:%S) $*"; }
die() { log "FAIL: $*"; exit 1; }
phase() { echo "$1" > "$OUT/.phase"; log "phase: $1"; }

pod_for() { case "$1" in prefill) echo "$PREFILL_POD" ;; decode) echo "$DECODE_POD" ;; esac; }
node_for() { case "$1" in prefill) echo "$PREFILL_NODE" ;; decode) echo "$DECODE_NODE" ;; esac; }

wait_ready() { # pod timeout_s
  _t0=$(date +%s)
  while :; do
    _s=$(kt get pod "$1" -o jsonpath='{.status.phase} {.status.containerStatuses[0].ready}' 2>&1 || true)
    case "$_s" in
      "Running true") return 0 ;;
      Running*|Pending*|ContainerCreating*) ;;
      *) kt logs "$1" --tail=40 > "$OUT/$1-failed.log" 2>&1 || true; die "$1 is '$_s'" ;;
    esac
    [ $(( $(date +%s) - _t0 )) -gt "$2" ] && die "$1 not Ready after $2 s"
    sleep 15
  done
}

metrics_for() { # role -> raw prometheus text from the engine, via the API-server proxy
  kraw "/api/v1/namespaces/$NS_WORK/pods/$(pod_for "$1"):$METRICS_PORT/proxy/metrics"
}

sum_metric() { # metric_name < metrics_text
  awk -v m="^$1" '$0 ~ m && $0 !~ /^#/ {s+=$NF} END {printf "%d", s}'
}

# ---------------------------------------------------------------------------- the sampler
# nixl.csv is the cheapest discriminator in the harness and it runs for the whole bench. The two
# worlds the hang could be in are told apart by these columns alone:
#   reads never posted        -> decode xfer_count flat, bytes flat
#   posted but never finished -> same, but the IB counters in the watchers' ib.csv still climb
#   completed, notif lost     -> xfer_count climbs and prefill STILL expires its blocks
# It also drives the snapshot trigger, because this process can reach the engines through the API
# server and the watcher pods cannot reach them at all.
sample_loop() {
  [ -s "$OUT/nixl.csv" ] || echo \
"wall,phase,d_running,d_waiting,d_xfer_count,d_bytes,d_failed_xfer,d_failed_notif,d_stale_notif,p_expired,p_running" \
    > "$OUT/nixl.csv"
  _prev_xfer=-1
  _last_change=$(date +%s)
  _last_trigger=0
  while :; do
    _dm=$(metrics_for decode || true)
    _pm=$(metrics_for prefill || true)
    _dr=$(echo "$_dm" | sum_metric 'vllm:num_requests_running')
    _dw=$(echo "$_dm" | sum_metric 'vllm:num_requests_waiting')
    _dx=$(echo "$_dm" | sum_metric 'vllm:nixl_xfer_time_seconds_count')
    _db=$(echo "$_dm" | sum_metric 'vllm:nixl_bytes_transferred_sum')
    _df=$(echo "$_dm" | sum_metric 'vllm:nixl_num_failed_transfers_total')
    _dn=$(echo "$_dm" | sum_metric 'vllm:nixl_num_failed_notifications_total')
    _ds=$(echo "$_dm" | sum_metric 'vllm:nixl_num_stale_xfer_notifs_total')
    _pe=$(echo "$_pm" | sum_metric 'vllm:nixl_num_kv_expired_reqs_total')
    _pr=$(echo "$_pm" | sum_metric 'vllm:num_requests_running')
    echo "$(date +%s),$(cat "$OUT/.phase" 2>/dev/null),$_dr,$_dw,$_dx,$_db,$_df,$_dn,$_ds,$_pe,$_pr" \
      >> "$OUT/nixl.csv"

    # Stall: decode has work outstanding and no KV transfer has completed in STALL_S.
    _now=$(date +%s)
    if [ "${_dr:-0}" -gt 0 ] && [ "$_dx" = "$_prev_xfer" ]; then
      _stalled=$((_now - _last_change))
    else
      _stalled=0
      _last_change=$_now
    fi
    _prev_xfer="$_dx"
    if [ "$_stalled" -ge "$STALL_S" ] && [ $((_now - _last_trigger)) -gt 90 ]; then
      log "STALL: decode has $_dr running, nixl xfer count flat at $_dx for ${_stalled}s -- snapshotting"
      echo "stall" >> "$OUT/stalls.txt"
      for r in prefill decode; do
        ki exec "ced2549-watcher-$r" -c snap -- \
          sh -c 'echo stall > /var/tmp/ced2549/trigger' >/dev/null 2>&1 || true
      done
      _last_trigger=$_now
      _last_change=$_now
    fi
    sleep "$SAMPLE_S"
  done
}

# ---------------------------------------------------------------------------- the watchers
start_watchers() {
  for r in prefill decode; do
    sed -e "s/__ROLE__/$r/g" -e "s/__NODE__/$(node_for "$r")/g" \
      30-watcher.yaml > "$OUT/30-watcher-$r.yaml"
    ki apply -f "$OUT/30-watcher-$r.yaml" >/dev/null
  done
  for r in prefill decode; do
    log "waiting for the $r watcher to attach"
    _t0=$(date +%s)
    while :; do
      ki logs "ced2549-watcher-$r" -c bpf 2>/dev/null | grep -q 'running until terminated' && break
      [ $(( $(date +%s) - _t0 )) -gt 600 ] && {
        ki logs "ced2549-watcher-$r" -c bpf > "$OUT/attach-$r.log" 2>&1 || true
        die "the $r watcher never attached; see $OUT/attach-$r.log"
      }
      sleep 5
    done
    ki logs "ced2549-watcher-$r" -c bpf > "$OUT/attach-$r.log" 2>&1
    # The symbol check is not optional reading: a probe on a missing symbol attaches to nothing
    # and reports nothing, which is indistinguishable from "that path is never taken".
    grep -q "side=$SIDE" "$OUT/attach-$r.log" \
      || die "the $r watcher reports a different side than '$SIDE'; see $OUT/attach-$r.log"
    if grep -q 'MISSING' "$OUT/attach-$r.log"; then
      log "NOTE: $r has missing symbols -- that is a finding, not a warning:"
      grep 'MISSING' "$OUT/attach-$r.log" | sed 's/^/      /'
    fi
    grep -E 'dropping that block|SKIPPED' "$OUT/attach-$r.log" | sed 's/^/      /' || true
    log "$r watcher attached (side=$SIDE)"
  done
}

stop_watchers() {
  # TERM, not a pod delete: bpftrace prints its END block only on a clean shutdown, and in
  # inflight.bt that END block is the list of calls STILL IN FLIGHT -- the headline result.
  for r in prefill decode; do
    ki exec "ced2549-watcher-$r" -c bpf -- pkill -TERM -f attach.sh >/dev/null 2>&1 || true
  done
  sleep 10
}

# ---------------------------------------------------------------------------- the load
run_bench() { # tag stages
  _tag="$1"; _stages="$2"
  _job="ced2549-bench-$_tag"
  sed -e "s/name: ced2549-bench$/name: $_job/" \
      -e "s/app: ced2549-bench/app: $_job/" \
      -e "s/{name: STAGES, value: \"[^\"]*\"}/{name: STAGES, value: \"$_stages\"}/" \
      20-bench-pd.yaml > "$OUT/20-bench-$_tag.yaml"
  grep -q "name: $_job" "$OUT/20-bench-$_tag.yaml" || die "could not retarget the bench manifest"
  kt delete job "$_job" --ignore-not-found --wait=true >/dev/null 2>&1
  kt apply -f "$OUT/20-bench-$_tag.yaml" >/dev/null
  log "bench '$_tag' running stages $_stages"
  _t0=$(date +%s)
  while :; do
    kt logs "job/$_job" --tail=5 2>/dev/null | grep -q 'bench finished' && break
    _s=$(kt get pod -l "app=$_job" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
    [ "$_s" = Failed ] && { kt logs "job/$_job" > "$OUT/bench-$_tag.log" 2>&1 || true
                            die "bench '$_tag' pod Failed; see $OUT/bench-$_tag.log"; }
    [ $(( $(date +%s) - _t0 )) -gt "$BENCH_TIMEOUT" ] && die "bench '$_tag' not done after $BENCH_TIMEOUT s"
    sleep 20
  done
  _pod=$(kt get pod -l "app=$_job" -o name | head -1 | cut -d/ -f2)
  kt logs "job/$_job" > "$OUT/bench-$_tag.log" 2>&1 || true
  kt cp "$_pod:/out/bench.jsonl" "$OUT/bench-$_tag.jsonl" >/dev/null 2>&1 \
    || log "WARNING: could not copy bench.jsonl for '$_tag'"
  kt delete job "$_job" --wait=false >/dev/null 2>&1 || true
  _hung=$(grep -c '"status": "deadline"' "$OUT/bench-$_tag.jsonl" 2>/dev/null || true)
  _hung=${_hung:-0}
  log "bench '$_tag' done in $(( ($(date +%s) - _t0) / 60 )) min; hung requests: $_hung"
  echo "$_hung" > "$OUT/.hung-$_tag"
}

preflight() {
  log "preflight"
  kt get pod "$FRONTEND_POD" >/dev/null 2>&1 || log "  (no frontend pod yet -- it will be created)"
  for r in prefill decode; do
    _n=$(node_for "$r")
    kiw get node "$_n" >/dev/null 2>&1 || die "node $_n not found; fix PREFILL_NODE/DECODE_NODE"
  done
  ki get ns "$NS_WATCH" >/dev/null 2>&1 || die "namespace $NS_WATCH not reachable with the installer kubeconfig"
  # ConfigMaps are mounted, not baked, so an edit is a replace plus a pod restart.
  ki create configmap ced2549-bpf --from-file=bpf/ --dry-run=client -o yaml | ki apply -f - >/dev/null
  ki create configmap ced2549-watcher --from-file=watcher/ --dry-run=client -o yaml | ki apply -f - >/dev/null
  kt create configmap ced2549-bench --from-file=bench/ --dry-run=client -o yaml | kt apply -f - >/dev/null
  log "  configmaps updated from bpf/, watcher/, bench/"
}

write_run_manifest() {
  # Runs sit side by side as out-cedana/run-1, run-2, ... and six weeks later nobody remembers
  # which one had STAGES=16x4 or which image digest it was against. Written before anything else
  # so even an aborted run says what it was trying to do.
  {
    echo "run=$RUN"
    echo "side=$SIDE"
    echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "out=$OUT"
    echo "git_commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "git_dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    echo "host=$(hostname)"
    echo
    echo "# knobs"
    for v in STAGES IDLE_S SAMPLE_S STALL_S READY_TIMEOUT BENCH_TIMEOUT METRICS_PORT \
             NS_WORK NS_WATCH PREFILL_NODE DECODE_NODE RESUME SKIP_CONTROL FORCE; do
      eval "echo \"$v=\${$v:-}\""
    done
    echo
    echo "# bench env as the Job will see it"
    grep -E '^\s*- \{name: (PROMPT_TOKENS|MAX_TOKENS|DEADLINE_S|HOST|PORT|MODEL)' 20-bench-pd.yaml \
      | sed 's/^ *- //'
    echo
    echo "# image under test"
    grep -m1 'image:' 10-pd-native.yaml | sed 's/^ *//'
  } > "$OUT/run.txt" 2>&1
  log "run manifest: $OUT/run.txt"
}

guard_running_baseline() {
  # The vendor's README is explicit that the baseline may already be running and that it occupies
  # both GPU workers. RESUME=0 deletes all three pods, and on a validated, in-use pair that costs a
  # long model reload and somebody else's afternoon. Refuse rather than assume the node is ours.
  _ready=0
  for p in "$FRONTEND_POD" "$PREFILL_POD" "$DECODE_POD"; do
    [ "$(kt get pod "$p" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = true ] \
      && _ready=$((_ready + 1))
  done
  [ "$_ready" -eq 0 ] && return 0
  [ "${FORCE:-0}" = 1 ] && { log "FORCE=1: deleting $_ready Ready baseline pod(s) anyway"; return 0; }
  die "$_ready of the 3 baseline pods are already Ready, and RESUME=0 would delete them.
     The baseline occupies both GPU workers and a reload is not quick, so this is not assumed.
       RESUME=1 $0     use the running pods as they are (native runs only)
       FORCE=1  $0     delete and recreate them anyway
     Check who is using them first:  kubectl -n $NS_WORK get pod -l together.ai/cedana-pd=glm53"
}

verify_metrics() {
  # An empty sampler would gut the run and look like a quiet cluster, so prove the endpoint works
  # BEFORE any load rather than discovering an empty nixl.csv at collect time.
  for r in prefill decode; do
    _m=$(metrics_for "$r" || true)
    _n=$(echo "$_m" | grep -c '^vllm:' || true)
    [ "${_n:-0}" -gt 0 ] || die "no vllm: metrics from $r at :$METRICS_PORT/metrics. \
Set METRICS_PORT, or check the installer kubeconfig can proxy to pods in $NS_WORK."
    log "  $r exposes $_n vllm: metric lines"
  done
}
