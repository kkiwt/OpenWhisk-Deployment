#!/bin/bash
# =====================================================================
#  test-all.sh - CHẠY CẢ TestMoi.sh VÀ test-golden.sh TRONG MỘT LỆNH
#
#  Chạy lần lượt (không chạy song song, vì test-golden.sh đo gọi lạnh và
#  bắn tải 300 request - chạy chung với test khác sẽ làm sai số đo):
#    Phần A  TestMoi.sh      tính năng serverless: tạo action Node.js, web action, 10 lần gọi
#    Phần B  test-golden.sh  chứng minh 5 việc của Golden Config + tương thích Gateway
#  Phần B vẫn chạy kể cả khi phần A lỗi. Cuối cùng in bảng tổng hợp.
#
#  Cách dùng (trong thư mục golden/):
#     ./test-all.sh
#     ./test-all.sh --restart-db                  # thêm bài tắt/bật CouchDB (chứng minh lưu bền)
#     ./test-all.sh --compare images-maykhac.txt  # tham số được chuyển thẳng cho test-golden.sh
#
#  Báo cáo gộp: test-all-report-<tên-máy>.txt
#  (test-golden.sh vẫn tự lưu golden-report-<tên-máy>.txt như cũ)
# =====================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
HOST="$(hostname)"
REPORT="$HERE/test-all-report-$HOST.txt"
: > "$REPORT"

case "${1:-}" in -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;; esac

for f in TestMoi.sh test-golden.sh; do
  [ -f "$HERE/$f" ] || { echo "❌ Không thấy $HERE/$f"; exit 2; }
done

log() { echo "$*" | tee -a "$REPORT"; }
run_part() {   # run_part <nhãn> <lệnh...>  -> trả về mã thoát của lệnh
  local label="$1"; shift
  local t0=$SECONDS rc
  log ""
  log "############################################################"
  log "### $label"
  log "############################################################"
  "$@" 2>&1 | tee -a "$REPORT"
  rc=${PIPESTATUS[0]}
  log "### $label kết thúc: mã $rc, $(( SECONDS - t0 ))s"
  return "$rc"
}

log "🚀 TEST TỔNG HỢP OPENWHISK - máy: $HOST - $(date '+%F %T')"

run_part "PHẦN A: TestMoi.sh (tính năng serverless)" bash "$HERE/TestMoi.sh"; RA=$?
run_part "PHẦN B: test-golden.sh (5 việc Golden Config)" bash "$HERE/test-golden.sh" "$@"; RB=$?

verdict() { [ "$1" -eq 0 ] && echo "ĐẠT" || echo "KHÔNG ĐẠT (mã $1)"; }
log ""
log "============================================================"
log "📊 TỔNG HỢP CẢ HAI BÀI TEST ($HOST)"
log "============================================================"
log "  A  TestMoi.sh       $(verdict "$RA")"
log "  B  test-golden.sh   $(verdict "$RB")"
# Chép lại bảng TỔNG KẾT của test-golden để nhìn một chỗ
if grep -q '📊 TỔNG KẾT' "$REPORT"; then
  log "     chi tiết B:"
  DETAIL="$(sed -n '/📊 TỔNG KẾT/,$p' "$REPORT" | grep -E '^  (Việc|\(phụ\)| +\(3b\))' | sed 's/^/   /' || true)"
  log "$DETAIL"
fi
log "  Báo cáo gộp: $REPORT"
log "============================================================"
if [ "$RA" -eq 0 ] && [ "$RB" -eq 0 ]; then log "✅ TẤT CẢ ĐỀU ĐẠT!"; exit 0
else log "⚠️  CÒN PHẦN KHÔNG ĐẠT - xem các dòng ❌ phía trên"; exit 1; fi