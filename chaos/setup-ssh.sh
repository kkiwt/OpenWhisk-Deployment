#!/bin/bash
# =====================================================================
#  setup-ssh.sh - TẠO KHÓA SSH VÀ CHÉP SANG 2 MÁY CÒN LẠI
#
#  chaos.sh F1 / F2 / F4 cần chạy lệnh trên máy của bạn cùng nhóm.
#  Phải đăng nhập SSH KHÔNG HỎI MẬT KHẨU, nếu không script sẽ treo giữa chừng
#  và mốc thời gian trong chaos.csv sẽ sai.
#
#  CÁCH DÙNG
#     ./setup-ssh.sh            # tạo khóa + chép sang các máy khai báo trong chaos.conf
#     ./setup-ssh.sh --check    # chỉ kiểm tra, không chép
#
#  YÊU CẦU: máy kia đã bật SSH server:  sudo apt install -y openssh-server
# =====================================================================
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/chaos.conf"

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then CHECK_ONLY=1; fi

KEY="$HOME/.ssh/id_ed25519"
if [ "$CHECK_ONLY" -eq 0 ] && [ ! -f "$KEY" ]; then
  echo "🔑 Chưa có khóa SSH, đang tạo..."
  ssh-keygen -t ed25519 -N "" -f "$KEY"
fi

for c in c1 c2 c3; do
  if [ "$c" = "$ME" ]; then continue; fi
  v="SSH_$c"; host="${!v:-}"
  [ -n "$host" ] || { echo "⏭  Bỏ qua $c (chưa khai báo SSH_$c)"; continue; }

  if ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" "echo ok" &>/dev/null; then
    echo "✅ $c ($host): đăng nhập không mật khẩu OK"
    continue
  fi

  if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "❌ $c ($host): CHƯA vào được. Chạy lại script này không kèm --check."
    continue
  fi

  echo "📤 $c ($host): đang chép khóa (sẽ hỏi mật khẩu máy đó một lần)..."
  ssh-copy-id -o ConnectTimeout=10 "$host" || {
    echo "   ❌ Chép thất bại. Kiểm tra: máy kia đã bật sshd chưa, user/IP đúng chưa."
    continue
  }
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" "echo ok" &>/dev/null \
    && echo "   ✅ Xong" || echo "   ⚠️  Vẫn chưa vào được"
done

echo
echo "🧪 Thử lệnh thật mà chaos.sh sẽ dùng:"
for c in c1 c2 c3; do
  if [ "$c" = "$ME" ]; then continue; fi
  v="SSH_$c"; host="${!v:-}"; [ -n "$host" ] || continue
  out="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" \
        "docker ps --format '{{.Names}}' | grep -c '^k3d-' || true" 2>/dev/null || echo "LỖI")"
  echo "   $c: số container k3d đang chạy = $out"
done
