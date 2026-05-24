#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq && apt-get install -y -qq curl

SERVER_IP="192.168.56.110"
K3S_TOKEN="IoTK3sToken42"

IFACE=$(ip -br addr | grep "$SERVER_IP" | awk '{print $1}')

echo ">>> Installing K3s in server mode (interface: $IFACE)..."
curl -sfL https://get.k3s.io | K3S_TOKEN="$K3S_TOKEN" sh -s - \
  --node-ip="$SERVER_IP" \
  --flannel-iface="$IFACE" \
  --tls-san="$SERVER_IP" \
  --write-kubeconfig-mode=644

echo ">>> Waiting for K3s to be ready..."
until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
  sleep 3
done
kubectl wait --for=condition=ready node --all --timeout=180s

echo ">>> Deploying applications..."
kubectl apply -f /tmp/confs/

echo ">>> Waiting for pods to be ready..."
kubectl rollout status deployment/app-one --timeout=300s
kubectl rollout status deployment/app-two --timeout=300s
kubectl rollout status deployment/app-three --timeout=300s

echo ">>> Done."
kubectl get all
