#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] Kubernetes node bootstrap started..."

#-----------------------------
# Variables
#-----------------------------
K8S_VERSION="1.33"
CONTAINERD_CONFIG="/etc/containerd/config.toml"

#-----------------------------
# Pre-flight checks
#-----------------------------
if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Please run as root"
  exit 1
fi

#-----------------------------
# Disable swap (required)
#-----------------------------
echo "[INFO] Disabling swap..."
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

#-----------------------------
# Load kernel modules
#-----------------------------
echo "[INFO] Loading kernel modules..."
cat <<EOF >/etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

#-----------------------------
# Sysctl settings
#-----------------------------
echo "[INFO] Applying sysctl settings..."
cat <<EOF >/etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

#-----------------------------
# Install prerequisites
#-----------------------------
echo "[INFO] Installing system dependencies..."
apt-get update -y
apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  apt-transport-https

#-----------------------------
# Install containerd
#-----------------------------
echo "[INFO] Installing containerd..."
apt-get install -y containerd

mkdir -p /etc/containerd
containerd config default > "$CONTAINERD_CONFIG"

# Enable Systemd cgroup driver (REQUIRED)
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "$CONTAINERD_CONFIG"

systemctl restart containerd
systemctl enable containerd

#-----------------------------
# Kubernetes repo
#-----------------------------
echo "[INFO] Adding Kubernetes APT repository..."
mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /
EOF

apt-get update -y

#-----------------------------
# Install Kubernetes binaries
#-----------------------------
echo "[INFO] Installing kubelet, kubeadm, kubectl..."
apt-get install -y kubelet kubeadm kubectl

apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet

echo 'source <(kubectl completion bash)' >>~/.bashrc
echo 'alias k=kubectl' >>~/.bashrc

#-----------------------------
# Final checks
#-----------------------------
echo "[INFO] Verifying installations..."
containerd --version
kubeadm version
kubelet --version

#-----------------------------
# Completion message
#-----------------------------
echo "--------------------------------------"
echo "[SUCCESS] Kubernetes node is READY"
echo
echo "Next steps:"
echo
echo "Control-plane:"
echo "  kubeadm init --pod-network-cidr=172.16.0.0/24"
echo
echo "Worker node:"
echo "  kubeadm join <MASTER_IP>:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>"
echo
echo "--------------------------------------"
