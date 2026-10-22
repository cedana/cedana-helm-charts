GLM-5.3 Dynamo P/D baseline — Cedana clean B200 cluster

Cluster: 4695a27d-222d-4434-8cc4-83f94f772ae0
Namespace: default
Topology: one TP8 prefill Pod on gpu-dp-ckck8-4pcmf,
one TP1/DP8/EP8 decode Pod on gpu-dp-ckck8-zl9zz,
and one Dynamo frontend + SMG Pod (no GPU).
The workers together occupy all 16 GPUs. Do not run this alongside another
full-node model workload.

Model: togethercomputer/GLM-5.3-TQuark-C2P-GPTQ-NVFP4
Revision: a1e9d28594bc905c89261ffc01fd0c4a8232252a
Image: 598726163780.dkr.ecr.us-west-2.amazonaws.com/smg@sha256:a81eebc35ed6581ca886e8f8912e97957b1101359a509f27d29e0d479f60e0de
Source image tag: glm52-v14-modelgt-drainhealth-098e21490-wp7-minp-925b191-vllm-a784b9b59-xgr026-smg-d0a5f112-maxping-cs3-b200-19c29-gtk5771dbb
The digest is the tag's linux/amd64 image manifest, preloaded and pinned on
both worker nodes. imagePullPolicy must remain Never.

Infrastructure already installed: Dynamo operator 1.2.1, etcd, and NATS
in dynamo-system. The baseline uses etcd discovery, TCP requests, ZMQ
events, and NIXL P-to-D KV transfer over the allocated InfiniBand devices.
No global Mooncake store, CS3 weight loader, Dynamo planner, or autoscaling
is enabled. This is a fixed 1P1D checkpoint/restore test baseline, not a
claim of production performance equivalence.

The YAML includes the ConfigMap and all three plain Pods. It can be created
with the tester kubeconfig; existing Pods must be deleted before changing
their command or args (the tester intentionally cannot patch Pods).

  kubectl --kubeconfig <tester.kubeconfig> create -f glm-5-3-dynamo-pd-1p1d-b200.yaml

If the baseline is already running, inspect it rather than creating copies:

  kubectl --kubeconfig <tester.kubeconfig> get pods -l together.ai/cedana-pd=glm53

For a local HTTP client, use the installer kubeconfig for port-forward:

  kubectl --kubeconfig <installer.kubeconfig> port-forward pod/cedana-glm53-pd-frontend 8990:8990

Model name for /v1/chat/completions: cedana-eval-glm53-pd

The model PVC hf-models-rwx is read-only. No HF/AWS/Together API credential
is required in the Pods. The existing default-deny egress remains in place;
the cluster's cedana-glm53-pd-egress policy allows only this labelled P/D
group, its internal etcd/NATS endpoints, and cluster DNS.

No runtimeClassName or CEDANA_CHECKPOINT identifier is baked into the
baseline. Establish the cold-start control first, then use Cedana's harness
to set runtimeClassName: cedana and the intended checkpoint/restore policy.
There are no liveness/startup probes that would kill a frozen checkpointed
process. Readiness may become false during a freeze.

Source recipe: togethercomputer/together-dynamo revision
1a4796f903984d601991fa14d7444fe73edc466a,
deploy/helm/charts/glm53-vllm-b200-3p3d-smg, with its 1P1D topology.
Adaptations: the downloaded HF snapshot; clean shared PVC; this cluster's
rdma/infiniband resource; no borrowed NUMA map; no global cache/CS3;
prefetch enabled explicitly for Weka; plain Pods with no projected token.

Validated on 2026-10-15 22:12:55 UTC: all three Pods Ready, two complete
HTTP 200 chat responses ("2 + 2 = 4" and "Paris"), and two additional
NIXL receives recorded on decode (6,196,224 bytes; 46 external prompt
tokens). NIXL failed-transfer and failed-notification counters stayed zero.
See validation.json for the full requests' responses and before/after
transfer counters. These are smoke checks, not a performance benchmark.
Runtime versions: ai-dynamo 1.4.0; vLLM 0.26.1rc1.dev1133+gf94666b60.

Checkpoint/restore itself has NOT been tested by this baseline setup.
This is GLM-5.3 (non-Flash) only; GLM-5.2 and GLM-5.3-Flash P/D are not
validated by this file. Do not substitute their weights or aggregated
engine images into it and assume compatibility.

The baseline is currently running and occupies both GPU workers.
Image pinning survives normal kubelet GC, not worker replacement/recreation.
