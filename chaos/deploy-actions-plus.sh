#!/bin/bash
# =====================================================================
#  deploy-actions-plus.sh - TẠO NỐT CÁC ACTION MÀ GOLDEN CHƯA TẠO
#
#  golden/deploy-actions.sh chỉ tạo: ping, test-thu  (để Gateway ping sống/chết)
#  Nhưng K6 bắn vào /invoke/A1, /invoke/A2, /invoke/A3, còn Dashboard cần
#  publish_result. Nếu cụm này thiếu, Gateway chia tải sang đây sẽ nhận 404
#  và tưởng cụm chết.
#
#  Script này tạo (trong namespace GUEST, đúng chỗ Gateway gọi):
#     A1, A2, A3        - việc giả lập, nặng dần
#     publish_result    - đẩy kết quả về Dashboard
#
#  CÁCH DÙNG (trong thư mục chaos của workspace):
#     ./deploy-actions-plus.sh
#
#  CHẠY LẠI sau mỗi lần cài lại cụm hoặc mở máy (CouchDB không lưu bền).
# =====================================================================
set -Eeuo pipefail
trap 'echo "❌ Dừng ở dòng $LINENO" >&2' ERR

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/chaos.conf"

for cmd in kubectl wsk base64 tailscale; do
  command -v "$cmd" &>/dev/null || { echo "❌ Thiếu lệnh '$cmd'"; exit 1; }
done

API_HOST="${API_HOST:-$(tailscale ip -4 2>/dev/null | head -1)}"
[ -n "$API_HOST" ] || { echo "❌ Không lấy được IP Tailscale"; exit 1; }
APIHOST="https://${API_HOST}:${OW_PORT}"

echo "🔑 1/3: Lấy khóa GUEST của cụm..."
GUEST_AUTH="$(kubectl -n "$NS" get secret "${RELEASE}-whisk.auth" \
  -o jsonpath='{.data.guest}' 2>/dev/null | base64 -d 2>/dev/null || true)"
[ -n "$GUEST_AUTH" ] || { echo "❌ Không đọc được khóa guest. Cụm đã chạy chưa?"; exit 1; }
echo "✅ Đã có khóa guest"

WSK=(wsk -i --apihost "$APIHOST" --auth "$GUEST_AUTH")

echo "⚙️  2/3: Tạo A1 / A2 / A3 và publish_result (namespace guest)..."
# -a provide-api-key true: để action đọc được __OW_API_KEY mà tự gọi publish_result
"${WSK[@]}" action update A1 "$HERE/actions/a_generic.py" --kind python:3 \
  --param NAME A1 --param BUSY "$A1_BUSY" --param CLUSTER "$ME" \
  --param SAMPLE_RATE "$SAMPLE_RATE" -a provide-api-key true
"${WSK[@]}" action update A2 "$HERE/actions/a_generic.py" --kind python:3 \
  --param NAME A2 --param BUSY "$A2_BUSY" --param CLUSTER "$ME" \
  --param SAMPLE_RATE "$SAMPLE_RATE" -a provide-api-key true
"${WSK[@]}" action update A3 "$HERE/actions/a_generic.py" --kind python:3 \
  --param NAME A3 --param BUSY "$A3_BUSY" --param CLUSTER "$ME" \
  --param SAMPLE_RATE "$SAMPLE_RATE" -a provide-api-key true
"${WSK[@]}" action update publish_result "$HERE/actions/publish_result.py" --kind python:3 \
  --param MODE dashboard --param TARGET_URL "$REAL_DASHBOARD_URL"
echo "✅ Xong 4 action"

echo "🎯 3/3: Gọi thử đúng kiểu Gateway gọi..."
B64="$(printf '%s' "$GUEST_AUTH" | base64 -w0)"
for a in A1 A2 A3; do
  OUT="$(curl -sk --max-time 30 -o /tmp/dap_$$ -w '%{http_code} %{time_total}' \
        -H "Authorization: Basic ${B64}" -H 'Content-Type: application/json' \
        -X POST "${APIHOST}/api/v1/namespaces/_/actions/${a}?blocking=true&result=true" \
        -d '{}' || true)"
  echo "   $a -> HTTP ${OUT%% *}  (${OUT#* }s)  $(head -c 120 /tmp/dap_$$ 2>/dev/null)"
  rm -f /tmp/dap_$$
done

echo "============================================================"
echo "✅ HOÀN TẤT. Cụm [$ME] đã sẵn sàng nhận tải K6 qua Gateway."
echo "   Danh sách action: wsk -i --apihost $APIHOST --auth '<guest>' action list"
echo "============================================================"
