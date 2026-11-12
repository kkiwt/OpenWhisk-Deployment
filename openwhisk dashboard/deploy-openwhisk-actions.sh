#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_URL="${DASHBOARD_URL:-}"
SAMPLE_RATE="${SAMPLE_RATE:-0.05}"
CLUSTERS="${CLUSTERS:-c1 c2 c3}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  printf 'Usage: DASHBOARD_URL=http://<dashboard-host>:9000 [CLUSTERS="c1 c2 c3"] [SAMPLE_RATE=0.05] %s\n' "$0"
  printf 'Requires ~/.wskprops.<cluster> for each selected cluster.\n'
  exit 0
fi

if [[ -z "$DASHBOARD_URL" ]]; then
  echo "ERROR: Set DASHBOARD_URL to the dashboard address reachable from the OpenWhisk clusters." >&2
  exit 2
fi
case "$DASHBOARD_URL" in
  http://*|https://*) ;;
  *) echo "ERROR: DASHBOARD_URL must start with http:// or https://." >&2; exit 2 ;;
esac
DASHBOARD_URL="${DASHBOARD_URL%/}"
if ! awk -v rate="$SAMPLE_RATE" 'BEGIN { exit !(rate ~ /^[0-9]*([.][0-9]+)?$/ && rate >= 0 && rate <= 1) }'; then
  echo "ERROR: SAMPLE_RATE must be a number from 0 to 1." >&2
  exit 2
fi

command -v wsk >/dev/null || { echo "ERROR: wsk CLI is required." >&2; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl is required." >&2; exit 1; }
curl --fail --silent --show-error --max-time 5 "$DASHBOARD_URL/health" >/dev/null || {
  echo "ERROR: Cannot reach $DASHBOARD_URL/health from this machine." >&2
  exit 1
}

read -r -a cluster_list <<< "$CLUSTERS"
if [[ ${#cluster_list[@]} -eq 0 ]]; then
  echo "ERROR: CLUSTERS must contain at least one of c1, c2, c3." >&2
  exit 2
fi
for cluster in "${cluster_list[@]}"; do
  case "$cluster" in
    c1|c2|c3) ;;
    *) echo "ERROR: Unsupported cluster '$cluster' (expected c1, c2, or c3)." >&2; exit 2 ;;
  esac
  if [[ ! -r "$HOME/.wskprops.$cluster" ]]; then
    echo "ERROR: Missing $HOME/.wskprops.$cluster; configure that cluster first." >&2
    exit 1
  fi
done

for cluster in "${cluster_list[@]}"; do
  props="$HOME/.wskprops.$cluster"
  echo "Deploying dashboard publisher and A1/A2/A3 to $cluster..."
  WSK_CONFIG_FILE="$props" wsk -i action update publish_result \
    "$SCRIPT_DIR/actions/publish_result.py" --kind python:3 \
    --param MODE dashboard --param TARGET_URL "$DASHBOARD_URL"

  for action in A1 A2 A3; do
    case "$action" in
      A1) busy="0.05" ;;
      A2) busy="0.20" ;;
      A3) busy="0.50" ;;
    esac
    WSK_CONFIG_FILE="$props" wsk -i action update "$action" \
      "$SCRIPT_DIR/actions/a1.py" --kind python:3 \
      --param ACTION_NAME "$action" --param BUSY "$busy" \
      --param CLUSTER "$cluster" --param SAMPLE_RATE "$SAMPLE_RATE" \
      -a provide-api-key true
  done
done

echo "Done. OpenWhisk actions now send sampled real activations to $DASHBOARD_URL/ingest."
echo "Verify by invoking an action on a selected cluster, then inspect /api/recent on the dashboard."