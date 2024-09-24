# Cedana examples

## Redis checkpoint restore

Let first set up a sample redis database on k8. Create a namespace called `cedana-examples` and install redis-example.yaml.

```bash
kubectl create namespace cedana-examples
kubectl apply -f redis-example.yaml
```

