#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Dừng ở dòng $LINENO" >&2' ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="$ROOT_DIR/video-demo"
source "$ROOT_DIR/scripts/lib.sh"
NS="${NAMESPACE:-${NS:-openwhisk}}"
RELEASE="${RELEASE:-owdev}"
API_HOST="${API_HOST:-$(ow_api_host)}"
CLUSTER_NAME="${CLUSTER_NAME:-k3s-vpc-demo}"
API="https://${API_HOST}:31001"

need_cmd kubectl
need_cmd curl
need_cmd base64
command -v wsk >/dev/null 2>&1 || {
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/wsk.tgz" \
    https://github.com/apache/openwhisk-cli/releases/download/1.2.0/OpenWhisk_CLI-1.2.0-linux-amd64.tgz
  tar -xzf "$tmp/wsk.tgz" -C "$tmp"
  sudo install -m 0755 "$tmp/wsk" /usr/local/bin/wsk
  rm -rf "$tmp"
}

AUTH="$(kubectl -n "$NS" get secret "${RELEASE}-whisk.auth" -o jsonpath='{.data.guest}' | base64 -d)"
[ -n "$AUTH" ] || { echo "Không đọc được guest auth" >&2; exit 1; }
WSK=(wsk -i --apihost "$API" --auth "$AUTH")

"${WSK[@]}" action update ping "$DEMO_DIR/actions/demo_action.py" --kind python:3 \
  --param NAME ping --param GROUP "Group 4" --param BUSY 0.01 --param CLUSTER "$CLUSTER_NAME"
"${WSK[@]}" action update node-info "$DEMO_DIR/actions/demo_action.py" --kind python:3 \
  --param NAME node-info --param GROUP "Group 4" --param BUSY 0.01 --param CLUSTER "$CLUSTER_NAME"
for spec in "Group4_Action1:0.05" "Group4_Action2:0.20" "Group4_Action3:0.50"; do
  name="${spec%%:*}"
  busy="${spec#*:}"
  "${WSK[@]}" action update "$name" "$DEMO_DIR/actions/demo_action.py" --kind python:3 \
    --param NAME "$name" --param GROUP "Group 4" --param BUSY "$busy" --param CLUSTER "$CLUSTER_NAME"
done
"${WSK[@]}" action update node-demo "$DEMO_DIR/actions/node_demo.js" --kind nodejs:18 \
  --param GROUP "Group 4" --param CLUSTER "$CLUSTER_NAME"

AUTH_B64="$(printf '%s' "$AUTH" | base64 -w0)"
for action in ping node-info Group4_Action1 Group4_Action2 Group4_Action3 node-demo; do
  code="$(curl -sk --max-time 60 -o "/tmp/${action}.json" -w '%{http_code}' \
    -H "Authorization: Basic ${AUTH_B64}" -H 'Content-Type: application/json' \
    -X POST "$API/api/v1/namespaces/_/actions/$action?blocking=true&result=true" -d '{}')"
  [ "$code" = "200" ] || { echo "$action trả HTTP $code" >&2; exit 1; }
  printf '%-5s ' "$action"
  cat "/tmp/${action}.json"
  echo
done

mkdir -p "$DEMO_DIR/evidence"
printf '%s\n' "$AUTH" > "$DEMO_DIR/evidence/.guest-auth"
chmod 600 "$DEMO_DIR/evidence/.guest-auth"
echo "Actions đã sẵn sàng. Auth được lưu trong video-demo/evidence/.guest-auth (không commit)."
