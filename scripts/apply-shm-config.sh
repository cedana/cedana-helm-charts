#!/bin/bash
set -euo pipefail

# Script to apply standalone SHM configuration
# Usage: ./apply-shm-config.sh [SIZE] [NAMESPACE]
# Example: ./apply-shm-config.sh 20G my-namespace

SHM_SIZE="${1:-10G}"
NAMESPACE="${2:-default}"

echo "Applying SHM configuration with size: $SHM_SIZE in namespace: $NAMESPACE"

# Calculate minimum bytes (convert size to bytes for comparison)
case $SHM_SIZE in
    *G)
        SIZE_NUM=$(echo $SHM_SIZE | sed 's/G//')
        MIN_BYTES=$((SIZE_NUM * 1024 * 1024 * 1024))
        ;;
    *M)
        SIZE_NUM=$(echo $SHM_SIZE | sed 's/M//')
        MIN_BYTES=$((SIZE_NUM * 1024 * 1024))
        ;;
    *)
        echo "Error: Size must be specified with G (gigabytes) or M (megabytes) suffix"
        echo "Example: 10G, 20G, 512M"
        exit 1
        ;;
esac

# Create temporary YAML with custom values
cat > /tmp/shm-config-custom.yaml << EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cedana-shm-config
  namespace: $NAMESPACE
  labels:
    app: cedana-shm-config
data:
  shm-size: "$SHM_SIZE"
  min-bytes: "$MIN_BYTES"
  configure-shm.sh: |
    #!/bin/bash
    set -euo pipefail
    
    # Configure /dev/shm size
    # This script increases the shared memory size on the host node
    
    SHM_PATH="/host/dev/shm"
    FSTAB="/host/etc/fstab"
    SIZE_G="$SHM_SIZE"
    MIN_BYTES="$MIN_BYTES"
    
    echo "Configuring /dev/shm with size \$SIZE_G..."
    
    # 1. Remount if current size is too small
    if [ "\$(df --output=size -B 1 "\$SHM_PATH" | tail -n 1)" -lt "\$MIN_BYTES" ]; then
        echo "Remounting \$SHM_PATH with size \$SIZE_G..."
        mount -o remount,size=\$SIZE_G "\$SHM_PATH"
    else
        echo "\$SHM_PATH already has sufficient size"
    fi
    
    # 2. Ensure fstab is correct for persistence
    FSTAB_ENTRY="tmpfs /dev/shm tmpfs defaults,size=\$SIZE_G 0 0"
    if [ -f "\$FSTAB" ] && grep -qE "^\\s*[^#]\\s*tmpfs\\s+/dev/shm" "\$FSTAB"; then
        echo "Updating existing fstab entry for /dev/shm..."
        sed -i.bak -E "s|^\\s*[^#]\\s*tmpfs\\s+/dev/shm.*|\$FSTAB_ENTRY|" "\$FSTAB"
    elif [ -f "\$FSTAB" ]; then
        echo "Adding new fstab entry for /dev/shm..."
        echo "\$FSTAB_ENTRY" >> "\$FSTAB"
    fi
    
    echo "/dev/shm configuration complete."

---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: cedana-shm-config
  namespace: $NAMESPACE
  labels:
    app: cedana-shm-config
spec:
  selector:
    matchLabels:
      app: cedana-shm-config
  template:
    metadata:
      labels:
        app: cedana-shm-config
    spec:
      hostPID: true
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      hostIPC: true
      containers:
        - name: shm-config
          image: busybox:latest
          securityContext:
            privileged: true
            allowPrivilegeEscalation: true
          volumeMounts:
            - name: host-volume
              mountPath: /host
              readOnly: false
            - name: shm-config
              mountPath: /scripts
              readOnly: true
          command: ["/bin/sh"]
          args: ["/scripts/configure-shm.sh"]
          # Run once and exit
          lifecycle:
            postStart:
              exec:
                command: ["/bin/sh", "-c", "chmod +x /scripts/configure-shm.sh"]
      volumes:
        - name: host-volume
          hostPath:
            path: /
        - name: shm-config
          configMap:
            name: cedana-shm-config
EOF

# Apply the configuration
kubectl apply -f /tmp/shm-config-custom.yaml

echo "SHM configuration applied successfully!"
echo "The DaemonSet will run on all nodes and configure /dev/shm with size $SHM_SIZE"
echo "You can check the status with: kubectl get pods -n $NAMESPACE -l app=cedana-shm-config"

# Clean up temporary file
rm -f /tmp/shm-config-custom.yaml 