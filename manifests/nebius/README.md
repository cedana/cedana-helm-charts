# Nebius inference stack manifests (cedana-helm-charts)

Deployment artifacts for `nebius-mk8s-purple-snail-cluster-8`, as of 2026-08-12.

## cedana-helm/values-nebius.yaml
Upgrade values for the `cedana` release in `cedana-systems` (canonical chart):
pins the fixed helper image digest (idempotent kubelet config), enables the
dynamo-watcher with `INFERENCE_NAMESPACE=inference`, points config at the
in-cluster propagator, keeps manager v0.6.5 until the watcher gate passes.

```sh
helm upgrade cedana ./cedana-helm -n cedana-systems -f cedana-helm/values-nebius.yaml
```

## manifests/nebius/propagator-env.yaml
Propagator env wiring: `propagator-aws` secret (operator .env values) via
envFrom (S3 plugin registry) + FQDN RabbitMQ discovery URI.

## manifests/nebius/cedana-ui.yaml
cedana-ui deployment (backend AUTH_MODE=custom + frontend + caddy) exposed via
`cedana-ui` LoadBalancer in `cedana-inference`. Login: paste the shared
`CEDANA_AUTH_TOKEN` from the `cedana-inference-auth` secret on the token screen.

```sh
kubectl get secret cedana-inference-auth -n cedana-inference \
  -o jsonpath='{.data.auth-token}' | base64 -d
```
