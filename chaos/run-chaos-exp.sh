#!/bin/bash
# =====================================================================
#  run-chaos-exp.sh - CHẠY K6 VÀ CHÈN LỖI THEO LỊCH (thí nghiệm E5)
#
#  Ý tưởng: bật K6 bắn tải đều, đợi hệ thống ổn định, rồi gây lỗi, giữ một
#  lúc, sửa lỗi, chờ hồi phục, rồi kết thúc. Mọi mốc thời gian đã được
#  chaos.sh ghi vào results/chaos.csv, ghép với k6.json là ra biểu đồ.
#
#  CÁCH DÙNG
#     ./run-chaos-exp.sh <tên> <req/s> <tình-huống> [--target cX]
#     ví dụ:
#     ./run-chaos-exp.sh e5_pod 30 pod --target c2
#     ./run-chaos-exp.sh e5_cluster 30 cluster --target c3
#
#  BIẾN
#     K6_DIR=<đường-dẫn-k6>       nếu run_exp.sh không nằm trong thư mục k6 của workspace
#     WARM=60    giây chạy bình thường trước khi gây lỗi
#     HOLD=120   giây giữ trạng thái lỗi
#     TAIL=120   giây chạy tiếp sau khi sửa lỗi
#     (tổng thời gian K6 = WARM + HOLD + TAIL)
# =====================================================================
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/chaos.conf"

NAME="${1:-}"; RATE="${2:-}"; SC="${3:-}"; shift 3 2>/dev/null || true
TARGET_ARG=("$@")

if [ -z "$NAME" ] || [ -z "$RATE" ] || [ -z "$SC" ]; then
  sed -n '2,25p' "$0"; exit 1
fi

[ -x "$K6_DIR/run_exp.sh" ] || { echo "❌ Không thấy $K6_DIR/run_exp.sh (đặt K6_DIR=... để chỉ thư mục chứa run_exp.sh)"; exit 1; }

WARM="${WARM:-60}"; HOLD="${HOLD:-120}"; TAIL="${TAIL:-120}"
TOTAL=$(( WARM + HOLD + TAIL ))

echo "============================================================"
echo "  Thí nghiệm : $NAME"
echo "  Tải        : $RATE request/giây trong ${TOTAL}s"
echo "  Gateway    : $GATEWAY_URL"
echo "  Tình huống : $SC ${TARGET_ARG[*]:-}"
echo "  Lịch       : ${WARM}s bình thường -> gây lỗi -> ${HOLD}s -> sửa lỗi -> ${TAIL}s"
echo "============================================================"
read -p "Bắt đầu? (y/n): " -n 1 -r; echo
[[ $REPLY =~ ^[Yy]$ ]] || exit 0

# dọn lỗi còn sót trước khi đo
"$HERE/chaos.sh" reset > /dev/null 2>&1 || true

# chạy K6 nền
GATEWAY_URL="$GATEWAY_URL" DURATION="${TOTAL}s" \
  "$K6_DIR/run_exp.sh" "$NAME" "$RATE" &
K6PID=$!

cleanup() {
  echo; echo "🧹 Dọn dẹp..."
  "$HERE/chaos.sh" "$SC" stop "${TARGET_ARG[@]}" || true
  kill "$K6PID" 2>/dev/null || true
}
trap cleanup INT TERM

echo "⏳ Giai đoạn 1: chạy bình thường ${WARM}s..."
sleep "$WARM"

echo "💥 Giai đoạn 2: GÂY LỖI [$SC]"
"$HERE/chaos.sh" "$SC" start "${TARGET_ARG[@]}"

echo "⏳ Giữ lỗi ${HOLD}s..."
sleep "$HOLD"

echo "🔧 Giai đoạn 3: SỬA LỖI [$SC]"
"$HERE/chaos.sh" "$SC" stop "${TARGET_ARG[@]}"

echo "⏳ Giai đoạn 4: chờ hồi phục ${TAIL}s..."
trap - INT TERM
wait "$K6PID" || echo "⚠️  K6 kết thúc với mã khác 0 (bình thường khi có lỗi cố ý)."

echo "============================================================"
echo "✅ XONG. Kết quả K6 ở $K6_DIR/results/, mốc lỗi ở $HERE/results/chaos.csv"
echo "   Vẽ biểu đồ: python3 $HERE/analyze.py $K6_DIR/results/<thư-mục-vừa-tạo>"
echo "============================================================"
