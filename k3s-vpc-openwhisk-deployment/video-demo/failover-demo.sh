#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Failover demo dừng ở dòng $LINENO: $BASH_COMMAND" >&2' ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="$ROOT_DIR/video-demo"
NS="${NAMESPACE:-${NS:-openwhisk}}"
RELEASE="${RELEASE:-owdev}"
API_HOST="${API_HOST:?Đặt API_HOST}"
MODE="${FAILOVER_MODE:-invoker}"
EVIDENCE_DIR="$DEMO_DIR/evidence"
EVIDENCE="$EVIDENCE_DIR/failover-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$EVIDENCE_DIR"
exec > >(tee "$EVIDENCE") 2>&1

command -v kubectl >/dev/null || { echo "Thiếu kubectl"; exit 1; }
command -v curl >/dev/null || { echo "Thiếu curl"; exit 1; }
AUTH_FILE="${AUTH_FILE:-$EVIDENCE_DIR/.guest-auth}"
[ -s "$AUTH_FILE" ] || { echo "Không tìm thấy guest auth trong video-demo/evidence" >&2; exit 1; }
AUTH="$(cat "$AUTH_FILE")"

now_ms() {
  date +%s%3N
}

restore_node() {
  if [ -n "${node:-}" ]; then
    kubectl uncordon "$node" >/dev/null 2>&1 || true
  fi
}

cleanup_parallel() {
  if [ -n "${parallel_dir:-}" ]; then
    rm -rf "$parallel_dir"
  fi
}

pod_is_ready() {
  local pod_name="$1" ready
  ready="$(kubectl -n "$NS" get pod "$pod_name" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [ "$ready" = "True" ]
}

pod_rows() {
  kubectl -n "$NS" get pods -l name="${RELEASE}-invoker" \
    -o custom-columns='NAME:.metadata.name,UID:.metadata.uid,NODE:.spec.nodeName,PHASE:.status.phase' \
    --no-headers
}

echo "Mode=$MODE"
echo "Started at $(date --iso-8601=seconds)"

old_pod=""
old_uid=""
node=""
before_uids=""
while read -r candidate candidate_uid candidate_node candidate_phase; do
  [ -n "$candidate" ] || continue
  [ "$candidate_phase" = "Running" ] || continue
  pod_is_ready "$candidate" || continue
  control="$(kubectl get node "$candidate_node" \
    -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null || true)"
  [ "$control" = "true" ] && continue
  old_pod="$candidate"
  old_uid="$candidate_uid"
  node="$candidate_node"
  break
done < <(pod_rows)

if [ -n "${FAILOVER_NODE:-}" ]; then
  node="$FAILOVER_NODE"
  old_pod=""
  old_uid=""
  while read -r candidate candidate_uid candidate_node candidate_phase; do
    if [ "$candidate_node" = "$node" ] && [ "$candidate_phase" = "Running" ] &&
       pod_is_ready "$candidate"; then
      old_pod="$candidate"
      old_uid="$candidate_uid"
      break
    fi
  done < <(pod_rows)
fi

[ -n "$node" ] || { echo "Không tìm được Invoker Ready trên agent"; exit 1; }
[ -n "$old_pod" ] && [ -n "$old_uid" ] || {
  echo "Node $node không có Invoker pod Running/Ready"; exit 1;
}
before_uids="$(pod_rows | awk '{print $2}')"

# Đăng ký ngay sau khi xác định node: mọi lỗi sau đây đều cố gắng uncordon.
trap 'cleanup_parallel; restore_node' EXIT

echo "Old pod: $old_pod"
echo "Old UID: $old_uid"
echo "Old node: $node"
echo "All Invoker pods before failure:"
pod_rows
kubectl -n "$NS" get pod "$old_pod" -o wide
kubectl get nodes -o wide

if [ "$MODE" = invoker ]; then
  kubectl cordon "$node"
  failure_started="$(now_ms)"
  kubectl -n "$NS" delete pod "$old_pod" --wait=false
elif [ "$MODE" = node ]; then
  kubectl cordon "$node"
  failure_started="$(now_ms)"
  kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data \
    --grace-period=30 --timeout=180s
else
  echo "FAILOVER_MODE phải là invoker hoặc node" >&2
  exit 2
fi

echo "Failure injection started at ${failure_started}ms"

# Không coi replica còn lại là recovery: old UID phải biến mất trước.
old_gone=0
delete_deadline=$(( $(date +%s) + 180 ))
while [ "$(date +%s)" -lt "$delete_deadline" ]; do
  current_uid="$(kubectl -n "$NS" get pod "$old_pod" \
    -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  if [ -z "$current_uid" ] || [ "$current_uid" != "$old_uid" ]; then
    old_gone=1
    echo "Old pod UID $old_uid is no longer present"
    break
  fi
  sleep 2
done
[ "$old_gone" -eq 1 ] || { echo "Old Invoker pod UID vẫn còn tồn tại"; exit 1; }

replacement_pod=""
replacement_uid=""
replacement_node=""
recovery_deadline=$(( $(date +%s) + 240 ))
while [ "$(date +%s)" -lt "$recovery_deadline" ]; do
  while read -r candidate candidate_uid candidate_node candidate_phase; do
    if printf '%s\n' "$before_uids" | grep -Fxq "$candidate_uid"; then
      continue
    fi
    [ "$candidate_uid" != "$old_uid" ] || continue
    [ "$candidate_node" != "$node" ] || continue
    [ "$candidate_phase" = "Running" ] || continue
    if pod_is_ready "$candidate"; then
      replacement_pod="$candidate"
      replacement_uid="$candidate_uid"
      replacement_node="$candidate_node"
      break
    fi
  done < <(pod_rows)
  [ -n "$replacement_pod" ] && break
  sleep 3
done

[ -n "$replacement_pod" ] || {
  echo "Không tìm thấy Invoker replacement UID mới, Running, Ready và khác node"
  exit 1
}

recovery_finished="$(now_ms)"
recovery_ms=$((recovery_finished - failure_started))
echo "Replacement pod: $replacement_pod"
echo "Replacement UID: $replacement_uid"
echo "Replacement node: $replacement_node"
echo "Replacement Ready: true"
echo "Recovery time: ${recovery_ms} ms"
kubectl -n "$NS" get pod "$replacement_pod" -o wide

call_action() {
  curl -sk --max-time 60 -o /dev/null -w '%{http_code}' \
    -u "$AUTH" -H 'Content-Type: application/json' \
    -X POST "https://${API_HOST}:31001/api/v1/namespaces/_/actions/Group4_Action2?blocking=true&result=true" \
    -d '{}'
}

code="$(call_action)"
[ "$code" = 200 ] || { echo "Action sau recovery trả HTTP $code"; exit 1; }
echo "Group4_Action2 sau recovery trả HTTP 200"

parallel_dir="$(mktemp -d)"
for i in $(seq 1 8); do
  (
    call_action > "$parallel_dir/$i"
  ) &
done
wait

total=0
successful=0
failed=0
for result in "$parallel_dir"/*; do
  total=$((total + 1))
  code="$(cat "$result")"
  if [ "$code" = "200" ]; then
    successful=$((successful + 1))
  else
    failed=$((failed + 1))
  fi
done
echo "Post-recovery parallel requests: total=$total successful=$successful failed=$failed"
[ "$total" -eq 8 ] && [ "$successful" -eq 8 ] || {
  echo "Concurrency sau recovery không đạt 8/8 HTTP 200"
  exit 1
}
echo "Failover verification completed at $(date --iso-8601=seconds)"
echo "Evidence: $EVIDENCE"
