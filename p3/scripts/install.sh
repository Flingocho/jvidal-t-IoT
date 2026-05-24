#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ">>> Installing dependencies..."
apt-get update -qq
apt-get install -y -qq curl

echo ">>> Installing Docker..."
curl -fsSL https://get.docker.com | sh
systemctl enable docker
systemctl start docker

echo ">>> Installing kubectl..."
curl -sfLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl

echo ">>> Installing k3d..."
curl -sfL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

echo ">>> Creating k3d cluster..."
k3d cluster delete iot-cluster 2>/dev/null || true
k3d cluster create iot-cluster --wait

if [ -n "$SUDO_USER" ]; then
  USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  mkdir -p "$USER_HOME/.kube"
  cp /root/.kube/config "$USER_HOME/.kube/config"
  chown "$SUDO_USER:$SUDO_USER" "$USER_HOME/.kube/config"
fi

echo ">>> Creating namespaces..."
kubectl create namespace argocd
kubectl create namespace dev

echo ">>> Installing Argo CD..."
kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo ">>> Waiting for Argo CD to be ready..."
kubectl wait --for=condition=available deployment --all -n argocd --timeout=300s

echo ">>> Configuring Argo CD in insecure mode..."
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge -p '{"data":{"server.insecure":"true"}}'
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment/argocd-server -n argocd --timeout=120s

echo ">>> Deploying application..."
kubectl apply -f "$SCRIPT_DIR/../confs/application.yaml"

echo ""
echo "=== Setup complete ==="
echo ""
echo "Argo CD initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo ""
echo ""
echo "To access Argo CD UI (run in a separate terminal):"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:80"
echo "  Open: http://localhost:8080  (user: admin)"
echo ""
echo "To access the app (run in a separate terminal):"
echo "  kubectl port-forward svc/wil-playground -n dev 8888:8888"
echo "  Then: curl http://localhost:8888/"
