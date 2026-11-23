#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="$ROOT_DIR/video-demo"
MODE="${1:-help}"
NS="${NAMESPACE:-${NS:-openwhisk}}"
AUTH_FILE="${AUTH_FILE:-$DEMO_DIR/evidence/.guest-auth}"

usage() {
  cat <<'EOF'
Usage:
  bash ./video-demo/run-demo2.sh smoke
  bash ./video-demo/run-demo2.sh concurrency [2|3|5|8|10|12] [duration]
  bash ./video-demo/run-demo2.sh health
  bash ./video-demo/run-demo2.sh collect
  bash ./video-demo/run-demo2.sh help

Environment:
  API_HOST          OpenWhisk host/IP
  RATE              Concurrency RPS override
  DURATION          Concurrency duration, default 60s
  AUTH_FILE         Guest auth file, default video-demo/evidence/.guest-auth
  PROMETHEUS_URL    Optional Prometheus URL for collect
EOF
}

need_auth() {
  [ -s "$AUTH_FILE" ] || {
    echo "Chạy deploy-demo.sh trước; không tìm thấy $AUTH_FILE" >&2
    exit 1
  }
  OW_AUTH="$(cat "$AUTH_FILE")"
}

call_action() {
  local action="$1"
  local output="$2"

  curl -skS --max-time 60 -u "$OW_AUTH" \
    -H 'Content-Type: application/json' \
    -X POST "https://${API_HOST}:31001/api/v1/namespaces/_/actions/${action}?blocking=true&result=true" \
    -d '{}' > "$output"
}

case "$MODE" in
  smoke)
    API_HOST="${API_HOST:?Đặt API_HOST}"
    need_auth
    output="$DEMO_DIR/evidence/smoke2-$(date +%Y%m%d-%H%M%S).json"
    call_action Group4_Action2 "$output"
    cat "$output"
    echo
    echo "Smoke evidence: $output"
    ;;
  concurrency)
    API_HOST="${API_HOST:?Đặt API_HOST}"
    need_auth
    command -v k6 >/dev/null 2>&1 || {
      echo "Cài k6 trên máy chạy test" >&2
      exit 1
    }

    rate="${2:-${RATE:-8}}"
    duration="${3:-${DURATION:-60s}}"

    case "$rate" in
      2|3|5|8|10|12) ;;
      *)
        echo "Mức tải hỗ trợ: 2, 3, 5, 8, 10 hoặc 12 RPS" >&2
        exit 2
        ;;
    esac

    result_dir="$DEMO_DIR/evidence/k6-2-$(date +%Y%m%d-%H%M%S)-${rate}rps"
    mkdir -p "$result_dir"
    printf 'rate=%s\nduration=%s\nstarted_at=%s\n' \
      "$rate" "$duration" "$(date --iso-8601=seconds)" \
      > "$result_dir/run-info.txt"

    k6 run \
      -e OW_API="https://${API_HOST}:31001" \
      -e OW_AUTH="$OW_AUTH" \
      -e SCENARIO=concurrency \
      -e RATE="$rate" \
      -e DURATION="$duration" \
      --summary-export "$result_dir/summary.json" \
      --out "csv=$result_dir/metrics.csv" \
      "$DEMO_DIR/tests/video-load2.js"

    echo "K6 JSON: $result_dir/summary.json"
    echo "K6 CSV:  $result_dir/metrics.csv"
    ;;
  health)
    API_HOST="${API_HOST:?Đặt API_HOST}"
    need_auth
    command -v kubectl >/dev/null 2>&1 || {
      echo "Thiếu kubectl" >&2
      exit 1
    }

    code="$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' \
      "https://${API_HOST}:31001/")"
    [ "$code" = 200 ] || {
      echo "OpenWhisk NodePort HTTP $code" >&2
      exit 1
    }

    ready="$(kubectl get nodes --no-headers | awk '$2=="Ready"{count++} END {print count+0}')"
    [ "$ready" -gt 0 ] || {
      echo "Không có node Ready" >&2
      exit 1
    }

    action_output="$DEMO_DIR/evidence/health2-$(date +%Y%m%d-%H%M%S).json"
    call_action ping "$action_output"
    kubectl get nodes -o wide
    kubectl -n "$NS" get pods -o wide
    echo "Health HTTP: 200"
    echo "Ready nodes: $ready"
    echo "Health action: $action_output"
    ;;
  collect)
    PROMETHEUS_URL="${PROMETHEUS_URL:-}" \
      bash "$DEMO_DIR/collect-evidence.sh"
    ;;
  help|*)
    usage
    if [ "$MODE" != "help" ]; then
      exit 2
    fi
    ;;
esac
