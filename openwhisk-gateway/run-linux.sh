#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${VENV_DIR:-$SCRIPT_DIR/venv}"
GATEWAY_BIND_HOST="${GATEWAY_BIND_HOST:-0.0.0.0}"
GATEWAY_PORT="${GATEWAY_PORT:-8080}"

if [ ! -x "$VENV_DIR/bin/python" ]; then
  echo "ERROR: Gateway virtualenv is missing. Run ./install-linux.sh first." >&2
  exit 1
fi
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "ERROR: $SCRIPT_DIR/.env is missing. Run ./install-linux.sh and configure it." >&2
  exit 1
fi

cd "$SCRIPT_DIR"
exec "$VENV_DIR/bin/python" -m uvicorn gateway:app \
  --host "$GATEWAY_BIND_HOST" --port "$GATEWAY_PORT" "$@"
