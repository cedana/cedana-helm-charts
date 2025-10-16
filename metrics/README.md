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
Vector will help us push the scraped prometheus metrics to our remote s3 bucket. You will have to give pod identity access to vector service account for the s3 access.

To install vector statefulset run the following
```
helm install vector vector/vector --namespace prometheus --values ./vector/values.yml
```
To uninstall vector
```
helm uninstall vector -n prometheus 
```
