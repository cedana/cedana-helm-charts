# CED-2575: NCCL initialises without one GPU's NVLink on a cedana cold start

On a **full engine cold start under cedana**, GLM-5.2 (SMG/SGLang, TP8, 8×B200) can initialise NCCL
with one GPU's NVLink missing — GPU 3 on 2026-11-03. That one gap degrades the whole topology
search: 4 channels instead of 32, SHM hops, 0 NVLS channels. Init completes and the engine serves,
but large all-reduces run ~2.5× slower. Cold start only; a restore inherits whatever the cold start
decided.

Pointing `NCCL_TOPO_FILE` at a topology XML dumped from a **native** run made three cedana cold
starts come up healthy. That is the workaround. This harness is for finding out *what* goes wrong,
*why* the XML sidesteps it, and what the real fix is.

## Where the gap can come from

NCCL does not ask the driver about NVLink. It asks **NVML**, per GPU, per link
(`graph/xml.cc`, `ncclTopoGetXmlFromGpu`):

```
for l in 0..17:
    nvmlDeviceGetNvLinkCapability(dev, l, P2P_SUPPORTED)   -> error or 0  => continue
    nvmlDeviceGetNvLinkState(dev, l)                       -> inactive    => continue
    nvmlDeviceGetNvLinkRemotePciInfo_v2(dev, l)            -> error       => continue
    add <nvlink target=… count=…> under <gpu>
```

Every `continue` is silent. A GPU whose 18 links all fail or read inactive gets no `<nvlink>`
children, so in the graph it reaches the switch only through PCIe, and the search degrades exactly
as reported. **`NCCL_TOPO_FILE` skips this loop whenever the XML already carries `<nvlink>`
children** — that is the whole mechanism of the workaround, and why it says nothing about the
cause.

So the question is why, under cedana and only sometimes, NVML in a rank process answers "no
links" for one GPU. The candidates the instrumentation separates:

| # | Candidate | What would show it |
| --- | --- | --- |
| 1 | **Timing**: a GPU is asked about its links before anything has initialised it, and the links are still training. Native initialises all 8 GPUs in the ranks themselves before NCCL runs; under cedana the worker does it, on its own schedule. | `NVL-STATE … active=0` for one bus id in `nvlink.bt`, with that GPU's `WORKER-CTX` in `worker.bt` *later* than the question; or `NVRM`/`NVLink` lines in `kmsg.log` at that moment |
| 2 | **Wrong device**: the interceptor answers `cuDeviceGetPCIBusId` for ordinal N with a bus id that is not the GPU NVML calls N. The graph is then built around the wrong device. | `BUSID` lines in `transport.bt` vs `WORKER-BUSID` in `worker.bt` vs the `@bus` table in `nvlink.bt` |
| 3 | **NVML is not the real NVML** in the rank, or cannot reach the device. | `attach.sh` logs whether the rank's `libnvidia-ml` is the host driver's; `NVL-* ret≠0`; `OPEN /dev/nvidia* ret<0` |
| 4 | **Sysfs**: NCCL reads `/sys/class/pci_bus` and `/sys/bus/pci` for the same GPUs; a path missing in the container changes the node, not the links. | `OPEN /sys/… ret=-2` in `nvlink.bt`; the XML itself |

The fix follows from which one it is: for (1) the cedana worker (or the interceptor's `cuInit`)
should bring up every visible GPU before releasing the ranks, or NCCL's answer should be retried
while links train; for (2) the interceptor's ordinal→bus-id mapping; for (3)/(4) what the cedana
runtime mounts into the pod. All of those are cedana-side changes rather than an env var every
customer has to know about.

## Files

```
00-model-volume.yaml     PV + PVC for the Weka model view, in cedana-systems (from CED-2538)
01-model-fetch.yaml      stage the model if it is not on the volume (needs an NVFP4 export)
10-glm52-native.yaml     SMG serve, GLM-5.2 TP8, native                  — the control
11-glm52-cedana.yaml     the same + runtimeClassName: cedana             — the case (generated from 10)
30-watcher.yaml          privileged hostPID watcher: bpftrace + kernel log + nvidia-smi snapshots
bpf/nvlink.bt            every NVML NVLink answer NCCL gets, with timestamps; /dev and sysfs opens
bpf/worker.bt            when the cedana worker first initialised each GPU (host libcuda)
bpf/transport.bt         what the ranks' driver library was asked: bus ids, P2P, IPC, comm init
watcher/attach.sh        attaches to host libraries before the server exists, the rest when ranks appear
watcher/nvlink-watch.sh  kmsg from boot onward; nvidia-smi nvlink/topo on request (never before Ready)
lib.sh                   shared by both runners
render.py                per-run manifest rewrite: node, image, SIDE, restore path, NCCL_TOPO_FILE
nccl-verdict.py          HEALTHY/DEGRADED from a server log, the dumped XML, or the watcher output
run-cedana.sh            COLD-START, or cold start + checkpoint + restore
run-native.sh            the control, and the source of nccl-topo.xml
```

## Runbook

Everything is in `cedana-systems`, pinned to `gpu-dp-ckck8-zl9zz` (`NODE=` to move). One 8-GPU
pod at a time. The runners create the ConfigMaps from `bpf/` and `watcher/` on every start, so an
edit there is just a re-run.

```bash
kubectl config current-context                  # the TEST cluster
kubectl get runtimeclass cedana
kubectl -n cedana-systems get pvc hf-models-rwx  # Bound, or apply 00-model-volume.yaml
```

The image is `lmsysorg/sglang:v0.5.15.post1-cu129`, as in CED-2538 (`IMAGE=` to override). `MODEL_GLOB` in the manifests picks the Hub snapshot under
`/data/modelpreload/huggingface` and links it to `/data/model`, Together's path.

### 1. The case: cedana cold start, no checkpoint

```bash
OUT=out-cedana/run-1 ./run-cedana.sh COLD-START
```

In order: watcher up and `watcher ready` (stage 1 probes on the host's `libnvidia-ml` and
`libcuda`), server applied, ranks appear (stage 2 probes on their driver library), Ready,
`nvidia-smi` snapshot, server log + NCCL dumps copied, verdict printed, watcher stopped with
SIGTERM and copied, both pods deleted. `KEEP=1` leaves them up.

### 2. The control, and the workaround's input

```bash
OUT=out-native/run-1 ./run-native.sh
TOPO_FILE=out-native/run-1/nccl-topo.xml OUT=out-cedana/run-2 ./run-cedana.sh COLD-START
```

The second line is the workaround as a controlled run: the native XML mounted from a ConfigMap and
`NCCL_TOPO_FILE` set on the server. Its `nvlink.bt` output still records what NVML would have said,
so the two cedana runs can be compared answer for answer.

### 3. With checkpoint/restore

```bash
OUT=out-cedana/run-3 ./run-cedana.sh
```

Same cold start, then checkpoint → restore → `server-init.log` checked for load markers. Needs
`config.checkpointDir=/scratch` on the chart. `RESUME=1` / `RESUME=restore` as before.

## Reading the output

`$OUT/` after a run:

```
nccl-verdict-cold.txt   HEALTHY / DEGRADED, with why: channels per rank, rank 0's path matrix
                        (which GPU is not NVL to its peers), transport per hop, NVLS lines,
                        WARNs, and each GPU's <nvlink> children from the dumped XML
nccl-topo.xml           NCCL's detected topology (rank 0). THE artefact: diff native vs cedana
nccl-graph.xml          the channel graphs searched on it
server-cold.log         NCCL_DEBUG=INFO, every subsystem but COLL, timestamped
watcher/nvlink.*.log    NVL-CAP / NVL-STATE / NVL-REMOTE per link, OPEN lines, @bus table at END
watcher/worker.*.log    WORKER-INIT / WORKER-CTX / WORKER-BUSID with timestamps
watcher/transport.*.log BUSID / CANP2P / PEER-FAIL / IPC-FAIL / NCCL-INIT
watcher/kmsg.log        the kernel log; grep -iE 'nvrm|nvlink|xid'
watcher/nvlink/         nvidia-smi nvlink -s, topo -m, -q, taken after Ready
watcher-summary.txt     nccl-verdict.py --watcher: per-GPU link answers, first time asked
attach.log              which library each script attached to, symbol checks, side detection
```

Cheapest first:

1. `nccl-verdict-cold.txt` — is it DEGRADED, and which GPU. On any old log too:
   `python3 nccl-verdict.py path/to/server.log`.
2. `diff out-native/run-1/nccl-topo.xml out-cedana/run-1/nccl-topo.xml` — the missing `<nvlink>`
   children, by bus id.
3. `grep NVL-STATE watcher/nvlink.*.log | grep active=0` — which bus id, from which pid, at what
   `wall=`; then the same bus id's `WORKER-CTX` time in `worker.*.log` and anything in `kmsg.log`
   around it. That is candidate 1 settled either way.
4. `grep BUSID watcher/transport.*.log` against `grep WORKER-BUSID watcher/worker.*.log` and the
   `@bus` table at the end of `nvlink.*.log` — candidate 2.
5. `attach.log`: `rank libnvidia-ml:` should be the host driver's file, and no `MISSING`.

Every bpftrace line carries `mono=` (boot ns, the clock `kmsg.log` uses in µs) and `wall=` (the
clock the NCCL log lines are stamped with), which is what joins them.

## Care on a shared cluster

- The watcher is a privileged `hostPID` pod with uprobes on a live process, pinned to one node.
  Keep it a Pod.
- `PRE_SNAP=0`: nothing queries `nvidia-smi` before the server is Ready. With persistence mode
  off, `nvidia-smi` attaches every GPU, which could train the very link under investigation.
- `--hicache-size 128` pins 128 GiB of host memory outside the pod cgroup.
