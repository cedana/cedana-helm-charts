#!/bin/sh
# run-restored.sh -- CED-2538: the cedana side as Together runs it, RESTORED from a checkpoint.
#
# Every earlier cedana run was a fresh start under the cedana runtime. Together serves from a restore
# deployment, and their memory layout differs from what a fresh start showed (pool resident only in
# the controllers, engine RSS ~7 GB, against ~150 GiB in both rank and worker here). This runs the
# same measurements on a restored pod.
#
# The checkpoint/restore follows cedana-bench's restore-time runner (feat/together-testing-august),
# RESTORE_MODE=path: cold start -> Ready -> POST /v1/checkpoint/pod -> poll -> delete -> re-apply the
# same manifest with CEDANA_CHECKPOINT_PATH -> Ready. The chart has fallbackColdStart=true, so a
# failed restore silently cold-starts: the cold-start log markers are checked and the run stops if
# the "restored" pod loaded weights.
#
# Measured, beyond ../rerun-nosnap/run-side.sh: rank vs worker memory (once, before any load),
# and DCGM PCIe RX/TX summed over the node's 8 GPUs every 5 s through 5 min idle and the bench.
#
# Needs the daemon's checkpoint dir on /scratch (14 TB); the root disk has ~40 GB:
#   helm upgrade cedana ... --reuse-values --set config.checkpointDir=/scratch
set -eu
# Empty = whatever context kubectl is already on, which is almost always what you want.
# Set it only to pin a run to a specific cluster from a machine with several configured.
CONTEXT="${CONTEXT:-}"
NS="${NS:-cedana-systems}"
NODE="${NODE:-gpu-dp-ckck8-4pcmf}"
IDLE_S="${IDLE_S:-300}"
# PCIe sample interval. 5 s caught only 3 burst samples across a whole bench; set
# PCIE_S=1 for a mechanism run where the shape of the transfer matters.
PCIE_S="${PCIE_S:-5}"
POD=glm52-cedana
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
# OUT=out-cedana/run-2 keeps runs side by side instead of refusing to start.
OUT="${OUT:-out-cedana}"
k() { kubectl ${CONTEXT:+--context "$CONTEXT"} -n "$NS" "$@"; }
log() { echo "[restored] $(date -u +%H:%M:%S) $*"; }
die() { log "FAIL: $*"; exit 1; }
# RESUME=1 starts at the checkpoint, from a cold pod that is already Ready; RESUME=restore starts at
# the restore, from the checkpoint recorded in $OUT/checkpoint-action.json. Both keep $OUT.
RESUME="${RESUME:-0}"
[ "$RESUME" != 0 ] || { [ -e "$OUT" ] && die "$HERE/$OUT already exists; move it away first"; }

DIR=$(k get cm cedana-config -o jsonpath='{.data.checkpoint-dir}')
[ "$DIR" = /scratch ] || die "cedana checkpoint dir is '$DIR', not /scratch; set config.checkpointDir=/scratch first"
mkdir -p "$OUT"

# Propagator: the cluster's own Cedana URL and token, as the helpers use them. Never printed.
URL=$(k get cm cedana-config -o jsonpath='{.data.url}'); URL=${URL%/}; URL=${URL%/v1}
TOKEN=$(k get secret cedana-secrets -o jsonpath='{.data.auth-token}' | base64 -d)
prop() { # method path [json] -> body, then the HTTP code on the last line
         # Strip that last line with `sed '$d'`, not `head -n -1`: the latter is GNU-only
         # and BSD head (macOS) rejects a negative count, which hangs the poll loops below.
  curl -s -X "$1" "$URL$2" -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
    ${3:+-d "$3"} -w '\n%{http_code}'
}
# Same CRIU options as the bench runner.
CRIU_OPTS='{"leave_running": true, "tcp_established": true, "tcp_skip_in_flight": true, "link_remap": true, "manage_cgroups": true, "manage_cgroups_mode": 1, "file_locks": true}'
LOAD_MARKERS='Load weight|Loading safetensors|Capture cuda graph|Launching server|Loading model'

wait_ready() { # pod timeout_s
  _t0=$(date +%s)
  while :; do
    _s=$(k get pod "$1" -o jsonpath='{.status.phase} {.status.containerStatuses[0].ready}' 2>&1 || true)
    case "$_s" in
      "Running true") return 0 ;;
      Running*|Pending*) ;;
      *) k logs "$1" --tail=30 > "$OUT/$1-failed.log" 2>&1 || true; die "$1 is '$_s'" ;;
    esac
    [ $(( $(date +%s) - _t0 )) -gt "$2" ] && die "$1 not Ready after $2 s"
    sleep 15
  done
}

pcie() { # sample DCGM PCIe rates for the node into $OUT/pcie.csv until killed
  _exp=$(kubectl ${CONTEXT:+--context "$CONTEXT"} -n gpu-operator get pod -o wide --no-headers | awk -v n="$NODE" '/dcgm-exporter/ && $0 ~ n {print $1}')
  [ -s "$OUT/pcie.csv" ] || echo "wall,phase,rx_gbps,tx_gbps" > "$OUT/pcie.csv"
  while :; do
    _m=$(kubectl ${CONTEXT:+--context "$CONTEXT"} get --raw "/api/v1/namespaces/gpu-operator/pods/$_exp:9400/proxy/metrics" 2>/dev/null || true)
    _rx=$(echo "$_m" | awk '/^DCGM_FI_PROF_PCIE_RX_BYTES\{/ {s+=$NF} END {printf "%.4f", s/1e9}')
    _tx=$(echo "$_m" | awk '/^DCGM_FI_PROF_PCIE_TX_BYTES\{/ {s+=$NF} END {printf "%.4f", s/1e9}')
    echo "$(date +%s),$(cat "$OUT/.phase" 2>/dev/null),$_rx,$_tx" >> "$OUT/pcie.csv"
    sleep "$PCIE_S"
  done
}
phase() { echo "$1" > "$OUT/.phase"; log "phase: $1"; }

if [ "$RESUME" = 1 ]; then
  [ "$(k get pod "$POD" -o jsonpath='{.status.containerStatuses[0].ready}')" = true ] || die "RESUME=1 needs $POD Ready"
  log "resuming from the checkpoint with the running cold $POD"
else
  log "clearing previous experiment pods"
  k delete pod glm52-native glm52-cedana ced2538-watcher --ignore-not-found --wait=true
  k delete job ced2538-bench --ignore-not-found --wait=true
fi

pcie & PCIE_PID=$!
trap 'kill $PCIE_PID 2>/dev/null || true' EXIT

if [ "$RESUME" = 0 ]; then
  phase cold-start
  k apply -f 11-glm52-cedana.yaml
  wait_ready "$POD" 10800
  log "cold $POD Ready"
  k logs "$POD" > "$OUT/server-cold.log" 2>&1
fi

if [ "$RESUME" = restore ]; then
  # A checkpoint from an earlier attempt: its action record is already in $OUT.
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
k delete pod "$POD" --ignore-not-found --wait=true
python3 - "$RESTORE_PATH" 11-glm52-cedana.yaml > "$OUT/11-glm52-cedana-restore.yaml" <<'EOF'
import sys, yaml
docs = list(yaml.safe_load_all(open(sys.argv[2])))
c = docs[0]["spec"]["containers"][0]
c["env"] = [e for e in c.get("env", []) if e["name"] not in ("CEDANA_CHECKPOINT", "CEDANA_CHECKPOINT_PATH")]
c["env"].append({"name": "CEDANA_CHECKPOINT_PATH", "value": sys.argv[1]})
yaml.safe_dump_all(docs, sys.stdout, sort_keys=False)
EOF
t0=$(date +%s)
k apply -f "$OUT/11-glm52-cedana-restore.yaml"
wait_ready "$POD" 10800
log "restored $POD Ready in $(( $(date +%s) - t0 )) s"
k logs "$POD" > "$OUT/server-init.log" 2>&1
MARKERS=$(grep -cE "$LOAD_MARKERS" "$OUT/server-init.log" || true)
[ "$MARKERS" -eq 0 ] || die "the restored pod logged $MARKERS cold-start markers: it fell back to a cold start"
log "restore verified: no cold-start markers"

phase idle
# Memory layout before any load: is the HiCache pool resident in the ranks, the workers, or both?
kubectl ${CONTEXT:+--context "$CONTEXT"} -n "$NS" exec "$(k get pod -o name -l app.kubernetes.io/component=helper --field-selector spec.nodeName="$NODE" | head -1 | cut -d/ -f2)" -- sh -c '
  for d in /host/proc/[0-9]*; do
    c=$(tr "\0" " " < $d/cmdline 2>/dev/null | cut -c1-80)
    case "$c" in *sglang*|*cedana-gpu-controller*--worker*)
      r=$(awk "/^Rss:/{print \$2}" $d/smaps_rollup 2>/dev/null); p=$(awk "/^Pss:/{print \$2}" $d/smaps_rollup 2>/dev/null)
      echo "${d#/host/proc/} rss_kb=$r pss_kb=$p $c";;
    esac
  done' > "$OUT/memory-layout.txt" 2>&1 || true
log "memory layout: $(awk '$2 ~ /rss_kb=[0-9]{8,}/' "$OUT/memory-layout.txt" | wc -l) processes over 10 GB; see memory-layout.txt"
sleep "$IDLE_S"

phase watcher
k apply -f 30-watcher.yaml
for _ in $(seq 60); do
  k logs ced2538-watcher -c bpf 2>/dev/null | grep -q 'running until terminated' && break
  sleep 5
done
k logs ced2538-watcher -c bpf 2>&1 | grep '^\[attach\]\|^  cu' > "$OUT/attach.log" || true
grep -q "side=cedana" "$OUT/attach.log" || die "watcher did not detect side=cedana; see $OUT/attach.log"
grep -E '^  cu' "$OUT/attach.log" | grep -qv ' ok ' && die "a symbol did not attach; see $OUT/attach.log"

phase bench
k apply -f 20-bench-burst.yaml
t0=$(date +%s)
while :; do
  k logs job/ced2538-bench --tail=3 2>/dev/null | grep -q 'bench finished' && break
  [ "$(k get pod "$POD" -o jsonpath='{.status.phase}')" = Running ] || die "$POD stopped during the bench"
  [ $(( $(date +%s) - t0 )) -gt 7200 ] && die "bench not finished after 2 h"
  sleep 30
done
log "bench finished after $(( ($(date +%s) - t0) / 60 )) min"
phase collect

SHIM=$(mktemp -d)
if [ -n "$CONTEXT" ]; then
  printf '#!/bin/sh\nexec %s --context %s "$@"\n' "$(command -v kubectl)" "$CONTEXT" > "$SHIM/kubectl"
else
  printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v kubectl)" > "$SHIM/kubectl"
fi
chmod +x "$SHIM/kubectl"
PATH="$SHIM:$PATH" NS="$NS" OUT="$OUT" sh collect.sh cedana
rm -rf "$SHIM" "$OUT/.phase"
log "done: $HERE/$OUT (checkpoint left at $RESTORE_PATH on $NODE)"
