#!/bin/sh
# attach.sh -- CED-2575. Attach before the server exists, then finish attaching when it does.
#
# A uprobe binds to a file's inode, so a probe can be placed before any process maps the file --
# as long as the file can be found. Two of the three targets can: the host's libnvidia-ml.so and
# libcuda.so, which the toolkit bind-mounts into every GPU pod and which the cedana worker loads
# directly. Scripts that need only those are launched at once (stage 1), so the first NCCL init
# is covered. The ranks' own driver library -- cedana's interceptor, or the image's compat
# libcuda -- is only known once a rank maps it, so the rest attaches when the engine processes
# appear (stage 2). If a rank or the worker turns out to map a different inode than the host
# file, the stage-1 script on that library is re-attached to what is actually mapped.
#
# Every named symbol is checked with `bpftrace -l` before launch: a probe on a missing symbol
# attaches to nothing and reports nothing, which reads exactly like "that path is never taken".
# Blocks between `>>>IF <lib>:<symbol>` and `<<<IF` are dropped when the symbol is absent.
#
# POSIX sh; no bash. Usage: attach.sh <script.bt> ...   Env: OUTDIR SIDE (auto|cedana|native)
set -u
OUTDIR="${OUTDIR:-/var/tmp/ced2575}"
SIDE="${SIDE:-auto}"
mkdir -p "$OUTDIR"
log() { echo "[attach] $(date -u +%H:%M:%S) $*" >&2; }

if command -v bpftrace >/dev/null 2>&1; then
  BPFTRACE="bpftrace"
elif nsenter -t 1 -m -- bpftrace --version >/dev/null 2>&1; then
  BPFTRACE="nsenter -t 1 -m -- bpftrace"
  log "using the host's bpftrace through nsenter"
else
  log "FATAL: no bpftrace in this image and none on the host"
  exit 1
fi
log "bpftrace: $($BPFTRACE --version 2>&1 | head -1)"

proc_match() { # regex on full argv -> pids
  for _d in /proc/[0-9]*; do
    [ -r "$_d/cmdline" ] || continue
    if tr '\0' ' ' < "$_d/cmdline" 2>/dev/null | grep -qE -- "$1"; then echo "${_d#/proc/}"; fi
  done
}
map_path() { # pid pattern -> tracer-visible path of the first matching mapping
  _lib=$(awk -v p="$2" '$6 ~ p {print $6; exit}' "/proc/$1/maps" 2>/dev/null)
  [ -n "$_lib" ] || return 1
  if [ -e "/proc/$1/root$_lib" ]; then echo "/proc/$1/root$_lib"; else echo "$_lib"; fi
}
ino() { stat -L -c %i "$1" 2>/dev/null || stat -L -f %i "$1" 2>/dev/null; }

# ------------------------------------------------------------- host-resident libraries
# Followed by hand under /proc/1/root: readlink -f would resolve the magic link into a host path
# that does not exist in this mount namespace.
HOST=/proc/1/root
resolve() {
  _p="$1"; _n=0
  while [ -L "$_p" ] && [ "$_n" -lt 8 ]; do
    _t=$(readlink "$_p")
    case "$_t" in /*) _p="$HOST$_t" ;; *) _p="$(dirname "$_p")/$_t" ;; esac
    _n=$((_n + 1))
  done
  [ -f "$_p" ] && echo "$_p"
}
host_lib() { # glob -> first real file in the places a driver or cedana install lives
  for _d in usr/lib/x86_64-linux-gnu usr/lib64 usr/lib run/nvidia/driver/usr/lib/x86_64-linux-gnu \
            run/nvidia/driver/usr/lib64 usr/local/lib usr/local/lib/cedana opt/cedana/lib var/lib/cedana; do
    for _f in "$HOST/$_d"/$1; do
      [ -e "$_f" ] || continue
      _r=$(resolve "$_f") && [ -n "$_r" ] && { echo "$_r"; return 0; }
    done
  done
  return 1
}
LIBNVML=$(host_lib 'libnvidia-ml.so.1' || host_lib 'libnvidia-ml.so.*')
LIBCUDA=$(host_lib 'libcuda.so.1' || host_lib 'libcuda.so.*')
LIB=$(host_lib 'libcedana-gpu.so*')
if [ -z "$LIB" ]; then
  # The daemon's own view of its install, if it is up.
  for _p in $(proc_match 'cedana daemon'); do
    LIB=$(resolve "/proc/$_p/root/usr/local/lib/libcedana-gpu.so") && [ -n "$LIB" ] && break
  done
fi
log "host libnvidia-ml: ${LIBNVML:-<none>}"
log "host libcuda:      ${LIBCUDA:-<none>}"
log "host interceptor:  ${LIB:-<none>}"

# ------------------------------------------------------------- render, check, launch
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
needs() { grep -o '__LIB[A-Z]*__' "$1" | sort -u | tr '\n' ' '; }
value_of() { case "$1" in __LIB__) echo "$LIB" ;; __LIBCUDA__) echo "$LIBCUDA" ;; __LIBNVML__) echo "$LIBNVML" ;; esac; }
resolvable() { for _n in $(needs "$1"); do [ -n "$(value_of "$_n")" ] || return 1; done; return 0; }

render() { # src -> rendered path on stdout; drops IF blocks whose symbol is absent
  _base=$(basename "$1" .bt)
  _r="$OUTDIR/${_base}.rendered.bt"
  sed -e "s#__LIB__#${LIB}#g" -e "s#__LIBCUDA__#${LIBCUDA}#g" -e "s#__LIBNVML__#${LIBNVML}#g" "$1" > "$_r"
  for _m in $(grep -o '>>>IF [^ ]*' "$_r" | awk '{print $2}'); do
    _l=${_m%%:*}; _s=${_m#*:}
    if [ "$($BPFTRACE -l "uprobe:$_l:$_s" 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]; then
      sed -e "\#>>>IF $_m#,\#<<<IF#d" "$_r" > "$_r.tmp" && mv "$_r.tmp" "$_r"
      log "$_base: $_s not in $_l, block dropped"
    fi
  done
  echo "$_r"
}
check_symbols() { # rendered -> prints a table; returns 1 if a named symbol is missing
  _miss=0
  for _ls in $(grep -oE 'u(ret)?probe:[^:]+:[A-Za-z0-9_]+$|u(ret)?probe:[^:]+:[A-Za-z0-9_]+[, ]' "$1" \
               | sed -E 's/^u(ret)?probe://; s/[, ]$//' | sort -u); do
    _l=${_ls%%:*}; _s=${_ls#*:}
    _n=$($BPFTRACE -l "uprobe:$_l:$_s" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$_n" -gt 0 ]; then printf '  %-40s ok\n' "$_s" >&2
    else printf '  %-40s MISSING in %s\n' "$_s" "$_l" >&2; _miss=1; fi
  done
  return $_miss
}
BGPIDS=""
launch() { # src tag
  _base=$(basename "$1" .bt)
  _r=$(render "$1")
  log "$_base ($2): symbol check"
  check_symbols "$_r" || log "$_base: a symbol is MISSING -- bpftrace will refuse the script; see above"
  _out="$OUTDIR/${_base}.${SIDE}.${STAMP}.log"
  $BPFTRACE -f text "$_r" > "$_out" 2>&1 &
  _pid=$!
  BGPIDS="$BGPIDS $_pid"
  eval "PID_$_base=$_pid"
  echo "$_base $_out $2" >> "$OUTDIR/manifest.txt"
  sleep 2
  if kill -0 "$_pid" 2>/dev/null; then log "$_base ($2): attached -> $_out"
  else log "$_base ($2): bpftrace EXITED at start; head of its output:"; head -5 "$_out" | sed 's/^/      /' >&2; fi
}
stop_one() { # base
  eval "_p=\${PID_$1:-}"
  [ -n "$_p" ] || return 0
  kill -TERM "$_p" 2>/dev/null; wait "$_p" 2>/dev/null
  BGPIDS=$(for _q in $BGPIDS; do [ "$_q" = "$_p" ] || printf ' %s' "$_q"; done)
}

# ------------------------------------------------------------- stage 1
EARLY=""; LATER=""
for src in "$@"; do
  if resolvable "$src"; then launch "$src" stage1; EARLY="$EARLY $src"
  else log "$(basename "$src" .bt): needs $(needs "$src")-- deferred until the ranks appear"; LATER="$LATER $src"; fi
done
log "watcher ready (stage 1:$(for s in $EARLY; do printf ' %s' "$(basename "$s" .bt)"; done); deferred:$(for s in $LATER; do printf ' %s' "$(basename "$s" .bt)"; done))"

cleanup() {
  log "stopping bpftrace"
  # TERM, not KILL: the END tables print only on a clean shutdown.
  kill -TERM $BGPIDS 2>/dev/null
  wait
  log "done; logs in $OUTDIR"
  exit 0
}
trap cleanup TERM INT

# ------------------------------------------------------------- stage 2: wait for the ranks
# A rank is an engine process with a driver library mapped. Which library decides the side: the
# interceptor is bind-mounted OVER /usr/local/lib/libcuda.so.1, so it is matched by CONTENT (it
# carries cedana strings the NVIDIA driver does not), never by name.
RANK=""; RANK_LIB=""
while [ -z "$RANK" ]; do
  for _p in $(proc_match 'sglang|smg'); do
    _m=$(map_path "$_p" 'libcuda\.so|libcedana-gpu') || continue
    RANK=$_p; RANK_LIB=$_m; break
  done
  [ -n "$RANK" ] && break
  sleep 1 & wait $!
done
DETECTED=native
case "$RANK_LIB" in *libcedana-gpu*) DETECTED=cedana ;; esac
grep -aqm1 'cedana' "$RANK_LIB" 2>/dev/null && DETECTED=cedana
log "ranks appeared: pid $RANK maps $RANK_LIB (side=$DETECTED)"
if [ "$SIDE" = auto ]; then SIDE=$DETECTED
elif [ "$SIDE" != "$DETECTED" ]; then log "WARNING: expected side=$SIDE but the ranks look like $DETECTED"; fi

# What the processes actually map, against what stage 1 attached to.
RANK_NVML=$(map_path "$RANK" 'libnvidia-ml\.so') || true
WORKER=$(proc_match 'cedana-gpu-controller' | head -1)
WORKER_CUDA=""; [ -n "$WORKER" ] && { WORKER_CUDA=$(map_path "$WORKER" 'libcuda\.so') || true; }
log "rank libnvidia-ml: ${RANK_NVML:-<none>}"
log "worker libcuda:    ${WORKER_CUDA:-<none>} (worker pid ${WORKER:-none})"
if [ -n "$RANK_NVML" ] && grep -aqm1 'cedana' "$RANK_NVML" 2>/dev/null; then
  log "NOTE: the rank's libnvidia-ml carries cedana strings -- NVML is interposed, not the driver's"
fi
actual_of() { case "$1" in __LIB__) echo "$RANK_LIB" ;; __LIBCUDA__) echo "$WORKER_CUDA" ;; __LIBNVML__) echo "$RANK_NVML" ;; esac; }
for s in $EARLY; do
  _base=$(basename "$s" .bt); _re=0
  for _n in $(needs "$s"); do
    _a=$(actual_of "$_n"); _h=$(value_of "$_n")
    [ -n "$_a" ] && [ "$(ino "$_a")" != "$(ino "$_h")" ] || continue
    log "WARNING: $_base is attached to $_h but the process maps $_a (different inode); re-attaching"
    case "$_n" in __LIB__) LIB=$_a ;; __LIBCUDA__) LIBCUDA=$_a ;; __LIBNVML__) LIBNVML=$_a ;; esac
    _re=1
  done
  [ "$_re" = 1 ] && { stop_one "$_base"; launch "$s" reattached; }
done
[ -n "$LIB" ] || LIB=$RANK_LIB
for src in $LATER; do launch "$src" stage2; done
log "stage 2 attached (side=$SIDE, detected=$DETECTED)"
log "running until terminated"
wait
