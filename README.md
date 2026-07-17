# Cedana Helm Charts

Repository with a collection of helm charts officially maintained to deploy Cedana, on a
Kubernetes cluster.

## cedana-helm

Chart for installing the controller and cedana daemon.
Additionally it aims to provide optional deployments for services commonly used with our deployments such as Kueue.

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

### Configuration Options

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
