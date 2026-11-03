#!/bin/sh
# nvlink-watch.sh -- CED-2575. The driver's own account of the links for the whole window, and
# nvidia-smi's view of them when the runner asks.
#
# PASSIVE BY DEFAULT. nvidia-smi attaches every GPU it queries, and with persistence mode off
# that alone can train a link that NCCL would otherwise have found down. So before the server
# is Ready nothing here touches a GPU: the kernel log (NVRM / NVLink / Xid lines, with the same
# boot-relative clock bpftrace prints as mono=) and /proc/driver/nvidia are read instead.
# Snapshots are taken when $OUTDIR/snap-now appears -- the runner writes it after Ready and after
# a restore -- or at start if PRE_SNAP=1.
set -u
OUTDIR="${OUTDIR:-/var/tmp/ced2575}"
PRE_SNAP="${PRE_SNAP:-0}"
mkdir -p "$OUTDIR/nvlink"
log() { echo "[nvlink-watch] $(date -u +%H:%M:%S) $*" >&2; }

if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  SMI="nvidia-smi"
elif nsenter -t 1 -m -- nvidia-smi -L >/dev/null 2>&1; then
  SMI="nsenter -t 1 -m -- nvidia-smi"
elif nsenter -t 1 -m -- chroot /run/nvidia/driver nvidia-smi -L >/dev/null 2>&1; then
  SMI="nsenter -t 1 -m -- chroot /run/nvidia/driver nvidia-smi"
else
  SMI=""; log "no working nvidia-smi: snapshots will be empty"
fi

# The passive record: persistence daemon present or not, per-GPU driver state, and the kernel
# log from boot onward, followed until stopped.
{
  echo "persistenced: $(for d in /proc/[0-9]*; do tr '\0' ' ' < $d/cmdline 2>/dev/null; done | grep -c nvidia-persistenced) process(es)"
  for g in /proc/driver/nvidia/gpus/*; do
    echo "== $g"; cat "$g/information" "$g/power" 2>/dev/null
  done
  echo "== /proc/driver/nvidia/version"; cat /proc/driver/nvidia/version 2>/dev/null
} > "$OUTDIR/nvlink/driver-state.txt" 2>&1
cat /dev/kmsg > "$OUTDIR/kmsg.log" 2>/dev/null &
KMSG=$!
log "kernel log -> $OUTDIR/kmsg.log; driver state -> nvlink/driver-state.txt"

snap() { # tag
  [ -n "$SMI" ] || return 0
  _d="$OUTDIR/nvlink"
  { echo "wall=$(date +%s.%N) mono=$(awk '{print $1}' /proc/uptime) tag=$1"; } > "$_d/when-$1.txt"
  $SMI nvlink -s > "$_d/nvlink-$1.txt" 2>&1
  $SMI topo -m   > "$_d/topo-$1.txt" 2>&1
  $SMI --query-gpu=index,pci.bus_id,persistence_mode,pstate --format=csv > "$_d/gpu-$1.csv" 2>&1
  $SMI -q > "$_d/smi-q-$1.txt" 2>&1
  log "snapshot '$1' -> $_d"
}
trap 'kill $KMSG 2>/dev/null; exit 0' TERM INT

[ "$PRE_SNAP" = 1 ] && snap pre
while :; do
  if [ -f "$OUTDIR/snap-now" ]; then
    _tag=$(head -1 "$OUTDIR/snap-now" | tr -cd 'A-Za-z0-9_-')
    rm -f "$OUTDIR/snap-now"
    snap "${_tag:-manual}"
  fi
  sleep 2
done
