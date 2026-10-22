#!/bin/sh
# run-native.sh -- CED-2538: the NATIVE baseline, same measurements as run-restored.sh.
#
# There is no checkpoint/restore here: native has no cedana runtime, so no worker and nothing to
# checkpoint. That asymmetry is inherent -- Together serves from a restore and native cannot --
# so the comparison is "cedana restored" against "native cold", which is the real-world question.
# Everything else is identical to run-restored.sh: same bench, same probes, same PCIe sampling,
# same idle settle, so the two sides' artifacts line up file for file.
#
# It PATCHES the watcher and bench manifests to point at glm52-native rather than asking you to
# sed them back and forth. The generated copies land in $OUT, so what ran is recorded.
#
#   OUT=out-native/run-2 ./run-native.sh
#
# Env: NS CONTEXT NODE IDLE_S OUT
set -eu
CONTEXT="${CONTEXT:-}"
NS="${NS:-cedana-systems}"
NODE="${NODE:-gpu-dp-ckck8-4pcmf}"
IDLE_S="${IDLE_S:-300}"
# PCIe sample interval. 5 s caught only 3 burst samples across a whole bench; set
# PCIE_S=1 for a mechanism run where the shape of the transfer matters.
PCIE_S="${PCIE_S:-5}"
POD=glm52-native
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
OUT="${OUT:-out-native}"
k() { kubectl ${CONTEXT:+--context "$CONTEXT"} -n "$NS" "$@"; }
log() { echo "[native] $(date -u +%H:%M:%S) $*"; }
die() { log "FAIL: $*"; exit 1; }
# RESUME=1 keeps a cold pod that is already Ready (or still loading) and skips straight to the
# idle/watcher/bench phases. Useful after an aborted start -- a 13 min model load is worth saving.
RESUME="${RESUME:-0}"
[ "$RESUME" != 0 ] || { [ -e "$OUT" ] && die "$HERE/$OUT already exists; move it away or set OUT elsewhere"; }
mkdir -p "$OUT"

wait_ready() {
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

pcie() { # DCGM PCIe rates for the node, every 5 s, tagged with the current phase
  _exp=$(kubectl ${CONTEXT:+--context "$CONTEXT"} -n gpu-operator get pod -o wide --no-headers \
         | awk -v n="$NODE" '/dcgm-exporter/ && $0 ~ n {print $1}')
  [ -s "$OUT/pcie.csv" ] || echo "wall,phase,rx_gbps,tx_gbps" > "$OUT/pcie.csv"
  while :; do
    _m=$(kubectl ${CONTEXT:+--context "$CONTEXT"} get --raw \
         "/api/v1/namespaces/gpu-operator/pods/$_exp:9400/proxy/metrics" 2>/dev/null || true)
    _rx=$(echo "$_m" | awk '/^DCGM_FI_PROF_PCIE_RX_BYTES\{/ {s+=$NF} END {printf "%.4f", s/1e9}')
    _tx=$(echo "$_m" | awk '/^DCGM_FI_PROF_PCIE_TX_BYTES\{/ {s+=$NF} END {printf "%.4f", s/1e9}')
    echo "$(date +%s),$(cat "$OUT/.phase" 2>/dev/null),$_rx,$_tx" >> "$OUT/pcie.csv"
    sleep "$PCIE_S"
  done
}
phase() { echo "$1" > "$OUT/.phase"; log "phase: $1"; }

# Point a manifest's HOST env (and the watcher's nodeName) at the native server. Doing this here
# rather than with sed is deliberate: a stale HOST silently benches the wrong server, or no server
# at all, and the bench then waits forever on a name that does not resolve.
retarget() { # src dst
  python3 - "$1" "$2" "$POD" "$NODE" <<'EOF'
import sys, yaml
src, dst, pod, node = sys.argv[1:5]
docs = list(yaml.safe_load_all(open(src)))
for d in docs:
    if not d: continue
    spec = d["spec"]["template"]["spec"] if d["kind"] == "Job" else d["spec"]
    spec["nodeName"] = node
    for c in spec["containers"]:
        for e in c.get("env", []):
            if e["name"] == "HOST":
                e["value"] = pod
yaml.safe_dump_all([d for d in docs if d], open(dst, "w"), sort_keys=False)
EOF
}

if [ "$RESUME" = 1 ]; then
  log "resuming with the existing $POD"
  k delete pod ced2538-watcher --ignore-not-found --wait=true
  k delete job ced2538-bench --ignore-not-found --wait=true
else
  log "clearing previous experiment pods"
  k delete pod glm52-native glm52-cedana ced2538-watcher --ignore-not-found --wait=true
  k delete job ced2538-bench --ignore-not-found --wait=true
fi

pcie & PCIE_PID=$!
trap 'kill $PCIE_PID 2>/dev/null || true' EXIT

phase cold-start
[ "$RESUME" = 1 ] || k apply -f 10-glm52-native.yaml
wait_ready "$POD" 10800
log "$POD Ready"
k logs "$POD" > "$OUT/server-cold.log" 2>&1

phase idle
log "settling ${IDLE_S}s with no load"
sleep "$IDLE_S"

phase watcher
retarget 30-watcher.yaml "$OUT/30-watcher-native.yaml"
k apply -f "$OUT/30-watcher-native.yaml"
sleep 20
k logs ced2538-watcher -c bpf 2>/dev/null | head -20 || true
k logs ced2538-watcher -c bpf 2>/dev/null | grep -q "side=native" \
  || log "WARNING: watcher did not report side=native -- check $OUT/attach.log after collect"

phase bench
retarget 20-bench-burst.yaml "$OUT/20-bench-burst-native.yaml"
k apply -f "$OUT/20-bench-burst-native.yaml"
t0=$(date +%s)
while :; do
  k logs job/ced2538-bench --tail=5 2>/dev/null | grep -q "all stages done" && break
  [ $(( $(date +%s) - t0 )) -gt 7200 ] && die "bench not done after 2 h"
  sleep 30
done
log "bench finished after $(( ($(date +%s) - t0) / 60 )) min"

phase collect
kill $PCIE_PID 2>/dev/null || true
NS="$NS" OUT="$OUT" sh collect.sh native
log "done: $HERE/$OUT"
