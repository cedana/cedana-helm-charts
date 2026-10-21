# CED-2538: GLM-5.2 TTFT tail under cedana

Reported on SGLang TP8, GLM-5.2, B200, 50/50 against production: median TTFT and decode speed at
parity with native, but a heavier TTFT tail — p99 +30–160%, with 17–63 s outliers against a 2.3–4.5 s
baseline during a 127k–151k-token prompt burst.

**No cause is assumed here.** The search space is wide enough that committing early would bias the
instrumentation, so the harness is broad: copy sizes and latencies, host-registration outcomes,
module-load cost, collective transport, host memory pressure and GPU link state, on both sides of
the split-process design, plus process state captured at the moment a slow request completes.

## Files

```
00-model-volume.yaml     PV + PVC for the Weka model view, in cedana-systems
01-model-fetch.yaml      pull GLM-5.2 onto the volume (cedana-provisioning, RW claim)
10-glm52-native.yaml     SGLang TP8 GLM-5.2, native            — A side
11-glm52-cedana.yaml     the same + runtimeClassName: cedana   — B side (generated from 10)
20-bench-burst.yaml      the load generator Job
30-watcher.yaml          privileged hostPID watcher: bpftrace + triggered snapshots
bench/burst_bench.py     three-stage driver; per-request JSONL, mono+wall timestamps
bpf/cuda-copy-hist.bt    copy size/latency, host registration, module load — both sides
bpf/transport.bt         NCCL P2P/IPC vs SHM fallback
watcher/attach.sh        resolves probe targets from /proc, verifies attachment, runs bpftrace
watcher/snapshot.sh      TTFT-histogram trigger, then py-spy / stacks / smaps / nvidia-smi
```

## The experiment

The same watcher and the same bench run against **both** servers, and `attach.sh` detects which side
it is on from `/proc` — cedana side if any process has `libcedana-gpu.so` mapped, native otherwise —
then probes the interceptor or the real libcuda accordingly. Both export the same symbol names
(`cuMemcpyDtoHAsync_v2`, `cuMemHostRegister`, `cuModuleLoad*`), so the histograms come out directly
comparable. The side lands in every output filename: `cuda-copy-hist.native.<ts>.log` against
`cuda-copy-hist.cedana.<ts>.log`. That difference is the result.

The load generator forces the two conditions the report describes, and **only** those — whether they
actually reproduce the 17–63 s outliers is the thing being tested, not something assumed:

| Stage | What it forces | Why |
| --- | --- | --- |
| WARM | JIT, DeepGEMM, shape buckets | An unwarmed native baseline reads ~2x slow (DeepSeek measured 575 vs 1099 tok/s), which would make cedana look like it wins |
| A | concurrency 1, 127k and 151k alternating | The clean TTFT floor. If A already differs, this is not a tail |
| B | idle 20 s, then 8 prompts at once, ×12 | Queueing. 8 × 151k ≈ 1.2M tokens arriving instantaneously |
| C | populate 6 prefixes → evict GPU-side → re-send identical | The only stage that reaches HiCache **load-back** rather than fresh prefill |

### The knob that matters most: `--hicache-io-backend`

`--hicache-size 128` pins a 128 GiB host pool (matching `hicache-probe-128.yaml` and
`glm-5-3-p1-b200.yaml` in cedana-bench). But the io-backend decides *how* that pool is read back,
and therefore whether the copies are interposable at all:

- **`direct`** → `cudaMemcpyAsync`, i.e. `cuMemcpyHtoDAsync_v2`. This is what `cuda-copy-hist.bt`
  probes, and what the 16 MiB staging split at `hooks/driver_api.cpp:2453` applies to.
- **`kernel`** → a device kernel reads the pinned pool directly, so load-back appears as kernel
  launches and **not** as `cuMemcpy` at all.

Run `direct` first — it is the one the probes can see. If the tail shows on `direct` and vanishes on
`kernel`, it is in the copy path; if it follows both, it is not. `hicache-probe-000.yaml` (cache off)
is the natural third run if the tail tracks pool size.

## Runbook

Everything is in **`cedana-systems`** except the model fetch. One 8-GPU server at a time.

### 0. Prerequisites — check before burning a node

```bash
kubectl config current-context                       # confirm you are on the TEST cluster
kubectl get runtimeclass cedana                      # the cedana opt-in must exist
kubectl -n cedana-systems get sa cedana-tester       # the cedana-side pods need it
kubectl get nodes -L nvidia.com/gpu.product          # pick the B200 node, confirm it is idle
```

Does this image serve GLM-5.2, and are the hicache flag names right on this tag? Both are in the
header of `10-glm52-native.yaml`; run them now, not after a two-hour model load:

```bash
kubectl -n cedana-systems run glmchk --rm -it --restart=Never \
  --image=lmsysorg/sglang:v0.5.15.post1-cu129 -- \
  bash -c "python3 -m sglang.launch_server --help | grep -i hicache"
```

### 1. Volume and model

```bash
kubectl apply -f 00-model-volume.yaml                # once; skip if gip-models-ro already exists

# Only if GLM-5.2 is not already staged on the volume:
kubectl -n cedana-provisioning apply -f 01-model-fetch.yaml --dry-run=server
kubectl -n cedana-provisioning apply -f 01-model-fetch.yaml
kubectl -n cedana-provisioning logs -f job/ced2538-model-fetch
kubectl -n cedana-provisioning delete job ced2538-model-fetch
```

### 2. ConfigMaps

The scripts are mounted, not baked, so an edit is a `replace` and a pod restart rather than a
rebuild. Re-run the matching line after editing anything under `bpf/`, `watcher/` or `bench/`.

```bash
kubectl -n cedana-systems create configmap ced2538-bpf     --from-file=bpf/
kubectl -n cedana-systems create configmap ced2538-watcher --from-file=watcher/
kubectl -n cedana-systems create configmap ced2538-bench   --from-file=bench/

# after an edit:
kubectl -n cedana-systems create configmap ced2538-bpf --from-file=bpf/ \
  --dry-run=client -o yaml | kubectl -n cedana-systems replace -f -
```

### 3. A side — native

```bash
kubectl apply -n cedana-systems -f 10-glm52-native.yaml
kubectl -n cedana-systems get pod glm52-native -w          # Ready can take ~1-2 h on a cold volume
kubectl -n cedana-systems logs -f glm52-native | grep -E 'ced-2538|Capture|hierarchical|KV Cache'
```

Point the watcher and bench at the native server, then start them **in that order** — the watcher
must be attached before any load arrives, or the first burst is unobserved:

```bash
sed -i.bak 's/glm52-cedana/glm52-native/g' 30-watcher.yaml 20-bench-burst.yaml

kubectl apply -n cedana-systems -f 30-watcher.yaml
kubectl -n cedana-systems logs ced2538-watcher -c bpf | head -40     # MUST show the symbol check
kubectl -n cedana-systems logs ced2538-watcher -c snap | head

kubectl apply -n cedana-systems -f 20-bench-burst.yaml
kubectl -n cedana-systems logs -f job/ced2538-bench
```

`attach.sh`'s symbol check is not optional reading. A probe on a missing symbol attaches silently
and reports no events, which looks identical to "that path is never taken":

```
[attach] side=native
[attach] LIB=/proc/12345/root/usr/lib/x86_64-linux-gnu/libcuda.so.580.126.09
[attach] symbol check on ...:
  cuMemcpyDtoHAsync_v2         ok (1)
  cuMemcpyHtoDAsync_v2         ok (1)
  cuMemHostRegister            ok (1)
  cuModuleLoadData             ok (1)
```

Watch the live signal while it runs:

```bash
kubectl -n cedana-systems exec ced2538-watcher -c bpf -- \
  sh -c 'tail -f /out/cuda-copy-hist.*.log' | grep -E 'HOSTREG|SLOW-|16777216'
kubectl -n cedana-systems exec ced2538-watcher -c snap -- ls -t /out/snapshots | head
```

### 4. Collect and tear down the A side

Stop with `pkill -TERM`, never by deleting pods: bpftrace prints its cumulative counters only on a
clean shutdown, and the interceptor's TSC profile is written on SIGTERM only.

```bash
BENCH=$(kubectl -n cedana-systems get pod -l app=ced2538-bench -o name | cut -d/ -f2)
kubectl -n cedana-systems cp "$BENCH":/out/bench.jsonl ./out-native/bench.jsonl

kubectl -n cedana-systems exec ced2538-watcher -c bpf -- pkill -TERM -f attach.sh
sleep 5
kubectl -n cedana-systems cp ced2538-watcher:/out ./out-native -c snap

kubectl -n cedana-systems exec glm52-native -- pkill -TERM -f sglang.launch_server
kubectl -n cedana-systems logs glm52-native > ./out-native/server.log
kubectl -n cedana-systems delete pod glm52-native ced2538-watcher
kubectl -n cedana-systems delete job ced2538-bench
```

### 5. B side — cedana

Same node, same everything else:

```bash
sed -i.bak 's/glm52-native/glm52-cedana/g' 30-watcher.yaml 20-bench-burst.yaml

kubectl apply -n cedana-systems -f 11-glm52-cedana.yaml
kubectl -n cedana-systems get pod glm52-cedana -w
kubectl apply -n cedana-systems -f 30-watcher.yaml
kubectl -n cedana-systems logs ced2538-watcher -c bpf | head -40     # expect side=cedana now
kubectl apply -n cedana-systems -f 20-bench-burst.yaml
kubectl -n cedana-systems logs -f job/ced2538-bench
```

Collect as in step 4 into `./out-cedana`, plus the TSC profile the native side does not have:

```bash
kubectl -n cedana-systems exec glm52-cedana -- pkill -TERM -f sglang.launch_server
sleep 10
kubectl -n cedana-systems cp glm52-cedana:/logs/cedana ./out-cedana/tsc-profiles
```

### 6. Sweep the io-backend

```bash
sed -i 's/--hicache-io-backend direct/--hicache-io-backend kernel/' 10-glm52-native.yaml 11-glm52-cedana.yaml
# then repeat steps 3-5 into ./out-native-kernel and ./out-cedana-kernel
```

## Reading the output

Cheapest first — the top two cost nothing and could reframe everything:

1. **Registration failures in the cedana server log.** These are `SPDLOG_CRITICAL`, which release
   builds print to the application's stderr, so they are already in `kubectl logs` if they happen:
   ```bash
   grep -i 'cuMemHostRegister(' out-cedana/server.log
   ```
   Any hit means HiCache's pool is not a published region and `isHostMem()` is false for it.
2. **NCCL's own transport verdict:**
   ```bash
   grep -hE 'via (P2P|SHM|NET)' out-*/server.log | sort | uniq -c
   ```
   On one node with 8 B200s this should be P2P/IPC everywhere. `SHM` is a finding.
3. **`@copy_bytes`** in `cuda-copy-hist.*.log`. A spike at exactly `16777216` is the signature of
   `kMaxShmCopyBytes` chunking, reachable only when the host buffer is unregistered. `@copy_16m`
   counts them, and native cannot produce the spike at all.
4. **`@hostreg_fail` and `@hostreg_us`.** Any non-zero return is significant. ~1 s latencies point at
   the `otherMapper` retry loop (`host_mem.cpp:907-913`), which TP8's eight rank processes can reach.
5. **`@copy_us` minus `@drv_copy_us`** for the same size bucket — cedana's share vs the driver's.
6. **`snapshots/*-tail/` against `snapshots/*-baseline/`**: `pyspy-*.txt` for the Python frame,
   `kstack-*.txt` and `threads-*.txt` for kernel blocking, and `smaps_rollup-*` on both the rank and
   the worker — Pss ≈ Rss/2 on each means one shared pool counted twice, not allocated twice.
7. **`@modload_us` across the run.** Decaying over the burst rounds means JIT warm-up; persisting
   means it is not.

Every bench record, bpftrace line and snapshot carries both `CLOCK_MONOTONIC` and wall time, which
is the only thing that ties a `SLOW-COPY` line to the request that caused it.

**Validity checks before concluding anything:**

- `cached_tokens` on stage C re-sends. `≈ prompt_len` means it came from cache and load-back was
  measured. `≈ 0` means it was evicted past the host tier and the record must be dropped, not read
  as a slow load-back. Tune `C_FLOOD`, or switch `--hicache-write-policy` to `write_through`.
- Stage A must match between the two sides. If the floor already differs, this is not a tail.
- The symbol check must have passed on both sides.

## What we cannot set from here

The interceptor reads its env in the **application's** process, so `CEDANA_GPU_PROFILING_ENABLED`
and `CEDANA_GPU_LOG_DIR` go on the server pod and need no chart change.

Controller- and worker-side env (`CEDANA_ASYNC_LAUNCH`, `CEDANA_ASYNC_RING`, `CEDANA_RUNNER_SPIN_US`,
`CEDANA_POINTER_CACHE`, `CEDANA_PIN_CORES`, `CEDANA_GPU_MMAP_THRESHOLD`) reaches the worker through
the cedana daemon, and `cedana-helm/templates/helper-daemonset.yaml` templates every variable
explicitly with no `extraEnv` escape hatch:

```bash
kubectl -n cedana-systems set env ds/cedana-helper CEDANA_GPU_MMAP_THRESHOLD=1048576
```

That restarts the helper on every node it selects. Scope it with `daemonHelper.nodeSelector` first,
or add an `extraEnv` passthrough to the chart — worth doing anyway if this needs more than one knob.

## Care on a shared test cluster

- Two privileged `hostPID` containers with uprobes on a live process. The watcher is a Pod with pod
  affinity, not a DaemonSet, so it lands only on the server's node — keep it that way.
- `ALLOW_GDB=0`. Attaching gdb SIGSTOPs eight TP ranks mid-forward, which can stall the server and
  trip the NCCL watchdog into tearing the engine down. Expect to lose the run if you set it.
- `MAX_SNAPS=20` bounds the emptyDir. A tail storm with it raised can fill the node's disk.
- Stage C deliberately thrashes the host KV tier, and `--hicache-size 128` pins 128 GiB of host
  memory outside the pod cgroup. Do not run next to anything that cares about host memory there.
- `nodeName` is commented out in both servers. Pin both sides to the same node, and check nothing
  else is on it first.

## Open questions

- Does stock `lmsysorg/sglang:v0.5.15.post1-cu129` serve GLM-5.2, and does it carry sm_100 kernels?
  Production runs Together's private SMG build, and the in-repo B200 hicache probes used
  v0.5.20-cu130 — so this tag is older than both. Confirm before a long run.
- Is `zai-org/GLM-5.2` the right repo id? The GLM-5.3 manifests point at
  `togethercomputer/GLM-5.3-TQuark-C2P-GPTQ-NVFP4`, so the 5.2 equivalent may also be a private
  quantised build rather than the upstream repo.
- Production's actual hicache sizing and io-backend are unknown, so 128 GiB / `direct` is taken from
  the in-repo B200 manifests rather than from the reported deployment.
