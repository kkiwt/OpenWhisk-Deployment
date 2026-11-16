#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="$ROOT_DIR/video-demo"
NS="${NAMESPACE:-${NS:-openwhisk}}"
RELEASE="${RELEASE:-owdev}"
OUT="$DEMO_DIR/evidence/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

write_or_note() {
  local output="$1"
  shift
  if "$@" > "$output" 2>&1; then
    return 0
  fi
  printf 'Command failed; inspect the command and cluster access.\n' >> "$output"
  return 0
}

write_or_note "$OUT/nodes.txt" kubectl get nodes -o wide
write_or_note "$OUT/node-ip.txt" kubectl get nodes \
  -o custom-columns='NAME:.metadata.name,INTERNAL-IP:.status.addresses[?(@.type=="InternalIP")].address,EXTERNAL-IP:.status.addresses[?(@.type=="ExternalIP")].address'
write_or_note "$OUT/nodes-labels.txt" kubectl get nodes --show-labels
write_or_note "$OUT/node-resources.txt" kubectl describe nodes
write_or_note "$OUT/top-nodes.txt" kubectl top nodes
write_or_note "$OUT/pods-all.txt" kubectl get pods --all-namespaces -o wide
write_or_note "$OUT/pods.txt" kubectl -n "$NS" get pods -o wide
write_or_note "$OUT/pod-placement.txt" kubectl -n "$NS" get pods \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,READY:.status.conditions[?(@.type=="Ready")].status,NODE:.spec.nodeName,IP:.status.podIP'
write_or_note "$OUT/pod-restarts.txt" kubectl -n "$NS" get pods \
  -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,PHASE:.status.phase,NODE:.spec.nodeName'
write_or_note "$OUT/top-pods.txt" kubectl -n "$NS" top pods
write_or_note "$OUT/pvc.txt" kubectl -n "$NS" get pvc -o wide
write_or_note "$OUT/events.txt" kubectl -n "$NS" get events --sort-by=.lastTimestamp
write_or_note "$OUT/invokers.txt" kubectl -n "$NS" get pods \
  -l name="${RELEASE}-invoker" -o wide

while read -r pod; do
  [ -n "$pod" ] || continue
  safe="${pod#pod/}"
  kubectl -n "$NS" logs "$pod" --since=15m \
    > "$OUT/${safe}.log" 2>&1 || true
done < <(kubectl -n "$NS" get pods -l name="${RELEASE}-invoker" -o name 2>/dev/null || true)

if [ -n "${PROMETHEUS_URL:-}" ]; then
  curl -fsS --max-time 10 "$PROMETHEUS_URL/-/ready" \
    > "$OUT/prometheus-ready.txt" 2>&1 || true
  : > "$OUT/prometheus-metrics.jsonl"
  while IFS= read -r query; do
    [ -n "$query" ] || continue
    encoded="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$query")"
    response="$(curl -fsS --max-time 10 \
      "$PROMETHEUS_URL/api/v1/query?query=$encoded" 2>&1 || true)"
    python3 -c 'import json, sys; print(json.dumps({"query": sys.argv[1], "response": sys.argv[2]}))' \
      "$query" "$response" >> "$OUT/prometheus-metrics.jsonl"
  done <<'QUERIES'
sum(rate(container_cpu_usage_seconds_total{container!="",container!="POD"}[5m]))
sum(container_memory_working_set_bytes{namespace="openwhisk"})
count(kube_pod_status_phase{namespace="openwhisk",phase="Running"})
kube_pod_container_status_restarts_total{namespace="openwhisk"}
kube_node_status_condition
QUERIES
else
  printf 'PROMETHEUS_URL was not provided; no Prometheus API snapshot collected.\n' \
    > "$OUT/prometheus-metrics.txt"
fi

# Copy report artifacts only. Never copy .guest-auth or any other secret file.
while IFS= read -r artifact; do
  [ "$artifact" != "$OUT" ] || continue
  [ "$(basename "$artifact")" != ".guest-auth" ] || continue
  cp "$artifact" "$OUT/$(basename "$artifact")" 2>/dev/null || true
done < <(
  find "$DEMO_DIR/evidence" -maxdepth 2 -type f \
    \( -name '*.json' -o -name '*.csv' -o -name 'failover-*.log' \) \
    ! -path "$OUT/*"
)

printf 'Evidence directory: %s\n' "$OUT"
printf 'Authentication files were intentionally excluded.\n'
