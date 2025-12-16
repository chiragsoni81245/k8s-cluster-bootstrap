#!/usr/bin/env bash
set -euo pipefail

############################################
# Globals
############################################
K8S_VERSION="1.29"
CONTAINERD_CONFIG="/etc/containerd/config.toml"

############################################
# Utility Functions
############################################
log() {
  echo -e "\n[INFO] $1"
}

error() {
  echo -e "\n[ERROR] $1"
  exit 1
}

require_root() {
  [[ $EUID -eq 0 ]] || error "Run this script as root"
}

############################################
# System Preparation
############################################
disable_swap() {
  log "Disabling swap"
  swapoff -a
  sed -i '/ swap / s/^/#/' /etc/fstab
}

load_kernel_modules() {
  log "Loading kernel modules"
  cat <<EOF >/etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

  modprobe overlay
  modprobe br_netfilter
}

apply_sysctl_settings() {
  log "Applying sysctl settings"
  cat <<EOF >/etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

  sysctl --system
}

install_system_dependencies() {
  log "Installing system dependencies"
  apt-get update -y
  apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    apt-transport-https
}

############################################
# Container Runtime
############################################
install_containerd() {
  log "Installing containerd"
  apt-get install -y containerd

  mkdir -p /etc/containerd
  containerd config default > "$CONTAINERD_CONFIG"

  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "$CONTAINERD_CONFIG"

  systemctl restart containerd
  systemctl enable containerd
}

############################################
# Kubernetes Binaries
############################################
add_kubernetes_repo() {
  log "Adding Kubernetes repository"
  mkdir -p /etc/apt/keyrings

  curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /
EOF

  apt-get update -y
}

install_kubernetes_packages() {
  log "Installing kubelet, kubeadm, kubectl"
  apt-get install -y kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
  systemctl enable kubelet
}

############################################
# Validation
############################################
validate_ip() {
  [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
}

validate_cidr() {
  [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$ ]] || return 1
}

############################################
# Control Plane Setup
############################################
get_primary_ip() {
  ip route get 1 | awk '{print $7; exit}'
}

collect_control_plane_inputs() {
  DEFAULT_API_IP=$(get_primary_ip)
  DEFAULT_POD_CIDR="10.0.0.0/16"
  DEFAULT_SERVICE_CIDR="10.96.0.0/12"

  echo
  read -rp "API Server Advertise Address [default: $DEFAULT_API_IP]: " APISERVER_IP
  APISERVER_IP=${APISERVER_IP:-$DEFAULT_API_IP}
  validate_ip "$APISERVER_IP" || error "Invalid API Server IP"

  read -rp "Pod CIDR [default: $DEFAULT_POD_CIDR]: " POD_CIDR
  POD_CIDR=${POD_CIDR:-$DEFAULT_POD_CIDR}
  validate_cidr "$POD_CIDR" || error "Invalid Pod CIDR"

  read -rp "Service CIDR [default: $DEFAULT_SERVICE_CIDR]: " SERVICE_CIDR
  SERVICE_CIDR=${SERVICE_CIDR:-$DEFAULT_SERVICE_CIDR}
  validate_cidr "$SERVICE_CIDR" || error "Invalid Service CIDR"

  echo
  log "Using configuration:"
  echo "  API Server IP : $APISERVER_IP"
  echo "  Pod CIDR      : $POD_CIDR"
  echo "  Service CIDR  : $SERVICE_CIDR"
}

initialize_control_plane() {
  log "Initializing Kubernetes control plane"

  kubeadm init \
    --skip-phases=addon/kube-proxy \
    --apiserver-advertise-address="$APISERVER_IP" \
    --pod-network-cidr="$POD_CIDR" \
    --service-cidr="$SERVICE_CIDR"


  log "Use following command join worker nodes in this cluster"
  log "  $(kubeadm token create --print-join-command)"
}

configure_kubectl_access() {
  log "Configuring kubectl access"

  mkdir -p "$HOME/.kube"
  cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
  chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"
}

install_cilium_cni() {
  log "Installing Cilium CNI"

  CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
  CLI_ARCH=amd64
  if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
  curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
  sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
  sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
  rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}


  cilium install
  cilium status --wait
  # cilium connectivity test
}

############################################
# Worker Node Setup
############################################
join_worker_node() {
  echo
  read -rp "Paste full 'kubeadm join ...' command: " JOIN_CMD

  [[ $JOIN_CMD == kubeadm\ join* ]] || error "Invalid join command"

  log "Joining worker node"
  eval "$JOIN_CMD"
}

############################################
# Node Role Selection
############################################
choose_node_role() {
  echo
  echo "Select node role:"
  echo "1) Control Plane"
  echo "2) Worker Node"
  read -rp "Choice [1-2]: " ROLE

  case "$ROLE" in
    1) setup_control_plane ;;
    2) setup_worker_node ;;
    *) error "Invalid selection" ;;
  esac
}

setup_control_plane() {
  collect_control_plane_inputs
  initialize_control_plane
  configure_kubectl_access
  install_cilium_cni
}

setup_worker_node() {
  join_worker_node
}

############################################
# Main
############################################
main() {
  require_root
  disable_swap
  load_kernel_modules
  apply_sysctl_settings
  install_system_dependencies
  install_containerd
  add_kubernetes_repo
  install_kubernetes_packages
  choose_node_role

  log "Kubernetes node setup complete"
}

main
