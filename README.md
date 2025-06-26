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
--set cedanaConfig.cedanaUrl=$CEDANA_URL \
--set cedanaConfig.cedanaAuthToken=$CEDANA_AUTH_TOKEN

# alternatively, you can use the OCI repo
helm install cedana oci://registry-1.docker.io/cedana/cedana-helm --create-namespace -n cedana-system \
--set cedanaConfig.cedanaUrl=$CEDANA_URL \
--set cedanaConfig.cedanaAuthToken=$CEDANA_AUTH_TOKEN
```

### Configuration Options

#### Shared Memory (SHM) Configuration

For workloads that require large shared memory, you can optionally increase the `/dev/shm` size on all nodes:

```bash
# Enable SHM configuration with default 10G size
helm install cedana ./cedana-helm-charts/cedana-helm --create-namespace -n cedana-system \
--set cedanaConfig.cedanaUrl=$CEDANA_URL \
--set cedanaConfig.cedanaAuthToken=$CEDANA_AUTH_TOKEN \
--set shmConfig.enabled=true

# Customize SHM size (e.g., 20G)
helm install cedana ./cedana-helm-charts/cedana-helm --create-namespace -n cedana-system \
--set cedanaConfig.cedanaUrl=$CEDANA_URL \
--set cedanaConfig.cedanaAuthToken=$CEDANA_AUTH_TOKEN \
--set shmConfig.enabled=true \
--set shmConfig.size="20G"
```

Alternatively, you can apply the standalone SHM configuration:

```bash
kubectl apply -f cedana-helm-charts/shm-config.yaml
```

**Note**: The SHM configuration requires privileged access and will modify the host's `/etc/fstab` for persistence.

**Important**: The SHM configuration uses `/shm-scripts` mount path to avoid conflicts with the Cedana daemon's expected `/scripts/host` directory structure.

### Usage

See https://docs.cedana.ai/get-started/using-the-cedana-platform for usage instructions with the Cedana Platform!

### Security

If you want to use our tools, but have specific security requirements reach out and let us know
about it.

- Daemonset requires privilege escalation for daemon container, and it updates the host directly with
  required dependencies and our cedana-daemon application.
- Currently our controller requires access to all pods to be able to list, checkpoint and restore them.
- SHM configuration requires privileged access to modify host filesystem and mount points.

### Uninstallation

To uninstall, simply run:

```bash
helm uninstall cedana -n cedana-system
```

Once the uninstallers have completed, delete the namespace to clean up all resources:

```bash
kubectl delete namespace cedana-system
```
