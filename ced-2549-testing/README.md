# CED-2549: concurrent KV transfers hang on the restored P/D pair

Reported on GLM-5.3, Dynamo 1P1D, B200. Single requests work. With **8 concurrent 5.8k-token
prompts, 2 return in 0.9 s and 6 hang**: decode's workers stop in `execute_model` right after
issuing NIXL reads, prefill later frees those blocks as *"retrieved by 0 remote worker(s)"*, and
after 300 s vLLM raises *"RPC call to execute_model timed out"* and the engine dies. Decode's GPU
workers log `cuMemRetainAllocationHandle -> 1: invalid argument` at every NIXL read — including
for the requests that **succeed**. The same deployments without Cedana, same nodes and config,
pass 8/8 and 2×16/16.

## This is vLLM + NIXL, not SGLang

Worth stating plainly, because it changes what is worth probing. The baseline runs `dynamo.vllm`
with `NixlConnector`:

| | prefill | decode |
| --- | --- | --- |
| pod | `cedana-glm53-pd-prefill` on `gpu-dp-ckck8-4pcmf` | `cedana-glm53-pd-decode` on `gpu-dp-ckck8-zl9zz` |
| parallelism | TP8 — one engine, 8 ranks | **DP8/EP8, TP1 — 8 independent engine processes** |
| connector | `kv_producer` | `kv_consumer` |

"Decode's TP workers" are 8 separate DP engines, one GPU each. One request lands on one engine and
works. Eight concurrent requests fan out across up to 8 engines, each issuing its own NIXL read
and its own side-channel handshake. **The concurrency axis is process-level fan-out against the
interceptor, not threads inside one engine** — which is why the watcher is two pods on two nodes,
and why the centrepiece probe is keyed on `(pid, tid, func)`.

## No cause is assumed, but two readings are testable immediately

**The reported error is probably a red herring, and that is cheap to prove.** `1` is
`CUDA_ERROR_INVALID_VALUE`, the *documented* return of `cuMemRetainAllocationHandle` for an
address not backed by a `cuMemCreate` (VMM) allocation. vLLM only uses its VMM allocator for sleep
mode, which is off here, so a plain `cudaMalloc`'d KV cache very likely returns `1` on native too
— and the report says it fires on the requests that succeed. `bpf/nixl-mem.bt` run on **both**
sides settles it, and `@dmabuf_fallback` is the row that matters either way: it pairs each retain
result with the `cuMemGetHandleForAddressRange` that followed it. `[1, 0]` means the fallback
rescued it and registration is fine; `[1, non-zero]` means there is no dmabuf fd at all.

**The hypothesis worth centring on is concurrency in the interception layer.** "Single works, 8
concurrent hang" plus "the error fires on successful requests too" points at 8 DP engines
round-tripping driver calls through one `cedana-gpu-controller`. `bpf/inflight.bt` answers it
directly, and in both directions: a call in flight for minutes, named with its pid/tid, means the
hang is in the driver path; nothing in flight while the engine is wedged means it is above the
driver — Python, the ZMQ side channel, or the notification path.

### Why dmabuf is on the critical path here at all

Decode sets `WITH_NVIDIA_PEERMEM=0` with `UCX_IB_GPU_DIRECT_RDMA=1`. Without `nv_peer_mem`, UCX
cannot hand the HCA a device pointer the old way — it must export the allocation as a dmabuf fd:

```
cuMemRetainAllocationHandle(&h, addr)              <- the call returning 1
  -> cuMemExportToShareableHandle(&fd, h, POSIX_FILE_DESCRIPTOR, 0)
  -> cuMemRelease(h)
fallback:
cuMemGetHandleForAddressRange(&fd, addr, len, CU_MEM_RANGE_HANDLE_TYPE_DMA_BUF_FD, 0)
```

and that fd then has to survive `ibv_reg_dmabuf_mr`, which is what `bpf/ibreg.bt` covers.
`UCX_MEMTYPE_CACHE=n` also means `cuPointerGetAttribute` is asked *per operation* rather than
cached, so it is both hot and load-bearing for which transport UCX picks.

## Files

```
cedana-pd-baseline-2026-10-15.zip   the vendor drop, kept as the provenance record
10-pd-native.yaml                   the zip's YAML, BYTE FOR BYTE. The native control
baseline-README.txt                 the vendor's notes, unzipped for grep
baseline-validation.json            their 2026-10-15 smoke check and NIXL counters
11-pd-cedana.patch.py               renders the cedana variant; only the two Pod docs are parsed
20-bench-pd.yaml                    the load generator Job
30-watcher.yaml                     TEMPLATED watcher; applied twice, once per node
bench/pd_bench.py                   the concurrency ladder; per-request JSONL, mono+wall
bpf/inflight.bt                     which driver call is stuck, on which thread, for how long
bpf/nixl-mem.bt                     the dmabuf export path and its return codes
bpf/ibreg.bt                        did the HCA accept the memory; did a QP go to ERR
watcher/attach.sh                   resolves probe targets, PROVES they attach, runs bpftrace
watcher/snapshot.sh                 hang-triggered stacks/sockets/IB; continuous IB sampler
lib.sh                              shared by both runners
run-native.sh                       the native baseline. RUN THIS FIRST
run-restored.sh                     cold cedana control, then checkpoint+restore the pair
collect.sh                          stop the producers in the right order, pull everything
```

`10-pd-native.yaml` is applied unmodified, and that is a property worth keeping:

```bash
unzip -p cedana-pd-baseline-2026-10-15.zip \
  cedana-pd-baseline-2026-10-15/glm-5-3-dynamo-pd-1p1d-b200.yaml | diff - 10-pd-native.yaml
```

The cedana variant is generated, never committed, and lands in `$OUT` so what ran is recorded.
`11-pd-cedana.patch.py` parses **only** the two Pod documents and passes the rest through as raw
text — document 1 is a ConfigMap carrying a 440-line `launch.py` that does node NIC selection, and
a YAML round trip would leave it *probably* identical rather than provably so.

## The experiment

| Run | What it establishes |
| --- | --- |
| `run-native.sh` | Does the baseline still pass 8/8 and 2×16/16 on these nodes today, and what do the driver return codes look like **without** interception? Without this there is no control. |
| `run-restored.sh` phase `control` | 8 concurrent against a **cold cedana pair, never checkpointed**. If this hangs, it is an interception bug and checkpoint/restore drops out of the repro entirely. |
| `run-restored.sh` phase `bench` | The ticket's actual subject: both pods checkpointed and restored, then the full ladder. |

The load ladder is `1x4,8x3,16x2` — concurrency × rounds. `c=1` is the control that **must** pass;
if it does not, the run is not about concurrency and everything downstream is noise. `c=8` is the
repro. `c=16` is the reported 2×16 case.

Every request gets a unique random salt, because prefill runs `--enable-prefix-caching` and
byte-identical prompts would be served from its prefix cache — a clean run would prove nothing.

The bench's per-request deadline is **120 s on purpose**, against vLLM's 300 s RPC timeout: the
hang is recorded, the runner's stall detector fires, and the watcher gets its snapshot while the
processes are still alive and dumpable.

### What distinguishes the possible failures

Three worlds, told apart by the cheapest instruments in the harness rather than by eBPF:

| Observation | Reading |
| --- | --- |
| decode `nixl_xfer_time_seconds_count` flat, `ib-decode.csv` `port_rcv_data` flat | the reads never reached the wire |
| counters climbing, still no completions | posted, never completed — look at `@qp_state` and the `ASYNC` lines |
| `xfer_count` climbs **and** prefill still expires blocks | the transfer worked and the notification was lost |

`nixl.csv` (written by the runner, which reaches the engines through the API-server proxy) and
`ib-*.csv` (written by each watcher) carry all of it.

## Runbook

### 0. Prerequisites

```bash
kubectl config current-context                     # confirm the TEST cluster
kubectl get runtimeclass cedana                    # the cedana opt-in must exist
kubectl get nodes -L nvidia.com/gpu.product        # both B200 nodes, and they must be idle
```

Two kubeconfigs, as the vendor's README describes them — the tester creates workload pods and
cannot patch them; the installer reaches `cedana-systems` and can proxy to pods:

```bash
export KUBECONFIG_TESTER=~/.kube/tester.kubeconfig
export KUBECONFIG_INSTALLER=~/.kube/installer.kubeconfig
```

`run-*.sh` refuse to start on a stale `$OUT`, create the three ConfigMaps described below, and
verify the engines actually serve `vllm:` metrics **before** any load — an empty `nixl.csv`
discovered at collect time would gut the run.

### 0.5 The ConfigMaps — the runners do this, you do not

Nothing is baked into an image: the eBPF scripts, the watcher scripts and the bench are all
mounted from ConfigMaps, so editing one is a `kubectl apply` and a pod restart rather than an
image rebuild. There is no egress here to pull a custom image anyway.

| ConfigMap | Namespace | From | Mounted into |
| --- | --- | --- | --- |
| `ced2549-bpf` | `cedana-systems` | `bpf/` | watcher `bpf` container at `/bpf` |
| `ced2549-watcher` | `cedana-systems` | `watcher/` | both watcher containers at `/watcher` |
| `ced2549-bench` | `default` | `bench/` | bench Job at `/bench` |

`preflight()` in `lib.sh` runs these on every invocation, so a local edit is always picked up:

```bash
ki create configmap ced2549-bpf     --from-file=bpf/     --dry-run=client -o yaml | ki apply -f -
ki create configmap ced2549-watcher --from-file=watcher/ --dry-run=client -o yaml | ki apply -f -
kt create configmap ced2549-bench   --from-file=bench/   --dry-run=client -o yaml | kt apply -f -
```

`create --dry-run=client -o yaml | apply -f -` rather than `create`, because `create` fails on the
second run and `replace` fails on the first. By hand, with the kubeconfigs spelled out:

```bash
kubectl --kubeconfig $KUBECONFIG_INSTALLER -n cedana-systems \
  create configmap ced2549-bpf --from-file=bpf/ --dry-run=client -o yaml | \
  kubectl --kubeconfig $KUBECONFIG_INSTALLER -n cedana-systems apply -f -

kubectl --kubeconfig $KUBECONFIG_INSTALLER -n cedana-systems \
  create configmap ced2549-watcher --from-file=watcher/ --dry-run=client -o yaml | \
  kubectl --kubeconfig $KUBECONFIG_INSTALLER -n cedana-systems apply -f -

kubectl --kubeconfig $KUBECONFIG_TESTER -n default \
  create configmap ced2549-bench --from-file=bench/ --dry-run=client -o yaml | \
  kubectl --kubeconfig $KUBECONFIG_TESTER -n default apply -f -
```

**Updating a ConfigMap does not affect a running watcher.** `attach.sh` reads the `.bt` files once
at startup, renders them with the resolved library paths, and hands the rendered copies to
bpftrace. A mid-run edit needs the pod recreated — and the rendered manifest is already in `$OUT`:

```bash
kubectl -n cedana-systems delete pod ced2549-watcher-decode
kubectl -n cedana-systems apply -f out-cedana/30-watcher-decode.yaml
```

### 0.75 Where things run, and what gets deleted

| | Namespace | Kubeconfig | Created by |
| --- | --- | --- | --- |
| ConfigMap + 3 engine pods + bench Job | `default` | tester | this folder |
| the 2 watcher pods | `cedana-systems` | installer | this folder |
| `hf-models-rwx` PVC (read-only, model already staged) | `default` | **pre-existing — not ours** |

`namespace: default` is the vendor's, not a choice: `10-pd-native.yaml` is applied byte for byte.
The watchers need privileged + `hostPID`, so they live in `cedana-systems`.

Unlike CED-2538 there is **no `00-model-volume.yaml` and no `01-model-fetch.yaml`** — this folder
creates no PV, no PVC and no model-fetch Job. The baseline mounts an existing `hf-models-rwx`
read-only, already staged, so there is nothing to provision and nothing to clean up.

Every delete in these scripts is **by exact pod name**; no script ever runs `delete -l`. The
watchers are Pods pinned with `nodeName`, not a DaemonSet, so the privileged hostPID uprobes land
on exactly the two nodes under test. `collect.sh` deletes nothing and does not kill the engines.

The one destructive step is `RESUME=0` recreating the three baseline pods. The vendor's README
says the baseline may already be running and occupies both GPU workers, so `guard_running_baseline`
refuses when any of the three is already Ready:

```
FAIL: 3 of the 3 baseline pods are already Ready, and RESUME=0 would delete them.
  RESUME=1 ./run-native.sh     use the running pods as they are (native runs only)
  FORCE=1  ./run-native.sh     delete and recreate them anyway
```

### 1. Native first

```bash
./run-native.sh                  # refuses if the baseline is already Ready; see above
RESUME=1 ./run-native.sh         # use the running baseline pods as they are
FORCE=1  ./run-native.sh         # delete and recreate them anyway
```

`RESUME=1` refuses to proceed if either engine pod carries `runtimeClassName`, so a cedana run
cannot be filed as the native control.

### 2. The cedana side

```bash
./run-restored.sh                # control, then checkpoint+restore the pair, then the ladder
SKIP_CONTROL=1 ./run-restored.sh # skip the cold control
RESUME=1 ./run-restored.sh       # cold pods already Ready; start at the control
RESUME=restore ./run-restored.sh # checkpoints already taken; start at the restore
```

The checkpoint dir must hold **two** engine pods:
`helm upgrade cedana ... --reuse-values --set config.checkpointDir=/scratch`.

### 3. Reading the output while it runs

`attach.sh`'s symbol check is not optional reading. A probe on a missing symbol attaches to nothing
and reports nothing, which is indistinguishable from "that path is never taken":

```
[attach] side=cedana
[attach] LIB=/proc/12345/root/usr/local/lib/libcuda.so.1
[attach] symbol check on ...:
  cuMemRetainAllocationHandle        ok (1)
  cuMemGetHandleForAddressRange      ok (1)
  ...
```

A `MISSING` line, or a `dropping that block` line, **is a finding** — it means the interceptor does
not export something the real driver does. The runners surface both rather than burying them.

Live signal:

```bash
kubectl -n cedana-systems exec ced2549-watcher-decode -c bpf -- \
  sh -c 'tail -f /var/tmp/ced2549/inflight.*.log' | grep -E 'SWEEP|SLOW'
```

An `@inflight` entry whose value sits far below its `SWEEP` line's `mono=` is a call that never
returned:

```
===== ced-2549 SWEEP mono=812934511000 wall=...
@inflight[1842, 1907, cuStreamSynchronize]: 812930002000          <- 4.5 ms old, normal
@inflight[1843, 1912, cuMemGetHandleForAddressRange]: 751002911000 <- 61 s old, STUCK
```

### 4. py-spy

There is no egress in this cluster, so `pip install py-spy` will fail and the Python frame — the
single most valuable artifact for a hang — would be missing from every snapshot. Side-load it
before the run:

```bash
kubectl -n cedana-systems cp ./py-spy ced2549-watcher-decode:/var/tmp/ced2549/py-spy -c snap
```

`snapshot.sh` says so loudly rather than producing quiet, useless snapshots.

### 4.5 Where the results land

`OUT` works as it did in CED-2538 — runs sit side by side instead of refusing to start:

```bash
OUT=out-native/run-1  ./run-native.sh
OUT=out-cedana/run-1  ./run-restored.sh
OUT=out-cedana/run-2  ./run-restored.sh     # a second attempt, run-1 untouched
```

Defaults are `out-native` and `out-cedana`. The two sides are deliberately symmetric, so
`diff <(ls out-native/run-1) <(ls out-cedana/run-1)` is short and the A/B lines up file for file.

```
out-cedana/run-1/
  run.txt                      what this run was: side, git commit, every knob, image digest
  nixl.csv                     both pods' vllm:nixl_* every 2 s, phase-tagged. THE discriminator
  stalls.txt                   one line per stall the sampler detected and snapshotted
  11-pd-cedana.yaml            the cedana variant as applied
  11-pd-cedana-restore.yaml    the same with CEDANA_CHECKPOINT_PATH on both pods
  20-bench-<tag>.yaml          each bench Job as applied
  30-watcher-{prefill,decode}.yaml
  checkpoint-action-{prefill,decode}.json    restore_path, size, timings
  post-restore-state.txt       pod IPs now, and NIXL/side-channel lines from the restored logs
  {prefill,decode}-cold.log    before the checkpoint
  {prefill,decode}-init.log    after the restore -- checked for cold-start fallback markers
  attach-{prefill,decode}.log  the symbol check. Read this before trusting any empty result
  bench-control-cold.{jsonl,log}   8 concurrent on the COLD cedana pair
  bench-restored.{jsonl,log}       the full ladder on the restored pair
  cedana-glm53-pd-{prefill,decode,frontend}.log
  metrics-final-{prefill,decode}.txt
  final-state.txt              pod state and decode's events at the end
  watcher-prefill/
  watcher-decode/
    ced2549/
      inflight.cedana.<ts>.log     the SWEEP lines and the still-in-flight map
      nixl-mem.cedana.<ts>.log     @ret, @dmabuf_fallback, @ptr_attr
      ibreg.cedana.<ts>.log        @dmabuf_reg, @qp_state, ASYNC lines
      *.rendered.bt                exactly what bpftrace ran, after block dropping
      ib-<role>.csv                IB port counters every 5 s
      manifest.txt
      snapshots/<ts>-<role>-<reason>/   py-spy, kernel stacks, threads, sockets, nvidia-smi
    attach.log  snapshot.log
```

The side is in every bpftrace filename (`inflight.cedana.*` against `inflight.native.*`), so the
two runs stay distinguishable even if the directories get merged.

### 5. Collect

`collect.sh` runs automatically at the end of each runner. The ordering is the point: bpftrace is
SIGTERMed **before** anything is copied, because `inflight.bt` deliberately does not clear
`@inflight` at exit — the last thing it prints is the set of calls still in flight, which on a hung
run is the entire result. A pod delete loses it. The engines are deliberately **not** killed: a
wedged process is evidence.

## Known limitations

- **bpftrace must exist on the nodes.** The image has none and there is no egress, so `attach.sh`
  falls back to the host's binary through `nsenter`. That is also why `/var/tmp/ced2549` is a
  hostPath mounted at the same path inside the container — a bpftrace in the host mount namespace
  cannot see an emptyDir.
- **The bench pod needs the `together.ai/cedana-pd=glm53` label** to get egress at all under this
  cluster's default-deny policy. If it still cannot connect, run `bench/pd_bench.py` from the
  operator's machine over `kubectl port-forward` instead; the manifest documents it.
- **`inflight.bt` excludes `cuLaunch*`** — far and away the hottest call, and an indefinitely
  blocked launch would surface as a stuck `cuStreamSynchronize` anyway. Widening to `cu*` is a
  one-line edit, at single-digit percent overhead on the engine.
- **No `for` loop over maps.** bpftrace only grew map iteration in 0.20 and these nodes may have
  0.14.x, so the sweep prints its own clock and then the whole map instead of scanning it.
