#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ Dừng ở dòng $LINENO (lệnh: $BASH_COMMAND)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

RELEASE="${RELEASE:-owdev}"
NS="${NS:-openwhisk}"
DELETE_PVCS="${DELETE_PVCS:-1}"
PURGE_CHART="${PURGE_CHART:-0}"

need_cmd kubectl
need_cmd helm

if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
  warn "Namespace $NS không tồn tại; không có gì để gỡ."
  exit 0
fi

if [ "${FORCE:-0}" != "1" ]; then
  cat >&2 <<EOF
WARNING: Script này sẽ gỡ release Helm '$RELEASE' trong namespace '$NS'.
- Nó KHÔNG gỡ K3s, Tailscale, node hoặc kubectl.
- DELETE_PVCS=$DELETE_PVCS: PVC/PV local-path có thể bị xóa và mất dữ liệu.
EOF
  read -r -p "Nhập chính xác DELETE OPENWHISK để tiếp tục: " confirmation
  [ "$confirmation" = "DELETE OPENWHISK" ] || die "Đã hủy."
fi

log "Gỡ Helm release $RELEASE..."
if helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
  helm uninstall "$RELEASE" -n "$NS"
else
  warn "Không thấy Helm release $RELEASE; tiếp tục dọn namespace."
fi

kubectl -n "$NS" delete daemonset preload-python-runtime --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "$NS" delete -f "$ROOT_DIR/k3s-resource-policy.yaml" --ignore-not-found >/dev/null 2>&1 || true

if [ "$DELETE_PVCS" = "1" ]; then
  log "Xóa PVC trong namespace $NS..."
  kubectl -n "$NS" delete pvc --all --ignore-not-found
else
  warn "Giữ lại PVC vì DELETE_PVCS=$DELETE_PVCS."
fi

log "Xóa namespace $NS..."
kubectl delete namespace "$NS" --ignore-not-found

if [ "$PURGE_CHART" = "1" ]; then
  SRC_DIR="${SRC_DIR:-$ROOT_DIR/openwhisk-deploy-kube}"
  if [ -d "$SRC_DIR" ]; then
    warn "Xóa source chart local: $SRC_DIR"
    rm -rf "$SRC_DIR"
  fi
fi

ok "Đã gỡ OpenWhisk. K3s/Tailscale và các node vẫn được giữ nguyên."
