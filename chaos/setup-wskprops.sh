#!/bin/bash
# =====================================================================
#  setup-wskprops.sh - TẠO ~/.wskprops.c1 / .c2 / .c3
#
#  chaos.sh F5 cần điều khiển wsk trên CẢ 3 CỤM. Mỗi cụm một file cấu hình.
#  File của CỤM NÀY script tự tạo được (đọc khóa guest từ secret).
#  Khóa của 2 cụm kia phải XIN từ bạn cùng nhóm.
#
#  CÁCH DÙNG
#     ./setup-wskprops.sh                       # tạo file cho cụm của máy này
#     ./setup-wskprops.sh c3 100.x.x.x 'uuid:key'   # thêm cụm của bạn khác
#
#  Bạn cùng nhóm lấy khóa guest của họ bằng:
#     kubectl -n openwhisk get secret owdev-whisk.auth -o jsonpath='{.data.guest}' | base64 -d
# =====================================================================
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/chaos.conf"

write_props() {   # write_props <cụm> <ip> <auth>
  local c="$1" ip="$2" auth="$3"
  local f="$HOME/.wskprops.$c"
  cat > "$f" <<EOF
APIHOST=https://${ip}:${OW_PORT}
AUTH=${auth}
NAMESPACE=_
EOF
  chmod 600 "$f"
  echo "✅ Đã ghi $f  (APIHOST=https://${ip}:${OW_PORT})"
}

if [ $# -ge 3 ]; then
  write_props "$1" "$2" "$3"
  exit 0
fi

echo "🔑 Tạo file cấu hình cho cụm của MÁY NÀY (ME=$ME)..."
API_HOST="${API_HOST:-$(tailscale ip -4 2>/dev/null | head -1)}"
[ -n "$API_HOST" ] || { echo "❌ Không lấy được IP Tailscale"; exit 1; }
GUEST_AUTH="$(kubectl -n "$NS" get secret "${RELEASE}-whisk.auth" \
  -o jsonpath='{.data.guest}' 2>/dev/null | base64 -d 2>/dev/null || true)"
[ -n "$GUEST_AUTH" ] || { echo "❌ Không đọc được khóa guest. Cụm đã chạy chưa?"; exit 1; }
write_props "$ME" "$API_HOST" "$GUEST_AUTH"

echo
echo "📋 Tình trạng 3 file:"
for c in c1 c2 c3; do
  if [ -f "$HOME/.wskprops.$c" ]; then
    echo "   ✅ ~/.wskprops.$c"
  else
    v="IP_$c"
    echo "   ❌ ~/.wskprops.$c  -> xin khóa guest của bạn giữ cụm $c rồi chạy:"
    echo "        $HERE/setup-wskprops.sh $c ${!v} 'uuid:key'"
  fi
done
echo
echo "👉 Thiếu file nào thì F5 sẽ bỏ qua cụm đó (vẫn chạy được, chỉ là thiếu dữ liệu)."
