```bash
#!/usr/bin/env bash
# =====================================================================
# install-openwhisk.sh - Cài đặt OpenWhisk trên cụm K3s VPC
#
# Các bước:
#   1. Kiểm tra môi trường và cấu hình node.
#   2. Tải và xác minh Helm chart.
#   3. Kiểm tra cấu hình Helm.
#   4. Triển khai OpenWhisk.
#   5. Áp dụng giới hạn CPU/RAM và Probe.
#   6. Áp dụng chính sách tài nguyên và chờ Pod sẵn sàng.
#   7. Tải trước Python runtime và kiểm tra API.
#
# Biến tùy chọn:
#   API_HOST=<private-ip>
#   API_PORT=31001
#   CHART_COMMIT=<sha>
#   GOLDEN_LOCK=/đường/dẫn/golden.lock
#   RELEASE=owdev
#   NS=openwhisk
#   TIMEOUT=900
#   INVOKER_REPLICAS=2
#   PY_KINDS=python:3
#   CLEANUP_STUCK_INSTALL_PACKAGES=1
# =====================================================================

set -Eeuo pipefail

trap 'echo "LỖI: Dừng tại dòng $LINENO (lệnh: $BASH_COMMAND)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/scripts/lib.sh"

# ---------------------------------------------------------------------
# 1. Cấu hình triển khai
# ---------------------------------------------------------------------

RELEASE="${RELEASE:-owdev}"
NS="${NS:-openwhisk}"
TIMEOUT="${TIMEOUT:-900}"

INVOKER_REPLICAS="${INVOKER_REPLICAS:-2}"

CHART_REPO="${CHART_REPO:-https://github.com/apache/openwhisk-deploy-kube.git}"
CHART_COMMIT="${CHART_COMMIT:-146d24925564e2871f4cc6506d4e92098968457d}"

SRC_DIR="${SRC_DIR:-$ROOT_DIR/openwhisk-deploy-kube}"
CHART_DIR="$SRC_DIR/helm/openwhisk"
VALUES="$SCRIPT_DIR/custom-values.yaml"

GOLDEN_LOCK="${GOLDEN_LOCK:-}"

API_PORT="${API_PORT:-31001}"

PY_KINDS="${PY_KINDS:-python:3}"
CLEANUP_STUCK_INSTALL_PACKAGES="${CLEANUP_STUCK_INSTALL_PACKAGES:-1}"

PRELOAD_DS="preload-python-runtime"

CONTROLLER_LIVENESS_INITIAL_DELAY=60
CONTROLLER_LIVENESS_FAILURE_THRESHOLD=12
CONTROLLER_READINESS_INITIAL_DELAY=30

KAFKA_READINESS_TIMEOUT=30
KAFKA_READINESS_PERIOD=15
KAFKA_READINESS_FAILURE_THRESHOLD=12

# ---------------------------------------------------------------------
# 2. Ngân sách tài nguyên
#
# Tuân theo LimitRange:
#   RAM tối đa/container: 2048Mi
#   CPU tối đa/container: 1000m
#
# Tuân theo ResourceQuota:
#   RAM requests: 10Gi
#   RAM limits:   16Gi
#   CPU requests: 8
#   CPU limits:   20
#   Pods:         60
# ---------------------------------------------------------------------

CONTROLLER_LIMIT=1280
CONTROLLER_REQUEST=768
CONTROLLER_CPU_REQUEST=500m
CONTROLLER_CPU_LIMIT=1000m

INVOKER_LIMIT=1024
INVOKER_REQUEST=512
INVOKER_CPU_REQUEST=500m
INVOKER_CPU_LIMIT=1000m

KAFKA_LIMIT=1024
KAFKA_REQUEST=512
KAFKA_CPU_REQUEST=250m
KAFKA_CPU_LIMIT=1000m
KAFKA_HEAP="-Xms512m -Xmx512m"

COUCHDB_LIMIT=640
COUCHDB_REQUEST=384
COUCHDB_CPU_REQUEST=200m
COUCHDB_CPU_LIMIT=1000m

ZOOKEEPER_LIMIT=384
ZOOKEEPER_REQUEST=128
ZOOKEEPER_CPU_REQUEST=100m
ZOOKEEPER_CPU_LIMIT=500m
ZOOKEEPER_HEAP="-Xms128m -Xmx256m"

# ---------------------------------------------------------------------
# 3. Kiểm tra tham số và file cấu hình
# ---------------------------------------------------------------------

[[ "$INVOKER_REPLICAS" =~ ^[1-9][0-9]*$ ]] \
  || die "INVOKER_REPLICAS phải là số nguyên dương"

[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] \
  || die "TIMEOUT phải là số nguyên dương"

[[ "$CLEANUP_STUCK_INSTALL_PACKAGES" == "0" || \
   "$CLEANUP_STUCK_INSTALL_PACKAGES" == "1" ]] \
  || die "CLEANUP_STUCK_INSTALL_PACKAGES chỉ nhận 0 hoặc 1"

[[ "$API_PORT" =~ ^[0-9]+$ ]] \
  || die "API_PORT không hợp lệ"

[[ -f "$VALUES" ]] \
  || die "Không tìm thấy custom-values.yaml: $VALUES"

RESOURCE_POLICY="$ROOT_DIR/k3s-resource-policy.yaml"

[[ -f "$RESOURCE_POLICY" ]] \
  || die "Không tìm thấy k3s-resource-policy.yaml"

# ---------------------------------------------------------------------
# Bước 1: Kiểm tra môi trường và cấu hình node
# ---------------------------------------------------------------------

log "1/7 Kiểm tra môi trường và cấu hình node..."

for c in kubectl git python3 curl sha256sum awk grep sort; do
  need_cmd "$c"
done

if ! command -v helm >/dev/null 2>&1; then
  log "Cài đặt Helm..."

  curl -fsSL \
    https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    | sudo bash
fi

need_cmd helm

kubectl get nodes >/dev/null 2>&1 \
  || die "Không kết nối được Kubernetes"

kubectl get nodes -o wide

# Tìm Server theo nhãn control-plane.
MASTER_NODE="$(
  kubectl get nodes \
    -l node-role.kubernetes.io/control-plane \
    -o name 2>/dev/null | head -n 1
)"

if [ -z "$MASTER_NODE" ]; then
  MASTER_NODE="$(
    kubectl get nodes \
      -l node-role.kubernetes.io/master \
      -o name 2>/dev/null | head -n 1
  )"
fi

# Mở khóa Server để có thể chạy workload.
if [ -n "$MASTER_NODE" ]; then

  kubectl taint nodes "$MASTER_NODE" \
    node-role.kubernetes.io/master:NoSchedule- \
    >/dev/null 2>&1 || true

  kubectl taint nodes "$MASTER_NODE" \
    node-role.kubernetes.io/control-plane:NoSchedule- \
    >/dev/null 2>&1 || true

  kubectl label "$MASTER_NODE" \
    openwhisk-role=invoker \
    --overwrite >/dev/null

  ok "Đã mở khóa $MASTER_NODE để chia sẻ workload"

else
  warn "Không tìm thấy node Server theo nhãn control-plane/master"
fi

INVOKER_NODE_COUNT="$(
  kubectl get nodes \
    -l openwhisk-role=invoker \
    --no-headers | wc -l
)"

[ "$INVOKER_NODE_COUNT" -ge 1 ] \
  || die "Không có node mang nhãn openwhisk-role=invoker"

if [ "$INVOKER_REPLICAS" -gt "$INVOKER_NODE_COUNT" ]; then
  warn "Số Invoker ban đầu lớn hơn số node được gắn nhãn"
fi

ok "Có $INVOKER_NODE_COUNT node được phép chạy Invoker"

# Kiểm tra StorageClass mặc định.
kubectl get storageclass \
  | grep -q '(default)' \
  || die "Không có StorageClass mặc định"

ok "Đã xác nhận StorageClass mặc định"

# Xác định API Host.
API_HOST="${API_HOST:-$(ow_api_host)}"

[ -n "$API_HOST" ] \
  || die "Không xác định được API_HOST"

ok "API Host: $API_HOST"

# ---------------------------------------------------------------------
# Bước 2: Tải và xác minh Helm chart
# ---------------------------------------------------------------------

log "2/7 Kiểm tra Helm chart..."

if [ ! -d "$SRC_DIR/.git" ]; then

  [ ! -e "$SRC_DIR" ] \
    || die "Thư mục chart tồn tại nhưng không phải Git repository"

  git clone "$CHART_REPO" "$SRC_DIR"

fi

CURRENT_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"

if [ "$CURRENT_COMMIT" != "$CHART_COMMIT" ]; then

  git -C "$SRC_DIR" fetch origin \
    || die "Không thể cập nhật Git repository"

  git -C "$SRC_DIR" cat-file -e "${CHART_COMMIT}^{commit}" \
    || die "Không tìm thấy commit $CHART_COMMIT"

  git -C "$SRC_DIR" checkout --detach "$CHART_COMMIT"

fi

ACTUAL_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"

[ "$ACTUAL_COMMIT" = "$CHART_COMMIT" ] \
  || die "Helm chart không khớp commit đã ghim"

[ -f "$CHART_DIR/Chart.yaml" ] \
  || die "Không tìm thấy Chart.yaml"

[ -f "$CHART_DIR/runtimes.json" ] \
  || die "Không tìm thấy runtimes.json"

ok "Chart khớp commit ${CHART_COMMIT:0:12}"

# Tính mã băm Helm chart.
chart_hash() {
  (
    cd "$CHART_DIR"

    find . -type f -print0 \
      | LC_ALL=C sort -z \
      | xargs -0 sha256sum \
      | sha256sum \
      | cut -d' ' -f1
  )
}

if [ -n "$GOLDEN_LOCK" ]; then

  [ -f "$GOLDEN_LOCK" ] \
    || die "Không tìm thấy GOLDEN_LOCK: $GOLDEN_LOCK"

  EXPECTED_HASH="$(
    grep '^CHART_SHA256=' "$GOLDEN_LOCK" \
      | cut -d= -f2
  )"

  [ -n "$EXPECTED_HASH" ] \
    || die "Không tìm thấy CHART_SHA256 trong golden.lock"

  ACTUAL_HASH="$(chart_hash)"

  [ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] \
    || die "Mã băm Helm chart không khớp golden.lock"

  ok "Helm chart khớp golden.lock"

else
  warn "Không sử dụng GOLDEN_LOCK"
fi

# ---------------------------------------------------------------------
# Bước 3: Kiểm tra cấu hình Helm
# ---------------------------------------------------------------------

log "3/7 Kiểm tra cấu hình Helm..."

HELM_SET_ARGS=(
  --set "whisk.ingress.apiHostName=$API_HOST"
  --set "invoker.containerFactory.kubernetes.replicaCount=$INVOKER_REPLICAS"
  --set "invoker.kubernetes.replicaCount=$INVOKER_REPLICAS"
)

if ! RENDER="$(
  helm template "$RELEASE" "$CHART_DIR" \
    -n "$NS" \
    -f "$VALUES" \
    "${HELM_SET_ARGS[@]}" 2>&1
)"; then

  echo "$RENDER" | tail -n 30
  die "Không thể render Helm chart"

fi

for VALUE in 600000 1024m ef725a6; do

  if grep -q -- "$VALUE" <<< "$RENDER"; then
    ok "Bản render có giá trị $VALUE"
  else
    warn "Không tìm thấy $VALUE trong bản render; cần kiểm tra values"
  fi

done

ok "Hoàn thành kiểm tra Helm template"

# ---------------------------------------------------------------------
# Bước 4: Triển khai OpenWhisk
# ---------------------------------------------------------------------

log "4/7 Triển khai OpenWhisk bằng Helm..."

kubectl create namespace "$NS" \
  --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null

helm upgrade --install "$RELEASE" "$CHART_DIR" \
  -n "$NS" \
  -f "$VALUES" \
  "${HELM_SET_ARGS[@]}"

ok "Helm triển khai hoàn tất"

# ---------------------------------------------------------------------
# Bước 5: Áp dụng giới hạn CPU/RAM
# ---------------------------------------------------------------------

log "5/7 Áp dụng giới hạn tài nguyên..."

cap() {

  local name="$1"
  local lim="$2"
  local req="$3"
  local cpu_request="$4"
  local cpu_limit="$5"

  shift 5

  local obj

  obj="$(
    kubectl -n "$NS" get sts,deploy -o name \
      | awk -F/ -v target="${RELEASE}-${name}" \
        '$NF == target {print; exit}'
  )"

  if [ -z "$obj" ]; then
    warn "Không tìm thấy workload ${RELEASE}-${name}"
    return 0
  fi

  kubectl -n "$NS" set resources "$obj" \
    --limits="memory=${lim}Mi,cpu=${cpu_limit}" \
    --requests="memory=${req}Mi,cpu=${cpu_request}" \
    >/dev/null

  if [ "$#" -gt 0 ]; then
    kubectl -n "$NS" set env "$obj" "$@" >/dev/null
  fi

  ok "Đã cấu hình $obj: RAM ${req}/${lim}Mi, CPU ${cpu_request}/${cpu_limit}"

}

cap controller \
  "$CONTROLLER_LIMIT" "$CONTROLLER_REQUEST" \
  "$CONTROLLER_CPU_REQUEST" "$CONTROLLER_CPU_LIMIT"

cap invoker \
  "$INVOKER_LIMIT" "$INVOKER_REQUEST" \
  "$INVOKER_CPU_REQUEST" "$INVOKER_CPU_LIMIT"

cap kafka \
  "$KAFKA_LIMIT" "$KAFKA_REQUEST" \
  "$KAFKA_CPU_REQUEST" "$KAFKA_CPU_LIMIT" \
  "KAFKA_HEAP_OPTS=$KAFKA_HEAP"

cap couchdb \
  "$COUCHDB_LIMIT" "$COUCHDB_REQUEST" \
  "$COUCHDB_CPU_REQUEST" "$COUCHDB_CPU_LIMIT"

cap zookeeper \
  "$ZOOKEEPER_LIMIT" "$ZOOKEEPER_REQUEST" \
  "$ZOOKEEPER_CPU_REQUEST" "$ZOOKEEPER_CPU_LIMIT" \
  "JVMFLAGS=$ZOOKEEPER_HEAP"

# ---------------------------------------------------------------------
# Điều chỉnh Probe
# ---------------------------------------------------------------------

log "5a/7 Điều chỉnh Probe..."

CONTROLLER_STS="${RELEASE}-controller"
KAFKA_STS="${RELEASE}-kafka"

if kubectl -n "$NS" get sts "$CONTROLLER_STS" >/dev/null 2>&1; then

  kubectl -n "$NS" patch "sts/$CONTROLLER_STS" \
    --type=json \
    -p="[
      {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/livenessProbe/initialDelaySeconds\",\"value\":$CONTROLLER_LIVENESS_INITIAL_DELAY},
      {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/livenessProbe/failureThreshold\",\"value\":$CONTROLLER_LIVENESS_FAILURE_THRESHOLD},
      {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/readinessProbe/initialDelaySeconds\",\"value\":$CONTROLLER_READINESS_INITIAL_DELAY}
    ]" >/dev/null

else
  warn "Không tìm thấy Controller StatefulSet để điều chỉnh Probe"
fi

if kubectl -n "$NS" get sts "$KAFKA_STS" >/dev/null 2>&1; then

  kubectl -n "$NS" patch "sts/$KAFKA_STS" \
    --type=json \
    -p="[
      {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/readinessProbe/timeoutSeconds\",\"value\":$KAFKA_READINESS_TIMEOUT},
      {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/readinessProbe/periodSeconds\",\"value\":$KAFKA_READINESS_PERIOD},
      {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/readinessProbe/failureThreshold\",\"value\":$KAFKA_READINESS_FAILURE_THRESHOLD}
    ]" >/dev/null

else
  warn "Không tìm thấy Kafka StatefulSet để điều chỉnh Probe"
fi

ok "Đã xử lý cấu hình Probe"

# ---------------------------------------------------------------------
# Bước 6: Áp dụng LimitRange, ResourceQuota và HPA
# ---------------------------------------------------------------------

log "6/7 Áp dụng chính sách tài nguyên..."

kubectl -n "$NS" apply -f "$RESOURCE_POLICY"

ok "Đã áp dụng LimitRange, ResourceQuota và HPA"

# Kiểm tra HPA.
if kubectl -n "$NS" get hpa "${RELEASE}-invoker-hpa" >/dev/null 2>&1; then

  kubectl -n "$NS" get hpa "${RELEASE}-invoker-hpa"

  ok "Đã cấu hình HPA cho Invoker"

else
  warn "Không tìm thấy HPA ${RELEASE}-invoker-hpa trong resource policy"
fi

# ---------------------------------------------------------------------
# Chờ Pod sẵn sàng.
# Không coi Pod Running nhưng chưa Ready là đã sẵn sàng.
# ---------------------------------------------------------------------

log "Chờ các Pod sẵn sàng..."

deadline=$(( $(date +%s) + TIMEOUT ))
READY=0
LAST_STATUS=""

while :; do

  POD_STATUS="$(
    kubectl -n "$NS" get pods -o json 2>/dev/null \
      | python3 -c '
import json
import sys

data = json.load(sys.stdin)

pending = []
total = 0

for pod in data.get("items", []):
    name = pod["metadata"]["name"]
    phase = pod.get("status", {}).get("phase", "")

    if "install-packages" in name:
        continue

    if name.startswith("preload-python-runtime"):
        continue

    if pod["metadata"].get("deletionTimestamp"):
        continue

    if phase in ("Succeeded",):
        continue

    total += 1

    conditions = pod.get("status", {}).get("conditions", [])
    ready = any(
        c.get("type") == "Ready" and c.get("status") == "True"
        for c in conditions
    )

    if not ready:
        reason = pod.get("status", {}).get("reason", phase)
        pending.append(f"{name} ({reason})")

print(total)
print("\n".join(pending))
'
  )"

  TOTAL="$(head -n 1 <<< "$POD_STATUS")"
  PENDING="$(tail -n +2 <<< "$POD_STATUS")"

  if [ -z "$TOTAL" ]; then
    TOTAL=0
  fi

  if [ "$TOTAL" -gt 0 ] && [ -z "$PENDING" ]; then
    READY=1
    ok "Các Pod chính đã sẵn sàng"
    break
  fi

  if [ "$PENDING" != "$LAST_STATUS" ]; then

    echo "   $(date +%T): Pod chưa sẵn sàng"

    if [ -n "$PENDING" ]; then
      printf '%s\n' "$PENDING"
    fi

    LAST_STATUS="$PENDING"
  fi

  if [ "$(date +%s)" -ge "$deadline" ]; then
    warn "Hết thời gian chờ Pod"
    break
  fi

  sleep 10

done



PACKAGE_JOB="${RELEASE}-install-packages"

PACKAGE_SUCCEEDED="$(
  kubectl -n "$NS" get job "$PACKAGE_JOB" \
    -o jsonpath='{.status.succeeded}' 2>/dev/null || true
)"

if [ "$PACKAGE_SUCCEEDED" = "1" ]; then

  ok "Job $PACKAGE_JOB đã hoàn thành"

elif kubectl -n "$NS" get job "$PACKAGE_JOB" >/dev/null 2>&1; then

  if [ "$CLEANUP_STUCK_INSTALL_PACKAGES" = "1" ]; then

    warn "Job cài package chưa hoàn thành; tiến hành dọn Job tùy chọn"

    kubectl -n "$NS" delete job "$PACKAGE_JOB" \
      --ignore-not-found >/dev/null

    ok "Đã dọn Job tùy chọn"

  else

    warn "Giữ lại Job cài package"

  fi

fi


echo
echo "Trạng thái các thành phần:"

kubectl -n "$NS" get pods -o wide \
  | awk 'NR==1 || /invoker|controller|couchdb|kafka|nginx/'

INV_STS="${RELEASE}-invoker"

INV_DESIRED="$(
  kubectl -n "$NS" get sts "$INV_STS" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0
)"

INV_READY="$(
  kubectl -n "$NS" get sts "$INV_STS" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0
)"

INV_DESIRED="${INV_DESIRED:-0}"
INV_READY="${INV_READY:-0}"

if [ "$INV_READY" -ge 2 ]; then
  ok "Invoker Ready: $INV_READY/$INV_DESIRED"
else
  warn "Invoker chưa đủ 2 replica Ready: $INV_READY/$INV_DESIRED"
  READY=0
fi

INV_NODES="$(
  kubectl -n "$NS" get pods \
    -l name="${RELEASE}-invoker" \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
    2>/dev/null \
    | sort -u \
    | grep -c . || true
)"

if [ "$INV_NODES" -ge 2 ]; then
  ok "Invoker được phân bổ trên $INV_NODES node"
else
  warn "Invoker hiện phân bổ trên $INV_NODES node"
fi

# ---------------------------------------------------------------------
# Bước 7: Tải trước Python runtime
# ---------------------------------------------------------------------

log "7/7 Tải trước Python runtime..."

PYIMG="$(
  python3 - "$CHART_DIR/runtimes.json" "$PY_KINDS" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)

wanted = set(sys.argv[2].split(","))
seen = []

for family in data.get("runtimes", {}).values():
    for runtime in family:
        if runtime.get("kind") not in wanted:
            continue

        image = runtime["image"]
        name = image["name"] + ":" + image.get("tag", "latest")

        full_name = (
            image["prefix"] + "/" + name
            if image.get("prefix")
            else name
        )

        if full_name not in seen:
            seen.append(full_name)

print("\n".join(seen))
PY
)"

# Hàm dọn DaemonSet preload.
cleanup_preload() {
  kubectl -n "$NS" delete ds "$PRELOAD_DS" \
    --ignore-not-found >/dev/null 2>&1 || true
}

trap cleanup_preload EXIT

if [ -z "$PYIMG" ]; then

  warn "Không tìm thấy Python runtime trong runtimes.json"

else

  while IFS= read -r IMG; do

    [ -n "$IMG" ] || continue

    log "Tải trước image: $IMG"

    kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ${PRELOAD_DS}
spec:
  selector:
    matchLabels:
      app: ${PRELOAD_DS}
  template:
    metadata:
      labels:
        app: ${PRELOAD_DS}
    spec:
      nodeSelector:
        openwhisk-role: invoker
      terminationGracePeriodSeconds: 0
      containers:
      - name: pull
        image: ${IMG}
        imagePullPolicy: IfNotPresent
        command: ["sleep", "600"]
        resources:
          requests:
            memory: 16Mi
            cpu: 5m
EOF

    if kubectl -n "$NS" rollout status \
      "ds/$PRELOAD_DS" --timeout=600s >/dev/null; then

      ok "Đã tải image $IMG"

    else

      warn "Không thể tải trước image $IMG"

    fi

    cleanup_preload

  done <<< "$PYIMG"

fi

cleanup_preload
trap - EXIT


log "Kiểm tra API OpenWhisk..."

CODE="000"

for _ in $(seq 1 18); do

  CODE="$(
    curl -sk \
      -o /dev/null \
      -w '%{http_code}' \
      --connect-timeout 5 \
      --max-time 10 \
      "https://${API_HOST}:${API_PORT}/" || true
  )"

  [ "$CODE" = "200" ] && break

  sleep 10

done

if [ "$CODE" = "200" ]; then
  ok "API OpenWhisk trả HTTP 200"
else
  warn "API chưa trả HTTP 200 (mã $CODE)"
fi




if [ "$READY" -eq 1 ] && [ "$CODE" = "200" ]; then
  ok "OPENWHISK ĐÃ SẴN SÀNG TRÊN K3S"
else
    warn "OPENWHISK CHƯA SẴN SÀNG TRÊN K3S"
fi
