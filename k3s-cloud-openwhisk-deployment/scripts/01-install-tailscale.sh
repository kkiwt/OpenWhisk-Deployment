#!/usr/bin/env bash
# =====================================================================
#  01-install-tailscale.sh - chạy trên CẢ 3 VM (master + 2 worker)
#
#  Cách dùng:
#    TS_AUTHKEY='tskey-auth-xxxx' TS_HOSTNAME=k3s-cloud-master ./01-install-tailscale.sh
#    TS_AUTHKEY='tskey-auth-xxxx' TS_HOSTNAME=k3s-cloud-w1     ./01-install-tailscale.sh
#    TS_AUTHKEY='tskey-auth-xxxx' TS_HOSTNAME=k3s-cloud-w2     ./01-install-tailscale.sh
# =====================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
need_root "$@"

# Auth key đọc từ biến môi trường (hoặc hỏi ẩn), KHÔNG ghi cứng vào script.
# Lý do: key tái sử dụng là "chìa khóa vạn năng" vào tailnet. Commit nhầm lên GitHub là ai
# cũng tự join máy vào mạng của nhóm và chạm được cổng 6443/31001 của cụm.
TS_AUTHKEY="${TS_AUTHKEY:-}"
if [ -z "$TS_AUTHKEY" ] && [ -t 0 ]; then
  read -rsp "Nhập Tailscale auth key (không hiển thị): " TS_AUTHKEY; echo
fi
[ -n "$TS_AUTHKEY" ] || die "Thiếu TS_AUTHKEY. Ví dụ: TS_AUTHKEY='tskey-auth-xxxx' $0"

# Hostname phải duy nhất trong tailnet: nếu 3 VM CloudFly cùng hostname mặc định,
# Tailscale sẽ đổi thành host-1, host-2... và bạn mất khả năng đoán tên node.
TS_HOSTNAME="${TS_HOSTNAME:-$(hostname -s)}"

if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled

# --accept-dns=false : MagicDNS sẽ ghi đè /etc/resolv.conf bằng 100.100.100.100. CoreDNS của
#                      K3s forward ra resolv.conf của node, và từ trong pod thì 100.100.100.100
#                      không phải lúc nào cũng tới được -> DNS trong pod chập chờn rất khó debug.
# --reset            : `tailscale up` từ chối chạy lại nếu cờ khác lần trước; --reset giúp
#                      script chạy lặp (idempotent) mà không phải nhớ cờ cũ.
tailscale up --auth-key="$TS_AUTHKEY" --hostname="$TS_HOSTNAME" --accept-dns=false --reset
unset TS_AUTHKEY

TS_IP="$(ts_ip)" || die "tailscale0 chưa có IPv4 sau 60s. Kiểm tra: tailscale status"
ok "Tailscale IP của ${TS_HOSTNAME}: ${TS_IP}"
tailscale status | head -n 10
echo
echo "👉 Ghi lại IP này. Đường đi giữa các node nên là 'direct' (cùng VPC), không phải 'relay/DERP':"
echo "   tailscale ping <ip-node-kia>"
