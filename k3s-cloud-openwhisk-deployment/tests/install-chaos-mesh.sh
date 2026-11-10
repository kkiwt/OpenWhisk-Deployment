#!/usr/bin/env bash
# =====================================================================
#  install-chaos-mesh.sh - cài Chaos Mesh cho K3s (chạy trên master, user thường)
#  Biến: CHAOS_MESH_VERSION=2.7.2   (xem: helm search repo chaos-mesh/chaos-mesh --versions)
# =====================================================================
set -Eeuo pipefail
command -v helm >/dev/null 2>&1 || { echo "❌ Thiếu helm (chạy openwhisk/install-openwhisk.sh trước)"; exit 1; }
CHAOS_MESH_VERSION="${CHAOS_MESH_VERSION:-2.7.2}"

helm repo add chaos-mesh https://charts.chaos-mesh.org >/dev/null 2>&1 || true
helm repo update >/dev/null

# --set chaosDaemon.runtime=containerd + socketPath: K3s KHÔNG dùng docker mà chạy containerd
#       riêng với socket ở /run/k3s/containerd/containerd.sock (không phải /run/containerd/...).
#       Sai socket -> chaos-daemon không vào được network namespace của pod -> NetworkChaos báo OK nhưng không có tác dụng.
# --set controllerManager.replicaCount=1: mặc định chart chạy 3 replica; tốn RAM vô ích trên cụm 16 GB.
# --set dashboard.create=false: không cần UI, và UI mặc định không có xác thực.
# chaos-daemon là DaemonSet nên không chạy trên master (bị taint): đúng ý, ta chỉ gây lỗi ở worker.
helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace chaos-mesh --create-namespace --version "$CHAOS_MESH_VERSION" \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/k3s/containerd/containerd.sock \
  --set controllerManager.replicaCount=1 \
  --set dashboard.create=false

kubectl -n chaos-mesh rollout status deploy/chaos-controller-manager --timeout=300s
kubectl -n chaos-mesh rollout status ds/chaos-daemon --timeout=300s
echo "✅ Chaos Mesh sẵn sàng. Thử: kubectl apply -f tests/chaos-pod-kill.yaml"
