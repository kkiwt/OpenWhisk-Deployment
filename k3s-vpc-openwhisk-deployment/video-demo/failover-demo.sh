#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Failover demo dừng ở dòng $LINENO" >&2' ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="$ROOT_DIR/video-demo"
NS="${NAMESPACE:-${NS:-openwhisk}}"
RELEASE="${RELEASE:-owdev}"
API_HOST="${API_HOST:?Đặt API_HOST}"
MODE="${FAILOVER_MODE:-invoker}"
EVIDENCE="$DEMO_DIR/evidence/failover-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$DEMO_DIR/evidence"
exec > >(tee "$EVIDENCE") 2>&1

command -v kubectl >/dev/null || { echo "Thiếu kubectl"; exit 1; }
AUTH_FILE="${AUTH_FILE:-$DEMO_DIR/evidence/.guest-auth}"
AUTH="$(cat "$AUTH_FILE")"
pod="$(kubectl -n "$NS" get pods -l name="${RELEASE}-invoker" \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' |
  while read -r candidate candidate_node; do
    [ -n "$candidate" ] || continue
    control="$(kubectl get node "$candidate_node" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null || true)"
    [ "$control" = "true" ] && continue
    printf '%s %s\n' "$candidate" "$candidate_node"
    break
  done)"
[ -n "$pod" ] || { echo "Không tìm thấy Invoker pod"; exit 1; }
node="$(printf '%s\n' "$pod" | awk '{print $2}')"
if [ -n "${FAILOVER_NODE:-}" ]; then node="$FAILOVER_NODE"; fi
[ -n "$node" ] || { echo "Không xác định được node"; exit 1; }
echo "Mode=$MODE node=$node"
kubectl get nodes -o wide
kubectl -n "$NS" get pods -o wide

restore_node() {
  kubectl uncordon "$node" >/dev/null 2>&1 || true
}

if [ "$MODE" = invoker ]; then
  target="$(kubectl -n "$NS" get pods -l name="${RELEASE}-invoker" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' | awk -v n="$node" '$2==n {print $1; exit}')"
  [ -n "$target" ] || { echo "Node $node không chứa Invoker"; exit 1; }
  kubectl cordon "$node"
  kubectl -n "$NS" delete pod "$target" --wait=true --timeout=120s
else
  [ "$MODE" = node ] || { echo "FAILOVER_MODE phải là invoker hoặc node"; exit 2; }
  kubectl cordon "$node"
  kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data \
    --grace-period=30 --timeout=180s
fi
trap restore_node EXIT

deadline=$(( $(date +%s) + 240 ))
new_node=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  new_node="$(kubectl -n "$NS" get pods -l name="${RELEASE}-invoker" \
    -o jsonpath='{range .items[*]}{.status.phase}{" "}{.spec.nodeName}{"\n"}{end}' |
    awk -v old="$node" '$1=="Running" && $2!="" && $2!=old {print $2; exit}')"
  [ -n "$new_node" ] && break
  sleep 5
done
[ -n "$new_node" ] || { echo "Invoker chưa chạy lại trên node khác"; exit 1; }
kubectl -n "$NS" get pods -l name="${RELEASE}-invoker" -o wide
code="$(curl -sk --max-time 60 -o /dev/null -w '%{http_code}' \
  -u "$AUTH" -H 'Content-Type: application/json' \
  -X POST "https://${API_HOST}:31001/api/v1/namespaces/_/actions/Group4_Action2?blocking=true&result=true" -d '{}')"
[ "$code" = 200 ] || { echo "Group4_Action2 sau failover trả HTTP $code"; exit 1; }
echo "Group4_Action2 sau failover trả HTTP 200"

parallel_dir="$(mktemp -d)"
cleanup_parallel() { rm -rf "$parallel_dir"; }
trap 'cleanup_parallel; restore_node' EXIT
for i in $(seq 1 8); do
  (
    curl -sk --max-time 60 -o /dev/null -w '%{http_code}' \
      -u "$AUTH" -H 'Content-Type: application/json' \
      -X POST "https://${API_HOST}:31001/api/v1/namespaces/_/actions/Group4_Action2?blocking=true&result=true" \
      -d '{}' > "$parallel_dir/$i"
  ) &
done
wait
failed="$(awk '$0 != "200" { count++ } END { print count+0 }' "$parallel_dir"/*)"
[ "$failed" -eq 0 ] || { echo "$failed/8 concurrency request lỗi sau failover"; exit 1; }
echo "8/8 request concurrency trả HTTP 200 sau failover"
echo "Evidence: $EVIDENCE"
