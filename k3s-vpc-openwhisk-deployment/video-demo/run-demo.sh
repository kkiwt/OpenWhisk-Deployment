#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="$ROOT_DIR/video-demo"
MODE="${1:-smoke}"
API_HOST="${API_HOST:?Đặt API_HOST}"
AUTH_FILE="${AUTH_FILE:-$DEMO_DIR/evidence/.guest-auth}"
[ -s "$AUTH_FILE" ] || { echo "Chạy deploy-demo.sh trước" >&2; exit 1; }
OW_AUTH="$(cat "$AUTH_FILE")"

case "$MODE" in
  smoke)
    curl -skS --max-time 60 -u "$OW_AUTH" -H 'Content-Type: application/json' \
      -X POST "https://${API_HOST}:31001/api/v1/namespaces/_/actions/Group4_Action2?blocking=true&result=true" -d '{}'
    echo
    ;;
  concurrency)
    command -v k6 >/dev/null 2>&1 || { echo "Cài k6 trên máy chạy test" >&2; exit 1; }
    k6 run -e OW_API="https://${API_HOST}:31001" -e OW_AUTH="$OW_AUTH" \
      -e SCENARIO=concurrency -e DURATION=60s "$DEMO_DIR/tests/video-load.js"
    ;;
  *)
    echo "Dùng: $0 smoke | concurrency" >&2
    exit 2
    ;;
esac
