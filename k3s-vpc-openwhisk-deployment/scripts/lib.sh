#!/usr/bin/env bash
# =====================================================================
#  lib.sh - hàm dùng chung cho mọi script (được `source`, KHÔNG chạy trực tiếp)
# =====================================================================

C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[1;33m'; C_C=$'\033[0;36m'; C_N=$'\033[0m'
log()  { printf '%s▶ %s%s\n'   "$C_C" "$*" "$C_N"; }
ok()   { printf '%s✅ %s%s\n'  "$C_G" "$*" "$C_N"; }
warn() { printf '%s⚠️  %s%s\n' "$C_Y" "$*" "$C_N"; }
die()  { printf '%s❌ %s%s\n'  "$C_R" "$*" "$C_N" >&2; exit 1; }

# Tự nâng quyền root nhưng giữ biến môi trường (-E) để K3S_TOKEN đi theo.
# Cách dùng ở đầu script:  need_root "$@"
need_root() { [ "$(id -u)" -eq 0 ] || exec sudo -E bash "$0" "$@"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Thiếu lệnh '$1'"; }

# Chuẩn bị hệ điều hành cho K3s + OpenWhisk (chạy bằng root, trên master và worker)
prep_host() {
  # 1) Swap: kubelet mặc định từ chối chạy khi còn swap, và swap làm JVM (Kafka/Controller)
  #    bị đẩy ra đĩa -> độ trễ đuôi (P99) của K6 tăng vọt khó giải thích.
  if [ -n "$(swapon --show --noheadings 2>/dev/null)" ]; then
    swapoff -a
    sed -ri '/\sswap\s/ s/^/#/' /etc/fstab
  fi

  # 2) inotify: mỗi action pod + kubelet + containerd đều xin inotify. Mặc định của Ubuntu
  #    (128 instance) cạn khi K6 sinh ra hàng chục container mới -> lỗi "too many open files".
  cat >/etc/sysctl.d/99-k3s-openwhisk.conf <<'EOF'
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
net.ipv4.ip_forward = 1
EOF
  sysctl --system >/dev/null

  # 3) ufw (nếu bật): cho phép lưu lượng từ private VPC và dải pod/service.
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    if [ -n "${VPC_CIDR:-}" ]; then
      ufw allow from "$VPC_CIDR" to any port 6443 proto tcp >/dev/null
      ufw allow from "$VPC_CIDR" to any port 10250 proto tcp >/dev/null
      ufw allow from "$VPC_CIDR" to any port 8472 proto udp >/dev/null
      ufw allow from "$VPC_CIDR" to any port 31001 proto tcp >/dev/null
    else
      warn "VPC_CIDR chưa đặt; không tự mở các cổng K3s/OpenWhisk trong UFW"
    fi
    ufw allow from "${CLUSTER_CIDR:-10.42.0.0/16}" >/dev/null
    ufw allow from "${SERVICE_CIDR:-10.43.0.0/16}" >/dev/null
  fi
}

# Drop-in systemd để K3s chờ network-online trước khi bind IP VPC.
install_network_dropin() {  # install_network_dropin <k3s|k3s-agent>
  local unit="$1"
  mkdir -p "/etc/systemd/system/${unit}.service.d"
  cat >"/etc/systemd/system/${unit}.service.d/10-after-network.conf" <<'EOF'
[Unit]
After=network-online.target
Wants=network-online.target
[Service]
ExecStartPre=/bin/sh -c 'for i in $$(seq 1 60); do ip route get 1.1.1.1 >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1'
EOF
  systemctl daemon-reload
}

# "Cửa vào" NodePort 31001 của cụm = IP private (InternalIP, vì ta đặt --node-ip) của
# node đầu tiên có nhãn workload. NodePort được kube-proxy phục vụ trên mọi node.
ow_api_host() {
  kubectl get nodes -l openwhisk-role=invoker \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
}
