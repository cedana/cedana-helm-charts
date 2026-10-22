#!/bin/sh
# collect.sh <native|cedana> -- pull one run's data into $OUT and stop the producers.
#
# ORDER MATTERS, which is the only reason this is a script rather than three kubectl cp lines:
#
#   1. SIGTERM attach.sh BEFORE copying anything. bpftrace prints its END block only on a clean
#      shutdown, and for THIS investigation that END block is not a nicety -- inflight.bt
#      deliberately does not clear @inflight at exit, so the very last thing it prints is the set
#      of driver calls that were still in flight when the run ended. On a hung run that map IS the
#      result. A pod delete or a kill -9 loses it and there is nothing to go back to.
#   2. Then copy /var/tmp/ced2549 from BOTH watchers. Prefill's view is not optional: "were the
#      blocks ever read" is answered on that side.
#   3. Engine logs last, and the engines are NOT killed. 2538 terminated the server to flush the
#      interceptor's TSC profiles; here the engines may still be wedged, and a wedged process is
#      evidence. Tear down by hand once the data has landed.
#
# Nothing is deleted here.
set -u
SIDE="${1:?usage: collect.sh <native|cedana>}"
OUT="${OUT:-out-$SIDE}"
NS_WORK="${NS_WORK:-default}"
NS_WATCH="${NS_WATCH:-cedana-systems}"
mkdir -p "$OUT"

KUBECONFIG_TESTER="${KUBECONFIG_TESTER:-}"; CONTEXT_TESTER="${CONTEXT_TESTER:-}"
KUBECONFIG_INSTALLER="${KUBECONFIG_INSTALLER:-}"; CONTEXT_INSTALLER="${CONTEXT_INSTALLER:-}"
kt() { kubectl ${KUBECONFIG_TESTER:+--kubeconfig "$KUBECONFIG_TESTER"} \
       ${CONTEXT_TESTER:+--context "$CONTEXT_TESTER"} -n "$NS_WORK" "$@"; }
ki() { kubectl ${KUBECONFIG_INSTALLER:+--kubeconfig "$KUBECONFIG_INSTALLER"} \
       ${CONTEXT_INSTALLER:+--context "$CONTEXT_INSTALLER"} -n "$NS_WATCH" "$@"; }

echo "==> stopping bpftrace (this is what flushes the still-in-flight map)"
for r in prefill decode; do
  ki exec "ced2549-watcher-$r" -c bpf -- pkill -TERM -f attach.sh >/dev/null 2>&1 \
    || echo "    no $r watcher to stop"
done
sleep 10

echo "==> watcher output, both nodes"
for r in prefill decode; do
  mkdir -p "$OUT/watcher-$r"
  ki cp "ced2549-watcher-$r:/var/tmp/ced2549" "$OUT/watcher-$r" -c snap >/dev/null 2>&1 \
    || echo "    could not copy from the $r watcher"
  ki logs "ced2549-watcher-$r" -c bpf  > "$OUT/watcher-$r/attach.log"   2>&1 || true
  ki logs "ced2549-watcher-$r" -c snap > "$OUT/watcher-$r/snapshot.log" 2>&1 || true
done

echo "==> engine logs"
for p in cedana-glm53-pd-prefill cedana-glm53-pd-decode cedana-glm53-pd-frontend; do
  kt logs "$p" --all-containers > "$OUT/$p.log" 2>&1 || echo "    no log for $p"
done

echo "==> final pod state (a wedged pod is evidence; nothing is torn down here)"
{
  kt get pod -l together.ai/cedana-pd=glm53 -o wide 2>&1
  echo
  kt describe pod cedana-glm53-pd-decode 2>&1 | sed -n '/Events:/,$p'
} > "$OUT/final-state.txt" 2>&1

echo "==> final NIXL counters"
for r in prefill decode; do
  kubectl ${KUBECONFIG_INSTALLER:+--kubeconfig "$KUBECONFIG_INSTALLER"} \
    ${CONTEXT_INSTALLER:+--context "$CONTEXT_INSTALLER"} get --raw \
    "/api/v1/namespaces/$NS_WORK/pods/cedana-glm53-pd-$r:${METRICS_PORT:-9090}/proxy/metrics" \
    2>/dev/null | grep -E '^vllm:(nixl|num_requests)' > "$OUT/metrics-final-$r.txt" 2>&1 \
    || echo "    no final metrics for $r"
done

echo
echo "==> headline rows, so a bad run is obvious before anyone opens a file:"
for r in prefill decode; do
  f=$(ls "$OUT/watcher-$r"/ced2549/inflight.*.log 2>/dev/null | head -1)
  [ -n "$f" ] || f=$(ls "$OUT/watcher-$r"/inflight.*.log 2>/dev/null | head -1)
  if [ -n "$f" ]; then
    echo "--- $r: last in-flight sweep (entries far below the SWEEP mono= never returned)"
    awk '/SWEEP/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' "$f" | tail -20 | sed 's/^/    /'
  fi
  f=$(ls "$OUT/watcher-$r"/ced2549/nixl-mem.*.log 2>/dev/null | head -1)
  [ -n "$f" ] || f=$(ls "$OUT/watcher-$r"/nixl-mem.*.log 2>/dev/null | head -1)
  if [ -n "$f" ]; then
    echo "--- $r: cuMemRetainAllocationHandle return codes, and whether the fallback rescued it"
    grep -A6 '@dmabuf_fallback' "$f" | tail -8 | sed 's/^/    /'
    grep 'cuMemRetainAllocationHandle' "$f" | grep '@ret' | tail -5 | sed 's/^/    /'
  fi
done

echo
echo "==> collected into $OUT:"
find "$OUT" -type f | sed 's/^/   /' | head -40
echo
echo "Tear down when you are happy the data landed:"
echo "   kubectl -n $NS_WATCH delete pod ced2549-watcher-prefill ced2549-watcher-decode"
echo "   kubectl -n $NS_WORK delete pod -l together.ai/cedana-pd=glm53"
