#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: Dừng tại dòng $LINENO: $BASH_COMMAND" >&2' ERR

RELEASE="${RELEASE:-owdev}"
NS="${NS:-openwhisk}"

PVC_NAMES=(
  migration-alarmprovider
  migration-couchdb
  migration-kafka
  migration-redis
  migration-zookeeper-data
  migration-zookeeper-datalog
  owdev-alarmprovider-pvc
  owdev-couchdb-pvc
  owdev-kafka-pvc
  owdev-redis-pvc
  owdev-zookeeper-pvc-data
  owdev-zookeeper-pvc-datalog
)

PV_NAMES=(
  pvc-17faf11e-33e6-444f-b1fe-832a347fad86
  pvc-e59ac383-76d0-40bf-865b-6a7582831ffa
  pvc-dd4532d6-d29d-42d7-bfe3-8ca2265a4fb4
  pvc-2afd9be1-11e0-4dd1-9b62-57ddf92b57aa
  pvc-92fe8b8f-a0fc-4507-9b59-2d06017a0ff6
  pvc-4e85747b-d635-4bf5-a71e-d11d2f216a2b
  pvc-67b5cccd-9d18-4365-9279-ff25227adee6
  pvc-cb56183c-8275-4afb-9321-b5e6739793bf
  pvc-f248c747-f1c4-46cf-8908-8992f9ad23b6
  pvc-b3673eb3-123d-4b28-b9a8-ae1822d6f7d4
  pvc-f0c56364-b2c9-4e66-a283-c93167463f9f
  pvc-40402641-f7fd-4928-ab5a-d739f31b8f54
)

for cmd in kubectl helm; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Missing command: $cmd" >&2
    exit 1
  }
done

kubectl get namespace "$NS" >/dev/null

echo "=========================================="
echo " OPENWHISK COMPLETE DELETION"
echo "=========================================="
echo "Release: $RELEASE"
echo "Namespace: $NS"
echo "PVCs: ${#PVC_NAMES[@]}"
echo "PVs: ${#PV_NAMES[@]}"
echo
echo "Will delete:"
echo "- Helm release $RELEASE"
echo "- Exactly the 12 listed PVCs and their PVs"
echo "- Namespace $NS and its remaining resources"
echo
echo "Will preserve:"
echo "- Longhorn installation"
echo "- PV pvc-34664444-7773-4c92-9570-25be90c0e59d"
echo "- Monitoring PVs"
echo "- Other namespaces and workloads"
echo "- K3s and Tailscale"
echo "- Project source code"
echo
echo "WARNING: DATA DELETION IS IRREVERSIBLE."
echo

if [ "${FORCE:-0}" != "1" ]; then
  read -r -p 'Type DELETE OPENWHISK to continue: ' CONFIRM
  [ "$CONFIRM" = "DELETE OPENWHISK" ] || {
    echo "Cancelled."
    exit 1
  }
fi

echo "[1/5] Validating PVC/PV ownership..."

for i in "${!PVC_NAMES[@]}"; do
  PVC="${PVC_NAMES[$i]}"
  PV="${PV_NAMES[$i]}"

  ACTUAL_PV="$(kubectl get pvc "$PVC" -n "$NS"     -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"

  if [ "$ACTUAL_PV" != "$PV" ]; then
    echo "ERROR: PVC $PVC does not reference expected PV $PV"
    exit 1
  fi

  CLAIM_NS="$(kubectl get pv "$PV"     -o jsonpath='{.spec.claimRef.namespace}' 2>/dev/null || true)"
  CLAIM_NAME="$(kubectl get pv "$PV"     -o jsonpath='{.spec.claimRef.name}' 2>/dev/null || true)"

  if [ "$CLAIM_NS" != "$NS" ] || [ "$CLAIM_NAME" != "$PVC" ]; then
    echo "ERROR: PV ownership mismatch: $PV"
    exit 1
  fi
done

echo "[2/5] Changing reclaim policy for the 12 approved PVs..."

for PV in "${PV_NAMES[@]}"; do
  kubectl patch pv "$PV" --type=merge     -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'
done

echo "[3/5] Uninstalling Helm release..."

if helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
  helm uninstall "$RELEASE" -n "$NS"
else
  echo "Helm release not found; continuing."
fi

echo "[4/5] Deleting the 12 approved PVCs..."

for PVC in "${PVC_NAMES[@]}"; do
  kubectl delete pvc "$PVC" -n "$NS"     --ignore-not-found --wait=true
done

echo "Waiting for approved PVs to be reclaimed..."

for PV in "${PV_NAMES[@]}"; do
  for attempt in $(seq 1 60); do
    if ! kubectl get pv "$PV" >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done

  if kubectl get pv "$PV" >/dev/null 2>&1; then
    echo "ERROR: PV $PV still exists."
    echo "Stopping before namespace deletion."
    exit 1
  fi
done

echo "[5/5] Deleting namespace $NS..."

kubectl delete namespace "$NS" --wait=true

echo
echo "=========================================="
echo " OpenWhisk deletion completed."
echo " Verify Longhorn volumes separately."
echo "=========================================="
