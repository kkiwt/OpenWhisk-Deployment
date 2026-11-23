#!/usr/bin/env bash
# =====================================================================
#  02-setup-k3s-master.sh - cài K3s SERVER trên private VPC
#  Chạy trên VM master, sau 01-setup-vpc-network.sh.
#
#  Biến tùy chọn:
#    K3S_VERSION=v1.35.5+k3s1   (pin để các node dùng cùng phiên bản)
#    NODE_NAME=k3s-vpc-server NODE_IP=10.0.0.10 TAINT_MASTER=0 EXTRA_TLS_SAN=a.b.c.d
#    CLUSTER_CIDR=10.42.0.0/16 SERVICE_CIDR=10.43.0.0/16
# =====================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
need_root "$@"

K3S_VERSION="${K3S_VERSION:-v1.35.5+k3s1}"
NODE_NAME="$(echo "${NODE_NAME:-$(hostname -s)}" | tr '[:upper:]' '[:lower:]')"  # tên node K8s phải là chữ thường
TAINT_MASTER="${TAINT_MASTER:-0}"
EXTRA_TLS_SAN="${EXTRA_TLS_SAN:-}"
CLUSTER_CIDR="${CLUSTER_CIDR:-10.42.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.43.0.0/16}"
JOIN_ENV="${JOIN_ENV:-$ROOT_DIR/join.env}"


NODE_IP="${NODE_IP:-$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')}"
FLANNEL_IFACE="${FLANNEL_IFACE:-$(ip -4 route get 1.1.1.1 | awk '{print $5; exit}')}"
[ -n "$NODE_IP" ] || die "Không xác định được NODE_IP; đặt NODE_IP=<private-ip>"
[ -n "$FLANNEL_IFACE" ] || die "Không xác định được FLANNEL_IFACE; đặt FLANNEL_IFACE=<vpc-interface>"
ok "IP private của master: $NODE_IP ($FLANNEL_IFACE)"

# Dải pod/service của K3s KHÔNG được trùng dải của VPC CloudFly, nếu trùng route sẽ sai
# âm thầm (ping được nhưng TCP chết). Chỉ cảnh báo vì không biết dải VPC của bạn.
ROUTES="$(ip -o route | awk '{print $1}')"   # tách khỏi pipe: grep -q thoát sớm + pipefail sẽ báo sai
if grep -Eq '^10\.(42|43)\.' <<< "$ROUTES"; then
  warn "Bảng route đã có dải 10.42/10.43 -> có thể trùng VPC. Đổi CLUSTER_CIDR / SERVICE_CIDR."
fi

log "Chuẩn bị hệ điều hành (swap, inotify, ufw)..."
prep_host
install_network_dropin k3s

# Mảng cờ để chú thích được TỪNG cờ (comment trong dòng nối `\` thì bash không cho).
K3S_FLAGS=(
  --node-ip "$NODE_IP"
  --advertise-address "$NODE_IP"
  --bind-address "$NODE_IP"
  --tls-san "$NODE_IP"
  --node-name "$NODE_NAME"
  --flannel-iface "$FLANNEL_IFACE"
  --flannel-backend vxlan
  --cluster-cidr "$CLUSTER_CIDR"
  --service-cidr "$SERVICE_CIDR"
  # OpenWhisk có nginx riêng (NodePort 31001). Traefik + ServiceLB chỉ ăn RAM và giành cổng 80/443.
  --disable traefik
  --disable servicelb
  # kubeconfig gốc chỉ root đọc được; bên dưới ta chép bản riêng cho user thường.
  --write-kubeconfig-mode 0600
)
if [ "$TAINT_MASTER" = "1" ]; then
  # Chỉ bật khi muốn dành riêng server cho control-plane. Mặc định server được chạy workload
  # để tận dụng 4 GB RAM trong mô hình nhỏ.
  K3S_FLAGS+=(--node-taint "node-role.kubernetes.io/control-plane:NoSchedule")
fi
if [ -n "$EXTRA_TLS_SAN" ]; then
  IFS=',' read -r -a _sans <<< "$EXTRA_TLS_SAN"
  for s in "${_sans[@]}"; do K3S_FLAGS+=(--tls-san "$s"); done
fi

log "Cài K3s server ${K3S_VERSION}..."
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server "${K3S_FLAGS[@]}"

log "Chờ master Ready..."
for _ in $(seq 1 60); do
  if KUBECONFIG=/etc/rancher/k3s/k3s.yaml k3s kubectl get node "$NODE_NAME" 2>/dev/null | grep -q ' Ready'; then break; fi
  sleep 3
done
KUBECONFIG=/etc/rancher/k3s/k3s.yaml k3s kubectl get nodes -o wide || die "API server không trả lời. Xem: journalctl -u k3s -n 50"
KUBECONFIG=/etc/rancher/k3s/k3s.yaml k3s kubectl label node "$NODE_NAME" openwhisk-role=invoker --overwrite >/dev/null
ok "Master Ready"

# --- K3S_TOKEN + lệnh join cho worker -------------------------------------------------
K3S_TOKEN="$(cat /var/lib/rancher/k3s/server/node-token)"
TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
( umask 077
  cat >"$JOIN_ENV" <<EOF
K3S_URL=https://${NODE_IP}:6443
K3S_TOKEN=${K3S_TOKEN}
EOF
)
chown "$TARGET_USER:" "$JOIN_ENV"

# --- kubeconfig cho user thường -------------------------------------------------------
# Ép kubeconfig về IP private để worker và người quản trị trong VPC dùng được.
mkdir -p "$TARGET_HOME/.kube"
sed -E "s#(server: https://)[^:]+(:6443)#\1${NODE_IP}\2#" /etc/rancher/k3s/k3s.yaml > "$TARGET_HOME/.kube/config"
chmod 600 "$TARGET_HOME/.kube/config"
chown -R "$TARGET_USER:" "$TARGET_HOME/.kube"

echo "============================================================"
ok "K3s master sẵn sàng. API: https://${NODE_IP}:6443"
echo "   K3S_TOKEN đã lưu (chmod 600) tại: $JOIN_ENV"
echo
echo "👉 Trên MỖI worker (sau khi chạy 01-setup-vpc-network.sh), chạy:"
echo "   sudo K3S_URL=https://${NODE_IP}:6443 K3S_TOKEN='<nội dung trong join.env>' \\"
echo "        NODE_NAME=k3s-cloud-w1 ./scripts/03-setup-k3s-worker.sh"
echo "   (hoặc chép join.env vào thư mục gốc repo trên worker: script tự đọc)"
echo "👉 K3S_TOKEN = chìa khóa join cụm: không dán vào chat/commit lên git."
echo "============================================================"
