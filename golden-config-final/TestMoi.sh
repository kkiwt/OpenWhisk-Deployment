#!/bin/bash
set -e

# Lấy tự động IP Tailscale
TAILSCALE_IP=$(tailscale ip -4)
API_URL="https://${TAILSCALE_IP}:31001"

echo "🚀 BẮT ĐẦU CHUỖI BÀI TEST TÍNH NĂNG SERVERLESS (TAILSCALE EDITION)..."

echo "📝 1. Tạo mã nguồn (hello.js)..."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat <<EOF > "$WORK/hello.js"
function main(params) {
    var name = params.name || 'Người lạ';
    return { message: 'Hello ' + name + ', Serverless của Kiệt qua Tailscale chạy mượt rồi nhé!' };
}
EOF

echo "⚙️ 2. Đẩy code lên OpenWhisk (Tạo Action)..."
# Thêm cờ -i để vượt lỗi x509 và dùng nodejs:14 thay vì 10 (bản 10 đã quá cũ)
wsk -i action update test-thu "$WORK/hello.js" --kind nodejs:14

echo "🌐 3. Mở khóa Action thành API Public..."
wsk -i action update test-thu --web true

echo "🎯 4. Chạy test đơn (Single Request)..."
echo "--- KẾT QUẢ TỪ SERVERLESS ---"
wsk -i action invoke test-thu --result --param name "Kiệt"
echo "-----------------------------"

echo "🔥 5. KÍCH HOẠT TEST TẢI NHẸ..."
echo "⏳ Đang chuẩn bị bắn đạn sau 3 giây..."
sleep 3

# ApacheBench (ab) hay lỗi với HTTPS tự ký, ta dùng curl -k bắn 10 phát để xác minh mạng thông
for i in {1..10}; do
    curl -s -k "${API_URL}/api/v1/web/guest/default/test-thu.json" | jq .
done

echo "============================================================"
echo "✅ HOÀN TẤT BÀI TEST TÍNH NĂNG!"
echo "============================================================"
