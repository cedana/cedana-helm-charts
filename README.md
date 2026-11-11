# Cedana Helm Charts

Repository with a collection of helm charts officially maintained to deploy Cedana, on a
Kubernetes cluster.

## cedana-helm

Chart for installing the controller and cedana daemon.

### Installation

Currently you can install the chart using this repo or you can use the oci repository.

```bash
# clone the repo
git clone https://github.com/cedana/cedana-helm-charts --depth 1

# install from local chart files
helm install cedana ./cedana-helm-charts/cedana-helm --create-namespace -n cedana-system \
--set config.url=$CEDANA_URL \
--set config.authToken=$CEDANA_AUTH_TOKEN \
--set config.clusterId=$CLUSTER_ID

# alternatively, you can use the OCI repo
helm install cedana oci://registry-1.docker.io/cedana/cedana-helm --create-namespace -n cedana-system \
--set config.url=$CEDANA_URL \
--set config.authToken=$CEDANA_AUTH_TOKEN \
--set config.clusterId=$CLUSTER_ID

# To install cedana on CPU only nodes
helm install cedana oci://registry-1.docker.io/cedana/cedana-helm --create-namespace -n cedana-system \
--set config.url=$CEDANA_URL \
--set config.authToken=$CEDANA_AUTH_TOKEN \
--set config.clusterId=$CLUSTER_ID
--set config.pluginsGpuVersion=none
```

`config.url`, `config.authToken`, and `config.clusterId` are required values.

### Inference in a Box

`cedana-helm/values-inference-box.yaml` adds the NVIDIA Dynamo platform (subchart, 1.6.2), the
dynamo-watcher with the inference controller, and the Switchyard gateway in `cedana-inference`.

Checkpoints go through CSX, so every GPU node needs the same shared directory (e.g. an NFS
mount) at `$SHARED_DIR`; on a single node any local directory works.

```bash
# managed cluster with GPU nodes and a device plugin
helm install cedana ./cedana-helm -n cedana-system --create-namespace \
  -f cedana-helm/values-inference-box.yaml \
  --set config.url=$CEDANA_URL --set config.authToken=$CEDANA_AUTH_TOKEN --set config.clusterId=$CLUSTER_ID \
  --set csx.nfsPath=$SHARED_DIR

# k3s (installs the device plugin and GPU feature discovery)
helm install cedana ./cedana-helm -n cedana-system --create-namespace \
  -f cedana-helm/values-inference-box.yaml -f cedana-helm/values-k3s.yaml \
  --set config.url=$CEDANA_URL --set config.authToken=$CEDANA_AUTH_TOKEN --set config.clusterId=$CLUSTER_ID \
  --set csx.nfsPath=$SHARED_DIR
```

k3s needs the NVIDIA container toolkit installed before it starts, and `--default-runtime nvidia`.
There the gateway listens on `http://<node IP>:30400`. Set `dynamo.global.grove.install=true` to
run DGDs through Grove.

Monitoring is part of the box (`clusterMetrics.enabled`): Prometheus scrapes cAdvisor,
kube-state-metrics, the DCGM exporter (GPU nodes) and the inference pods, and Vector ships the
series Cedana keeps, plus node host metrics, to `config.url` with `config.authToken`.

### Configuration Options

#### CRIU Device Plugins

The CRIU `nvidia-dev` and `infiniband` plugins are installed on every node by default.
They let CRIU checkpoint processes holding open `/dev/nvidia*` (e.g. NVML users) or
`/dev/infiniband/*` fds, and are inert on nodes without those devices. They follow
`config.pluginsCriuVersion`. To opt out (the plugin is removed from the node):

```bash
--set config.pluginsCriuNvidiaDev=false
--set config.pluginsCriuInfiniband=false
```

#### Restricting Cedana to Specific Nodes

By default the Cedana helper runs on every node in the cluster. To limit it to a
specific set of nodes, label those nodes and set a matching `nodeSelector`:

- Label the nodes you want Cedana to run on:
```bash
kubectl label nodes <node-name> cedana.ai/enabled=true
```

- Set the selector at install time (or in a values override):
```bash
helm install cedana ./cedana-helm \
  --set daemonHelper.nodeSelector."cedana\.ai/enabled"=true
```

## EKS Pod Identity for S3 checkpoints

The helper and health-check DaemonSets use a dedicated `cedana-helper` ServiceAccount. The chart does not install the EKS Pod Identity Agent, create IAM roles or policies, or create Pod Identity associations.

1. Install the EKS Pod Identity Agent add-on on the cluster.
2. Create an IAM role with a least-privilege policy for the checkpoint bucket. Typical permissions are `s3:ListBucket` on the bucket and `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload`, and multipart-list permissions on the checkpoint prefix.
3. Associate that role with the chart namespace and the `cedana-helper` ServiceAccount.
4. Install or upgrade with:

```yaml
config:
  checkpointDir: s3://my-checkpoint-bucket/cedana
  awsCredentialsMode: eksPodIdentity
  awsRegion: us-east-1

daemonHelper:
  serviceAccount:
    create: true
    name: cedana-helper
    automount: false
    annotations: {}
```

To use an externally managed ServiceAccount, set `daemonHelper.serviceAccount.create: false` and provide its non-empty `name`. Use `config.awsCredentialsMode: ambient` for IRSA, node roles, or other AWS default-chain credential sources. Static mode remains the default and continues to read `config.awsAccessKeyId` and `config.awsSecretAccessKey`.

The Cedana controller reads this same `nodeSelector` to decide which nodes to
manage, so it only applies the `cedana.ai/not-ready` taint to in-scope nodes.
Nodes outside the selector are never tainted, and if you narrow the selector
later, any existing `not-ready` taint is removed from the now-out-of-scope
nodes automatically. You do **not** need to configure the taint or its
toleration yourself — leave the built-in `cedana.ai/not-ready` toleration in
place; it is required for Cedana to function.

> This is the common case ("run Cedana on these nodes"). It does **not**
> prevent other workloads from also running on those nodes. To *dedicate*
> nodes exclusively to Cedana, see [Dedicated Node for Controller](#dedicated-node-for-controller)
> below, which additionally taints the node to repel other workloads.

#### Managing Node Taints Yourself

By default the controller manages a `cedana.ai/not-ready:NoSchedule` taint on each
node: it taints the node while Cedana is starting up there and removes the taint
once Cedana is ready, gating other workloads off the node until it can
checkpoint/restore. If you'd rather manage node readiness yourself (via your own
tooling, GitOps, or an admission controller), disable it:

```bash
helm install cedana ./cedana-helm \
  --set controllerManager.taintNodes=false
```

When disabled, the controller is completely hands-off — it will neither add nor
remove the `cedana.ai/not-ready` taint — and you are responsible for keeping
workloads off nodes until Cedana is ready. This is enabled (`true`) by default.

#### Disaggregated Prefill/Decode Worker Restores

To checkpoint and restore Dynamo/vLLM or SGLang prefill and decode workers, turn on the
controller's P/D disagg webhook:

```bash
helm install cedana ./cedana-helm \
  --set controllerManager.pdDisaggWebhook.enabled=true
```

The controller then creates the webhook's `cedana-pd-webhook` Service, its self-signed serving
cert (Secret `cedana-pd-webhook-pd-webhook-tls`) and the `cedana-pd-disagg`
MutatingWebhookConfiguration itself; there is nothing else to install. It sets up only pods
annotated `cedana.ai/pd-disagg` (see the Cedana docs). Setting it back to `false` removes the
webhook configuration and Service on the controller's next start. The RBAC it needs is part of
the chart either way. This is disabled (`false`) by default.

#### Dedicated Node for Controller

To run the Cedana Controller exclusively on a specific node:

- Taint the node to prevent general workloads:
```bash
kubectl taint node <node-name> dedicated=cedana-manager:NoSchedule
```

- Label the node to target it for scheduling:
```bash
kubectl label node <node-name> dedicated=cedana-manager
```

Helm values.yaml uses:
- tolerations to allow scheduling on tainted nodes.
- affinity to restrict placement to labeled nodes.

**Note**: Do not forget to uncomment the tolerations and affinity code blocks before performing the helm install.

#### Shared Memory (SHM) Configuration

For workloads that require large shared memory, you can optionally increase the `/dev/shm` size on all nodes:

```bash
# Enable SHM configuration with default 10G size
helm install cedana ./cedana-helm-charts/cedana-helm --create-namespace -n cedana-system \
--set config.url=$CEDANA_URL \
--set config.authToken=$CEDANA_AUTH_TOKEN \
--set config.clusterId=$CLUSTER_ID \
--set hostConfig.shmConfig.enabled=true

# Customize SHM size (e.g., 20G)
helm install cedana ./cedana-helm-charts/cedana-helm --create-namespace -n cedana-system \
--set config.url=$CEDANA_URL \
--set config.authToken=$CEDANA_AUTH_TOKEN \
--set config.clusterId=$CLUSTER_ID \
--set hostConfig.shmConfig.enabled=true \
--set hostConfig.shmConfig.size="20G"
```

### Usage

See https://docs.cedana.ai/get-started/using-the-cedana-platform for usage instructions with the Cedana Platform!

### Examples

You can find samples on the Cedana Platform or check out the [cedana-samples](https://github.com/cedana/cedana-samples) for example spec files.

### Security

If you want to use our tools, but have specific security requirements reach out and let us know
about it.

- Daemonset requires privilege escalation for daemon container, and it updates the host directly with
  required dependencies and our cedana-daemon application.
- Currently our controller requires access to all pods to be able to list, checkpoint and restore them.
- SHM configuration requires privileged access to modify host filesystem and mount points.

### Uninstallation

To uninstall completely, simply run:

```bash
helm uninstall cedana -n cedana-system
```
