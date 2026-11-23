#!/usr/bin/env bash
set -Eeuo pipefail

cd /root/OpenWhisk-Deployment/k3s-vpc-openwhisk-deployment

POLICY="k3s-resource-policy.yaml"
BACKUP="${POLICY}.bak.$(date +%Y%m%d-%H%M%S)"

echo "===== BACKUP ====="
cp "$POLICY" "$BACKUP"
echo "Backup: $BACKUP"

echo "===== UPDATE RESOURCE POLICY ====="
cat > "$POLICY" <<'YAML'
apiVersion: v1
kind: LimitRange
metadata:
  name: openwhisk-default-limits
spec:
  limits:
    - type: Container
      default:
        memory: 128Mi
        cpu: 500m
      defaultRequest:
        memory: 64Mi
        cpu: 50m
      max:
        memory: 2048Mi
        cpu: "1"
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: openwhisk-safety-quota
spec:
  hard:
    requests.memory: 10Gi
    limits.memory: 16Gi
    requests.cpu: "8"
    limits.cpu: "20"
    pods: "60"
YAML

echo "===== VALIDATE ====="
kubectl apply --dry-run=server -f "$POLICY"

echo "===== APPLY ====="
kubectl apply -f "$POLICY"

echo "===== VERIFY ====="
kubectl -n openwhisk describe resourcequota openwhisk-safety-quota
kubectl -n openwhisk describe limitrange openwhisk-default-limits

echo "===== DONE ====="
