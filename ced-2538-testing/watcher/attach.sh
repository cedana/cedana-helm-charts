#!/bin/sh
# attach.sh -- CED-2538. Resolve what to probe, prove the probes attach, then run bpftrace.
#
# WHY THERE IS A SCRIPT AND NOT JUST A bpftrace COMMAND. A uprobe attaches to a file by inode, and
# the three things worth probing all live at paths the tracer cannot guess:
#   - libcedana-gpu.so is bind-mounted into the application container by the runtime shim, so its
#     path differs between the host's view and the container's;
#   - the GPU worker is a separate process started by the cedana daemon, outside the pod cgroup;
#   - on the native side there is no interceptor at all and the same probes belong on libcuda.
# So the paths are read out of /proc/<pid>/maps and reached through /proc/<pid>/root, which works
# across the mount namespace because this pod is privileged with hostPID.
#
# It also VERIFIES attachment before running. The failure mode this exists to prevent: a probe on a
# symbol that does not exist attaches to nothing and reports no events, which reads identically to
# "the path under test is never taken" -- a false negative that would send the whole investigation
# the wrong way. See the _v2 note in bpf/cuda-copy-hist.bt.
#
# POSIX sh on purpose: the bpftrace images are variously Alpine- and Debian-based and bash is not
# guaranteed. No arrays, no mapfile, no process-substitution.
#
# Usage:  attach.sh <script.bt> [more.bt ...]
# Env:    OUTDIR (default /out), SIDE (auto|cedana|native), DURATION (0 = until killed)
set -u

OUTDIR="${OUTDIR:-/out}"
SIDE="${SIDE:-auto}"
DURATION="${DURATION:-0}"
mkdir -p "$OUTDIR"

log() { echo "[attach] $(date -u +%H:%M:%S) $*" >&2; }

# Match processes by full argv without pgrep: the bpftrace images are minimal and procps is not
# guaranteed. tr + grep are in busybox, so this works everywhere.
proc_match() {
  for _d in /proc/[0-9]*; do
    [ -r "$_d/cmdline" ] || continue
    if tr '\0' ' ' < "$_d/cmdline" 2>/dev/null | grep -qE -- "$1"; then
      echo "${_d#/proc/}"
    fi
  done
}

# ---------------------------------------------------------------- find the processes to probe
# Application ranks: any process with the interceptor mapped. On the native side there are none,
# which is itself the signal that we are looking at the baseline.
CEDANA_PIDS=$(grep -l libcedana-gpu /proc/[0-9]*/maps 2>/dev/null \
                | sed 's#/proc/\([0-9]*\)/maps#\1#' | tr '\n' ' ')
# The GPU worker/controller. Matched on full argv, so the 15-char comm truncation that makes this
# process show up as "cedana-gpu-cont" in ps does not matter here.
WORKER_PIDS=$(proc_match 'cedana-gpu-controller' | tr '\n' ' ')
# sglang ranks regardless of side: the native fallback probes these, and snapshot.sh needs them.
SGLANG_PIDS=$(proc_match 'sglang\.launch_server|sglang::' | tr '\n' ' ')

log "interceptor pids: ${CEDANA_PIDS:-none}"
log "worker pids:      ${WORKER_PIDS:-none}"
log "sglang pids:      ${SGLANG_PIDS:-none}"

# --------------------------------------------------------------------------- resolve the paths
# Print the tracer-visible path of the first mapping matching $2 in pid $1.
map_path() {
  _pid="$1"; _pat="$2"
  _lib=$(awk -v p="$_pat" '$6 ~ p {print $6; exit}' "/proc/$_pid/maps" 2>/dev/null)
  [ -n "$_lib" ] || return 1
  if [ -e "/proc/$_pid/root$_lib" ]; then echo "/proc/$_pid/root$_lib"; else echo "$_lib"; fi
}

LIB=""; LIBCUDA=""
if [ "$SIDE" = "cedana" ] || { [ "$SIDE" = "auto" ] && [ -n "$CEDANA_PIDS" ]; }; then
  SIDE=cedana
  for pid in $CEDANA_PIDS; do
    LIB=$(map_path "$pid" "libcedana-gpu") && [ -n "$LIB" ] && break
  done
  for pid in $WORKER_PIDS; do
    LIBCUDA=$(map_path "$pid" "libcuda\\.so") && [ -n "$LIBCUDA" ] && break
  done
else
  # Native baseline: the same script is symbol-compatible with the real driver -- libcuda exports
  # cuMemcpyDtoHAsync_v2, cuMemHostRegister and cuModuleLoad* under those exact names too. So the
  # histograms are directly comparable between the two sides, which is the point of the A/B.
  SIDE=native
  for pid in $SGLANG_PIDS; do
    LIB=$(map_path "$pid" "libcuda\\.so") && [ -n "$LIB" ] && break
  done
fi

log "side=$SIDE"
log "LIB=$LIB"
log "LIBCUDA=${LIBCUDA:-<none>}"
if [ -z "$LIB" ]; then
  log "FATAL: nothing to probe. Is the server up, and does this pod have hostPID: true?"
  log "       cedana side needs libcedana-gpu.so mapped; native needs libcuda.so mapped."
  exit 1
fi

# ------------------------------------------------------------------- verify symbols attach
# bpftrace -l expands the probe glob against the real file, so an empty result here is exactly the
# silent no-attach failure this script exists to catch. Needs no binutils in the image.
MISSING=0
log "symbol check on $LIB:"
for s in cuMemcpyDtoHAsync_v2 cuMemcpyHtoDAsync_v2 cuMemHostRegister cuModuleLoadData; do
  n=$(bpftrace -l "uprobe:$LIB:$s" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -gt 0 ]; then
    printf '  %-28s ok (%s)\n' "$s" "$n" >&2
  else
    printf '  %-28s MISSING\n' "$s" >&2
    MISSING=1
  fi
done
if [ "$MISSING" -ne 0 ]; then
  log "WARNING: a symbol above is missing. bpftrace refuses to attach rather than running half the"
  log "         script, so fix the name before trusting any empty result. List what IS exported:"
  log "           bpftrace -l 'uprobe:$LIB:cu*' | head -50"
fi

# --------------------------------------------------------------------------- render and launch
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BGPIDS=""
for src in "$@"; do
  base=$(basename "$src" .bt)
  rendered="$OUTDIR/${base}.rendered.bt"
  sed -e "s#__LIB__#${LIB}#g" -e "s#__LIBCUDA__#${LIBCUDA}#g" "$src" > "$rendered"
  if [ -z "$LIBCUDA" ]; then
    # No worker libcuda to probe: delete the driver-side block, and every reference to the maps it
    # populates. bpftrace rejects a print/clear of a map that is never assigned, so the END block's
    # @drv_* lines have to go with the section.
    sed -e '/>>>LIBCUDA_SECTION/,/<<<LIBCUDA_SECTION/d' \
        -e '/@drv_/d' -e '/@dstart/d' -e '/@dsize/d' -e '/@dfunc/d' \
        "$rendered" > "$rendered.tmp" && mv "$rendered.tmp" "$rendered"
    log "$base: no worker libcuda, driver-side section removed"
  fi
  out="$OUTDIR/${base}.${SIDE}.${STAMP}.log"
  log "launching $base -> $out"
  # -f text keeps output line-oriented and greppable for the offline join against bench.jsonl.
  bpftrace -f text "$rendered" >"$out" 2>&1 &
  BGPIDS="$BGPIDS $!"
  echo "$base $out" >> "$OUTDIR/manifest.txt"
done

cleanup() {
  log "stopping bpftrace"
  # TERM, not KILL: bpftrace prints its END block (the cumulative registration counters, the
  # headline result) only on a clean shutdown.
  kill -TERM $BGPIDS 2>/dev/null
  wait
  log "done; logs in $OUTDIR"
}
trap cleanup TERM INT

if [ "$DURATION" -gt 0 ]; then
  log "running for ${DURATION}s"
  sleep "$DURATION"
  cleanup
else
  log "running until terminated"
  wait
fi
