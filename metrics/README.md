## Prometheus Install
Prometheus helm install installs the following components
- node-exporters daemonset
- kube-state-metrics deployment
- prometheus-server deployment

To install, run the following:
```
helm install prometheus oci://ghcr.io/prometheus-community/charts/prometheus -n prometheus --values ./prometheus/values.yml
```

Run the following to uninstall Prometheus:
```
helm uninstall prometheus -n prometheus
```

## Vector Installation
Vector collects Prometheus metrics, DCGM metrics, and Kubernetes pod logs, then exports them to S3.

### Prerequisites
Configure S3 access using one of these methods:

**Option A: IRSA (IAM Roles for Service Accounts) - Recommended for EKS**
1. Create an IAM role with S3 write permissions to your bucket
2. Update `vector/values.yml` with your IAM role ARN in `serviceAccount.annotations`
3. Ensure your EKS cluster has IRSA enabled

**Option B: Explicit AWS Credentials**
1. Create a Kubernetes secret with AWS credentials:
   ```bash
   kubectl create secret generic vector-aws-credentials \
     --from-literal=AWS_ACCESS_KEY_ID=<your-key> \
     --from-literal=AWS_SECRET_ACCESS_KEY=<your-secret> \
     -n prometheus
   ```
2. Uncomment the `env` section in `vector/values.yml`

### Install Vector
Vector runs as a DaemonSet to collect logs from all nodes:
```bash
helm install vector vector/vector --namespace prometheus --values ./vector/values.yml
```

### Data Organization in S3
- Metrics: `vector/metrics/date=YYYY-MM-DD/`
- Logs: `vector/logs/date=YYYY-MM-DD/` (gzip compressed)

### Uninstall
```bash
helm uninstall vector -n prometheus
```

## DCGM Exporter Installation

```
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm repo update
helm install dcgm-exporters gpu-helm-charts/dcgm-exporter --namespace prometheus
```

To uninstall dcgm-exporters
```
helm uninstall dcgm-exporters -n prometheus
```
