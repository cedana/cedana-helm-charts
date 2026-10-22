#!/bin/sh
# run-native.sh -- CED-2549: the NATIVE P/D baseline, same measurements as run-restored.sh.
#
# RUN THIS FIRST. It is not a formality:
#
#   1. It is what makes `cuMemRetainAllocationHandle -> 1` interpretable. 1 is
#      CUDA_ERROR_INVALID_VALUE, and it is the DOCUMENTED return for an address not backed by a
#      cuMemCreate allocation -- which a plain cudaMalloc'd KV cache is not. If the native side
#      produces the identical @ret row, the reported error is normal UCX probing and the finding
#      moves to @dmabuf_fallback. If native returns 0 where cedana returns 1, cedana's pointers
#      are not recognised as VMM allocations and the whole dmabuf path diverges. Nothing else in
#      this harness can tell those two apart.
#   2. It confirms the baseline still passes 8/8 and 2x16/16 on these nodes, today. Without that,
#      a hang on the cedana side has no control to be a hang relative to.
#
# There is no checkpoint/restore here: native has no cedana runtime and nothing to checkpoint.
# That asymmetry is inherent and it is the ONLY asymmetry -- same bench, same probes, same
# sampler, same idle settle, so out-native/ and out-cedana/ line up file for file.
#
# attach.sh detects side=native from /proc and probes the real libcuda, which exports the same
# symbol names as the interceptor, so the return-code tables are directly comparable.
#
# The baseline pods may ALREADY be running on this cluster -- the zip's README says so. Then:
#   RESUME=1 ./run-native.sh
# which keeps them and skips straight to the watchers and the load.
#
#   OUT=out-native/run-2 ./run-native.sh
#
# Env: see lib.sh, plus RESUME
set -eu
RUN=native
SIDE=native
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
OUT="${OUT:-out-native}"
RESUME="${RESUME:-0}"
. ./lib.sh

if [ "$RESUME" = 0 ] && [ -e "$OUT" ]; then
  die "$HERE/$OUT already exists; move it away, or set OUT elsewhere"
fi
mkdir -p "$OUT"
phase init
write_run_manifest
preflight

if [ "$RESUME" = 0 ]; then
  guard_running_baseline
  log "clearing previous experiment pods"
  kt delete pod "$PREFILL_POD" "$DECODE_POD" "$FRONTEND_POD" --ignore-not-found --wait=true >/dev/null
  ki delete pod ced2549-watcher-prefill ced2549-watcher-decode --ignore-not-found --wait=true >/dev/null

  phase cold-start
  # 10-pd-native.yaml is the vendor's file byte for byte and is applied unmodified. That is the
  # point of it: `unzip -p cedana-pd-baseline-*.zip ...| diff - 10-pd-native.yaml` must stay empty.
  kt apply -f 10-pd-native.yaml >/dev/null
  for p in "$FRONTEND_POD" "$PREFILL_POD" "$DECODE_POD"; do
    wait_ready "$p" "$READY_TIMEOUT"
    log "$p Ready"
  done
else
  log "RESUME=1: using the pods that are already running"
  for p in "$FRONTEND_POD" "$PREFILL_POD" "$DECODE_POD"; do
    [ "$(kt get pod "$p" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = true ] \
      || die "RESUME=1 needs $p Ready"
  done
  # A pod under runtimeClassName: cedana would make this an unlabelled cedana run, and the output
  # would be filed as the native control. Refuse rather than mislabel the A/B.
  for r in prefill decode; do
    RC=$(kt get pod "$(pod_for "$r")" -o jsonpath='{.spec.runtimeClassName}' 2>/dev/null || true)
    [ -z "$RC" ] || die "$r is running under runtimeClassName '$RC'; this is not the native baseline"
  done
fi
for r in prefill decode; do kt logs "$(pod_for "$r")" > "$OUT/$r-cold.log" 2>&1; done

verify_metrics
sample_loop & SAMPLER_PID=$!
trap 'kill $SAMPLER_PID 2>/dev/null || true' EXIT

log "settling ${IDLE_S}s before load"
phase idle
sleep "$IDLE_S"

phase watcher
start_watchers
phase bench
run_bench native "$STAGES"

HUNG=$(cat "$OUT/.hung-native" 2>/dev/null || echo 0)
if [ "${HUNG:-0}" -gt 0 ]; then
  log "========================================================================"
  log "THE NATIVE BASELINE HUNG $HUNG REQUESTS. The report says these same"
  log "deployments pass 8/8 and 2x16/16 without cedana, so either the cluster"
  log "has changed since 2026-10-15 or the load shape here is harder than the"
  log "one that was measured. Settle this before reading anything into the"
  log "cedana side: with the control failing, a cedana hang proves nothing."
  log "========================================================================"
else
  log "native baseline passed the full ladder with no hang -- the A/B has a control"
fi

phase collect
kill $SAMPLER_PID 2>/dev/null || true
SIDE="$SIDE" OUT="$OUT" NS_WORK="$NS_WORK" NS_WATCH="$NS_WATCH" \
  KUBECONFIG_TESTER="$KUBECONFIG_TESTER" KUBECONFIG_INSTALLER="$KUBECONFIG_INSTALLER" \
  CONTEXT_TESTER="$CONTEXT_TESTER" CONTEXT_INSTALLER="$CONTEXT_INSTALLER" \
  sh collect.sh native
rm -f "$OUT/.phase" "$OUT"/.hung-*
log "done: $HERE/$OUT"
