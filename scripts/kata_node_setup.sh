#!/bin/bash
# Kata Containers node setup for GKE Standard (Ubuntu nodes)
# This script runs as a startup script on each GKE node.
# It installs Kata runtime binaries and configures containerd
# with the kata-qemu runtime handler.
set -euo pipefail

KATA_VERSION="3.12.0"
KATA_DIR="/opt/kata"
MARKER_FILE="/opt/kata/.installed-${KATA_VERSION}"

# Skip if already installed (idempotent)
if [ -f "$MARKER_FILE" ]; then
  echo "[kata-setup] Kata ${KATA_VERSION} already installed, skipping."
  exit 0
fi

echo "[kata-setup] Installing Kata Containers ${KATA_VERSION}..."

# Verify KVM is available
if [ ! -e /dev/kvm ]; then
  echo "[kata-setup] ERROR: /dev/kvm not found. Nested virtualization may not be enabled."
  exit 1
fi

# Download and extract kata-static tarball
mkdir -p "$KATA_DIR"
cd /tmp
TARBALL="kata-static-${KATA_VERSION}-amd64.tar.xz"
curl -fsSL "https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/${TARBALL}" -o "$TARBALL"
tar xf "$TARBALL" -C /
rm -f "$TARBALL"

# Verify installation
if [ ! -x /opt/kata/bin/kata-runtime ]; then
  echo "[kata-setup] ERROR: kata-runtime binary not found after extraction."
  exit 1
fi

# Create symlinks
ln -sf /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2
ln -sf /opt/kata/bin/kata-runtime /usr/local/bin/kata-runtime

# Configure containerd to add kata-qemu runtime handler
CONTAINERD_CONFIG="/etc/containerd/config.toml"
if [ -f "$CONTAINERD_CONFIG" ]; then
  # Check if kata-qemu is already configured
  if ! grep -q "kata-qemu" "$CONTAINERD_CONFIG"; then
    echo "[kata-setup] Adding kata-qemu runtime to containerd config..."
    cat >> "$CONTAINERD_CONFIG" <<'EOF'

# Kata Containers runtime (added by kata_node_setup.sh)
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-qemu]
  runtime_type = "io.containerd.kata.v2"
  privileged_without_host_devices = true
  pod_annotations = ["io.katacontainers.*"]
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-qemu.options]
    ConfigPath = "/opt/kata/share/defaults/kata-containers/configuration-qemu.toml"
EOF

    echo "[kata-setup] Restarting containerd to pick up new runtime..."
    systemctl restart containerd
    echo "[kata-setup] Waiting for containerd to be ready..."
    sleep 5
  fi
else
  echo "[kata-setup] WARNING: containerd config not found at $CONTAINERD_CONFIG"
fi

# Mark as installed
touch "$MARKER_FILE"
echo "[kata-setup] Kata Containers ${KATA_VERSION} installed successfully."
