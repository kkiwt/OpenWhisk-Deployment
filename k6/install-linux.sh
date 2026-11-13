#!/usr/bin/env bash
set -Eeuo pipefail

if ! command -v apt-get >/dev/null 2>&1; then
  echo "ERROR: This installer supports Debian/Ubuntu. Install k6 from https://grafana.com/docs/k6/latest/set-up/install-k6/." >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

apt-get update
apt-get install -y ca-certificates curl gnupg
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://dl.k6.io/key.gpg | gpg --dearmor --yes -o /etc/apt/keyrings/k6-archive-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
  > /etc/apt/sources.list.d/k6.list
apt-get update
apt-get install -y k6

k6 version
