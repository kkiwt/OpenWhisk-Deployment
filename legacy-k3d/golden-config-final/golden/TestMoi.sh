#!/bin/bash
# =====================================================================
#  TestMoi.sh - KIỂM TRA NHANH TÍNH NĂNG SERVERLESS QUA TAILSCALE
#   1. wsk gọi được cụm (tự trỏ bằng khóa guest nếu chưa trỏ)
#   2. Tạo action Node.js, bật web action
#   3. Gọi 1 lần bằng wsk
#   4. Gọi 10 lần qua URL web action bằng curl
#  Kết thúc bằng mã 0 nếu đạt hết, 1 nếu có bước lỗi (test-all.sh dựa vào mã này).
#
#  Action tên "hello-web" (KHÔNG dùng "test-thu" vì tên đó Gateway dùng để ping).
#  Biến môi trường: NODE_KIND=nodejs:14   ACTION=hello-web
# =====================================================================
set -uo pipefail

RELEASE="${RELEASE:-owdev}"; NS="${NS:-openwhisk}"
NODE_KIND="${NODE_KIND:-nodejs:14}"
ACTION="${ACTION:-hello-web}"
TAILSCALE_IP="${API_HOST:-$(tailscale ip -4 2>/dev/null | head -1)}"
API_URL="https://${TAILSCALE_IP}:31001"
FAIL=0

echo "🚀 BẮT ĐẦU CHUỖI BÀI TEST TÍNH NĂNG SERVERLESS (TAILSCALE EDITION)..."
[ -n "$TAILSCALE_IP" ] || { echo "❌ Không lấy được IP Tailscale"; exit 1; }

# 1. wsk đã trỏ đúng cụm chưa? Chưa thì tự trỏ bằng khóa guest
if ! NS_LIST=$(wsk -i namespace list 2>&1) || ! grep -q "$TAILSCALE_IP" ~/.wskprops 2>/dev/null; then
    echo "ℹ️  wsk chưa trỏ vào cụm này -> tự trỏ bằng khóa guest"
    AUTH=$(kubectl get secret "${RELEASE}-whisk.auth" -n "$NS" -o jsonpath='{.data.guest}' 2>/dev/null | base64 -d 2>/dev/null)
    [ -n "$AUTH" ] || { echo "❌ Không đọc được khóa guest (cụm đã chạy chưa?)"; exit 1; }
    wsk property set --apihost "$API_URL" --auth "$AUTH" > /dev/null
    if ! NS_LIST=$(wsk -i namespace list 2>&1); then
        echo "❌ wsk vẫn chưa gọi được cụm: $NS_LIST"; exit 1
    fi
fi
NS_NAME=$(echo "$NS_LIST" | tail -n +2 | head -1 | awk '{print $1}')
echo "✅ wsk đang dùng namespace: ${NS_NAME}"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
echo "📝 2. Tạo mã nguồn (hello.js)..."
cat <<'EOF' > "$WORK/hello.js"
function main(params) {
    var name = params.name || 'Người lạ';
    return { message: 'Hello ' + name + ', Serverless qua Tailscale chạy mượt rồi nhé!' };
}
EOF

echo "⚙️ 3. Đẩy code lên OpenWhisk (action ${ACTION}, ${NODE_KIND}) và bật web action..."
if wsk -i action update "$ACTION" "$WORK/hello.js" --kind "$NODE_KIND" --web true; then
    echo "✅ Đã tạo/cập nhật action ${ACTION}"
else
    echo "❌ Không tạo được action ${ACTION}"; exit 1
fi

echo "🎯 4. Chạy test đơn (wsk invoke)..."
echo "--- KẾT QUẢ TỪ SERVERLESS ---"
if OUT=$(wsk -i action invoke "$ACTION" --result --param name "Kiệt" 2>&1) && echo "$OUT" | grep -q '"message"'; then
    echo "$OUT"; echo "✅ Gọi đơn thành công"
else
    echo "$OUT"; echo "❌ Gọi đơn thất bại"; FAIL=1
fi
echo "-----------------------------"

echo "🔥 5. TEST TẢI NHẸ: 10 lần gọi qua URL web action..."
URL="${API_URL}/api/v1/web/${NS_NAME}/default/${ACTION}.json?name=Kiet"
OK=0
for i in $(seq 1 10); do
    BODY=$(curl -s -k --max-time 30 "$URL")
    if echo "$BODY" | jq -e '.message' > /dev/null 2>&1; then
        OK=$((OK+1)); echo "   [$i] $(echo "$BODY" | jq -r .message)"
    else
        echo "   [$i] ❌ ${BODY:0:200}"
    fi
done
if [ "$OK" -eq 10 ]; then echo "✅ 10/10 lần gọi web action thành công"
else echo "❌ Chỉ $OK/10 lần gọi web action thành công"; FAIL=1; fi

echo "============================================================"
if [ "$FAIL" -eq 0 ]; then echo "✅ HOÀN TẤT BÀI TEST TÍNH NĂNG - ĐẠT"; exit 0
else echo "⚠️  BÀI TEST TÍNH NĂNG CÓ BƯỚC KHÔNG ĐẠT"; exit 1; fi
