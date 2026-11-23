#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "LỖI: Dừng tại dòng $LINENO: $BASH_COMMAND" >&2' ERR

RELEASE="${RELEASE:-owdev}"
NS="${NS:-openwhisk}"

# Kiểm tra các công cụ cần thiết
for cmd in kubectl helm; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "LỖI: Không tìm thấy công cụ $cmd" >&2
        exit 1
    }
done

# Kiểm tra namespace OpenWhisk
kubectl get namespace "$NS" >/dev/null

echo "=========================================="
echo "       GỠ BỎ OPENWHISK"
echo "=========================================="
echo "Helm Release: $RELEASE"
echo "Namespace:    $NS"
echo
echo "Các thành phần sẽ bị xóa:"
echo "- Helm Release OpenWhisk"
echo "- Toàn bộ tài nguyên trong namespace $NS"
echo "- Namespace $NS"
echo
echo


# Yêu cầu xác nhận trước khi thực hiện
if [ "${FORCE:-0}" != "1" ]; then
    read -r -p 'Nhập DELETE OPENWHISK để xác nhận xóa: ' CONFIRM

    [ "$CONFIRM" = "DELETE OPENWHISK" ] || {
        echo "Đã hủy thao tác."
        exit 1
    }
fi

# Bước 1: Gỡ cài đặt Helm Release
echo
echo "[1/3] Đang gỡ Helm Release..."

if helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
    helm uninstall "$RELEASE" -n "$NS"
else
    echo "Không tìm thấy Helm Release. Tiếp tục xử lý."
fi

# Bước 2: Xóa namespace OpenWhisk
echo
echo "[2/3] Đang xóa namespace $NS..."

kubectl delete namespace "$NS" --wait=true

# Bước 3: Kiểm tra kết quả
echo
echo "[3/3] Đang kiểm tra kết quả..."

if kubectl get namespace "$NS" >/dev/null 2>&1; then
    echo "LỖI: Namespace $NS vẫn còn tồn tại."
    exit 1
fi
echo "    ĐÃ GỠ BỎ OPENWHISK THÀNH CÔNG"

