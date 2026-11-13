#!/usr/bin/env bash
# =====================================================================
#  02-setup-k3s-master.sh - cài K3s SERVER, gắn chặt vào IP Tailscale
#  Chạy trên VM master, SAU 01-install-tailscale.sh.
#
#  Biến tùy chọn:
#    K3S_VERSION=v1.35.5+k3s1   (pin để các node dùng cùng phiên bản)
#    NODE_NAME=k3s-cloud-master TAINT_MASTER=0 EXTRA_TLS_SAN=a.b.c.d,host.example
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

need_cmd tailscale
TS_IP="$(ts_ip)" || die "tailscale0 chưa có IPv4. Chạy 01-install-tailscale.sh trước."
ok "IP Tailscale của master: $TS_IP"

# Dải pod/service của K3s KHÔNG được trùng dải của VPC CloudFly, nếu trùng route sẽ sai
# âm thầm (ping được nhưng TCP chết). Chỉ cảnh báo vì không biết dải VPC của bạn.
ROUTES="$(ip -o route | awk '{print $1}')"   # tách khỏi pipe: grep -q thoát sớm + pipefail sẽ báo sai
if grep -Eq '^10\.(42|43)\.' <<< "$ROUTES"; then
  warn "Bảng route đã có dải 10.42/10.43 -> có thể trùng VPC. Đổi CLUSTER_CIDR / SERVICE_CIDR."
fi

log "Chuẩn bị hệ điều hành (swap, inotify, ufw)..."
prep_host
install_tailscale_dropin k3s

# Mảng cờ để chú thích được TỪNG cờ (comment trong dòng nối `\` thì bash không cho).
K3S_FLAGS=(
  # Mặc định K3s lấy IP của interface mặc định (IP VPC/public CloudFly). Các node kia sẽ cố nói
  # chuyện với IP đó, đi ra ngoài tailnet và bị security-group chặn. Ép về IP Tailscale để
  # kubelet, flannel, logs/exec đều đi trong tunnel WireGuard.
  --node-ip "$TS_IP"
  # Địa chỉ API server quảng bá trong Endpoints của `kubernetes.default`. Pod (invoker gọi
  # K8s API để tạo action pod) dùng nó nên phải là IP mà MỌI node tới được.
  --advertise-address "$TS_IP"
  # API server + supervisor (cổng 6443) CHỈ nghe trên tailscale0, không lộ ra IP public/VPC.
  # Đánh đổi: nếu k3s start trước khi Tailscale có IP thì bind lỗi -> đã có drop-in systemd ở trên.
  --bind-address "$TS_IP"
  # Cert của API server phải chứa IP Tailscale, nếu không worker và kubectl từ xa báo x509.
  --tls-san "$TS_IP"
  --node-name "$NODE_NAME"
  # Flannel chạy VXLAN BÊN TRONG tunnel Tailscale: mọi lưu lượng pod<->pod xuyên node đều đã
  # được WireGuard mã hóa. tailscale0 có MTU 1280, flannel tự trừ 50 byte VXLAN -> MTU pod 1230.
  --flannel-iface tailscale0
  # Cố ý dùng vxlan, KHÔNG dùng wireguard-native: nó mã hóa lần hai (WireGuard trong WireGuard),
  # tốn CPU trên VM 4 vCPU và hạ MTU thêm nữa.
  --flannel-backend vxlan
  # (Cố ý KHÔNG đặt --node-external-ip: nếu có, flannel lấy nó làm endpoint của tunnel và kéo
  #  lưu lượng ra IP public thay vì tailscale0.)
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
K3S_URL=https://${TS_IP}:6443
K3S_TOKEN=${K3S_TOKEN}
EOF
)
chown "$TARGET_USER:" "$JOIN_ENV"

# --- kubeconfig cho user thường -------------------------------------------------------
# Ép server về IP Tailscale: nếu API chỉ nghe trên tailscale0 thì 127.0.0.1:6443 sẽ từ chối.
mkdir -p "$TARGET_HOME/.kube"
sed -E "s#(server: https://)[^:]+(:6443)#\1${TS_IP}\2#" /etc/rancher/k3s/k3s.yaml > "$TARGET_HOME/.kube/config"
chmod 600 "$TARGET_HOME/.kube/config"
chown -R "$TARGET_USER:" "$TARGET_HOME/.kube"

echo "============================================================"
ok "K3s master sẵn sàng. API: https://${TS_IP}:6443"
echo "   K3S_TOKEN đã lưu (chmod 600) tại: $JOIN_ENV"
echo
echo "👉 Trên MỖI worker (sau khi chạy 01-install-tailscale.sh), chạy:"
echo "   sudo K3S_URL=https://${TS_IP}:6443 K3S_TOKEN='<nội dung trong join.env>' \\"
echo "        NODE_NAME=k3s-cloud-w1 ./scripts/03-setup-k3s-worker.sh"
echo "   (hoặc chép join.env vào thư mục gốc repo trên worker: script tự đọc)"
echo "👉 K3S_TOKEN = chìa khóa join cụm: không dán vào chat/commit lên git."
echo "============================================================"
