#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
need_root "$@"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git jq python3 python3-venv python3-pip \
  apache2-utils bash-completion iproute2 openssh-client socat conntrack

if ! command -v kubectl >/dev/null 2>&1; then
  arch="$(dpkg --print-architecture)"
  case "$arch" in amd64) arch=amd64 ;; arm64) arch=arm64 ;; *) die "Kiến trúc chưa hỗ trợ: $arch" ;; esac
  version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/${version}/bin/linux/${arch}/kubectl"
  install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm -f /tmp/kubectl
fi

if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

if ! command -v wsk >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/wsk.tgz" \
    https://github.com/apache/openwhisk-cli/releases/download/1.2.0/OpenWhisk_CLI-1.2.0-linux-amd64.tgz
  tar -xzf "$tmp/wsk.tgz" -C "$tmp"
  install -m 0755 "$tmp/wsk" /usr/local/bin/wsk
  rm -rf "$tmp"
fi

ok "Linux prerequisites đã sẵn sàng. Chạy 01-install-tailscale.sh tiếp theo."
