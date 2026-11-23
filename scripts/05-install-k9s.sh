#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required." >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "ERROR: tar is required." >&2; exit 1; }

arch="$(uname -m)"
case "$arch" in
  x86_64) asset_arch="amd64" ;;
  aarch64|arm64) asset_arch="arm64" ;;
  *) echo "ERROR: Unsupported architecture: $arch" >&2; exit 1 ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
url="$(curl -fsSL https://api.github.com/repos/derailed/k9s/releases/latest |
  grep -o '"browser_download_url": "[^"]*Linux_[^"]*'"$asset_arch"'[^"]*\.tar\.gz"' |
  head -n1 | cut -d'"' -f4)"
[ -n "$url" ] || { echo "ERROR: Could not find a K9s Linux release for $asset_arch." >&2; exit 1; }
curl -fsSL -o "$tmp/k9s.tar.gz" "$url"
tar -xzf "$tmp/k9s.tar.gz" -C "$tmp"
install -m 0755 "$tmp/k9s" /usr/local/bin/k9s
k9s version
