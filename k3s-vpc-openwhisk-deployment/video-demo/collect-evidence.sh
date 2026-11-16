#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="$ROOT_DIR/video-demo"
NS="${NAMESPACE:-${NS:-openwhisk}}"
RELEASE="${RELEASE:-owdev}"
OUT="$DEMO_DIR/evidence/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
kubectl get nodes -o wide > "$OUT/nodes.txt"
kubectl get nodes --show-labels > "$OUT/nodes-labels.txt"
kubectl -n "$NS" get pods -o wide > "$OUT/pods.txt"
kubectl get pods --all-namespaces 2>/dev/null > "$OUT/pods-all.txt" || true
kubectl -n "$NS" get pvc > "$OUT/pvc.txt" || true
kubectl -n "$NS" get events --sort-by=.lastTimestamp > "$OUT/events.txt" || true
kubectl -n "$NS" top pods > "$OUT/top-pods.txt" 2>&1 || true
kubectl top nodes > "$OUT/top-nodes.txt" 2>&1 || true
kubectl -n "$NS" get pods -l name="${RELEASE}-invoker" -o wide > "$OUT/invokers.txt"
for pod in $(kubectl -n "$NS" get pods -l name="${RELEASE}-invoker" -o name); do
  safe="${pod##*/}"
  kubectl -n "$NS" logs "$pod" --since=10m > "$OUT/${safe}.log" 2>&1 || true
done

if [ -n "${PROMETHEUS_URL:-}" ]; then
  curl -fsS --max-time 10 "$PROMETHEUS_URL/-/ready" > "$OUT/prometheus-ready.txt"
  for query in \
    'sum(rate(container_cpu_usage_seconds_total[5m]))' \
    'sum(container_memory_working_set_bytes)' \
    'count(kube_pod_status_phase{namespace="openwhisk",phase="Running"})'; do
    encoded="$(printf '%s' "$query" | python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read()))')"
    curl -fsS --max-time 10 "$PROMETHEUS_URL/api/v1/query?query=$encoded" \
      >> "$OUT/prometheus-query.json" || true
    echo >> "$OUT/prometheus-query.json"
  done
fi
echo "Evidence: $OUT"
