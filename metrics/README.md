## Prometheus Install
Prometheus helm install installs the following components
- node-exporters daemonset
- kube-state-metrics deployment
- prometheus-server deployment

To install, run the following:
```
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade -i prometheus prometheus-community/prometheus -n prometheus --create-namespace --values ./prometheus/values.yml
```

Run the following to uninstall Prometheus:
```
helm uninstall prometheus -n prometheus
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

helm upgrade -i vector vector/vector --namespace prometheus --create-namespace \
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
helm uninstall vector -n prometheus 
```

## DCGM Exporter Installation

```
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm repo update
helm install dcgm-exporters gpu-helm-charts/dcgm-exporter --namespace prometheus --create-namespace
```

To uninstall dcgm-exporters
```
helm uninstall dcgm-exporters -n prometheus
```
