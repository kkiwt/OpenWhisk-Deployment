#!/bin/bash
# =====================================================================
#  deploy-actions.sh - TẠO ACTION CHO GATEWAY (namespace guest)
#
#  Vì sao cần: Gateway của TV1 gọi cụm bằng khóa GUEST, đường dẫn
#  /api/v1/namespaces/_/actions/<tên>  => "_" nghĩa là namespace guest.
#  Action tạo bằng khóa 'system' (namespace whisk.system) Gateway KHÔNG thấy
#  => Gateway nhận 404, tưởng cụm chết và ngắt cầu dao.
#
#  CaiDatOpenWhiskMoi.sh tự gọi script này ở bước 10.
#  CouchDB đã lưu bền nên action còn sau khi mở máy; chạy lại bao nhiêu lần cũng an toàn
#  (dùng "action update"), nên chạy lại khi IP Tailscale đổi để lấy dòng cấu hình mới.
#
#  Cách dùng (trong thư mục golden/):
#     ./deploy-actions.sh                 # đặt tên cụm là c2
#     CLUSTER_NAME=c3 ./deploy-actions.sh # nếu máy này là cụm c3
#
#  Kết quả: tạo action ping + test-thu, thử gọi đúng kiểu Gateway gọi,
#  và in sẵn DÒNG CẤU HÌNH để gửi cho TV1 dán vào gateway.py.
# =====================================================================
set -Eeuo pipefail
trap 'echo "❌ Script dừng ở dòng $LINENO. Xem lại thông báo phía trên." >&2' ERR

RELEASE="${RELEASE:-owdev}"
NS="${NS:-openwhisk}"
CLUSTER_NAME="${CLUSTER_NAME:-c2}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🚀 BẮT ĐẦU TẠO ACTION CHO GATEWAY (cụm ${CLUSTER_NAME})..."

for cmd in kubectl wsk curl base64 tailscale; do
  command -v "$cmd" &> /dev/null || { echo "❌ Thiếu lệnh '$cmd'"; exit 1; }
done

API_HOST="${API_HOST:-$(tailscale ip -4 2>/dev/null | head -1)}"
[ -n "$API_HOST" ] || { echo "❌ Không lấy được IP Tailscale (đặt API_HOST=100.x.x.x)"; exit 1; }
APIHOST="https://${API_HOST}:31001"

echo "🔑 1/4: Lấy khóa GUEST của cụm..."
GUEST_AUTH="$(kubectl -n "$NS" get secret "${RELEASE}-whisk.auth" -o jsonpath='{.data.guest}' 2>/dev/null | base64 -d 2>/dev/null || true)"
if [ -z "$GUEST_AUTH" ]; then
  echo "❌ Không đọc được khóa guest từ secret ${RELEASE}-whisk.auth."
  echo "   Cụm đã chạy chưa? Thử: kubectl -n $NS get secret"
  exit 1
fi
echo "✅ Đã có khóa guest"

echo "📝 2/4: Chuẩn bị mã nguồn ping.py..."
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
cat <<'EOF' > "$TMPDIR/ping.py"
import time
def main(args):
    return {"status": "ok", "cluster": args.get("CLUSTER", "?"), "ts": time.time()}
EOF

echo "⚙️ 3/4: Tạo action trong namespace guest..."
WSK=(wsk -i --apihost "$APIHOST" --auth "$GUEST_AUTH")
# ping: action thăm dò sức khỏe theo tài liệu nhóm. test-thu: tên mà Gateway đang dùng làm mục tiêu ping mặc định.
"${WSK[@]}" action update ping "$TMPDIR/ping.py" --kind python:3 --param CLUSTER "$CLUSTER_NAME"
"${WSK[@]}" action update test-thu "$TMPDIR/ping.py" --kind python:3 --param CLUSTER "$CLUSTER_NAME"
echo "✅ Đã tạo ping và test-thu"

echo "🎯 4/4: Thử gọi ĐÚNG kiểu Gateway gọi (Authorization: Basic, namespace _)..."
B64="$(printf '%s' "$GUEST_AUTH" | base64 -w0)"
URL="${APIHOST}/api/v1/namespaces/_/actions/ping?blocking=true&result=true"
call() {
  curl -sk --max-time "$1" -o /tmp/da_body.$$ -w '%{http_code} %{time_total}' \
    -H "Authorization: Basic ${B64}" -H 'Content-Type: application/json' -X POST "$URL" -d '{}'
}
# Lần đầu phải khởi động container (lạnh) nên cho tối đa 30 giây
OUT="$(call 30 || true)"; CODE="${OUT%% *}"
echo "   Lần 1 (lạnh): HTTP ${CODE}, ${OUT#* }s  -> $(head -c 160 /tmp/da_body.$$ 2>/dev/null)"
OUT="$(call 2 || true)"; CODE="${OUT%% *}"
echo "   Lần 2 (nóng, giới hạn 2 giây như Gateway): HTTP ${CODE}, ${OUT#* }s"
rm -f /tmp/da_body.$$
if [ "$CODE" = "200" ]; then
  echo "✅ Gateway sẽ gọi được cụm này"
else
  echo "⚠️  Lần gọi 2 chưa đạt 200 trong 2 giây. Gateway ping mỗi 2 giây với timeout 2 giây,"
  echo "    nên nếu cụm chậm hơn thế, cầu dao sẽ ngắt nhầm. Chạy lại script sau 1 phút để thử lại."
fi

LINE="    \"${CLUSTER_NAME}\": (\"${APIHOST}\", \"${B64}\"),"
echo "$LINE" > "$HERE/gateway-line-${CLUSTER_NAME}.txt"

echo "============================================================"
echo "✅ HOÀN TẤT!"
echo "============================================================"
echo "👉 GỬI CHO TV1 (dán vào INITIAL_CLUSTERS trong gateway.py, thay dòng \"${CLUSTER_NAME}\"):"
echo
echo "$LINE"
echo
echo "   (đã lưu trong file: $HERE/gateway-line-${CLUSTER_NAME}.txt)"
echo "============================================================"
