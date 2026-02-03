# Cedana Monitoring Stack

## Quickstart

Run these commands to set up the full monitoring stack in the `cedana-monitoring` namespace.

**Prerequisites:**
- kubectl configured for your cluster
- Helm 3.x installed
- AWS credentials configured (for S3 access)

```bash
# Set your environment variables
export CEDANA_URL="your-cluster.cedana.ai/v2"  # Your cluster's unique identifier
export S3_BUCKET="your-s3-bucket"               # S3 bucket for metrics/logs
export AWS_REGION="us-east-1"                   # Your AWS region
export AWS_ACCESS_KEY_ID="your-access-key"      # AWS access key with S3 write permissions
export AWS_SECRET_ACCESS_KEY="your-secret-key"  # AWS secret access key

# Add helm repos
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add vector https://helm.vector.dev
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm repo update

# 1. Install Prometheus (node-exporter, kube-state-metrics, prometheus-server)
helm upgrade -i prometheus prometheus-community/prometheus \
  -n cedana-monitoring --create-namespace \
  --values ./prometheus/values.yml

# 2. Create AWS credentials secret for Vector
kubectl create secret generic vector-aws-credentials \
  -n cedana-monitoring \
  --from-literal=awsAccessKeyId="${AWS_ACCESS_KEY_ID}" \
  --from-literal=awsSecretAccessKey="${AWS_SECRET_ACCESS_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. Install Vector (metrics & logs collection to S3)
helm upgrade -i vector vector/vector \
  -n cedana-monitoring \
  --values ./vector/values.yml \
  --set "env[0].value=${CEDANA_URL}" \
  --set "customConfig.sinks.s3_sink.bucket=${S3_BUCKET}" \
  --set "customConfig.sinks.s3_sink.region=${AWS_REGION}" \
  --set "customConfig.sinks.s3_sink.key_prefix=${CEDANA_URL}/vector/data/date=%Y-%m-%d/hour=%H/minute=%M/" \
  --set "customConfig.sinks.s3_logs_sink.bucket=${S3_BUCKET}" \
  --set "customConfig.sinks.s3_logs_sink.region=${AWS_REGION}" \
  --set "customConfig.sinks.s3_logs_sink.key_prefix=${CEDANA_URL}/vector/logs/date=%Y-%m-%d/hour=%H/minute=%M/"

# 3. Install DCGM Exporter (GPU metrics - optional, only if you have NVIDIA GPUs)
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
Vector will help us push the scraped prometheus metrics and logs to our remote s3 bucket. You will have to give pod identity access to vector service account for the s3 access.

**IMPORTANT**: Set the `CEDANA_URL` environment variable in `./vector/values.yml` to enable multi-tenant data isolation. This prefixes all S3 paths with your cluster's unique identifier.

To specify the AWS credentials being used for the s3 bucket, refer to secrets section of `./vector/values.yml`
```yaml
# Set CEDANA_URL to your cluster's unique identifier
env:
  - name: CEDANA_URL
    value: "customer-name.cedana.ai/v2" # REQUIRED: Set this to your cluster's CEDANA_URL value

# Create a Secret resource for Vector to use.
secrets:
  # secrets.generic -- Each Key/Value will be added to the Secret's data key, each value should be raw and NOT base64
  # encoded. Any secrets can be provided here. It's commonly used for credentials and other access related values.
  # **NOTE: Don't commit unencrypted secrets to git!**
  generic: {}
    # my_variable: "my-secret-value"
    # datadog_api_key: "api-key"
    # awsAccessKeyId: "access-key"
    # awsSecretAccessKey: "secret-access-key"
```

The S3 bucket, region, and CEDANA_URL prefix must be set at deployment time using `--set` flags (see installation command below). While you can edit these values directly in `./vector/values.yml`, it's recommended to use `--set` to avoid committing sensitive configuration to git.

**Note**: The `bucket`, `region`, and `key_prefix` values in `values.yml` are intentionally left empty as placeholders. They will be overridden during helm installation with the `--set` flags.

Example configuration structure in `./vector/values.yml`:
```yaml
customConfig:
  sinks:
    s3_sink:
      type: aws_s3
      bucket: ""  # Will be set via --set customConfig.sinks.s3_sink.bucket
      region: ""  # Will be set via --set customConfig.sinks.s3_sink.region
      key_prefix: "vector/data/date=%Y-%m-%d/hour=%H/minute=%M/"  # Will be set via --set to include CEDANA_URL prefix
    s3_logs_sink:
      type: aws_s3
      bucket: ""  # Will be set via --set customConfig.sinks.s3_logs_sink.bucket
      region: ""  # Will be set via --set customConfig.sinks.s3_logs_sink.region
      key_prefix: "vector/logs/date=%Y-%m-%d/hour=%H/minute=%M/"  # Will be set via --set to include CEDANA_URL prefix
```

To install vector daemonset run the following
```bash
helm repo add vector https://helm.vector.dev
helm repo update

# Replace placeholders with your actual values:
# - YOUR_CEDANA_URL: e.g., "customer-name.cedana.ai/v2"
# - YOUR_S3_BUCKET: Your S3 bucket name
# - YOUR_AWS_REGION: Your AWS region (e.g., "us-east-1")
# - YOUR_AWS_ACCESS_KEY_ID: AWS access key with S3 write permissions
# - YOUR_AWS_SECRET_ACCESS_KEY: AWS secret access key

# First, create the AWS credentials secret
kubectl create secret generic vector-aws-credentials \
  -n cedana-monitoring \
  --from-literal=awsAccessKeyId="YOUR_AWS_ACCESS_KEY_ID" \
  --from-literal=awsSecretAccessKey="YOUR_AWS_SECRET_ACCESS_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

# Then install Vector
helm upgrade -i vector vector/vector --namespace cedana-monitoring --create-namespace \
  --values ./vector/values.yml \
  --set env[0].value="YOUR_CEDANA_URL" \
  --set customConfig.sinks.s3_sink.bucket="YOUR_S3_BUCKET" \
  --set customConfig.sinks.s3_sink.region="YOUR_AWS_REGION" \
  --set customConfig.sinks.s3_sink.key_prefix="YOUR_CEDANA_URL/vector/data/date=%Y-%m-%d/hour=%H/minute=%M/" \
  --set customConfig.sinks.s3_logs_sink.bucket="YOUR_S3_BUCKET" \
  --set customConfig.sinks.s3_logs_sink.region="YOUR_AWS_REGION" \
  --set customConfig.sinks.s3_logs_sink.key_prefix="YOUR_CEDANA_URL/vector/logs/date=%Y-%m-%d/hour=%H/minute=%M/"
```
To uninstall vector
```
helm uninstall vector -n cedana-monitoring 
```

## DCGM Exporter Installation

```
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm repo update
helm install dcgm-exporters gpu-helm-charts/dcgm-exporter --namespace cedana-monitoring --create-namespace
```

To uninstall dcgm-exporters
```
helm uninstall dcgm-exporters -n cedana-monitoring
```
