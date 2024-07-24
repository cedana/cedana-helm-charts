# Cedana Helm Charts

Repository with a collection of helm charts officially maintained to deploy Cedana, on a
Kubernetes cluster.

## cedana-helm

Chart for installing the controller and cedana daemon.
Additionally it aims to provide optional deployments for services commonly used with our
deployments.

### Installation

Currently you can install the chart using this repo or you can use the oci repository.

```bash
# clone the repo
git clone https://github.com/cedana/cedana-helm-charts --depth 1
# install from local chart files
helm install cedana ./cedana-helm-charts/cedana-helm --create-namespace -n cedanacontroller-system

# alternatively, you can use the oci repo
helm install cedana oci://registry-1.docker.io/cedana/cedana-helm --create-namespace -n cedanacontroller-system
```
