#!/bin/sh
# collect.sh <native|cedana> -- pull one run's data into ./out-<side>/ and stop the producers.
#
# ORDER MATTERS, which is the only reason this is a script:
#   1. bench.jsonl first -- the Job pod is the first thing a cleanup reaps.
#   2. SIGTERM attach.sh BEFORE copying /out -- bpftrace prints its cumulative END block (the
#      host-registration counters) only on a clean shutdown. kill -9 or a pod delete loses it.
#   3. SIGTERM the server LAST -- under cedana that is what writes the per-thread TSC profiles.
# Nothing is deleted here; tear down by hand once you have verified the data landed.
set -u
SIDE="${1:?usage: collect.sh <native|cedana>}"
NS="${NS:-cedana-systems}"
POD="glm52-$SIDE"
OUT="out-$SIDE"
mkdir -p "$OUT"
k() { kubectl -n "$NS" "$@"; }

echo "==> bench records"
BENCH=$(k get pod -l app=ced2538-bench -o name | cut -d/ -f2)
[ -n "$BENCH" ] && k cp "$BENCH:/out/bench.jsonl" "$OUT/bench.jsonl" || echo "   no bench pod"

echo "==> stopping bpftrace (flushes cumulative counters)"
k exec ced2538-watcher -c bpf -- pkill -TERM -f attach.sh 2>/dev/null
sleep 5

echo "==> watcher output (bpftrace logs + snapshots)"
k cp "ced2538-watcher:/out" "$OUT" -c snap

echo "==> server log (NCCL transport, cedana criticals)"
k logs "$POD" > "$OUT/server.log" 2>&1

echo "==> stopping the engine"
k exec "$POD" -- pkill -TERM -f sglang.launch_server 2>/dev/null
sleep 10

if [ "$SIDE" = "cedana" ]; then
  echo "==> interceptor TSC profiles"
  k cp "$POD:/logs/cedana" "$OUT/tsc-profiles" || echo "   none (profiling off, or no SIGTERM?)"
fi

echo
echo "==> collected into $OUT:"
find "$OUT" -type f | sed 's/^/   /' | head -40
echo
echo "Now tear down when you are happy:"
echo "   kubectl -n $NS delete pod $POD ced2538-watcher; kubectl -n $NS delete job ced2538-bench"
