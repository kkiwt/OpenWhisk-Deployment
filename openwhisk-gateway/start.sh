#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -x "${VENV_DIR:-$SCRIPT_DIR/venv}/bin/python" ]; then
  "$SCRIPT_DIR/install-linux.sh"
fi

exec "$SCRIPT_DIR/run-linux.sh" "$@"
