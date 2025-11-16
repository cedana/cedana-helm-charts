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

To specify the AWS credentials being used for the s3 bucket, refer to secrets section of `./vector/values.yml`
```yaml
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

You can specify the s3 bucket name and it's respective region under the customConfig section of `./vector/values.yml`
```yaml
# for all options.
customConfig:
  data_dir: /vector-data-dir
  api:
  ...
  sinks:
    s3_sink:
      type: aws_s3
      inputs: [filter]
      bucket: "" # specify s3 bucket name
      region: "" # specify s3 bucket region
      compression: "none"
      encoding:
        codec: "json"
      batch:
        max_bytes: 10485760 # 10MB
        timeout_secs: 10
      key_prefix: "vector/data/date=%Y-%m-%d/"
      filename_time_format: "%s"
    stdout:
      type: console
      inputs: [filter]
      encoding:
        codec: json
    s3_logs_sink:
      type: aws_s3
      inputs: [kubernetes_logs]
      bucket: "" # specify s3 bucket name
      region: "" # specify s3 bucket region
      compression: "gzip"
```

To install vector daemonset run the following
```
helm repo add vector https://helm.vector.dev
helm repo update
helm upgrade -i vector vector/vector --namespace prometheus --create-namespace --values ./vector/values.yml
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
