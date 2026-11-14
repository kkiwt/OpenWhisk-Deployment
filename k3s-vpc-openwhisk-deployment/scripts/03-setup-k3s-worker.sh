#!/usr/bin/env bash
# =====================================================================
#  03-setup-k3s-worker.sh - cài K3s AGENT, join master qua private VPC
#  Chạy trên từng worker, sau 01-setup-vpc-network.sh.
#
#  Cần: K3S_URL=https://<ip-private-master>:6443  và  K3S_TOKEN=...
#       (hoặc đặt file join.env do script 02 sinh ra ở thư mục gốc repo)
# =====================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
need_root "$@"

JOIN_ENV="${JOIN_ENV:-$ROOT_DIR/join.env}"
if { [ -z "${K3S_URL:-}" ] || [ -z "${K3S_TOKEN:-}" ]; } && [ -f "$JOIN_ENV" ]; then
  set -a; source "$JOIN_ENV"; set +a
fi
: "${K3S_URL:?Thiếu K3S_URL (https://<ip-private-master>:6443)}"
: "${K3S_TOKEN:?Thiếu K3S_TOKEN (lấy trong join.env trên master)}"

K3S_VERSION="${K3S_VERSION:-v1.35.5+k3s1}"   # PHẢI khớp master: agent mới hơn server là cấu hình không được hỗ trợ
NODE_NAME="$(echo "${NODE_NAME:-$(hostname -s)}" | tr '[:upper:]' '[:lower:]')"
OW_ROLE_LABEL="${OW_ROLE_LABEL:-openwhisk-role=invoker}"

NODE_IP="${NODE_IP:-$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')}"
FLANNEL_IFACE="${FLANNEL_IFACE:-$(ip -4 route get 1.1.1.1 | awk '{print $5; exit}')}"
[ -n "$NODE_IP" ] || die "Không xác định được NODE_IP; đặt NODE_IP=<private-ip>"
[ -n "$FLANNEL_IFACE" ] || die "Không xác định được FLANNEL_IFACE; đặt FLANNEL_IFACE=<vpc-interface>"
MASTER_IP="${K3S_URL#https://}"; MASTER_IP="${MASTER_IP%%:*}"
ok "IP private của worker: $NODE_IP ($FLANNEL_IFACE) | master: $MASTER_IP"

# Kiểm tra trước khi cài: lỗi firewall/VPC là nguyên nhân số 1 khiến agent join treo.
log "Kiểm tra đường tới master..."
if [ "$(curl -sk --max-time 8 "${K3S_URL}/ping" || true)" != "pong" ]; then
  die "Không gọi được ${K3S_URL}/ping. Kiểm tra VPC firewall cho phép tcp:6443."
fi
ok "Supervisor của master trả lời"

log "Chuẩn bị hệ điều hành..."
prep_host
install_network_dropin k3s-agent

AGENT_FLAGS=(
  --node-ip "$NODE_IP"
  --node-name "$NODE_NAME"
  --flannel-iface "$FLANNEL_IFACE"
  --node-label "$OW_ROLE_LABEL"
)

log "Cài K3s agent ${K3S_VERSION}..."
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" \
  K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" sh -s - agent "${AGENT_FLAGS[@]}"

for _ in $(seq 1 30); do systemctl is-active --quiet k3s-agent && break; sleep 2; done
systemctl is-active --quiet k3s-agent || die "k3s-agent không chạy. Xem: journalctl -u k3s-agent -n 50"

echo "============================================================"
ok "Worker ${NODE_NAME} đã gửi yêu cầu join."
echo "👉 Trên MASTER chạy: ./scripts/04-verify-cluster.sh  (sau khi các agent đã join)"
echo "============================================================"
