#!/usr/bin/env bash
# =====================================================================
#  01-setup-vpc-network.sh - kiểm tra network private VPC cho K3s
#  Chạy trên cả server và agent trước khi cài K3s.
#
#  Có thể đặt:
#    NODE_IP=10.0.0.10
#    FLANNEL_IFACE=eth0
#    VPC_CIDR=10.0.0.0/24
# =====================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
need_root "$@"

NODE_IP="${NODE_IP:-$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')}"
FLANNEL_IFACE="${FLANNEL_IFACE:-$(ip -4 route get 1.1.1.1 | awk '{print $5; exit}')}"

[ -n "$NODE_IP" ] || die "Không xác định được NODE_IP; đặt NODE_IP=<private-ip>"
[ -n "$FLANNEL_IFACE" ] || die "Không xác định được FLANNEL_IFACE; đặt FLANNEL_IFACE=<vpc-interface>"

need_cmd ip
need_cmd awk
ok "NODE_IP=$NODE_IP"
ok "FLANNEL_IFACE=$FLANNEL_IFACE"

if ip -4 addr show dev "$FLANNEL_IFACE" | grep -q "inet $NODE_IP/"; then
  ok "NODE_IP thuộc interface $FLANNEL_IFACE"
else
  die "NODE_IP không thuộc interface $FLANNEL_IFACE"
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  if [ -n "${VPC_CIDR:-}" ]; then
    ufw allow from "$VPC_CIDR" to any port 6443 proto tcp >/dev/null
    ufw allow from "$VPC_CIDR" to any port 10250 proto tcp >/dev/null
    ufw allow from "$VPC_CIDR" to any port 8472 proto udp >/dev/null
    ufw allow from "$VPC_CIDR" to any port 31001 proto tcp >/dev/null
    ok "Đã mở các cổng K3s/OpenWhisk trong VPC CIDR"
  else
    warn "VPC_CIDR chưa đặt; chưa tự mở cổng trong UFW"
  fi
else
  warn "UFW không active; hãy mở cổng trong Cloud Firewall/VPC Security Group"
fi

echo "============================================================"
ok "Network VPC sẵn sàng cho K3s"
echo "   Server: NODE_IP=<private-ip> ./scripts/02-setup-k3s-master.sh"
echo "   Agent:  NODE_IP=<private-ip> K3S_URL=https://<server-private-ip>:6443 \\"
echo "           ./scripts/03-setup-k3s-worker.sh"
echo "============================================================"
