#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Dừng ở dòng $LINENO: $BASH_COMMAND" >&2' ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="$ROOT_DIR/video-demo"
API_HOST="${API_HOST:?Đặt API_HOST là private IP truy cập được từ máy test}"
RELEASE="${RELEASE:-owdev}"
NS="${NAMESPACE:-${NS:-openwhisk}}"

command -v kubectl >/dev/null 2>&1 || { echo "Thiếu kubectl" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "Thiếu curl" >&2; exit 1; }

echo "Preflight OpenWhisk hiện tại; không chạy installer hoặc thay đổi deployment."
kubectl get namespace "$NS" >/dev/null
kubectl -n "$NS" get secret "${RELEASE}-whisk.auth" >/dev/null
nodeport="$(kubectl -n "$NS" get svc \
  -o jsonpath='{range .items[*].spec.ports[*]}{.nodePort}{"\n"}{end}' |
  grep -Fx '31001' || true)"
[ "$nodeport" = "31001" ] || {
  echo "Không tìm thấy OpenWhisk NodePort 31001 trong namespace $NS" >&2
  exit 1
}
ready_invokers="$(kubectl -n "$NS" get pods -l name="${RELEASE}-invoker" \
  -o custom-columns='READY:.status.conditions[?(@.type=="Ready")].status' --no-headers |
  awk '$1=="True"{count++} END {print count+0}')"
[ "$ready_invokers" -gt 0 ] || {
  echo "Không có Invoker Ready; hãy kiểm tra OpenWhisk trước khi deploy action" >&2
  exit 1
}
api_code="$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' \
  "https://${API_HOST}:31001/")"
[ "$api_code" = "200" ] || {
  echo "OpenWhisk NodePort trả HTTP $api_code" >&2
  exit 1
}
echo "Preflight OK: namespace=$NS nodeport=31001 ready_invokers=$ready_invokers api_http=$api_code"

API_HOST="$API_HOST" RELEASE="$RELEASE" NS="$NS" \
  bash "$DEMO_DIR/actions/deploy-demo-actions.sh"

API_HOST="$API_HOST" RELEASE="$RELEASE" NS="$NS" \
  bash "$DEMO_DIR/collect-evidence.sh"
echo "Demo deployment hoàn tất. Chạy: $DEMO_DIR/run-demo.sh smoke"
