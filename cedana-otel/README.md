## Open telemetry collector chart values for Cedana

The helm chart installs [OpenTelemetry Collector](https://github.com/open-telemetry/opentelemetry-collector)
in kubernetes cluster.

## Prerequisites

- Kubernetes 1.24+
- Helm 3.9+

## Installing the Chart

Add OpenTelemetry Helm repository:

```console
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
```

To install the chart with the release name cedana-opentelemetry-collector, run the following command:

```console
helm install cedana-opentelemetry-collector open-telemetry/opentelemetry-collector --values values.yaml -n cedanacontroller-system
```

To upgrade the installed chart with new changes , run the following command:

```console
helm upgrade -i cedana-opentelemetry-collector open-telemetry/opentelemetry-collector --values values.yaml -n cedanacontroller-system
```
