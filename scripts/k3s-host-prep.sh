#!/usr/bin/env bash
# Host prep for single-node k3s Inference in a Box; needs the NVIDIA driver (>= 580) loaded.
# Then install with values-inference-box.yaml + values-k3s.yaml (see README).
#   sudo bash scripts/k3s-host-prep.sh
set -euo pipefail

K3S_VERSION=${K3S_VERSION:-v1.34.2+k3s1} # >= v1.32: the helper sets the kubelet timeout via kubelet.conf.d
NODE_NAME=${NODE_NAME:-$(hostname -s)}

[ -r /proc/driver/nvidia/version ] || { echo "no NVIDIA driver loaded" >&2; exit 1; }

# k3s registers the nvidia runtime only if the toolkit exists when it starts.
if ! command -v nvidia-container-runtime >/dev/null; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      >/etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -qq && apt-get install -y -qq nvidia-container-toolkit
fi

if [ ! -f /etc/rancher/k3s/config.yaml ]; then
  mkdir -p /etc/rancher/k3s
  cat >/etc/rancher/k3s/config.yaml <<YAML
write-kubeconfig-mode: "0644"
node-name: $NODE_NAME
disable: [traefik]
default-runtime: nvidia
YAML
fi
systemctl is-active --quiet k3s || curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION sh -s - server

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
until kubectl get node "$NODE_NAME" >/dev/null 2>&1; do sleep 2; done
kubectl wait --for=condition=Ready "node/$NODE_NAME" --timeout=300s

# k3s keeps runc only in its data dir.
ln -sfn /var/lib/rancher/k3s/data/current/bin/runc /usr/local/bin/runc

# No NFD on k3s: the device plugin and DCGM exporter select on this label.
kubectl label node "$NODE_NAME" nvidia.com/gpu.present=true --overwrite

command -v helm >/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
