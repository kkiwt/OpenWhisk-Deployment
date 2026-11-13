#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RATE="${1:-${RATE:-50}}"
DURATION="${2:-${DURATION:-5m}}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/results/quick_$(date -u +%Y%m%d_%H%M%S)}"
K6_BIN="${K6_BIN:-k6}"

command -v "$K6_BIN" >/dev/null 2>&1 || { echo "ERROR: k6 is not installed." >&2; exit 1; }
[[ "$RATE" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "ERROR: RATE must be positive." >&2; exit 2; }
[[ -n "$DURATION" ]] || { echo "ERROR: DURATION must not be empty." >&2; exit 2; }
mkdir -p "$OUTPUT_DIR"

ARGS=(run
  -e "RATE=$RATE"
  -e "DURATION=$DURATION"
  -e "GATEWAY_URL=$GATEWAY_URL"
  -e "TARGET_MODE=${TARGET_MODE:-gateway}"
  -e "DIRECT_API_URL=${DIRECT_API_URL:-}"
  -e "DIRECT_AUTH=${DIRECT_AUTH:-}"
  -e "DIRECT_CLUSTER=${DIRECT_CLUSTER:-unknown}"
  -e "DIRECT_NAMESPACE=${DIRECT_NAMESPACE:-_}"
  -e "DRY_RUN=${DRY_RUN:-0}"
  --summary-export="$OUTPUT_DIR/k6.json"
  "$SCRIPT_DIR/load.js")

printf 'Running K6 at %s req/s for %s against %s\nOutput: %s\n' \
  "$RATE" "$DURATION" "$GATEWAY_URL" "$OUTPUT_DIR"
"$K6_BIN" "${ARGS[@]}"
