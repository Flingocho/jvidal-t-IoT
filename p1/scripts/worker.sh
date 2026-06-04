#!/bin/bash
set -e

apt-get update -qq && apt-get install -y -qq curl

SERVER_IP="192.168.56.110"
WORKER_IP="192.168.56.111"
K3S_TOKEN="IoTK3sToken42"

# Get the network interface associated with the worker IP
IFACE=$(ip -br addr | grep "$WORKER_IP" | awk '{print $1}')

echo ">>> Waiting for K3s server at $SERVER_IP..."
until curl -sk "https://$SERVER_IP:6443/ping" >/dev/null 2>&1; do
  echo "    Server not available, retrying in 5s..."
  sleep 5
done
echo ">>> Server available."

echo ">>> Installing K3s in agent mode (interface: $IFACE)..."
curl -sfL https://get.k3s.io | \
  K3S_URL="https://$SERVER_IP:6443" \
  K3S_TOKEN="$K3S_TOKEN" \
  sh -s - \
    --node-ip="$WORKER_IP" \
    --flannel-iface="$IFACE"

echo ">>> K3s agent ready."
