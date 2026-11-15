#!/usr/bin/env bash
# =====================================================================
#  deploy-actions.sh - triển khai action lên cụm K3s bằng wsk CLI (chạy trên master)
#
#  Tạo trong namespace GUEST (có thể gọi trực tiếp qua NodePort):
#    ping, test-thu      <- cluster_info.py
#    A1, A2, A3          <- busy_work.py
#    publish_result      <- publish_result.py (chỉ khi có DASHBOARD_URL)
#  Rồi làm nóng và thử qua OpenWhisk API. Có thể sinh thêm cấu hình Gateway nếu cần.
#
#  Biến: CLUSTER_NAME=cloud  DASHBOARD_URL=http://<private-dashboard>:9000  SAMPLE_RATE=0.05  API_HOST=...
# =====================================================================
set -Eeuo pipefail
trap 'echo "❌ Dừng ở dòng $LINENO" >&2' ERR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

RELEASE="${RELEASE:-owdev}"; NS="${NS:-openwhisk}"
CLUSTER_NAME="${CLUSTER_NAME:-cloud}"
DASHBOARD_URL="${DASHBOARD_URL:-}"
SAMPLE_RATE="${SAMPLE_RATE:-0.05}"
A1_BUSY="${A1_BUSY:-0.05}"; A2_BUSY="${A2_BUSY:-0.20}"; A3_BUSY="${A3_BUSY:-0.50}"   # khớp deploy-actions-plus.sh của 3 cụm k3d

need_cmd kubectl; need_cmd curl; need_cmd base64
if ! command -v wsk >/dev/null 2>&1; then
  log "Cài wsk CLI..."
  T="$(mktemp -d)"
  curl -fsSL -o "$T/wsk.tgz" https://github.com/apache/openwhisk-cli/releases/download/1.2.0/OpenWhisk_CLI-1.2.0-linux-amd64.tgz
  tar -xzf "$T/wsk.tgz" -C "$T"; sudo install -m 0755 "$T/wsk" /usr/local/bin/wsk; rm -rf "$T"
fi

API_HOST="${API_HOST:-$(ow_api_host)}"
[ -n "$API_HOST" ] || die "Không xác định được API_HOST (worker đã có nhãn invoker chưa?)"
APIHOST="https://${API_HOST}:31001"

log "1/4 Lấy khóa GUEST của cụm..."
GUEST_AUTH="$(kubectl -n "$NS" get secret "${RELEASE}-whisk.auth" -o jsonpath='{.data.guest}' | base64 -d)"
[ -n "$GUEST_AUTH" ] || die "Không đọc được khóa guest. OpenWhisk đã chạy xong chưa?"
B64="$(printf '%s' "$GUEST_AUTH" | base64 -w0)"
# -i = bỏ kiểm tra TLS (cert tự ký). Khóa truyền qua cờ --auth sẽ lộ trong `ps` vài giây trên máy này,
# chấp nhận được vì đây là master của chính bạn; đừng chạy trên máy dùng chung.
WSK=(wsk -i --apihost "$APIHOST" --auth "$GUEST_AUTH")

log "2/4 Tạo action (namespace guest)..."
"${WSK[@]}" action update ping      "$SCRIPT_DIR/cluster_info.py" --kind python:3 --param CLUSTER "$CLUSTER_NAME"
"${WSK[@]}" action update test-thu  "$SCRIPT_DIR/cluster_info.py" --kind python:3 --param CLUSTER "$CLUSTER_NAME"

if [ -n "$DASHBOARD_URL" ]; then
  "${WSK[@]}" action update publish_result "$SCRIPT_DIR/publish_result.py" --kind python:3 \
    --param MODE dashboard --param TARGET_URL "$DASHBOARD_URL"
else
  warn "Không có DASHBOARD_URL -> đặt SAMPLE_RATE=0 (A1-A3 không báo về Dashboard). Chạy lại với DASHBOARD_URL=http://<ip-private-gateway>:9000 để bật."
  SAMPLE_RATE=0
fi
for spec in "A1:$A1_BUSY" "A2:$A2_BUSY" "A3:$A3_BUSY"; do
  n="${spec%%:*}"; b="${spec#*:}"
  # -a provide-api-key true: để action đọc __OW_API_KEY mà tự gọi publish_result (báo ngầm).
  "${WSK[@]}" action update "$n" "$SCRIPT_DIR/busy_work.py" --kind python:3 \
    --param NAME "$n" --param BUSY "$b" --param CLUSTER "$CLUSTER_NAME" \
    --param SAMPLE_RATE "$SAMPLE_RATE" -a provide-api-key true
done
ok "Đã tạo action"

log "3/4 Làm nóng + thử qua OpenWhisk API (Authorization: Basic)..."
call() {  # call <action> <timeout>
  curl -sk --max-time "$2" -o /dev/null -w '%{http_code} %{time_total}' \
    -H "Authorization: Basic ${B64}" -H 'Content-Type: application/json' \
    -X POST "${APIHOST}/api/v1/namespaces/_/actions/$1?blocking=true&result=true" -d '{}' || echo "000 -"
}
FAILED=0
for a in test-thu A1 A2 A3; do
  OUT="$(call "$a" 60)";  COLD="${OUT#* }"; [ "${OUT%% *}" = "200" ] || FAILED=1
  OUT="$(call "$a" 5)"; HOT="${OUT#* }"; CODE="${OUT%% *}"
  printf '   %-9s lạnh %ss -> nóng %ss (HTTP %s)\n' "$a" "$COLD" "$HOT" "$CODE"
done
if [ "$FAILED" -eq 1 ]; then
  warn "Có action chưa trả 200: kubectl -n $NS get pods"
  kubectl -n "$NS" logs -l name="${RELEASE}-invoker" --tail=80 --prefix=true 2>/dev/null || true
else
  ok "Mọi action trả HTTP 200"
fi

log "4/4 Sinh cấu hình Gateway tùy chọn..."
VAR="$(echo "$CLUSTER_NAME" | tr '[:lower:]' '[:upper:]')"
( umask 077
  cat > "$ROOT_DIR/gateway/.env.cloud" <<EOF
CLUSTER_${VAR}_URL=${APIHOST}
CLUSTER_${VAR}_AUTH_B64=${B64}
EOF
  printf 'proxy_set_header Authorization "Basic %s";\n' "$B64" > "$ROOT_DIR/gateway/ow-cloud-auth.conf"
)
echo "============================================================"
ok "HOÀN TẤT. Cụm [$CLUSTER_NAME] sẵn sàng nhận tải trực tiếp qua $APIHOST"
echo "   Đã ghi (chmod 600, nằm trong .gitignore):"
echo "     gateway/.env.cloud          -> dán vào .env của Gateway FastAPI"
echo "     gateway/ow-cloud-auth.conf  -> include trong NGINX"
echo "👉 Test trực tiếp: k6 run -e OW_API=$APIHOST -e OW_AUTH=\"\$(kubectl -n $NS get secret ${RELEASE}-whisk.auth -o jsonpath='{.data.guest}' | base64 -d)\" tests/load-test.js"
echo "   Gateway là tùy chọn: GATEWAY_TLS_INSECURE=1 ./gateway/register-cloud-cluster.sh https://<ip-gateway>:8080"
echo "============================================================"
