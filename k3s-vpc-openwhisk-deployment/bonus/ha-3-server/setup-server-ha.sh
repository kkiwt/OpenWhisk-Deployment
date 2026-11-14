#!/usr/bin/env bash
# Bootstrap one server in a fresh 3-server K3s embedded-etcd cluster.
#
# First server:
#   CLUSTER_INIT=1 NODE_IP=... NODE_NAME=c1-server-1 ./setup-server-ha.sh
# Additional servers:
#   copy join.env from server 1, then use CLUSTER_INIT=0.
set -Eeuo pipefail
trap 'echo "Stopped at line $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
need_root "$@"

K3S_VERSION="${K3S_VERSION:-v1.35.5+k3s1}"
CLUSTER_INIT="${CLUSTER_INIT:-1}"
NODE_NAME="$(echo "${NODE_NAME:-$(hostname -s)}" | tr '[:upper:]' '[:lower:]')"
NODE_IP="${NODE_IP:-}"
FLANNEL_IFACE="${FLANNEL_IFACE:-}"
VPC_CIDR="${VPC_CIDR:-}"
JOIN_ENV="${JOIN_ENV:-$SCRIPT_DIR/join.env}"
CLUSTER_CIDR="${CLUSTER_CIDR:-10.42.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.43.0.0/16}"
TAINT_MASTER="${TAINT_MASTER:-0}"

[[ "$CLUSTER_INIT" == "0" || "$CLUSTER_INIT" == "1" ]] ||
  die "CLUSTER_INIT phải là 0 hoặc 1"
if [ "$CLUSTER_INIT" = "0" ] && [ -f "$JOIN_ENV" ]; then
  set -a
  source "$JOIN_ENV"
  set +a
fi
if [ "$CLUSTER_INIT" = "0" ]; then
  : "${K3S_URL:?Thiếu K3S_URL trong join.env của server đầu tiên}"
  : "${K3S_TOKEN:?Thiếu K3S_TOKEN trong join.env của server đầu tiên}"
fi

NODE_IP="${NODE_IP:-$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')}"
FLANNEL_IFACE="${FLANNEL_IFACE:-$(ip -4 route get 1.1.1.1 | awk '{print $5; exit}')}"
[ -n "$NODE_IP" ] || die "Thiếu NODE_IP"
[ -n "$FLANNEL_IFACE" ] || die "Thiếu FLANNEL_IFACE"

prep_host
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active' &&
  [ -n "$VPC_CIDR" ]; then
  ufw allow from "$VPC_CIDR" to any port 2379:2380 proto tcp >/dev/null
fi
install_network_dropin k3s

FLAGS=(
  --node-ip "$NODE_IP"
  --advertise-address "$NODE_IP"
  --bind-address "$NODE_IP"
  --tls-san "$NODE_IP"
  --node-name "$NODE_NAME"
  --flannel-iface "$FLANNEL_IFACE"
  --flannel-backend vxlan
  --cluster-cidr "$CLUSTER_CIDR"
  --service-cidr "$SERVICE_CIDR"
  --disable traefik
  --disable servicelb
  --write-kubeconfig-mode 0600
)
[ "$TAINT_MASTER" = "1" ] &&
  FLAGS+=(--node-taint "node-role.kubernetes.io/control-plane:NoSchedule")
[ "$CLUSTER_INIT" = "1" ] && FLAGS+=(--cluster-init)

if [ "$CLUSTER_INIT" = "0" ]; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" \
    K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" sh -s - server "${FLAGS[@]}"
else
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" \
    sh -s - server "${FLAGS[@]}"
fi

for _ in $(seq 1 60); do
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml k3s kubectl get node "$NODE_NAME" 2>/dev/null |
    grep -q ' Ready' && break
  sleep 3
done
KUBECONFIG=/etc/rancher/k3s/k3s.yaml k3s kubectl get nodes -o wide
KUBECONFIG=/etc/rancher/k3s/k3s.yaml k3s kubectl label node "$NODE_NAME" \
  openwhisk-role=invoker --overwrite >/dev/null

if [ "$CLUSTER_INIT" = "1" ]; then
  TARGET_USER="${SUDO_USER:-root}"
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  TOKEN="$(cat /var/lib/rancher/k3s/server/node-token)"
  (umask 077; cat > "$JOIN_ENV" <<EOF
K3S_URL=https://${NODE_IP}:6443
K3S_TOKEN=${TOKEN}
EOF
  )
  chown "$TARGET_USER:" "$JOIN_ENV"
  echo "Copy $JOIN_ENV to server 2 and server 3."
  echo "Run there with CLUSTER_INIT=0 and a different NODE_IP/NODE_NAME."
  mkdir -p "$TARGET_HOME/.kube"
  sed -E "s#(server: https://)[^:]+(:6443)#\1${NODE_IP}\2#" \
    /etc/rancher/k3s/k3s.yaml > "$TARGET_HOME/.kube/config"
  chmod 600 "$TARGET_HOME/.kube/config"
  chown -R "$TARGET_USER:" "$TARGET_HOME/.kube"
fi
ok "HA server $NODE_NAME is ready"
