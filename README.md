<div align="center">

![Vagrant](https://img.shields.io/badge/Vagrant-2.x-1868F2?style=flat-square)
![K3s](https://img.shields.io/badge/K3s-Kubernetes-FFC61C?style=flat-square)
![K3d](https://img.shields.io/badge/K3d-Docker-2496ED?style=flat-square)
![ArgoCD](https://img.shields.io/badge/ArgoCD-GitOps-EF7B4D?style=flat-square)
![GitLab](https://img.shields.io/badge/GitLab-CE-FC6D26?style=flat-square)
![Debian](https://img.shields.io/badge/Debian-Bookworm-A81D33?style=flat-square)

</div>

# IoT — Kubernetes & GitOps

A three-part project exploring container orchestration and continuous deployment using K3s, Vagrant, K3d and Argo CD.

## Project Structure

| Part | Description |
|:----:|:------------|
| [p1](#part-1--k3s-cluster-with-vagrant) | K3s cluster with two virtual machines (server + worker) |
| [p2](#part-2--k3s-with-ingress-routing) | K3s single node with three apps and Ingress by HOST header |
| [p3](#part-3--k3d--argo-cd-gitops) | K3d cluster with Argo CD continuous deployment |
| [bonus](#bonus--gitlab-in-cluster) | GitLab running inside the cluster, ArgoCD syncs from it |

---

## Requirements

### Virtual machine specs

| Resource | Minimum | Recommended |
|:--------:|:-------:|:-----------:|
| OS | Debian 12 (Bookworm) 64-bit | Debian 12 (Bookworm) 64-bit |
| RAM | 8 GB | 16 GB (bonus needs ~6 GB for GitLab) |
| CPU | 2 cores | 4 cores |
| Disk | 40 GB | 60 GB |
| Nested virtualization | Enabled (for p1/p2) | Enabled |

### p1 and p2 — install once on the host VM

p1 and p2 use **Vagrant + libvirt** to create virtual machines. Install these before running them:

```bash
sudo apt-get update
sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients \
    bridge-utils ruby-dev build-essential libvirt-dev

# Vagrant
wget -O /tmp/vagrant.deb \
  https://releases.hashicorp.com/vagrant/2.4.3/vagrant_2.4.3-1_amd64.deb
sudo dpkg -i /tmp/vagrant.deb

# Vagrant libvirt plugin
vagrant plugin install vagrant-libvirt

# Add your user to the libvirt group (log out and back in after this)
sudo usermod -aG libvirt $USER
```

> **Nested virtualization** must be enabled in your hypervisor for p1/p2 to work.
> Verify on the host: `cat /sys/module/kvm_intel/parameters/nested` (Intel) or
> `cat /sys/module/kvm_amd/parameters/nested` (AMD) — must return `Y` or `1`.

### p3 and bonus — no manual installation needed

The `install.sh` scripts handle everything automatically (Docker, kubectl, k3d, git, jq).
Only `curl` is required to start, which is pre-installed on Debian:

```bash
sudo apt-get install -y curl   # usually already present
```

---

## Part 1 — K3s Cluster with Vagrant

Two virtual machines forming a K3s cluster: a server node and a worker node.

| Machine | IP | Role |
|:-------:|:--:|:----:|
| `jvidal-tS` | 192.168.56.110 | K3s Server |
| `jvidal-tSW` | 192.168.56.111 | K3s Agent |

### Start

```bash
cd p1
vagrant up
```

### Verify cluster

```bash
vagrant ssh jvidal-tS
kubectl get nodes -o wide
```

---

## Part 2 — K3s with Ingress Routing

Single virtual machine running K3s with three applications exposed via Ingress depending on the `Host` header.

| Host | Application |
|:----:|:-----------:|
| `app1.com` | app-one |
| `app2.com` | app-two |
| *(any other)* | app-three |

### Start

```bash
cd p2
vagrant up
```

### Verify apps

```bash
vagrant ssh jvidal-tS

# Default → app-three
curl http://192.168.56.110/

# app-one
curl -H "Host: app1.com" http://192.168.56.110/

# app-two
curl -H "Host: app2.com" http://192.168.56.110/
```

---

## Part 3 — K3d + Argo CD GitOps

K3d cluster with Argo CD monitoring this GitHub repository. Any push to `p3/confs/manifests/` is automatically deployed to the `dev` namespace.

### Architecture

```
GitHub repo (p3/confs/manifests/)
        │
        │  watches (every 3 min or manual sync)
        ▼
    Argo CD  (namespace: argocd)
        │
        │  deploys
        ▼
  wil-playground  (namespace: dev)
  image: wil42/playground:v1
  port: 8888
```

### Start

```bash
cd p3
sudo bash scripts/install.sh
```

This installs Docker, kubectl, k3d, creates the cluster, deploys Argo CD and the application automatically.

### Verify namespaces and pods

```bash
kubectl get ns
kubectl get pods -n dev
kubectl get pods -n argocd
```

### Access Argo CD UI

Run in a separate terminal:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
```

Open in browser: `http://localhost:8080`

- **User:** `admin`
- **Password:** printed at the end of `install.sh`, or retrieve it with:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

### Access the application

```bash
kubectl port-forward svc/wil-playground -n dev 8888:8888
curl http://localhost:8888/
# {"status":"ok", "message": "v1"}
```

### Update to v2 (GitOps flow)

Edit the manifest, commit and push — Argo CD detects the change and redeploys automatically:

```bash
sed -i 's/wil42\/playground:v1/wil42\/playground:v2/' p3/confs/manifests/deployment.yaml
git add p3/confs/manifests/deployment.yaml
git commit -m "Update wil-playground to v2"
git push
```

Wait for the pod to restart, then verify:

```bash
kubectl get pods -n dev
kubectl port-forward svc/wil-playground -n dev 8888:8888
curl http://localhost:8888/
# {"status":"ok", "message": "v2"}
```

### Destroy cluster

```bash
sudo k3d cluster delete iot-cluster
```

---

## Bonus — GitLab CE in Cluster

Extends Part 3 by replacing GitHub with a **self-hosted GitLab CE** instance running inside the same k3d cluster. Argo CD syncs manifests from the local GitLab repository — a fully self-contained GitOps pipeline with no external dependencies.

### Technologies

| Tool | Role |
|:----:|:-----|
| **GitLab CE** (`gitlab/gitlab-ce:latest`) | Self-hosted Git server in namespace `gitlab` |
| **Argo CD** | GitOps controller, watches the local GitLab repo |
| **k3d** | Kubernetes cluster inside Docker |

### Architecture

```
bonus/confs/manifests/  ← pushed to local GitLab on install
                               │
         ┌─────────────────────┘
         │
   GitLab CE  (namespace: gitlab)
   svc: gitlab.gitlab.svc.cluster.local:80
         │
         │  automated sync
         ▼
     Argo CD  (namespace: argocd)
         │
         │  deploys
         ▼
   wil-playground  (namespace: dev)
   image: wil42/playground:v1  ·  port: 8888
```

### Start

```bash
cd bonus
sudo bash scripts/install.sh
```

Installs Docker, kubectl, k3d — creates the cluster, deploys GitLab CE (latest official image), waits for initialization (~10 min), pushes manifests to the local repo, installs Argo CD and connects everything automatically.

See [bonus/README.md](bonus/README.md) for full command reference and manual recovery steps.

### Access GitLab

```bash
kubectl port-forward svc/gitlab -n gitlab 8929:80
# Browser: http://localhost:8929   user: root
kubectl exec -n gitlab deployment/gitlab -- \
  grep Password /etc/gitlab/initial_root_password
```

### Access Argo CD

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
# Browser: http://localhost:8080   user: admin
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

### Access the application

```bash
kubectl port-forward svc/wil-playground -n dev 8888:8888
curl http://localhost:8888/
# {"status":"ok", "message": "v1"}
```

### Update version — local GitOps flow

```bash
# Port-forward GitLab (separate terminal)
kubectl port-forward svc/gitlab -n gitlab 8929:80

# Get token
GITLAB_TOKEN=$(kubectl exec -n gitlab deployment/gitlab -- \
  gitlab-rails runner \
  "puts User.find_by_username('root').personal_access_tokens.active.first.token" \
  2>/dev/null | tail -1)

# Clone, update, push
cd /tmp && git clone "http://root:${GITLAB_TOKEN}@localhost:8929/root/iot-manifests.git" iot-update
sed -i 's/playground:v1/playground:v2/' /tmp/iot-update/deployment.yaml
git -C /tmp/iot-update config user.email "root@gitlab.local"
git -C /tmp/iot-update config user.name "Root"
git -C /tmp/iot-update add . && git -C /tmp/iot-update commit -m "Update to v2" && git -C /tmp/iot-update push
rm -rf /tmp/iot-update
```

Wait ~30 seconds, then:

```bash
kubectl port-forward svc/wil-playground -n dev 8888:8888
curl http://localhost:8888/
# {"status":"ok", "message": "v2"}
```

### Destroy cluster

```bash
sudo k3d cluster delete iot-cluster
```

---

<div align="center">
  Created with ❤️ by <a href="https://github.com/Flingocho">Flingocho</a>
</div>
