#!/bin/sh
# run-native.sh -- CED-2575: the NATIVE control, same watcher, same collection as run-cedana.sh.
#
# Two things come out of it: the proof that this node, image and command initialise NCCL whole
# without cedana, and $OUT/nccl-topo.xml -- the XML that, fed back as NCCL_TOPO_FILE, is the
# workaround under test. No checkpoint/restore: native has nothing to checkpoint.
#
#   OUT=out-native/run-1 ./run-native.sh
#   TOPO_FILE=$OUT/nccl-topo.xml OUT=out-cedana/run-2 ./run-cedana.sh COLD-START
#
# Env: see lib.sh, plus OUT
set -eu
RUN=native
SIDE=native
POD=glm52-native
MODE="${1:-COLD-START}"
[ "$MODE" = COLD-START ] || { echo "usage: $0 [COLD-START]" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
OUT="${OUT:-out-native}"
. ./lib.sh

[ -e "$OUT" ] && die "$HERE/$OUT already exists; move it away or set OUT"
mkdir -p "$OUT"
write_run_manifest
preflight

clear_pods
phase watcher
start_watcher
phase cold-start
render 10-glm52-native.yaml "$OUT/10-glm52-native.as-run.yaml" ${TOPO_FILE:+--topo-file}
k apply -f "$OUT/10-glm52-native.as-run.yaml" >/dev/null
t0=$(date +%s)
wait_ready "$POD" "$READY_TIMEOUT"
log "$POD Ready in $(( $(date +%s) - t0 )) s"
snap_links cold
collect_server "$POD" cold

phase collect
collect_watcher
teardown
log "done: $HERE/$OUT"
[ -s "$OUT/nccl-topo.xml" ] && log "feed it back: TOPO_FILE=$OUT/nccl-topo.xml ./run-cedana.sh COLD-START"
