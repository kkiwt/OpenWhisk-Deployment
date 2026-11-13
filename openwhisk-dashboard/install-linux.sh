#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${VENV_DIR:-$SCRIPT_DIR/.venv}"

command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 is required. Install python3, python3-venv, and python3-pip first." >&2
  exit 1
}

if [ ! -d "$VENV_DIR" ]; then
  python3 -m venv "$VENV_DIR"
fi

"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/python" -m pip install -r "$SCRIPT_DIR/requirements.txt"

if [ ! -f "$SCRIPT_DIR/.env" ]; then
  cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
  chmod 600 "$SCRIPT_DIR/.env"
  echo "Created .env from .env.example. Set DASHBOARD_URL and optionally INGEST_TOKEN."
fi

echo "OpenWhisk Dashboard dependencies are installed in $VENV_DIR."
