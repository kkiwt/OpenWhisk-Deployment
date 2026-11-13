#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${VENV_DIR:-$SCRIPT_DIR/.venv}"

if [ ! -x "$VENV_DIR/bin/python" ]; then
  echo "ERROR: Dashboard virtualenv is missing. Run ./install-linux.sh first." >&2
  exit 1
fi
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "ERROR: .env is missing. Run ./install-linux.sh and configure it." >&2
  exit 1
fi

set -a
. "$SCRIPT_DIR/.env"
set +a
export DASHBOARD_BIND_HOST="${DASHBOARD_BIND_HOST:-0.0.0.0}"
export DASHBOARD_PORT="${DASHBOARD_PORT:-9000}"

cd "$SCRIPT_DIR"
exec "$VENV_DIR/bin/python" -m uvicorn dashboard:app \
  --host "$DASHBOARD_BIND_HOST" --port "$DASHBOARD_PORT" --workers 1 "$@"
