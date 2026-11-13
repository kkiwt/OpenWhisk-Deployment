#!/bin/bash
# =====================================================================
#  warmup.sh - LÀM NÓNG ACTION TRƯỚC KHI CHẠY test-golden.sh
#
#  VÌ SAO CẦN: TEST 6 (phụ) trong test-golden.sh gọi action 'ping' với
#  --max-time 10 giây. Lần gọi ĐẦU TIÊN là "gọi lạnh": OpenWhisk phải dựng
#  container Python mới, trên máy ảo thường mất 10-20 giây (chính vì vậy
#  Test 5 mới để COLD_MAX=20). Quá 10 giây -> curl trả 000 -> Test 6
#  báo "Gateway sẽ ngắt cụm này" dù cụm hoàn toàn khỏe.
#
#  Script này gọi trước vài lần cho container nóng sẵn, rồi mới chạy test.
#  KHÔNG sửa gì trong thư mục golden/.
#
#  CÁCH DÙNG
#     ./warmup.sh                 # làm nóng ping + test-thu + A1/A2/A3
#     Sau đó chạy đường dẫn test-golden.sh được in ở cuối.
# =====================================================================
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/chaos.conf"

API_HOST="${API_HOST:-$(tailscale ip -4 2>/dev/null | head -1)}"
[ -n "$API_HOST" ] || { echo "❌ Không lấy được IP Tailscale"; exit 1; }
BASE="https://${API_HOST}:${OW_PORT}/api/v1/namespaces/_/actions"

GUEST_AUTH="$(kubectl -n "$NS" get secret "${RELEASE}-whisk.auth" \
  -o jsonpath='{.data.guest}' 2>/dev/null | base64 -d 2>/dev/null || true)"
[ -n "$GUEST_AUTH" ] || { echo "❌ Không đọc được khóa guest"; exit 1; }
B64="$(printf '%s' "$GUEST_AUTH" | base64 -w0)"

call() {  # call <action> <timeout>
  curl -sk --max-time "$2" -o /dev/null -w '%{http_code} %{time_total}' \
    -H "Authorization: Basic ${B64}" -H 'Content-Type: application/json' \
    -X POST "${BASE}/$1?blocking=true&result=true" -d '{}' 2>/dev/null || echo "000 -"
}

ACTIONS="${ACTIONS:-ping test-thu A1 A2 A3}"
echo "🔥 Làm nóng action: $ACTIONS"
echo "   (Gateway ping mỗi 2 giây với timeout 2 giây, nên mục tiêu là lần gọi nóng < 2s)"
echo

FAIL=0
for a in $ACTIONS; do
  printf '  %-12s ' "$a"
  OUT="$(call "$a" 60)"; CODE="${OUT%% *}"; T1="${OUT#* }"
  if [ "$CODE" = "404" ]; then
    echo "❌ 404 - CHƯA CÓ ACTION NÀY"
    case "$a" in
      ping|test-thu) echo "               -> chạy: $GOLDEN_DIR/deploy-actions.sh" ;;
      *)             echo "               -> chạy: $HERE/deploy-actions-plus.sh" ;;
    esac
    FAIL=1; continue
  fi
  if [ "$CODE" != "200" ]; then
    echo "❌ lần lạnh HTTP $CODE (${T1}s)"
    FAIL=1; continue
  fi
  # gọi thêm 2 lần cho nóng hẳn, lấy lần cuối làm số liệu
  call "$a" 30 > /dev/null
  OUT="$(call "$a" 30)"; T2="${OUT#* }"
  HOT="$(python3 -c "print('OK' if float('$T2') < 2 else 'CHẬM')" 2>/dev/null || echo '?')"
  if [ "$HOT" = "OK" ]; then
    echo "✅ lạnh ${T1}s -> nóng ${T2}s"
  else
    echo "⚠️  lạnh ${T1}s -> nóng ${T2}s (>2s, Gateway có thể ngắt cụm)"
  fi
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✅ Container đã nóng. CHẠY NGAY (đừng chờ lâu, container nguội sau ~10 phút):"
  echo "   $GOLDEN_DIR/test-golden.sh"
else
  echo "⚠️  Còn action thiếu/lỗi ở trên, sửa xong rồi chạy lại warmup.sh"
  exit 1
fi
