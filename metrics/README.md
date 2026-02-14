# Cedana Monitoring Stack

## Quickstart

Run these commands to set up the full monitoring stack in the `cedana-monitoring` namespace.

**Prerequisites:**
- kubectl configured for your cluster
- Helm 3.x installed
- Cedana API credentials (auth token and cluster ID)

```bash
# Set your environment variables
export CEDANA_URL="https://api.cedana.ai"       # Cedana API URL
export CEDANA_AUTH_TOKEN="your-auth-token"      # Your Cedana auth token
export CLUSTER_ID="your-cluster-uuid"           # Your cluster UUID from Cedana
export S3_BUCKET="your-s3-bucket"               # S3 bucket for metrics/logs (provided by Cedana)
export AWS_REGION="us-east-1"                   # Your AWS region

# Add helm repos
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add vector https://helm.vector.dev
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm repo update

# 1. Install Prometheus (node-exporter, kube-state-metrics, prometheus-server)
helm upgrade -i prometheus prometheus-community/prometheus \
  -n cedana-monitoring --create-namespace \
  --values ./prometheus/values.yml

# 2. Create Cedana credentials secret (for automatic STS credential refresh)
kubectl create secret generic cedana-credentials \
  -n cedana-monitoring \
  --from-literal=authToken="${CEDANA_AUTH_TOKEN}" \
  --from-literal=clusterId="${CLUSTER_ID}" \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. Install Vector with cred-refresher sidecar (automatic S3 credential management)
helm upgrade -i vector vector/vector \
  -n cedana-monitoring \
  --values ./vector/values.yml \
  --set "env[0].value=${CEDANA_URL}" \
  --set "extraContainers[0].env[0].value=${CEDANA_URL}" \
  --set "customConfig.sinks.s3_sink.bucket=${S3_BUCKET}" \
  --set "customConfig.sinks.s3_sink.region=${AWS_REGION}" \
  --set 'customConfig.sinks.s3_sink.key_prefix=vector/data/{{ "{{" }} tags.ts {{ "}}" }}/'

# 4. Install Kubernetes Event Exporter (captures pod termination events for efficiency tracking)
kubectl apply -f ./event-exporter/deploy.yaml

# 5. Install DCGM Exporter (GPU metrics - REQUIRED for GPU clusters)
# This enables GPU utilization, memory, temperature, and power metrics in the Cedana UI
helm upgrade -i dcgm-exporters gpu-helm-charts/dcgm-exporter \
  -n cedana-monitoring
```

**Verify installation:**
```bash
kubectl get pods -n cedana-monitoring
```

---

## Prometheus Install
Prometheus helm install installs the following components
- node-exporters daemonset
- kube-state-metrics deployment
- prometheus-server deployment

To install, run the following:
```
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade -i prometheus prometheus-community/prometheus -n cedana-monitoring --create-namespace --values ./prometheus/values.yml
```

Run the following to uninstall Prometheus:
```
helm uninstall prometheus -n cedana-monitoring
```

## Vector Installation

Vector collects Prometheus metrics and pushes them to Cedana's S3 bucket. The monitoring stack uses **automatic STS credential refresh** via a sidecar container, eliminating the need for long-lived AWS credentials.

### How Credential Refresh Works

1. A `cred-refresher` sidecar runs alongside Vector in each pod
2. The sidecar authenticates with Cedana's API using your auth token
3. Cedana issues temporary AWS STS credentials (1-hour validity)
4. Credentials are automatically refreshed every 45 minutes
5. Vector reads credentials from a shared file mounted at `/credentials/aws-credentials`

### Required Secrets

Create a Kubernetes secret with your Cedana credentials:
```bash
kubectl create secret generic cedana-credentials \
  -n cedana-monitoring \
  --from-literal=authToken="YOUR_CEDANA_AUTH_TOKEN" \
  --from-literal=clusterId="YOUR_CLUSTER_UUID"
```

### Installation

```bash
helm repo add vector https://helm.vector.dev
helm repo update

# Install Vector with cred-refresher sidecar
helm upgrade -i vector vector/vector --namespace cedana-monitoring --create-namespace \
  --values ./vector/values.yml \
  --set "env[0].value=https://api.cedana.ai" \
  --set "extraContainers[0].env[0].value=https://api.cedana.ai" \
  --set "customConfig.sinks.s3_sink.bucket=YOUR_S3_BUCKET" \
  --set "customConfig.sinks.s3_sink.region=YOUR_AWS_REGION" \
  --set 'customConfig.sinks.s3_sink.key_prefix=vector/data/{{ "{{" }} tags.ts {{ "}}" }}/'
```

### Verifying Credential Refresh

Check the cred-refresher sidecar logs:
```bash
kubectl logs -n cedana-monitoring -l app.kubernetes.io/name=vector -c cred-refresher
```

You should see output like:
```
Starting credentials refresher
  Cedana URL: https://api.cedana.ai
  Cluster ID: abc123-...
  Refresh Interval: 45m
Credentials written successfully (expires: 2024-01-01T12:00:00Z, bucket: cedana-metrics, prefix: org-xxx/v2/vector/data)
```

### Manual AWS Credentials (Legacy)

If you prefer to use static AWS credentials instead of STS refresh, you can:
1. Remove the `extraContainers` section from values.yml
2. Create the old-style secret and update env vars:
```bash
kubectl create secret generic vector-aws-credentials \
  -n cedana-monitoring \
  --from-literal=awsAccessKeyId="YOUR_AWS_ACCESS_KEY_ID" \
  --from-literal=awsSecretAccessKey="YOUR_AWS_SECRET_ACCESS_KEY"
```

To uninstall vector:
```
helm uninstall vector -n cedana-monitoring
```

## Kubernetes Event Exporter Installation

The Kubernetes Event Exporter captures cluster events (pod terminations, preemptions, evictions, OOM kills) and exposes them as Prometheus metrics. This enables Cedana to track job efficiency and compute time saved through checkpoint/restore.

Uses the upstream [resmoio/kubernetes-event-exporter](https://github.com/resmoio/kubernetes-event-exporter) image.

```bash
kubectl apply -f ./event-exporter/deploy.yaml
```

The event exporter exposes metrics on port 2112, which Vector scrapes and forwards to S3.

Key metrics captured:
- `event_exporter_events_sent` - Total events processed
- `event_exporter_events_discarded` - Events older than maxEventAgeSeconds
- Pod termination events (reason: Killing, Preempting, Evicted, OOMKilling)
- Job failure events (BackoffLimitExceeded, DeadlineExceeded)

To uninstall:
```bash
kubectl delete -f ./event-exporter/deploy.yaml
```

## DCGM Exporter Installation (Required for GPU Metrics)

DCGM (Data Center GPU Manager) exporter is **required** for GPU metrics in the Cedana UI. It provides:
- GPU utilization percentage
- GPU memory usage (used/free)
- GPU temperature
- Power consumption

```bash
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm repo update
helm upgrade -i dcgm-exporters gpu-helm-charts/dcgm-exporter \
  -n cedana-monitoring --create-namespace
```

**Note**: DCGM exporter requires NVIDIA GPUs with DCGM drivers installed on the nodes. It will only run on nodes with GPUs.

Vector scrapes DCGM metrics from `dcgm-exporters.cedana-monitoring.svc.cluster.local:9400/metrics` and forwards them to S3 for ClickHouse ingestion.

To uninstall dcgm-exporters:
```bash
helm uninstall dcgm-exporters -n cedana-monitoring
```
