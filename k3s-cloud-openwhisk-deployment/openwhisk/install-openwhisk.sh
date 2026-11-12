#!/usr/bin/env bash
# =====================================================================
#  install-openwhisk.sh - cài OpenWhisk lên cụm K3s 3 node (1 Master 4GB + 2 Worker 2GB)
#
#  Làm: mở khóa master -> kiểm tra -> tải chart -> helm install -> ép trần RAM pod
#       -> chờ pod sẵn sàng -> tải sẵn image Python -> thử API.
#
#  Biến tùy chọn:
#    API_HOST=100.x.x.x         (mặc định: IP Tailscale của worker đầu tiên)
#    CHART_COMMIT=<sha>         (mặc định = commit trong golden.lock của 3 cụm k3d)
#    GOLDEN_LOCK=/đường/dẫn/golden.lock   (nếu có: so mã băm chart, bắt lệch phiên bản)
#    RELEASE=owdev NS=openwhisk TIMEOUT=900
# =====================================================================
set -Eeuo pipefail
trap 'echo "❌ Dừng ở dòng $LINENO (lệnh: $BASH_COMMAND)" >&2' ERR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

RELEASE="${RELEASE:-owdev}"; NS="${NS:-openwhisk}"; TIMEOUT="${TIMEOUT:-900}"
CHART_REPO="${CHART_REPO:-https://github.com/apache/openwhisk-deploy-kube.git}"
CHART_COMMIT="${CHART_COMMIT:-146d24925564e2871f4cc6506d4e92098968457d}"
SRC_DIR="${SRC_DIR:-$ROOT_DIR/openwhisk-deploy-kube}"
CHART_DIR="$SRC_DIR/helm/openwhisk"
VALUES="$SCRIPT_DIR/custom-values.yaml"
GOLDEN_LOCK="${GOLDEN_LOCK:-}"
PY_KINDS="${PY_KINDS:-python:3}"

# --- Ngân sách RAM (Mi) tối ưu cho cụm 8GB (Master 4GB + 2 Worker 2GB) ---
# Tổng Request ~ 2304Mi -> Đảm bảo K8s xếp lịch được toàn bộ pod mà không kẹt Pending.
# Tổng Limit   ~ 4352Mi -> Ngăn pod ăn lẹm vào RAM của hệ điều hành và K3s.
CONTROLLER_LIMIT=1280; CONTROLLER_REQUEST=768;  CONTROLLER_CPU=500m
INVOKER_LIMIT=1024;    INVOKER_REQUEST=512;     INVOKER_CPU=500m
KAFKA_LIMIT=1024;      KAFKA_REQUEST=512;       KAFKA_CPU=400m;  KAFKA_HEAP="-Xms512m -Xmx512m"
COUCHDB_LIMIT=640;     COUCHDB_REQUEST=384;     COUCHDB_CPU=250m
ZOOKEEPER_LIMIT=384;   ZOOKEEPER_REQUEST=128;   ZOOKEEPER_CPU=100m; ZOOKEEPER_HEAP="-Xms128m -Xmx256m"

log "1/7 Kiểm tra môi trường & mở khóa Master node..."
for c in kubectl git python3 curl sha256sum; do need_cmd "$c"; done
if ! command -v helm >/dev/null 2>&1; then
  log "Cài helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
fi
kubectl get nodes >/dev/null 2>&1 || die "kubectl không nối được cụm (~/.kube/config từ script 02?)"

# Gỡ taint NoSchedule trên master và gắn nhãn để master 4GB cùng gánh pod với 2 worker 2GB
MASTER_NODE=$(kubectl get nodes --selector='node-role.kubernetes.io/master' -o name 2>/dev/null | head -n 1)
[ -z "$MASTER_NODE" ] && MASTER_NODE=$(kubectl get nodes --selector='node-role.kubernetes.io/control-plane' -o name 2>/dev/null | head -n 1)
if [ -n "$MASTER_NODE" ]; then
  kubectl taint nodes "$MASTER_NODE" node-role.kubernetes.io/master:NoSchedule- 2>/dev/null || true
  kubectl taint nodes "$MASTER_NODE" node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true
  kubectl label "$MASTER_NODE" openwhisk-role=invoker --overwrite >/dev/null 2>&1 || true
  ok "Đã mở khóa $MASTER_NODE để chia sẻ tải RAM"
fi

[ "$(kubectl get nodes -l openwhisk-role=invoker --no-headers | wc -l)" -ge 1 ] \
  || die "Chưa có node nào mang nhãn openwhisk-role=invoker (worker join bằng script 03?)"
kubectl get storageclass | grep -q '(default)' || die "Không có StorageClass mặc định"
API_HOST="${API_HOST:-$(ow_api_host)}"
[ -n "$API_HOST" ] || die "Không xác định được API_HOST"
case "$API_HOST" in 100.*) ok "API host (IP Tailscale): $API_HOST" ;;
  *) warn "API_HOST=$API_HOST không phải IP Tailscale (100.x). Gateway ngoài tailnet sẽ không gọi tới được." ;; esac

log "2/7 Chart ghim commit ${CHART_COMMIT:0:12}..."
if [ ! -d "$SRC_DIR/.git" ]; then git clone -q "$CHART_REPO" "$SRC_DIR"; fi
if [ "$(git -C "$SRC_DIR" rev-parse HEAD)" != "$CHART_COMMIT" ]; then
  git -C "$SRC_DIR" fetch -q origin || true
  git -C "$SRC_DIR" checkout -q "$CHART_COMMIT"
fi
chart_hash() { ( cd "$CHART_DIR" && find . -type f -not -path './.git/*' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1 ); }
if [ -n "$GOLDEN_LOCK" ] && [ -f "$GOLDEN_LOCK" ]; then
  [ "$(chart_hash)" = "$(grep '^CHART_SHA256=' "$GOLDEN_LOCK" | cut -d= -f2)" ] \
    && ok "Chart khớp golden.lock" || die "Chart KHÁC golden.lock của 3 cụm k3d -> kết quả so sánh sẽ không công bằng"
else
  warn "Không có GOLDEN_LOCK: chỉ đối chiếu theo commit. (Đặt GOLDEN_LOCK=.../golden.lock để so mã băm)"
fi

log "3/7 Kiểm tra render Helm..."
RENDER="$(helm template "$RELEASE" "$CHART_DIR" -n "$NS" -f "$VALUES" --set whisk.ingress.apiHostName="$API_HOST" 2>&1)" \
  || { echo "$RENDER" | tail -20; die "helm template lỗi"; }
for k in 600000 3072m ef725a6; do
  grep -q -- "$k" <<< "$RENDER" && ok "Render có '$k'" || warn "KHÔNG thấy '$k' trong bản render -> khóa values có thể không được chart nhận"
done

log "4/7 helm upgrade --install..."
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm upgrade --install "$RELEASE" "$CHART_DIR" -n "$NS" -f "$VALUES" --set whisk.ingress.apiHostName="$API_HOST"
ok "helm xong"

log "5/7 Khóa trần RAM pod..."
cap() {  # cap <tên> <limitMi> <requestMi> <cpuReq> [KEY=VALUE ...]
  local name="$1" lim="$2" req="$3" cpu="$4"; shift 4
  local obj
  obj="$(kubectl -n "$NS" get sts,deploy -o name | grep -E "/${RELEASE}-${name}$" | head -n1 || true)"
  [ -n "$obj" ] || { warn "không thấy ${RELEASE}-${name}"; return 0; }
  kubectl -n "$NS" set resources "$obj" --limits="memory=${lim}Mi" --requests="memory=${req}Mi,cpu=${cpu}" >/dev/null
  if [ "$#" -gt 0 ]; then kubectl -n "$NS" set env "$obj" "$@" >/dev/null; fi
  ok "$obj  limit=${lim}Mi request=${req}Mi cpu=${cpu}"
}
cap controller "$CONTROLLER_LIMIT" "$CONTROLLER_REQUEST" "$CONTROLLER_CPU"
cap invoker    "$INVOKER_LIMIT"    "$INVOKER_REQUEST"    "$INVOKER_CPU"
cap kafka      "$KAFKA_LIMIT"      "$KAFKA_REQUEST"      "$KAFKA_CPU"     "KAFKA_HEAP_OPTS=$KAFKA_HEAP"
cap couchdb    "$COUCHDB_LIMIT"    "$COUCHDB_REQUEST"    "$COUCHDB_CPU"
cap zookeeper  "$ZOOKEEPER_LIMIT"  "$ZOOKEEPER_REQUEST"  "$ZOOKEEPER_CPU" "JVMFLAGS=$ZOOKEEPER_HEAP"

log "6/7 Chờ pod sẵn sàng (tối đa ${TIMEOUT}s)..."
deadline=$(( $(date +%s) + TIMEOUT )); LAST=""; READY=0
while :; do
  STUCK="$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk '$3=="Unknown"||$3=="Init:Unknown"||$3=="NodeLost"{print $1}' || true)"
  [ -z "$STUCK" ] || echo "$STUCK" | xargs -r kubectl -n "$NS" delete pod --force --grace-period=0 >/dev/null 2>&1 || true
  BAD="$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk '
      $1 ~ /install-packages|preload-python/ {next}
      $3=="Completed" || $3=="Succeeded" {next}
      $3=="Running" { split($2,a,"/"); if (a[1]==a[2]) next }
      {print $1" ("$3" "$2")"}' || true)"
  NPODS="$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | wc -l)"
  if [ -z "$BAD" ] && [ "$NPODS" -gt 0 ]; then ok "Mọi pod đã Running/Completed"; READY=1; break; fi
  NOW="$(printf '%s' "$BAD" | grep -c . || true) pod chưa xong"
  [ "$NOW" = "$LAST" ] || { echo "   $(date +%T)  $NOW"; LAST="$NOW"; }
  if [ "$(date +%s)" -ge "$deadline" ]; then warn "Hết giờ chờ:"; echo "$BAD" | sed 's/^/     /'; break; fi
  sleep 10
done
kubectl -n "$NS" get pods -o wide | awk 'NR==1 || /invoker|controller|couchdb|kafka|nginx/'
INV_NODES="$(kubectl -n "$NS" get pods -l name="${RELEASE}-invoker" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l)"
[ "$INV_NODES" -ge 2 ] && ok "Các invoker đã phân bổ trên $INV_NODES node khác nhau" || warn "Các invoker đang dồn trên $INV_NODES node (kiểm tra nhãn/affinity)"

log "7/7 Tải sẵn image Python runtime vào các node (tránh cold-start 20 giây đầu)..."
PYIMG="$(python3 - "$CHART_DIR/runtimes.json" "$PY_KINDS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); want = set(sys.argv[2].split(",")); seen = []
for fam in d.get("runtimes", {}).values():
    for r in fam:
        if r.get("kind") in want:
            i = r["image"]; n = i["name"] + ":" + i.get("tag", "latest")
            img = (i["prefix"] + "/" + n) if i.get("prefix") else n
            if img not in seen: seen.append(img)
print("\n".join(seen))
PY
)"
for IMG in $PYIMG; do
  kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: preload-python-runtime}
spec:
  selector: {matchLabels: {app: preload-python-runtime}}
  template:
    metadata: {labels: {app: preload-python-runtime}}
    spec:
      nodeSelector: {openwhisk-role: invoker}
      terminationGracePeriodSeconds: 0
      containers:
      - name: pull
        image: ${IMG}
        imagePullPolicy: IfNotPresent
        command: ["sleep", "600"]
        resources: {requests: {memory: 16Mi, cpu: 5m}}
EOF
  if kubectl -n "$NS" rollout status ds/preload-python-runtime --timeout=600s >/dev/null; then ok "Đã có $IMG trên mọi node"; else warn "Không tải được $IMG (Docker Hub rate limit?)"; fi
  kubectl -n "$NS" delete ds preload-python-runtime --ignore-not-found >/dev/null
done

CODE="000"
for _ in $(seq 1 18); do
  CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${API_HOST}:31001/" || true)"
  [ "$CODE" = "200" ] && break; sleep 10
done
[ "$CODE" = "200" ] && ok "API trả lời: https://${API_HOST}:31001/" || warn "API chưa trả HTTP 200 (mã $CODE). Xem: kubectl -n $NS get pods"

echo "============================================================"
[ "$READY" -eq 1 ] && ok "OPENWHISK ĐÃ SẴN SÀNG TRÊN K3S" || warn "Cài xong nhưng còn pod chưa sẵn sàng"
echo "👉 Bước tiếp: GATEWAY_URL=http://100.74.202.23:8080 DASHBOARD_URL=http://100.74.202.23:9000 CLUSTER_NAME=c1 ./actions/deploy-actions.sh"
echo "============================================================"