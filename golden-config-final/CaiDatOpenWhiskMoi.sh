#!/bin/bash
# =====================================================================
#  CaiDatOpenWhiskMoi.sh - CÀI OPENWHISK + GOLDEN CONFIG TRONG 1 LẦN CHẠY
#  Để ở Desktop, cạnh thư mục golden/ và XoaOpenWhiskDeCaiLai.sh
#
#  Gộp CaiDatOpenWhiskMoi.sh + install-golden.sh + trỏ wsk + deploy-actions.sh:
#    1. Kiểm tra Tailscale, RAM máy ảo, file golden
#    2. Cài công cụ còn thiếu (Docker, kubectl, k3d, helm, wsk)
#    3. Tạo cụm k3d 1 server + 2 agent (khóa trần RAM node, taint server)
#    4. Tải chart + ghim phiên bản (golden.lock)
#    5. Kiểm tra golden-values.yaml bằng helm template
#    6. Tải sẵn image Python vào các node
#    7. helm install MỘT LẦN với golden-values.yaml (lưu bền đã bật sẵn)
#    8. Khóa trần RAM pod, chờ pod sẵn sàng
#    9. Trỏ wsk vào cụm bằng khóa guest
#   10. Tạo action cho Gateway (golden/deploy-actions.sh)
#   11. (tùy chọn --test) chạy golden/test-all.sh
#
#  Cách dùng (KHÔNG chạy bằng sudo, script tự gọi sudo khi cần):
#      ./CaiDatOpenWhiskMoi.sh                  cài từ đầu (xóa cụm k3d cũ nếu có)
#      ./CaiDatOpenWhiskMoi.sh --test           cài xong chạy test luôn
#      ./CaiDatOpenWhiskMoi.sh --redeploy       giữ cụm k3d, chỉ cài/cập nhật OpenWhisk
#      ./CaiDatOpenWhiskMoi.sh --redeploy --clean  giữ cụm k3d, gỡ sạch OpenWhisk (cả PVC) rồi cài lại
#  Tùy chọn thêm: --yes (không hỏi xác nhận)   --no-preload (bỏ tải sẵn image Python)
#
#  Biến môi trường (không bắt buộc):
#      CLUSTER_NAME=c2      tên cụm trong Gateway (c1 / c2 / c3)
#      API_HOST=100.x.x.x   IP Tailscale (mặc định tự lấy bằng tailscale ip -4)
#      SERVER_MEM=1536m AGENT_MEM=3328m NODE_CAP=1 TAINT_SERVER=1 TOLERATE_SECONDS=3600
#      TIMEOUT=900          số giây tối đa chờ pod sẵn sàng
# =====================================================================
set -Eeuo pipefail
trap 'echo "❌ Script dừng ở dòng $LINENO (lệnh: $BASH_COMMAND). Xem thông báo phía trên." >&2' ERR

# ------------------------- CẤU HÌNH CỤM (3 máy dùng chung) -------------------------
SERVER_MEM="${SERVER_MEM:-1536m}"          # trần RAM node server (API server K3s)
AGENT_MEM="${AGENT_MEM:-3328m}"            # trần RAM MỖI node agent (1536 + 2x3328 = 8192 MB = 8 GB)
NODE_CAP="${NODE_CAP:-1}"                  # 1 = khóa trần RAM node k3d | 0 = không khóa
TAINT_SERVER="${TAINT_SERVER:-1}"          # 1 = pod OpenWhisk không chạy trên node server
TOLERATE_SECONDS="${TOLERATE_SECONDS:-3600}"  # VM ngủ ít hơn số giây này thì pod không bị đá ra

# ------------------------- BẢNG TRẦN RAM POD (CỤM <= 8 GB) -------------------------
# Đơn vị Mi. LIMIT = trần cứng (vượt là bị kill). REQUEST = mức xin trước.
# Đã bọc biến môi trường để có thể truyền từ ngoài vào khi gọi script.
CONTROLLER_LIMIT="${CONTROLLER_LIMIT:-1536}"; CONTROLLER_REQUEST="${CONTROLLER_REQUEST:-1024}"
INVOKER_LIMIT="${INVOKER_LIMIT:-1024}";    INVOKER_REQUEST="${INVOKER_REQUEST:-768}"
KAFKA_LIMIT="${KAFKA_LIMIT:-1024}";      KAFKA_REQUEST="${KAFKA_REQUEST:-768}";    KAFKA_HEAP="${KAFKA_HEAP:--Xms512m -Xmx512m}"
COUCHDB_LIMIT="${COUCHDB_LIMIT:-768}";     COUCHDB_REQUEST="${COUCHDB_REQUEST:-512}"
ZOOKEEPER_LIMIT="${ZOOKEEPER_LIMIT:-384}";   ZOOKEEPER_REQUEST="${ZOOKEEPER_REQUEST:-256}"; ZOOKEEPER_HEAP="${ZOOKEEPER_HEAP:--Xms128m -Xmx256m}"
# ---------------------------------------------------------------------------------------

CLUSTER="${CLUSTER:-openwhisk-cluster}"
RELEASE="${RELEASE:-owdev}"
NS="${NS:-openwhisk}"
TIMEOUT="${TIMEOUT:-900}"
CLUSTER_NAME="${CLUSTER_NAME:-c2}"
PY_KINDS="${PY_KINDS:-python:3}"
CHART_REPO="${CHART_REPO:-https://github.com/apache/openwhisk-deploy-kube.git}"

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
cd "$HERE"
GOLDEN="${GOLDEN_DIR:-$HERE/golden}"
VALUES="$GOLDEN/golden-values.yaml"
LOCK="$GOLDEN/golden.lock"
SRC_DIR="${SRC_DIR:-$HERE/openwhisk-deploy-kube}"
CHART_DIR="$SRC_DIR/helm/openwhisk"

REDEPLOY=0; CLEAN=0; RUN_TEST=0; YES=0; PRELOAD=1
for a in "$@"; do
  case "$a" in
    --redeploy)   REDEPLOY=1 ;;
    --clean)      CLEAN=1 ;;
    --test)       RUN_TEST=1 ;;
    --yes|-y)     YES=1 ;;
    --no-preload) PRELOAD=0 ;;
    -h|--help)    awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "❌ Tham số lạ: $a (xem: $0 --help)"; exit 2 ;;
  esac
done
if [ "$CLEAN" -eq 1 ] && [ "$REDEPLOY" -eq 0 ]; then
  echo "ℹ️  --clean chỉ có tác dụng cùng --redeploy (cài từ đầu thì cụm đã mới tinh)."
fi

T0=$(date +%s)
echo "🚀 BẮT ĐẦU CÀI OPENWHISK + GOLDEN CONFIG (chế độ: $([ "$REDEPLOY" -eq 1 ] && echo 'giữ cụm k3d, cài lại OpenWhisk' || echo 'cài từ đầu'))"

# =====================================================================
echo; echo "🔎 1/11: Kiểm tra Tailscale, RAM, file golden..."
if [ "$(id -u)" -eq 0 ]; then
  echo "❌ Đừng chạy bằng sudo. Chạy: ./$(basename "$0")"; exit 1
fi
[ -f "$VALUES" ] || { echo "❌ Không thấy $VALUES. Thư mục golden/ phải nằm cạnh script này."; exit 1; }
[ -f "$GOLDEN/deploy-actions.sh" ] || { echo "❌ Không thấy $GOLDEN/deploy-actions.sh"; exit 1; }
if ! command -v tailscale &> /dev/null; then
  echo "❌ Máy này chưa cài Tailscale. Cài và chạy 'sudo tailscale up' trước!"; exit 1
fi
API_HOST="${API_HOST:-$(tailscale ip -4 2>/dev/null | head -1 || true)}"
[ -n "$API_HOST" ] || { echo "❌ Không lấy được IP Tailscale. Chạy 'sudo tailscale up' rồi thử lại."; exit 1; }
echo "✅ IP Tailscale: $API_HOST"
VM_MB="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
echo "ℹ️  RAM máy ảo: ${VM_MB} MB"
if [ "$NODE_CAP" = "1" ] && [ "$VM_MB" -lt 9500 ]; then
  echo "⚠️  Trần RAM cụm là 8 GB nhưng máy chỉ có ${VM_MB} MB. Nên tắt VM, tăng RAM lên >= 10 GB."
  echo "    Vẫn tiếp tục, nhưng cụm có thể chập chờn (pod Unknown) khi chạy nặng."
fi

# =====================================================================
echo; echo "📦 2/11: Cài công cụ còn thiếu..."
NEED_APT=0
for c in curl git jq python3 ab wget sha256sum; do command -v "$c" &> /dev/null || NEED_APT=1; done
if [ "$NEED_APT" -eq 1 ]; then
  sudo apt-get update -y
  sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common \
        git jq apache2-utils python3 wget coreutils
fi
if ! command -v docker &> /dev/null; then
  TMPD="$(mktemp -d)"
  curl -fsSL https://get.docker.com -o "$TMPD/get-docker.sh"
  sudo sh "$TMPD/get-docker.sh"
  sudo usermod -aG docker "$USER"
  rm -rf "$TMPD"
  echo "⚠️  Vừa cài Docker. Đăng xuất rồi đăng nhập lại (hoặc chạy: newgrp docker), sau đó chạy lại script này."
  exit 1
fi
if ! docker info &> /dev/null; then
  echo "❌ User '$USER' chưa dùng được Docker (thiếu quyền hoặc Docker chưa chạy)."
  echo "   Thử: sudo systemctl start docker ; sudo usermod -aG docker $USER  rồi đăng xuất/đăng nhập lại."
  exit 1
fi
if ! command -v kubectl &> /dev/null; then
  TMPD="$(mktemp -d)"
  curl -fsSL -o "$TMPD/kubectl" "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 "$TMPD/kubectl" /usr/local/bin/kubectl
  rm -rf "$TMPD"
fi
if ! command -v k3d &> /dev/null; then
  curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi
if ! command -v helm &> /dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
if ! command -v wsk &> /dev/null; then
  TMPD="$(mktemp -d)"
  wget -q -O "$TMPD/wsk.tgz" https://github.com/apache/openwhisk-cli/releases/download/1.2.0/OpenWhisk_CLI-1.2.0-linux-amd64.tgz
  tar -xzf "$TMPD/wsk.tgz" -C "$TMPD"
  sudo install -m 0755 "$TMPD/wsk" /usr/local/bin/wsk
  rm -rf "$TMPD"
fi
echo "✅ docker, kubectl, k3d, helm, wsk đã sẵn sàng"

# =====================================================================
echo; echo "🌐 3/11: Cụm Kubernetes k3d..."
cluster_exists() { k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$CLUSTER"; }
if [ "$REDEPLOY" -eq 0 ]; then
  if cluster_exists; then
    if [ "$YES" -ne 1 ]; then
      read -p "⚠️  Cụm k3d '$CLUSTER' đang có. XÓA và tạo lại (mất mọi dữ liệu đã lưu, kể cả action)? (y/n): " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Đã dừng. Muốn giữ cụm và chỉ cài lại OpenWhisk: ./$(basename "$0") --redeploy"; exit 0
      fi
    fi
    k3d cluster delete "$CLUSTER"
  fi
  K3D_ARGS=(--agents 2 -p "31001:31001@server:0")
  K3D_ARGS+=(--k3s-arg "--disable=traefik@server:0")
  K3D_ARGS+=(--k3s-arg "--kube-apiserver-arg=default-not-ready-toleration-seconds=${TOLERATE_SECONDS}@server:0")
  K3D_ARGS+=(--k3s-arg "--kube-apiserver-arg=default-unreachable-toleration-seconds=${TOLERATE_SECONDS}@server:0")
  if [ "$NODE_CAP" = "1" ]; then
    echo "   🔒 Khóa trần RAM node: server=${SERVER_MEM}, mỗi agent=${AGENT_MEM}"
    K3D_ARGS+=(--servers-memory "$SERVER_MEM" --agents-memory "$AGENT_MEM")
  fi
  if [ "$TAINT_SERVER" = "1" ]; then
    echo "   🛡  Node server chỉ chạy điều khiển K3s, pod OpenWhisk chạy trên 2 agent"
    K3D_ARGS+=(--k3s-arg "--node-taint=node-role.kubernetes.io/control-plane:NoSchedule@server:0")
  fi
  k3d cluster create "$CLUSTER" "${K3D_ARGS[@]}"
else
  cluster_exists || { echo "❌ Chưa có cụm k3d '$CLUSTER'. Chạy không kèm --redeploy để tạo mới."; exit 1; }
  docker ps --format '{{.Names}}' | grep -q "^k3d-${CLUSTER}-" || k3d cluster start "$CLUSTER"
  echo "✅ Giữ nguyên cụm k3d '$CLUSTER'"
fi
kubectl config use-context "k3d-${CLUSTER}" > /dev/null

# Chờ đủ 3 node đăng ký rồi mới chờ Ready (agent có thể lên chậm hơn server)
for _ in $(seq 1 60); do
  [ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)" -ge 3 ] && break
  sleep 3
done
kubectl wait --for=condition=Ready nodes --all --timeout=180s > /dev/null
echo "✅ $(kubectl get nodes --no-headers | wc -l) node Ready"

for n in $(kubectl get nodes -o name | sed 's#node/##' | grep -- '-agent-'); do
  kubectl label node "$n" openwhisk-role=invoker --overwrite > /dev/null
done
N_INV="$(kubectl get nodes -l openwhisk-role=invoker --no-headers 2>/dev/null | wc -l)"
[ "$N_INV" -ge 1 ] || { echo "❌ Không gắn được nhãn invoker cho node agent nào"; exit 1; }
echo "✅ $N_INV node mang nhãn openwhisk-role=invoker"

# Lưu bền cần StorageClass mặc định (k3d có sẵn local-path, nhưng lên sau vài giây)
SC=""
for _ in $(seq 1 30); do
  SC="$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1 || true)"
  [ -n "$SC" ] && break
  sleep 3
done
if [ -z "$SC" ]; then
  echo "❌ Cụm không có StorageClass mặc định -> PVC của CouchDB/Kafka sẽ Pending mãi."
  echo "   Kiểm tra: kubectl get storageclass ; kubectl -n kube-system get pods | grep local-path"
  exit 1
fi
echo "✅ StorageClass mặc định: $SC (dùng cho lưu bền)"

# =====================================================================
echo; echo "📌 4/11: Tải chart và ghim phiên bản (golden.lock)..."
if [ ! -d "$CHART_DIR" ]; then
  git clone -q "$CHART_REPO" "$SRC_DIR"
  echo "✅ Đã tải $CHART_REPO"
fi
LOCK_COMMIT="$(grep '^GIT_COMMIT=' "$LOCK" 2>/dev/null | cut -d= -f2 || true)"
if [ -n "$LOCK_COMMIT" ] && [ -d "$SRC_DIR/.git" ]; then
  if [ "$(git -C "$SRC_DIR" rev-parse HEAD)" != "$LOCK_COMMIT" ]; then
    echo "   Chuyển chart về commit đã ghim ${LOCK_COMMIT:0:12}..."
    if ! git -C "$SRC_DIR" checkout -q "$LOCK_COMMIT" 2>/dev/null; then
      git -C "$SRC_DIR" fetch -q origin
      git -C "$SRC_DIR" checkout -q "$LOCK_COMMIT" || {
        echo "❌ Không checkout được commit $LOCK_COMMIT (có sửa tay trong openwhisk-deploy-kube?)"; exit 1; }
    fi
  fi
fi
chart_hash() { ( cd "$CHART_DIR" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1 ); }
CHART_VER="$(grep '^version:' "$CHART_DIR/Chart.yaml" | awk '{print $2}' || true)"
CUR_HASH="$(chart_hash)"
CUR_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || true)"
if [ -f "$LOCK" ]; then
  LOCK_HASH="$(grep '^CHART_SHA256=' "$LOCK" | cut -d= -f2 || true)"
  [ -n "$LOCK_HASH" ] || { echo "❌ golden.lock hỏng (thiếu CHART_SHA256). Xóa file này nếu đây là máy gốc."; exit 1; }
  if [ "$CUR_HASH" != "$LOCK_HASH" ]; then
    echo "❌ Chart trên máy này KHÁC chart của máy gốc (golden.lock)."
    echo "   Máy gốc : ${LOCK_HASH:0:16}...  ($(grep '^CHART_VERSION=' "$LOCK" | cut -d= -f2 || true))"
    echo "   Máy này : ${CUR_HASH:0:16}...  ($CHART_VER, commit ${CUR_COMMIT:0:12})"
    echo "   Cách xử lý: xin máy gốc file golden.lock mới (có dòng GIT_COMMIT) rồi chạy lại,"
    echo "   hoặc xin máy gốc nén thư mục openwhisk-deploy-kube gửi sang."
    exit 1
  fi
  echo "✅ Chart khớp golden.lock (${CUR_HASH:0:16}..., version $CHART_VER)"
  if [ -z "$LOCK_COMMIT" ] && [ -n "$CUR_COMMIT" ]; then
    echo "GIT_COMMIT=$CUR_COMMIT" >> "$LOCK"
    echo "✅ Đã bổ sung GIT_COMMIT=${CUR_COMMIT:0:12} vào golden.lock -> gửi lại file này cho 2 bạn"
  fi
else
  printf 'CHART_VERSION=%s\nCHART_SHA256=%s\nGIT_COMMIT=%s\n' "$CHART_VER" "$CUR_HASH" "$CUR_COMMIT" > "$LOCK"
  echo "✅ Đã tạo golden.lock: version $CHART_VER, mã băm ${CUR_HASH:0:16}..., commit ${CUR_COMMIT:0:12}"
  echo "👉 Đây là máy GỐC. Nhớ gửi file golden/golden.lock cho 2 bạn còn lại!"
fi

# =====================================================================
echo; echo "🧪 5/11: Kiểm tra golden-values.yaml (helm template)..."
RENDER="$(helm template "$RELEASE" "$CHART_DIR" -n "$NS" -f "$VALUES" \
         --set whisk.ingress.apiHostName="$API_HOST" 2>&1)" || {
  echo "$RENDER" | tail -20; echo "❌ helm template lỗi, kiểm tra golden-values.yaml"; exit 1; }
chk() {
  if grep -q -- "$1" <<< "$RENDER"; then echo "✅ $2"
  else echo "⚠️  KHÔNG thấy '$1' trong bản render -> $2 có thể chưa có hiệu lực"; fi
}
chk '600000'  "giới hạn gọi/phút đã nâng (hết 429)"
chk '2048m'   "userMemory 2048m"
chk 'ef725a6' "tag image đã ghim"
N_PVC_RENDER="$(grep -c 'kind: PersistentVolumeClaim' <<< "$RENDER" || true)"
if [ "$N_PVC_RENDER" -ge 1 ]; then
  echo "✅ Bản render có $N_PVC_RENDER PersistentVolumeClaim (CouchDB/Kafka/ZooKeeper/Redis lưu bền)"
else
  echo "⚠️  Bản render KHÔNG có PersistentVolumeClaim -> k8s.persistence.enabled=true chưa ăn"
fi

# =====================================================================
echo; echo "🐍 6/11: Tải sẵn image Python vào các node..."
preload_image() {
  local img="$1" n
  for n in $(kubectl get nodes -l openwhisk-role=invoker -o name | sed 's#node/##'); do
    if docker exec "$n" crictl pull "$img" > /dev/null 2>&1; then echo "✅ $n: đã có $img"
    else echo "⚠️  $n: không tải được $img (kiểm tra mạng / giới hạn Docker Hub)"; fi
  done
}
if [ "$PRELOAD" -eq 1 ]; then
  IMAGES="$(python3 - "$CHART_DIR/runtimes.json" "$PY_KINDS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
want = set(sys.argv[2].split(","))
seen = []
for fam in d.get("runtimes", {}).values():
    for r in fam:
        if r.get("kind") in want:
            i = r["image"]
            name = i["name"] + ":" + i.get("tag", "latest")
            img = (i["prefix"] + "/" + name) if i.get("prefix") else name
            if img not in seen:
                seen.append(img)
print("\n".join(seen))
PY
)"
  [ -n "$IMAGES" ] || echo "⚠️  Không tìm thấy kind '$PY_KINDS' trong runtimes.json"
  for img in $IMAGES; do preload_image "$img"; done
else
  echo "⏭  Bỏ qua (--no-preload)"
fi

# =====================================================================
echo; echo "🔥 7/11: Triển khai OpenWhisk theo Golden Config..."
if [ "$REDEPLOY" -eq 1 ] && [ "$CLEAN" -eq 1 ]; then
  echo "🧹 --clean: gỡ release cũ và xóa PVC (MẤT dữ liệu đã lưu)..."
  helm -n "$NS" uninstall "$RELEASE" 2>/dev/null || echo "   (không có release '$RELEASE' để gỡ)"
  kubectl -n "$NS" delete pvc --all --ignore-not-found > /dev/null 2>&1 || true
  kubectl -n "$NS" wait --for=delete pod --all --timeout=180s > /dev/null 2>&1 || true
  echo "✅ Đã dọn sạch namespace $NS"
fi
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - > /dev/null
if ! helm upgrade --install "$RELEASE" "$CHART_DIR" -n "$NS" \
      -f "$VALUES" --set whisk.ingress.apiHostName="$API_HOST"; then
  echo "❌ helm lỗi. Nếu thông báo có 'StatefulSet ... forbidden' hoặc 'volumeClaimTemplates'"
  echo "   (do đổi persistence trên bản đã cài) thì chạy:  ./$(basename "$0") --redeploy --clean"
  exit 1
fi
echo "✅ helm xong"

# =====================================================================
echo; echo "🧱 8/11: Khóa trần RAM pod và chờ pod sẵn sàng..."
cap() {  # cap <tên> <limitMi> <requestMi> [KEY=VALUE ...]
  local name="$1" lim="$2" req="$3"; shift 3
  local obj
  obj="$(kubectl -n "$NS" get sts,deploy -o name | grep -E "/${RELEASE}-${name}$" | head -1 || true)"
  if [ -z "$obj" ]; then echo "⚠️  không thấy ${RELEASE}-${name}"; return 0; fi
  kubectl -n "$NS" set resources "$obj" --limits=memory="${lim}Mi" --requests=memory="${req}Mi" > /dev/null
  if [ "$#" -gt 0 ]; then kubectl -n "$NS" set env "$obj" "$@" > /dev/null; fi
  echo "✅ $obj  limit=${lim}Mi  request=${req}Mi"
}
cap controller "$CONTROLLER_LIMIT" "$CONTROLLER_REQUEST"
cap invoker    "$INVOKER_LIMIT"    "$INVOKER_REQUEST"
cap kafka      "$KAFKA_LIMIT"      "$KAFKA_REQUEST"      "KAFKA_HEAP_OPTS=$KAFKA_HEAP"
cap couchdb    "$COUCHDB_LIMIT"    "$COUCHDB_REQUEST"
cap zookeeper  "$ZOOKEEPER_LIMIT"  "$ZOOKEEPER_REQUEST"  "JVMFLAGS=$ZOOKEEPER_HEAP"

echo "⏳ Chờ tất cả pod sẵn sàng (tối đa ${TIMEOUT}s, lần đầu thường 10-15 phút)..."
deadline=$(( $(date +%s) + TIMEOUT ))
READY=0; LAST=""
while :; do
  STUCK="$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk '$3=="Unknown"||$3=="Init:Unknown"||$3=="NodeLost"{print $1}' || true)"
  if [ -n "$STUCK" ]; then
    echo "🩹 Xóa cứng pod kẹt Unknown: $(echo "$STUCK" | tr '\n' ' ')"
    echo "$STUCK" | xargs -r kubectl -n "$NS" delete pod --force --grace-period=0 > /dev/null 2>&1 || true
  fi
  BAD="$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk '
      $1 ~ /install-packages/ {next}
      $3=="Completed" || $3=="Succeeded" {next}
      $3=="Running" { split($2,a,"/"); if (a[1]==a[2]) next }
      {print $1" ("$3" "$2")"}' || true)"
  NPODS="$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | wc -l)"
  if [ -z "$BAD" ] && [ "$NPODS" -gt 0 ]; then echo "✅ Mọi pod đã Running/Completed"; READY=1; break; fi
  NOW_STATE="$(echo "$BAD" | wc -l) pod chưa xong"
  if [ "$NOW_STATE" != "$LAST" ]; then echo "   $(date +%T)  $NOW_STATE"; LAST="$NOW_STATE"; fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "⚠️  Hết giờ chờ, pod chưa sẵn sàng:"; echo "$BAD" | sed 's/^/     /'
    echo "   Xem: kubectl -n $NS get pods ; kubectl -n $NS describe pod <tên>"
    break
  fi
  sleep 10
done
echo "   PVC (lưu bền):"
kubectl -n "$NS" get pvc --no-headers 2>/dev/null | awk '{printf "     %-40s %s\n", $1, $2}' || true

# =====================================================================
echo; echo "🔑 9/11: Trỏ wsk vào cụm bằng khóa GUEST..."
for _ in $(seq 1 18); do   # chờ nginx/controller nhận request, tối đa ~3 phút
  CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${API_HOST}:31001/" || true)"
  [ "$CODE" = "200" ] && break
  sleep 10
done
if [ "${CODE:-000}" = "200" ]; then echo "✅ API trả lời: https://${API_HOST}:31001/"
else echo "⚠️  API chưa trả lời HTTP 200 (mã: ${CODE:-000}). Các bước sau có thể lỗi."; fi
GUEST_AUTH="$(kubectl -n "$NS" get secret "${RELEASE}-whisk.auth" -o jsonpath='{.data.guest}' | base64 -d)"
wsk property set --apihost "https://${API_HOST}:31001" --auth "$GUEST_AUTH" > /dev/null
if WSK_NS="$(wsk -i namespace list 2>&1)"; then
  echo "✅ wsk đã trỏ vào cụm, namespace: $(echo "$WSK_NS" | tail -n +2 | head -1)"
else
  echo "⚠️  wsk chưa gọi được cụm: $WSK_NS"
fi

# =====================================================================
echo; echo "🎯 10/11: Tạo action cho Gateway (cụm ${CLUSTER_NAME})..."
if ! CLUSTER_NAME="$CLUSTER_NAME" API_HOST="$API_HOST" RELEASE="$RELEASE" NS="$NS" bash "$GOLDEN/deploy-actions.sh"; then
  echo "⚠️  deploy-actions.sh lỗi. Chạy lại sau 1 phút: bash \"$GOLDEN/deploy-actions.sh\""
fi

# =====================================================================
echo; echo "📝 11/11: Lưu danh sách image..."
IMG_FILE="$GOLDEN/images-$(hostname).txt"
kubectl -n "$NS" get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sort -u > "$IMG_FILE"
echo "✅ $IMG_FILE"

MINS=$(( ( $(date +%s) - T0 ) / 60 ))
echo "============================================================"
if [ "$READY" -eq 1 ]; then echo "✅ CÀI ĐẶT + GOLDEN CONFIG HOÀN TẤT (${MINS} phút)"
else echo "⚠️  CÀI XONG NHƯNG CÒN POD CHƯA SẴN SÀNG (${MINS} phút) - xem cảnh báo phía trên"; fi
echo "============================================================"
echo "   API      : https://${API_HOST}:31001   (wsk đã trỏ sẵn bằng khóa guest)"
echo "   Lưu bền  : BẬT (StorageClass $SC) - action còn nguyên sau khi tắt/mở máy"
if [ "$RUN_TEST" -eq 1 ]; then
  echo "============================================================"
  echo "🧪 --test: chạy golden/test-all.sh ..."
  bash "$GOLDEN/test-all.sh" || true
else
  echo "👉 Bước tiếp theo:  bash \"$GOLDEN/test-all.sh\""
fi
echo "============================================================"
