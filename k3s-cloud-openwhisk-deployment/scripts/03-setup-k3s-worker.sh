#!/usr/bin/env bash
# =====================================================================
#  03-setup-k3s-worker.sh - cài K3s AGENT, join master qua IP Tailscale
#  Chạy trên từng worker, SAU 01-install-tailscale.sh.
#
#  Cần: K3S_URL=https://<ip-tailscale-master>:6443  và  K3S_TOKEN=...
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
: "${K3S_URL:?Thiếu K3S_URL (https://<ip-tailscale-master>:6443)}"
: "${K3S_TOKEN:?Thiếu K3S_TOKEN (lấy trong join.env trên master)}"

K3S_VERSION="${K3S_VERSION:-v1.35.5+k3s1}"   # PHẢI khớp master: agent mới hơn server là cấu hình không được hỗ trợ
NODE_NAME="$(echo "${NODE_NAME:-$(hostname -s)}" | tr '[:upper:]' '[:lower:]')"
OW_ROLE_LABEL="${OW_ROLE_LABEL:-openwhisk-role=invoker}"

need_cmd tailscale
TS_IP="$(ts_ip)" || die "tailscale0 chưa có IPv4. Chạy 01-install-tailscale.sh trước."
MASTER_IP="${K3S_URL#https://}"; MASTER_IP="${MASTER_IP%%:*}"
ok "IP Tailscale của worker: $TS_IP  |  master: $MASTER_IP"

# Kiểm tra TRƯỚC khi cài: lỗi mạng/ACL Tailscale là nguyên nhân số 1 khiến agent join treo.
log "Kiểm tra đường tới master..."
tailscale ping -c 2 "$MASTER_IP" || warn "tailscale ping lỗi (ACL chặn hoặc master chưa lên tailnet?)"
if [ "$(curl -sk --max-time 8 "${K3S_URL}/ping" || true)" != "pong" ]; then
  die "Không gọi được ${K3S_URL}/ping. Kiểm tra ACL Tailscale (cho phép tcp:6443) và master đã chạy chưa."
fi
ok "Supervisor của master trả lời"

log "Chuẩn bị hệ điều hành..."
prep_host
install_tailscale_dropin k3s-agent

AGENT_FLAGS=(
  # Cùng lý do như master: kubelet đăng ký bằng IP Tailscale để master/các node khác
  # (logs, exec, metrics, VXLAN) nói chuyện với nó trong tunnel.
  --node-ip "$TS_IP"
  --node-name "$NODE_NAME"
  # Phải giống master. Nếu worker để mặc định flannel sẽ chọn interface VPC -> VXLAN đi
  # ngoài Tailscale, một nửa pod<->pod xuyên node chạy đường khác và lệch MTU.
  --flannel-iface tailscale0
  # Gắn nhãn ngay lúc đăng ký (không cần kubectl label sau). Chart OpenWhisk dùng nhãn này để
  # xếp invoker vào worker; trùng quy ước với cụm k3d trong golden-config.
  --node-label "$OW_ROLE_LABEL"
)

log "Cài K3s agent ${K3S_VERSION}..."
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" \
  K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" sh -s - agent "${AGENT_FLAGS[@]}"

for _ in $(seq 1 30); do systemctl is-active --quiet k3s-agent && break; sleep 2; done
systemctl is-active --quiet k3s-agent || die "k3s-agent không chạy. Xem: journalctl -u k3s-agent -n 50"

echo "============================================================"
ok "Worker ${NODE_NAME} đã gửi yêu cầu join."
echo "👉 Trên MASTER chạy: ./scripts/04-verify-cluster.sh  (sau khi cả 2 worker đã join)"
echo "============================================================"
