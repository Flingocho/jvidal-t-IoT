#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq && apt-get install -y -qq curl

SERVER_IP="192.168.56.110"
K3S_TOKEN="IoTK3sToken42"

# Get the network interface associated with the server IP
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

# Vagrant user needs access to kubeconfig
mkdir -p /home/vagrant/.kube
cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
chown vagrant:vagrant /home/vagrant/.kube/config
chmod 600 /home/vagrant/.kube/config

echo ">>> K3s server ready."
kubectl get nodes -o wide
