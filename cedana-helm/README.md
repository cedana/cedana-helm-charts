# Cedana Helm Chart

Official Helm chart for deploying Cedana on Kubernetes clusters.

## Features

- **Checkpoint/Restore**: Automatic checkpoint and restore for Kubernetes workloads
- **GPU Support**: Full GPU state checkpoint/restore with CUDA support
- **Event-Driven**: RabbitMQ integration for orchestrated checkpoints
- **File-Based Triggers**: Support for Dynamo-style checkpoint triggers via file watching
- **Storage Options**: Cedana-managed, S3, or local storage
- **High Performance**: Parallel streaming with LZ4 compression

## Installation

```bash
# Add Cedana Helm repository
helm repo add cedana https://charts.cedana.ai
helm repo update

# Install with default values
helm install cedana cedana/cedana-helm \
  --set config.authToken=<your-token> \
  --set config.url=https://sandbox.cedana.ai \
  --set config.clusterId=<cluster-id>
```

## Configuration

### Basic Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `config.authToken` | Cedana authentication token | Required |
| `config.url` | Cedana propagator URL | Required |
| `config.clusterId` | Cluster identifier | Required |
| `config.checkpointDir` | Checkpoint storage directory | `cedana://` |
| `config.metrics` | Enable metrics | `true` |
| `config.profiling` | Enable profiling | `true` |

### File Watching (Dynamo Integration)

Enable file-based checkpoint triggers for frameworks like Dynamo (vLLM, SGLang):

```yaml
config:
  fileWatching:
    enabled: true
    pollInterval: "1s"
    triggers:
      - path: "/tmp/ready-for-checkpoint"
        action: "checkpoint"
        onSuccess: "SIGUSR1"
        onRestore: "SIGCONT"
        onFailure: "SIGKILL"
```

**How it works:**
1. Worker writes `/tmp/ready-for-checkpoint` file
2. Cedana detects file (polling every 1s)
3. Checkpoint performed automatically
4. `SIGUSR1` signal sent on completion
5. Worker exits gracefully

**Supported signals:** `SIGUSR1`, `SIGUSR2`, `SIGCONT`, `SIGTERM`, `SIGKILL`, `SIGHUP`

### GPU Configuration

```yaml
config:
  gpuPoolSize: 2 # Number of warm GPU controllers
  gpuShmSize: "8589934592" # 8 GiB shared memory
  gpuLdLibPath: /run/nvidia/driver/usr/lib/x86_64-linux-gnu

daemonHelper:
  nodeSelector:
    nvidia.com/gpu: "true"
  tolerations:
    - key: "nvidia.com/gpu"
      operator: "Exists"
      effect: "NoSchedule"
```

### Storage Options

**Cedana-managed (recommended):**
```yaml
config:
  checkpointDir: "cedana://"
```

**S3:**
```yaml
config:
  checkpointDir: "s3://my-bucket/checkpoints"
  awsAccessKeyId: "..."
  awsSecretAccessKey: "..."
  awsRegion: "us-west-2"
```

**Local:**
```yaml
config:
  checkpointDir: "/var/lib/cedana/checkpoints"
```

## Examples

### Dynamo (vLLM/SGLang) Integration

Use the provided example values:

```bash
helm install cedana cedana-helm/ -f cedana-helm/values-dynamo.yaml \
  --set config.authToken=<your-token> \
  --set config.clusterId=<cluster-id>
```

Or customize:

```yaml
# custom-values.yaml
config:
  authToken: "your-token"
  clusterId: "my-cluster"
  checkpointDir: "/checkpoints"

  fileWatching:
    enabled: true
    pollInterval: "1s"
    triggers:
      - path: "/tmp/ready-for-checkpoint"
        action: "checkpoint"
        onSuccess: "SIGUSR1"
        onRestore: "SIGCONT"
        onFailure: "SIGKILL"

daemonHelper:
  nodeSelector:
    nvidia.com/gpu: "true"

hostConfig:
  shmConfig:
    enabled: true
    size: 20G
```

```bash
helm install cedana cedana-helm/ -f custom-values.yaml
```

### High-Performance Setup

```yaml
config:
  checkpointDir: "cedana://"
  checkpointStreams: 8 # 8 parallel streams
  checkpointCompression: lz4 # Fast compression
  checkpointAsync: true # Background compression/upload

  gpuPoolSize: 4 # Keep 4 GPU controllers warm
```

## Verification

```bash
# Check DaemonSet status
kubectl get daemonset cedana-helper

# View logs
kubectl logs -l app=cedana-helper -f

# Test checkpoint (if using file watching)
kubectl exec -it <pod> -- sh -c "echo ready > /tmp/ready-for-checkpoint"
kubectl logs -l app=cedana-helper | grep "checkpoint complete"
```

## Troubleshooting

**DaemonSet not starting:**
```bash
kubectl describe daemonset cedana-helper
kubectl get configmap cedana-config -o yaml
```

**File watcher not detecting triggers:**
```bash
# Check config
kubectl get configmap cedana-config -o yaml | grep file-watching

# Check logs
kubectl logs -l app=cedana-helper | grep "file watcher"
```

**Checkpoint failures:**
```bash
# Daemon logs
kubectl exec -it <cedana-helper-pod> -- journalctl -u cedana -f

# Check storage
kubectl exec -it <cedana-helper-pod> -- ls -la /checkpoints
```

## Uninstallation

```bash
helm uninstall cedana
```

## Documentation

- [Cedana Documentation](https://github.com/cedana/cedana)
- [File Watcher Guide](https://github.com/cedana/cedana/tree/main/pkg/filewatcher)
- [API Reference](https://github.com/cedana/cedana/tree/main/api)

## Support

- GitHub Issues: https://github.com/cedana/cedana/issues
- Email: support@cedana.ai
