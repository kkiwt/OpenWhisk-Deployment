#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Dừng ở dòng $LINENO: $BASH_COMMAND" >&2' ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="$ROOT_DIR/video-demo"
API_HOST="${API_HOST:?Đặt API_HOST là private IP truy cập được từ máy test}"
INVOKER_REPLICAS="${INVOKER_REPLICAS:-2}"
RELEASE="${RELEASE:-owdev}"
NS="${NAMESPACE:-${NS:-openwhisk}}"

RELEASE="$RELEASE" NS="$NS" API_HOST="$API_HOST" \
INVOKER_REPLICAS="$INVOKER_REPLICAS" PY_KINDS="${PY_KINDS:-python:3,nodejs:18}" \
  bash "$ROOT_DIR/openwhisk/install-openwhisk.sh"

API_HOST="$API_HOST" RELEASE="$RELEASE" NS="$NS" \
  bash "$DEMO_DIR/actions/deploy-demo-actions.sh"

API_HOST="$API_HOST" RELEASE="$RELEASE" NS="$NS" \
  bash "$DEMO_DIR/collect-evidence.sh"
echo "Demo deployment hoàn tất. Chạy: $DEMO_DIR/run-demo.sh smoke"
