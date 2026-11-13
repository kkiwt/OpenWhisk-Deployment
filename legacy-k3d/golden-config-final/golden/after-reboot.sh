#!/bin/bash
# =====================================================================
#  after-reboot.sh - HỒI PHỤC OPENWHISK SAU KHI TẮT/MỞ LẠI MÁY ẢO
#
#  Chạy SAU KHI mở máy ảo và Docker đã lên (khoảng 1-2 phút).
#  Golden Config đã BẬT lưu bền, nên thông thường chỉ cần chờ pod lên lại,
#  KHÔNG phải cài lại như trước.
#
#  Script làm 5 việc:
#   1. Chờ 3 node k3d Ready
#   2. Xóa cứng các pod kẹt Unknown (để Kubernetes tạo lại)
#   3. Kiểm tra CouchDB còn mốc khởi tạo (ow_kube_couchdb_initialized_marker)
#   4. Còn -> chờ pod sẵn sàng.  Mất (hiếm, vd PVC hỏng) -> cài lại OpenWhisk:
#        ../CaiDatOpenWhiskMoi.sh --redeploy --clean --yes  (giữ cụm k3d)
#   5. Chạy lại deploy-actions.sh (action còn sẵn, chạy lại chỉ để cập nhật
#      dòng cấu hình Gateway nếu IP Tailscale đổi)
#
#  Cách dùng (trong thư mục golden/):
#     ./after-reboot.sh          # hỏi trước khi cài lại
#     ./after-reboot.sh --auto   # tự cài lại nếu cần, không hỏi
# =====================================================================
set -Eeuo pipefail
trap 'echo "❌ Script dừng ở dòng $LINENO. Xem lại thông báo phía trên." >&2' ERR

RELEASE="${RELEASE:-owdev}"
NS="${NS:-openwhisk}"
TIMEOUT="${TIMEOUT:-600}"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
INSTALLER="${INSTALLER:-$(dirname "$HERE")/CaiDatOpenWhiskMoi.sh}"
[ -f "$INSTALLER" ] && INSTALLER="$(readlink -f "$INSTALLER")" || INSTALLER=""
AUTO=0
for a in "$@"; do
  case "$a" in
    --auto) AUTO=1 ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "❌ Tham số lạ: $a"; exit 2 ;;
  esac
done

echo "🚀 BẮT ĐẦU HỒI PHỤC SAU KHI MỞ MÁY..."

echo "🖥  1/5: Chờ các node k3d Ready..."
if ! docker ps --format '{{.Names}}' | grep -q '^k3d-'; then
  echo "❌ Không thấy container k3d nào đang chạy. Thử: k3d cluster start openwhisk-cluster"
  exit 1
fi
if ! kubectl wait --for=condition=Ready nodes --all --timeout=300s; then
  echo "⚠️  Node chưa Ready sau 300 giây. Xem: kubectl get nodes ; kubectl describe node <tên>"
  exit 1
fi
kubectl get nodes

echo "🩹 2/5: Xóa cứng pod kẹt Unknown..."
STUCK="$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk '$3=="Unknown"||$3=="Init:Unknown"||$3=="NodeLost"{print $1}' || true)"
if [ -n "$STUCK" ]; then
  echo "   Pod kẹt: $(echo "$STUCK" | tr '\n' ' ')"
  echo "$STUCK" | xargs -r kubectl -n "$NS" delete pod --force --grace-period=0 > /dev/null 2>&1 || true
  echo "✅ Đã xóa, Kubernetes sẽ tạo lại"
else
  echo "✅ Không có pod kẹt Unknown"
fi

echo "🗄  3/5: Kiểm tra mốc khởi tạo của CouchDB..."
kubectl -n "$NS" rollout status "deploy/${RELEASE}-couchdb" --timeout=300s > /dev/null 2>&1 || true
DB_USER="$(kubectl -n "$NS" get secret "${RELEASE}-db.auth" -o jsonpath='{.data.db_username}' 2>/dev/null | base64 -d 2>/dev/null || true)"
DB_PASS="$(kubectl -n "$NS" get secret "${RELEASE}-db.auth" -o jsonpath='{.data.db_password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
DB_USER="${DB_USER:-whisk_admin}"; DB_PASS="${DB_PASS:-some_passw0rd}"
ALLDBS=""
for _ in $(seq 1 12); do   # CouchDB có thể cần thêm vài giây sau khi Running
  ALLDBS="$(kubectl -n "$NS" exec "deploy/${RELEASE}-couchdb" -- curl -s -u "${DB_USER}:${DB_PASS}" http://127.0.0.1:5984/_all_dbs 2>/dev/null || true)"
  echo "$ALLDBS" | grep -q '^\[' && break
  sleep 5
done
echo "   Danh sách CSDL trong CouchDB: ${ALLDBS:-<không đọc được>}"
NEED_REINSTALL=0
if echo "$ALLDBS" | grep -q 'ow_kube_couchdb_initialized_marker'; then
  echo "✅ CouchDB còn mốc khởi tạo (lưu bền hoạt động) -> không cần cài lại"
else
  NEED_REINSTALL=1
  echo "⚠️  CouchDB KHÔNG có mốc khởi tạo. Với lưu bền thì việc này hiếm - kiểm tra: kubectl -n $NS get pvc"
  echo "    Controller và invoker chờ mốc này nên sẽ kẹt mãi nếu không khởi tạo lại."
fi

if [ "$NEED_REINSTALL" -eq 1 ]; then
  [ -n "$INSTALLER" ] || { echo "❌ Không thấy CaiDatOpenWhiskMoi.sh (mặc định nằm ở thư mục cha của golden/)"; exit 1; }
  if [ "$AUTO" -ne 1 ]; then
    read -p "👉 Cài lại OpenWhisk theo Golden, giữ cụm k3d (khoảng 10 phút)? (y/n): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || { echo "Đã dừng. Khi sẵn sàng: $INSTALLER --redeploy --clean"; exit 0; }
  fi
  echo "🔥 4/5: Cài lại bằng CaiDatOpenWhiskMoi.sh --redeploy --clean..."
  bash "$INSTALLER" --redeploy --clean --yes
  echo "✅ Cài lại xong (installer đã tự chạy deploy-actions.sh)"
  echo "👉 BƯỚC TIẾP THEO: bash \"$HERE/test-all.sh\""
  exit 0
fi

echo "⏳ 4/5: Chờ pod sẵn sàng..."
deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  BAD="$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk '
      $1 ~ /install-packages/ {next}
      $3=="Completed" || $3=="Succeeded" {next}
      $3=="Running" { split($2,a,"/"); if (a[1]==a[2]) next }
      {print $1" ("$3" "$2")"}' || true)"
  if [ -z "$BAD" ]; then echo "✅ Mọi pod chính đã sẵn sàng"; break; fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "⚠️  Hết giờ chờ, pod chưa sẵn sàng:"; echo "$BAD" | sed 's/^/      /'
    echo "   Xem log init: kubectl -n $NS logs <tên-pod> -c wait-for-couchdb --tail=5"
    exit 1
  fi
  STUCK="$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk '$3=="Unknown"||$3=="Init:Unknown"{print $1}' || true)"
  if [ -n "$STUCK" ]; then
    echo "$STUCK" | xargs -r kubectl -n "$NS" delete pod --force --grace-period=0 > /dev/null 2>&1 || true
  fi
  sleep 10
done

echo "🎯 5/5: Kiểm tra action cho Gateway..."
"$HERE/deploy-actions.sh"

echo "============================================================"
echo "✅ HỒI PHỤC HOÀN TẤT!"
echo "============================================================"
echo "👉 BƯỚC TIẾP THEO: bash \"$HERE/test-all.sh\""
echo "============================================================"
