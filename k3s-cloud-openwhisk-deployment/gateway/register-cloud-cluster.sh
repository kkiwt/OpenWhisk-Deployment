#!/usr/bin/env bash
# =====================================================================
#  register-cloud-cluster.sh - đăng ký cụm K3s cloud (c4) vào Gateway FastAPI đang chạy
#
#  Dùng API quản trị sẵn có của gateway.py (POST /admin/clusters/{name}) nên KHÔNG phải sửa
#  code và KHÔNG phải restart Gateway: vòng ping 2 giây và cầu dao tự bao gồm c4 ngay.
#
#  Cách dùng (chạy ở máy có Gateway truy cập được):
#     GATEWAY_TLS_INSECURE=1 ./register-cloud-cluster.sh https://100.x.y.z:8080
#  Cần file gateway/.env.cloud do actions/deploy-actions.sh sinh ra.
# =====================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_URL="${1:-${GATEWAY_URL:-}}"
CLUSTER_NAME="${CLUSTER_NAME:-c4}"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.cloud}"
GATEWAY_TLS_INSECURE="${GATEWAY_TLS_INSECURE:-0}"

[ -n "$GATEWAY_URL" ] || { echo "Dùng: $0 http://<ip-tailscale-gateway>:8080"; exit 2; }
[ -f "$ENV_FILE" ] || { echo "❌ Thiếu $ENV_FILE (chạy actions/deploy-actions.sh trước)"; exit 1; }
GATEWAY_URL="${GATEWAY_URL%/}"
if [ "$GATEWAY_TLS_INSECURE" = "1" ]; then
  CURL_TLS_ARGS=(--insecure)
else
  CURL_TLS_ARGS=()
fi
VAR="$(echo "$CLUSTER_NAME" | tr '[:lower:]' '[:upper:]')"
set -a; source "$ENV_FILE"; set +a
URL_VAR="CLUSTER_${VAR}_URL"; AUTH_VAR="CLUSTER_${VAR}_AUTH_B64"
[ -n "${!URL_VAR:-}" ] && [ -n "${!AUTH_VAR:-}" ] || { echo "❌ $ENV_FILE thiếu $URL_VAR / $AUTH_VAR"; exit 1; }

# Dựng JSON bằng python (khỏi lo ký tự đặc biệt) và đẩy qua stdin: khóa không xuất hiện trên
# dòng lệnh curl nên không lộ trong `ps`.
URL="${!URL_VAR}" AUTH="${!AUTH_VAR}" python3 -c \
  'import json,os; print(json.dumps({"url": os.environ["URL"], "auth": os.environ["AUTH"]}))' \
| curl -fsS -X POST "$GATEWAY_URL/admin/clusters/$CLUSTER_NAME" \
    "${CURL_TLS_ARGS[@]}" \
    -H 'Content-Type: application/json' --data-binary @-
echo; echo "✅ Đã đăng ký [$CLUSTER_NAME]. Chờ vòng ping đầu tiên..."

# Gateway đặt up=true NGAY khi đăng ký và chỉ ngắt cầu dao sau 10 lần ping hỏng liên tiếp (mỗi 2s),
# nên thấy "up" lúc này CHƯA chứng minh gì. Theo dõi ~24s để chắc chắn không có lỗi ping.
# (ewma_ms bắt đầu ở 100ms và chỉ cập nhật khi có request thật, đừng coi nó là độ trễ đã đo.)
BAD=0
for _ in $(seq 1 12); do
  sleep 2
  STATE="$(curl -fsS "${CURL_TLS_ARGS[@]}" "$GATEWAY_URL/admin/clusters" | NAME="$CLUSTER_NAME" python3 -c '
import json, os, sys
d = json.load(sys.stdin)["nodes"].get(os.environ["NAME"])
print("missing" if d is None else "%s fails=%s" % ("up" if d["up"] else "down", d["fails"]))')"
  echo "   $CLUSTER_NAME: $STATE"
  case "$STATE" in down*|missing*) BAD=1; break ;; esac
done
if [ "$BAD" -eq 1 ]; then
  echo "❌ Gateway ngắt cầu dao [$CLUSTER_NAME]. Kiểm tra: action test-thu phải trả < 2s khi nóng; ACL Tailscale cho phép tcp:31001 từ máy Gateway."
  exit 1
fi
echo "✅ 24s liên tục không có lỗi ping. Kiểm tra thật bằng request qua Gateway: xem HUONG-DAN-CHAY-TU-DAU.md, phần H."

cat <<EOF

⚠️  Đăng ký qua API chỉ nằm trong RAM của Gateway: restart là mất. Muốn bền vững, trên máy Gateway:
   1) cat $ENV_FILE >> /đường/dẫn/openwhisk-gateway/.env      # rồi chmod 600 .env
   2) đặt ACTIVE=c1,c2,c3,c4 trong .env
   3) gateway.py đang cứng CLUSTER_NAMES = ("c1","c2","c3") nên cần sửa 2 chỗ:
      sed -i 's/CLUSTER_NAMES = ("c1", "c2", "c3")/CLUSTER_NAMES = ("c1", "c2", "c3", "c4")/; s/"ACTIVE", "c1,c2,c3"/"ACTIVE", "c1,c2,c3,c4"/' gateway.py
   Nhắc lại: API /admin/* của Gateway KHÔNG có xác thực -> chỉ bind trên IP Tailscale.
EOF
