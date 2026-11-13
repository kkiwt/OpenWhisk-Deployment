#!/usr/bin/env bash
# =====================================================================
#  lib.sh - hàm dùng chung cho mọi script (được `source`, KHÔNG chạy trực tiếp)
# =====================================================================

C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[1;33m'; C_C=$'\033[0;36m'; C_N=$'\033[0m'
log()  { printf '%s▶ %s%s\n'   "$C_C" "$*" "$C_N"; }
ok()   { printf '%s✅ %s%s\n'  "$C_G" "$*" "$C_N"; }
warn() { printf '%s⚠️  %s%s\n' "$C_Y" "$*" "$C_N"; }
die()  { printf '%s❌ %s%s\n'  "$C_R" "$*" "$C_N" >&2; exit 1; }

# Tự nâng quyền root nhưng GIỮ biến môi trường (-E) để TS_AUTHKEY / K3S_TOKEN đi theo.
# Cách dùng ở đầu script:  need_root "$@"
need_root() { [ "$(id -u)" -eq 0 ] || exec sudo -E bash "$0" "$@"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Thiếu lệnh '$1'"; }

# IPv4 Tailscale của máy này. Đây là nguồn sự thật DUY NHẤT cho --node-ip.
# Chờ tối đa ~60s vì ngay sau `tailscale up` interface tailscale0 có thể chưa có địa chỉ.
ts_ip() {
  local addr i
  for i in $(seq 1 30); do
    addr="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
    if [ -n "$addr" ]; then echo "$addr"; return 0; fi
    sleep 2
  done
  return 1
}

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

  # 3) ufw (nếu bật): tin cậy toàn bộ lưu lượng đến từ tailscale0 (kể cả VXLAN UDP 8472 của
  #    flannel chạy BÊN TRONG tunnel) và dải pod/service. KHÔNG mở 6443/31001 ra interface public.
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow in on tailscale0 >/dev/null
    ufw allow from "${CLUSTER_CIDR:-10.42.0.0/16}" >/dev/null
    ufw allow from "${SERVICE_CIDR:-10.43.0.0/16}" >/dev/null
  fi
}

# Drop-in systemd: bắt k3s/k3s-agent đợi Tailscale có IP rồi mới chạy.
# Vì sao: --bind-address / --node-ip trỏ vào IP Tailscale. Sau khi reboot VM, nếu k3s khởi động
# trước khi tailscale0 có địa chỉ thì bind thất bại và service crash-loop.
# Lưu ý `$$`: systemd dùng `$` cho biến của nó, muốn truyền `$` nguyên văn phải viết `$$`.
install_tailscale_dropin() {  # install_tailscale_dropin <k3s|k3s-agent>
  local unit="$1"
  mkdir -p "/etc/systemd/system/${unit}.service.d"
  cat >"/etc/systemd/system/${unit}.service.d/10-after-tailscale.conf" <<'EOF'
[Unit]
After=tailscaled.service network-online.target
Wants=tailscaled.service network-online.target
[Service]
ExecStartPre=/bin/sh -c 'for i in $$(seq 1 60); do tailscale ip -4 2>/dev/null | grep -q . && exit 0; sleep 2; done; exit 1'
EOF
  systemctl daemon-reload
}

# "Cửa vào" NodePort 31001 của cụm = IP Tailscale (InternalIP, vì ta đặt --node-ip) của
# node đầu tiên có nhãn workload. NodePort được kube-proxy phục vụ trên mọi node.
ow_api_host() {
  kubectl get nodes -l openwhisk-role=invoker \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
}
