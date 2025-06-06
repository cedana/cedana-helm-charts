# Cedana Helm Charts

Repository with a collection of helm charts officially maintained to deploy Cedana, on a
Kubernetes cluster.

## cedana-helm

Chart for installing the controller and cedana daemon.
Additionally it aims to provide optional deployments for services commonly used with our deployments such as Kueue. 
### Installation

Currently you can install the chart using this repo or you can use the oci repository.

```bash
# clone the repo
git clone https://github.com/cedana/cedana-helm-charts --depth 1
# install from local chart files
helm install cedana ./cedana-helm-charts/cedana-helm --create-namespace -n cedana-systems \ 
--set cedanaConfig.cedanaUrl=$CEDANA_URL \
--set cedanaConfig.cedanaAuthToken=$CEDANA_AUTH_TOKEN

# alternatively, you can use the oci repo
helm install cedana oci://registry-1.docker.io/cedana/cedana-helm --create-namespace -n cedana-systems \ 
--set cedanaConfig.cedanaUrl=$CEDANA_URL \
--set cedanaConfig.cedanaAuthToken=$CEDANA_AUTH_TOKEN
```

### Usage
See https://docs.cedana.ai/get-started/using-the-cedana-platform for usage instructions with the Cedana Platform!

### Security

```
[!NOTE]
If you want to use our tools, but have specific security requirements reach out and let us know
about it.
```

- Daemonset requires privilege escalation for daemon container, and it updates the host directly with
  required dependencies and our cedana-daemon application.

- Currently our controller requires access to all pods to be able to list, checkpoint and restore them.
