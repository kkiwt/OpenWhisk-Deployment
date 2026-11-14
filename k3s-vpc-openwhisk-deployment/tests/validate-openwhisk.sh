#!/usr/bin/env bash
# Validate the deployed OpenWhisk path, parallel action execution, and invoker recovery.
#
# Usage:
#   API_HOST=10.0.0.10 ./tests/validate-openwhisk.sh
#   API_HOST=10.0.0.10 RUN_NODE_FAILOVER=1 ./tests/validate-openwhisk.sh
#
# RUN_NODE_FAILOVER=1 is destructive to one selected worker: it cordons and drains
# the node, then checks that the OpenWhisk API remains reachable. Use only on a
# disposable test cluster and restore the node afterwards if it is still needed.
set -Eeuo pipefail
trap 'echo "Validation stopped at line $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"

RELEASE="${RELEASE:-owdev}"
NS="${NS:-openwhisk}"
API_HOST="${API_HOST:-$(ow_api_host)}"
RUN_NODE_FAILOVER="${RUN_NODE_FAILOVER:-0}"
FAILOVER_NODE="${FAILOVER_NODE:-}"
PARALLEL_REQUESTS="${PARALLEL_REQUESTS:-8}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-60}"

need_cmd kubectl
need_cmd curl
need_cmd base64
[[ "$API_HOST" ]] || die "Thiếu API_HOST"
[[ "$PARALLEL_REQUESTS" =~ ^[1-9][0-9]*$ ]] || die "PARALLEL_REQUESTS phải là số nguyên dương"
[[ "$RUN_NODE_FAILOVER" == "0" || "$RUN_NODE_FAILOVER" == "1" ]] || die "RUN_NODE_FAILOVER phải là 0 hoặc 1"

GUEST_AUTH="$(kubectl -n "$NS" get secret "${RELEASE}-whisk.auth" -o jsonpath='{.data.guest}' | base64 -d)"
[[ "$GUEST_AUTH" ]] || die "Không đọc được guest auth"
B64="$(printf '%s' "$GUEST_AUTH" | base64 -w0)"
API="https://${API_HOST}:31001"

call_action() {
  local action="$1" timeout="${2:-$REQUEST_TIMEOUT}"
  curl -skS --max-time "$timeout" -o /dev/null \
    -w '%{http_code}' \
    -H "Authorization: Basic ${B64}" \
    -H 'Content-Type: application/json' \
    -X POST "${API}/api/v1/namespaces/_/actions/${action}?blocking=true&result=true" \
    -d '{}'
}

log "1/4 Kiểm tra API và action test-thu..."
CODE="$(call_action test-thu)"
[ "$CODE" = "200" ] || die "test-thu trả HTTP $CODE"
ok "OpenWhisk API trả HTTP 200 qua ${API}"

log "2/4 Kiểm tra concurrency với ${PARALLEL_REQUESTS} request A2..."
RESULTS="$(mktemp)"
cleanup() { rm -f "$RESULTS"; }
trap cleanup EXIT
for _ in $(seq 1 "$PARALLEL_REQUESTS"); do
  (
    code="$(call_action A2 "$REQUEST_TIMEOUT")"
    printf '%s\n' "$code" >> "$RESULTS"
  ) &
done
wait
FAILED="$(grep -v '^200$' "$RESULTS" | wc -l)"
[ "$FAILED" -eq 0 ] || die "$FAILED/$PARALLEL_REQUESTS request concurrency không trả HTTP 200"
ok "Tất cả request concurrency trả HTTP 200"

if [ "$RUN_NODE_FAILOVER" = "1" ]; then
  log "3/4 Mô phỏng failover bằng cordon/drain một node..."
  if [ -z "$FAILOVER_NODE" ]; then
    FAILOVER_NODE="$(kubectl get nodes -l openwhisk-role=invoker \
      -o jsonpath='{range .items[1:]}{.metadata.name}{"\n"}{end}' | head -n1)"
  fi
  [ "$FAILOVER_NODE" ] || die "Không chọn được FAILOVER_NODE"
  kubectl get node "$FAILOVER_NODE" >/dev/null || die "Không tìm thấy node $FAILOVER_NODE"
  restore_node() { kubectl uncordon "$FAILOVER_NODE" >/dev/null 2>&1 || true; }
  trap 'restore_node; cleanup' EXIT
  kubectl cordon "$FAILOVER_NODE" >/dev/null
  kubectl drain "$FAILOVER_NODE" --ignore-daemonsets --delete-emptydir-data \
    --grace-period=30 --timeout=180s
  CODE="$(call_action test-thu)"
  [ "$CODE" = "200" ] || die "API không phục vụ được sau drain $FAILOVER_NODE (HTTP $CODE)"
  ok "API vẫn trả HTTP 200 sau khi drain $FAILOVER_NODE"
else
  log "3/4 Bỏ qua node failover (đặt RUN_NODE_FAILOVER=1 để chạy)"
fi

log "4/4 Kiểm tra phân bố invoker và trạng thái node..."
kubectl -n "$NS" get pods -l name="${RELEASE}-invoker" -o wide
kubectl get nodes -o wide
ok "Đã hoàn tất kiểm tra routing, concurrency và health"
