#!/bin/sh
# attach.sh -- CED-2549. Resolve what to probe, prove the probes attach, then run bpftrace.
#
# Carried over from CED-2538 because the failure it prevents is the same one: a uprobe on a symbol
# that does not exist attaches to nothing and reports no events, which reads identically to "that
# path is never taken". On an investigation whose whole premise is a driver call's return code,
# that false negative would be fatal. Every symbol is listed before the run, and every block whose
# symbols are absent is dropped loudly rather than silently failing the script.
#
# WHAT IS DIFFERENT FROM 2538. The workload is vLLM + Dynamo + NIXL, not SGLang, so:
#   - processes are matched on dynamo.vllm / VLLM::EngineCore, not sglang::;
#   - there is a THIRD library to resolve, libibverbs, because the dmabuf fd that CUDA exports
#     only matters if the HCA then accepts it (bpf/ibreg.bt);
#   - block dropping is generic. 2538 hard-coded one NCCL section; here each optional block is
#     marked `>>>REQUIRES <symbol-glob> <map-prefix>` and resolved against the library its own
#     probes name, so adding a probe for a symbol that may not exist needs no change here.
#
# bpftrace may not exist in this image and the cluster's default-deny egress means apt will not
# save us, so the host's binary is used through nsenter when the container has none. That is why
# OUTDIR must be a hostPath mounted at the SAME path inside the container: a bpftrace running in
# the host mount namespace has to be able to read the rendered script and write its log.
#
# POSIX sh on purpose: these images are variously Alpine- and Debian-based and bash is not
# guaranteed. No arrays, no mapfile, no process substitution.
#
# Usage:  attach.sh <script.bt> [more.bt ...]
# Env:    OUTDIR (default /var/tmp/ced2549), SIDE (auto|cedana|native), DURATION (0 = until killed)
set -u

OUTDIR="${OUTDIR:-/var/tmp/ced2549}"
SIDE="${SIDE:-auto}"
DURATION="${DURATION:-0}"
mkdir -p "$OUTDIR"

log() { echo "[attach] $(date -u +%H:%M:%S) $*" >&2; }

# ------------------------------------------------------------------------ find a bpftrace
if command -v bpftrace >/dev/null 2>&1; then
  BPFTRACE="bpftrace"
elif nsenter -t 1 -m -- bpftrace --version >/dev/null 2>&1; then
  # The host has one. Works only because OUTDIR is a hostPath at an identical path.
  BPFTRACE="nsenter -t 1 -m -- bpftrace"
  log "using the host's bpftrace through nsenter (none in this image)"
else
  log "FATAL: no bpftrace in this image and none on the host."
  log "       Install one on the node:  apt-get install -y bpftrace"
  log "       Then delete this pod; there is no egress here to fetch it."
  exit 1
fi
log "bpftrace: $($BPFTRACE --version 2>&1 | head -1)"

# Match processes by full argv without pgrep: these images are minimal and procps is not
# guaranteed. tr + grep are in busybox, so this works everywhere.
proc_match() {
  for _d in /proc/[0-9]*; do
    [ -r "$_d/cmdline" ] || continue
    if tr '\0' ' ' < "$_d/cmdline" 2>/dev/null | grep -qE -- "$1"; then
      echo "${_d#/proc/}"
    fi
  done
}

# Print the tracer-visible path of the first mapping matching $2 in pid $1.
map_path() {
  _pid="$1"; _pat="$2"
  _lib=$(awk -v p="$_pat" '$6 ~ p {print $6; exit}' "/proc/$_pid/maps" 2>/dev/null)
  [ -n "$_lib" ] || return 1
  if [ -e "/proc/$_pid/root$_lib" ]; then echo "/proc/$_pid/root$_lib"; else echo "$_lib"; fi
}

# ---------------------------------------------------------------- find the processes to probe
# The k8s runtime shim does NOT mount the interceptor as libcedana-gpu.so -- it bind-mounts it
# OVER the container's libcuda.so.1, so the engine loads it as the driver and matching on the name
# finds nothing. Match on CONTENT: the interceptor carries cedana strings the real NVIDIA driver
# does not. Getting this wrong would label a cedana run "native" and silently void the A/B.
CEDANA_PIDS=$(
  for _d in /proc/[0-9]*; do
    _lib=$(awk '$6 ~ /libcuda\.so|libcedana-gpu/ {print $6; exit}' "$_d/maps" 2>/dev/null)
    [ -n "$_lib" ] || continue
    _path="$_d/root$_lib"; [ -e "$_path" ] || _path="$_lib"
    if [ "${_lib#*libcedana-gpu}" != "$_lib" ]; then echo "${_d#/proc/}"; continue; fi
    if grep -aqm1 'cedana' "$_path" 2>/dev/null; then echo "${_d#/proc/}"; fi
  done | tr '\n' ' ')
WORKER_PIDS=$(proc_match 'cedana-gpu-controller' | tr '\n' ' ')
# vLLM renames its engine subprocesses with setproctitle, so cmdline shows VLLM::EngineCore_DP0
# rather than the python argv. Decode is DP8: expect EIGHT of these on the decode node.
ENGINE_PIDS=$(proc_match 'dynamo\.vllm|VLLM::EngineCore|VllmWorker' | tr '\n' ' ')

log "interceptor pids: ${CEDANA_PIDS:-none}"
log "controller pids:  ${WORKER_PIDS:-none}"
log "engine pids:      ${ENGINE_PIDS:-none}"
log "engine count:     $(echo $ENGINE_PIDS | wc -w) (decode should show 8 for DP8)"

# --------------------------------------------------------------------------- resolve the paths
LIB=""; LIBCUDA=""; LIBIBV=""
if [ "$SIDE" = "cedana" ] || { [ "$SIDE" = "auto" ] && [ -n "$CEDANA_PIDS" ]; }; then
  SIDE=cedana
  for pid in $CEDANA_PIDS; do
    LIB=$(map_path "$pid" "libcedana-gpu") && [ -n "$LIB" ] && break
    LIB=$(map_path "$pid" "libcuda\.so") && [ -n "$LIB" ] && break
  done
  case "$LIB" in *libcedana-gpu*) : ;; *) log "interceptor is mounted as libcuda.so (matched by content)" ;; esac
  for pid in $WORKER_PIDS; do
    LIBCUDA=$(map_path "$pid" "libcuda\.so") && [ -n "$LIBCUDA" ] && break
  done
else
  # Native baseline. The real driver exports the same names, so nixl-mem.bt's return-code tables
  # come out directly comparable -- which is the entire point of running this on both sides.
  SIDE=native
  for pid in $ENGINE_PIDS; do
    LIB=$(map_path "$pid" "libcuda\.so") && [ -n "$LIB" ] && break
  done
fi
# libibverbs lives in the engine process on BOTH sides: cedana does not interpose on verbs.
for pid in $ENGINE_PIDS; do
  LIBIBV=$(map_path "$pid" "libibverbs\.so") && [ -n "$LIBIBV" ] && break
done

log "side=$SIDE"
log "LIB=$LIB"
log "LIBCUDA=${LIBCUDA:-<none>}"
log "LIBIBV=${LIBIBV:-<none>}"
if [ -z "$LIB" ]; then
  log "FATAL: nothing to probe. Is the engine up, and does this pod have hostPID: true?"
  log "       cedana side needs the interceptor mapped; native needs libcuda.so mapped."
  exit 1
fi
if [ -z "$LIBIBV" ]; then
  log "WARNING: no libibverbs mapped by any engine process. ibreg.bt will be skipped."
  log "         On decode that means NIXL has not opened the HCA yet -- wait for Ready."
fi

# ------------------------------------------------------------------- verify symbols attach
# bpftrace -l expands the probe glob against the real file, so an empty result here is exactly the
# silent no-attach failure this script exists to catch. Needs no binutils in the image.
check() { # lib sym...
  _lib="$1"; shift
  [ -n "$_lib" ] || return 0
  log "symbol check on $_lib:"
  for s in "$@"; do
    n=$($BPFTRACE -l "uprobe:$_lib:$s" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$n" -gt 0 ]; then
      printf '  %-34s ok (%s)\n' "$s" "$n" >&2
    else
      printf '  %-34s MISSING\n' "$s" >&2
    fi
  done
}
check "$LIB" cuMemRetainAllocationHandle cuMemGetHandleForAddressRange \
             cuMemExportToShareableHandle cuMemRelease cuPointerGetAttribute cuStreamSynchronize
check "$LIBIBV" ibv_reg_dmabuf_mr 'ibv_reg_mr*' ibv_modify_qp ibv_get_async_event
log "a MISSING line above is a finding, not a warning: the block that needs it is dropped below,"
log "and an empty result from a dropped block must never be read as 'that path is not taken'."

# --------------------------------------------------------------------------- render and launch
# Drop every >>>REQUIRES block whose symbol glob resolves to nothing in the library its own probes
# name. bpftrace refuses to run a script naming an absent symbol, so this is what lets one script
# cover a library that may or may not export a given entry point.
drop_unresolved() { # rendered-file label
  _f="$1"; _label="$2"
  # Markers are matched ANCHORED at the start of the line. The scripts discuss their own markers
  # in prose, and an unanchored match picks up the explanation instead of the marker -- which
  # deletes an arbitrary span of the script and is almost impossible to spot in the output.
  _guard=0
  while [ "$_guard" -lt 32 ]; do
    _guard=$((_guard + 1))
    _hdr=$(grep -nE '^/\* >>>REQUIRES ' "$_f" | head -1)
    [ -n "$_hdr" ] || return 0
    _ln=${_hdr%%:*}
    _glob=$(echo "$_hdr" | sed -n 's#^[0-9]*:/\* >>>REQUIRES  *\([^ ]*\)  *\([^ ]*\).*#\1#p')
    _pfx=$(echo "$_hdr" | sed -n 's#^[0-9]*:/\* >>>REQUIRES  *\([^ ]*\)  *\([^ ]*\).*#\2#p')
    _end=$(awk -v s="$_ln" 'NR > s && /^\/\* <<<REQUIRES/ {print NR; exit}' "$_f")
    if [ -z "$_glob" ] || [ -z "$_pfx" ] || [ -z "$_end" ]; then
      log "$_label: malformed REQUIRES marker at line $_ln; refusing to guess"
      return 1
    fi
    # The library is whatever this block's own probes name, so the marker stays path-free.
    _blib=$(awk -v s="$_ln" -v e="$_end" 'NR > s && NR < e' "$_f" \
            | sed -n 's/^u[a-z]*probe:\([^:]*\):.*/\1/p' | head -1)
    if [ -n "$_blib" ] && [ "$($BPFTRACE -l "uprobe:$_blib:$_glob" 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]; then
      # Rename rather than delete, so the next pass finds the NEXT marker and the loop ends.
      sed "${_ln}s/>>>REQUIRES/>>>RESOLVED/" "$_f" > "$_f.tmp" && mv "$_f.tmp" "$_f"
      continue
    fi
    log "$_label: no '$_glob' in ${_blib:-<unresolved>}, dropping that block and its $_pfx maps"
    # The block goes, and so does every reference to the maps only it populates: bpftrace rejects
    # a print() or clear() of a map that is never assigned. That is why every map in a REQUIRES
    # block carries the block's prefix and every clear() sits on its own line.
    sed -e "${_ln},${_end}d" -e "\#${_pfx}#d" "$_f" > "$_f.tmp" && mv "$_f.tmp" "$_f"
  done
  log "$_label: gave up after $_guard REQUIRES passes; the markers are probably malformed"
  return 1
}

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BGPIDS=""
for src in "$@"; do
  base=$(basename "$src" .bt)
  rendered="$OUTDIR/${base}.rendered.bt"
  sed -e "s#__LIB__#${LIB}#g" -e "s#__LIBCUDA__#${LIBCUDA}#g" -e "s#__LIBIBV__#${LIBIBV}#g" \
      "$src" > "$rendered"

  if [ -z "$LIBCUDA" ]; then
    sed -e '/>>>LIBCUDA_SECTION/,/<<<LIBCUDA_SECTION/d' -e '/@drv_/d' "$rendered" \
      > "$rendered.tmp" && mv "$rendered.tmp" "$rendered"
    log "$base: no controller libcuda, driver-side block removed"
  fi
  if [ -z "$LIBIBV" ] && grep -q '__LIBIBV__\|ibv_' "$src"; then
    log "$base: SKIPPED, it probes libibverbs and none is mapped"
    continue
  fi
  drop_unresolved "$rendered" "$base"
  if ! grep -q '^u[a-z]*probe:' "$rendered"; then
    log "$base: SKIPPED, every one of its blocks was dropped -- nothing left to attach"
    continue
  fi

  out="$OUTDIR/${base}.${SIDE}.${STAMP}.log"
  log "launching $base -> $out"
  # -f text keeps output line-oriented and greppable for the offline join against bench.jsonl.
  $BPFTRACE -f text "$rendered" >"$out" 2>&1 &
  BGPIDS="$BGPIDS $!"
  echo "$base $out" >> "$OUTDIR/manifest.txt"
done

[ -n "$BGPIDS" ] || { log "FATAL: no script could be launched"; exit 1; }

cleanup() {
  log "stopping bpftrace"
  # TERM, not KILL: bpftrace prints its END block -- the cumulative return-code tables and, in
  # inflight.bt, whatever calls are STILL in flight -- only on a clean shutdown. That last map is
  # the headline result of a hung run, so losing it loses the run.
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
