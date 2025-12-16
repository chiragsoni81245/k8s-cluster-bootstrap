# Kubernetes Node Bootstrap Script (Ubuntu Server)

This repository provides a **production‑ready Bash script** to convert a **fresh Ubuntu Server installation** into a **Kubernetes node** using **kubeadm**.

The script supports **both Control Plane and Worker nodes**, installs all required dependencies, validates user input, and follows Kubernetes best practices.

---

## 📌 Prerequisites

### ✅ Base Operating System

* **Ubuntu Server OS** (base/minimal ISO)
* Supported versions:

  * Ubuntu **20.04 LTS**
  * Ubuntu **22.04 LTS**
  * Ubuntu **24.04 LTS**
* The OS should be freshly installed with **no Kubernetes components pre‑installed**

### 🌐 Internet Access

* **Required**
* Needed to:

  * Install system packages
  * Download Kubernetes binaries
  * Install containerd
  * Install Cilium CNI

> ❗ Air‑gapped environments are **not supported** by this script.

### 🔐 Permissions

* Script must be executed as **root**

```bash
sudo ./k8s-bootstrap.sh
```

### 🧠 Minimum System Requirements

* Swap enabled at install time is OK (script disables it)
* Recommended:

  * **2 CPU cores** (≥4 for control plane)
  * **2 GB RAM** (≥4 GB recommended for control plane)

---

## 🚀 What the Script Does

### System Preparation

* Disables swap (Kubernetes requirement)
* Loads required kernel modules
* Applies required sysctl networking settings

### Container Runtime

* Installs **containerd**
* Configures **systemd cgroup driver** (recommended by Kubernetes)

### Kubernetes Components

* Installs and pins:

  * `kubeadm`
  * `kubelet`
  * `kubectl`

---

## 🧭 Node Role Selection

When the script runs, you are prompted to choose the node role:

```text
1) Control Plane
2) Worker Node
```

---

## 🛠 Control Plane Setup

### Input Collection (with Defaults)

The script asks for the following parameters:

| Parameter                    | Default Value      |
| ---------------------------- | ------------------ |
| API Server Advertise Address | Machine primary IP |
| Pod CIDR                     | `10.0.0.0/16`      |
| Service CIDR                 | `10.96.0.0/12`     |

> Press **Enter** to accept defaults. All inputs are validated.

### Kubernetes Initialization

```bash
kubeadm init \
  --skip-phases=addon/kube-proxy \
  --apiserver-advertise-address=<IP> \
  --pod-network-cidr=<POD_CIDR> \
  --service-cidr=<SERVICE_CIDR>
```

### kubectl Configuration

The script automatically configures `kubectl` access for the current user:

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### CNI Installation

* Installs **Cilium CNI** using the official CLI
* Waits until the network is fully ready

```bash
cilium install
cilium status --wait
```

---

## 👷 Worker Node Setup

When **Worker Node** is selected:

* You are prompted to paste the full `kubeadm join` command
* The command is validated
* The node joins the cluster

Example:

```bash
kubeadm join 192.168.1.10:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

---

## ▶️ Usage

```bash
chmod +x k8s-bootstrap.sh
sudo ./k8s-bootstrap.sh
```

Follow the on‑screen prompts to complete the setup.

---

## 🧩 Design Highlights

* Modular, function‑based Bash script
* Safe defaults with strict validation
* containerd (Docker‑free)
* Cilium (eBPF‑based networking)
* kubeadm‑aligned and production‑friendly

Works on:

* Bare‑metal servers
* VirtualBox / KVM / ESXi
* Cloud VMs

---

## ⚠️ Limitations

* Internet access required
* Single control plane only (no HA)
* IPv4‑only
