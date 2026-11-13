#!/bin/bash
# =====================================================================
#  install-golden.sh - ÁP DỤNG GOLDEN CONFIG CHO CỤM OPENWHISK
#  (chạy SAU KHI đã chạy xong CaiDatOpenWhiskMoi.sh và pod đã Running)
#
#  Làm đúng 5 việc của nhóm trưởng:
#   1. Khóa trần RAM (8 GB)  : jvmHeapMB + userMemory (golden-values.yaml)
#                              + trần RAM từng pod (kubectl set resources, ở script này)
#   2. Nâng giới hạn gọi     : whisk.limits.* (golden-values.yaml)  -> hết lỗi 429
#   3. CouchDB không lưu bền : k8s.persistence.enabled=false (golden-values.yaml)
#   4. Ghim phiên bản        : tag image (golden-values.yaml) + mã băm của chart (golden.lock)
#   5. Tải sẵn image Python  : crictl pull vào các node của cụm
#
#  Cách dùng (chạy trong thư mục golden/, KHÔNG cần sudo):
#     chmod +x install-golden.sh
#     ./install-golden.sh --clean        # LẦN ĐẦU: gỡ bản cũ (kể cả PVC) rồi cài lại theo Golden
#     ./install-golden.sh                # các lần sau: chỉ cập nhật
#     ./install-golden.sh --cap-nodes    # (tùy chọn) khóa luôn trần RAM của node k3d
#     ./install-golden.sh --no-preload   # (tùy chọn) bỏ qua bước tải sẵn image Python
#
#  Biến môi trường (không bắt buộc):
#     API_HOST=100.x.x.x    IP Tailscale (mặc định tự lấy bằng `tailscale ip -4`)
#     SRC_DIR=/duong/dan/openwhisk-deploy-kube   (thư mục chứa helm/openwhisk)
#     CLUSTER=openwhisk-cluster   RELEASE=owdev   NS=openwhisk   TIMEOUT=900
# =====================================================================
set -Eeuo pipefail
trap 'echo "❌ Script dừng ở dòng $LINENO. Xem lại thông báo phía trên." >&2' ERR

# ------------------------- BẢNG TRẦN RAM POD (CỤM <= 8 GB) -------------------------
# Đơn vị Mi. LIMIT = trần cứng (vượt là bị kill). REQUEST = mức xin trước.
# Heap JVM luôn nhỏ hơn LIMIT (còn chỗ cho metaspace, thread, bộ đệm).
# Đây là giá trị KHỞI ĐẦU: phải đo bằng `docker stats` rồi chỉnh, sao cho
# tổng cả cụm <= 8 GB. Chỉnh xong thì cả 3 máy dùng chung bảng này.
# LƯU Ý: trần 8 GB chỉ có nghĩa khi máy ảo (VM) có RAM lớn hơn 8 GB (nên >= 10 GB).
CONTROLLER_LIMIT=1536; CONTROLLER_REQUEST=1024    # JVM heap 896m (golden-values.yaml)
INVOKER_LIMIT=1024;    INVOKER_REQUEST=768        # JVM heap 512m (golden-values.yaml) - MỖI invoker
KAFKA_LIMIT=1024;      KAFKA_REQUEST=768;    KAFKA_HEAP="-Xms512m -Xmx512m"
COUCHDB_LIMIT=768;     COUCHDB_REQUEST=512
ZOOKEEPER_LIMIT=384;   ZOOKEEPER_REQUEST=256; ZOOKEEPER_HEAP="-Xms128m -Xmx256m"   # phụ, đi kèm Kafka
# Trần RAM node k3d (dùng với --cap-nodes cho cụm đã tạo sẵn): 1536 + 2x3328 = 8192 MB = 8 GB
NODE_SERVER_MEM="1536m"; NODE_AGENT_MEM="3328m"
# Lưu ý: userMemory (2048m/invoker) chỉ là TRẦN để xếp chỗ cho action, RAM thật dùng ít hơn nhiều.
# ---------------------------------------------------------------------------------------

RELEASE="${RELEASE:-owdev}"
NS="${NS:-openwhisk}"
CLUSTER="${CLUSTER:-openwhisk-cluster}"
TIMEOUT="${TIMEOUT:-900}"
PY_KINDS="${PY_KINDS:-python:3}"          # kind của action (wsk ... --kind python:3)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES="$HERE/golden-values.yaml"
LOCK="$HERE/golden.lock"
GOLDEN_ROOT="$(cd "$HERE/.." && pwd)"
SRC_DIR="${SRC_DIR:-$GOLDEN_ROOT/openwhisk-deploy-kube}"
[ -d "$SRC_DIR" ] && SRC_DIR="$(cd "$SRC_DIR" && pwd)"
CHART_DIR="$SRC_DIR/helm/openwhisk"

CLEAN=0; PRELOAD=1; CAP_NODES=0
for a in "$@"; do
  case "$a" in
    --clean) CLEAN=1 ;;
    --no-preload) PRELOAD=0 ;;
    --cap-nodes) CAP_NODES=1 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "❌ Tham số lạ: $a"; exit 2 ;;
  esac
done

echo "🚀 BẮT ĐẦU ÁP DỤNG GOLDEN CONFIG CHO OPENWHISK..."

# ---------------------------------------------------------------------
echo "🔎 1/6: Kiểm tra môi trường..."
for cmd in kubectl helm python3 curl docker sha256sum; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "❌ Lỗi: Thiếu lệnh '$cmd'. Hãy chạy CaiDatOpenWhiskMoi.sh trước!"; exit 1
  fi
done
[ -f "$VALUES" ] || { echo "❌ Không thấy $VALUES (golden-values.yaml phải nằm cạnh script này)"; exit 1; }
if ! kubectl get nodes &> /dev/null; then
  echo "❌ Lỗi: kubectl không nối được cụm. Cụm k3d đã chạy chưa? (docker ps | grep k3d)"; exit 1
fi
echo "✅ kubectl nối được cụm: $(kubectl config current-context)"

VM_MB="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
echo "ℹ️  RAM của máy (VM): ${VM_MB} MB"
if [ "$VM_MB" -lt 9500 ]; then
  echo "⚠️  Trần RAM cụm là 8 GB nhưng máy chỉ có ${VM_MB} MB -> nâng trần trong script KHÔNG tạo thêm RAM thật."
  echo "    Hãy tắt VM, tăng RAM lên >= 10 GB (VirtualBox > Settings > System > Base Memory) để cụm không bị Unknown."
fi
NOTREADY_NODES="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{print $1" ("$2")"}' || true)"
if [ -n "$NOTREADY_NODES" ]; then
  echo "⚠️  Có node chưa Ready: $NOTREADY_NODES"
fi

API_HOST="${API_HOST:-}"
if [ -z "$API_HOST" ] && command -v tailscale &> /dev/null; then
  API_HOST="$(tailscale ip -4 2>/dev/null | head -1 || true)"
fi
if [ -z "$API_HOST" ]; then
  echo "❌ Lỗi: Không lấy được IP Tailscale. Chạy 'sudo tailscale up' hoặc: API_HOST=100.x.x.x bash \"$HERE/install-golden.sh\""; exit 1
fi
echo "✅ IP Tailscale của máy này: $API_HOST"

if [ "$(kubectl get nodes -l openwhisk-role=invoker --no-headers 2>/dev/null | wc -l)" -eq 0 ]; then
  echo "⚠️  Chưa có node nào mang nhãn openwhisk-role=invoker -> invoker sẽ không lên."
  echo "    Gắn nhãn: kubectl label nodes --all openwhisk-role=invoker"
fi

# ---------------------------------------------------------------------
echo "📌 2/6: Ghim phiên bản chart (golden.lock)..."
if [ ! -d "$CHART_DIR" ]; then
  echo "❌ Không thấy chart tại $CHART_DIR"
  echo "   Hãy chạy CaiDatOpenWhiskMoi.sh trước, hoặc chỉ đường dẫn: SRC_DIR=/duong/dan/openwhisk-deploy-kube bash \"$HERE/install-golden.sh\""
  exit 1
fi
# Mã băm = dấu vân tay của toàn bộ thư mục chart. 3 máy cùng mã băm nghĩa là chart giống hệt nhau.
chart_hash() { ( cd "$CHART_DIR" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1 ); }
CHART_VER="$(grep '^version:' "$CHART_DIR/Chart.yaml" | awk '{print $2}' || true)"
CUR_HASH="$(chart_hash)"
if [ -f "$LOCK" ]; then
  LOCK_HASH="$(grep '^CHART_SHA256=' "$LOCK" | cut -d= -f2 || true)"
  [ -n "$LOCK_HASH" ] || { echo "❌ golden.lock hỏng (thiếu CHART_SHA256). Xóa file này nếu đây là máy gốc."; exit 1; }
  if [ "$CUR_HASH" != "$LOCK_HASH" ]; then
    echo "❌ Chart trên máy này KHÁC chart của máy gốc (golden.lock)."
    echo "   Máy gốc : ${LOCK_HASH:0:16}...  ($(grep '^CHART_VERSION=' "$LOCK" | cut -d= -f2))"
    echo "   Máy này : ${CUR_HASH:0:16}...  ($CHART_VER)"
    echo "   Cách xử lý: xin máy gốc nén thư mục openwhisk-deploy-kube gửi sang, giải nén đè lên thư mục cũ, rồi chạy lại."
    exit 1
  fi
  echo "✅ Chart khớp golden.lock (${CUR_HASH:0:16}..., version $CHART_VER)"
else
  printf 'CHART_VERSION=%s\nCHART_SHA256=%s\n' "$CHART_VER" "$CUR_HASH" > "$LOCK"
  echo "✅ Đã tạo golden.lock: chart version $CHART_VER, mã băm ${CUR_HASH:0:16}..."
  echo "👉 Đây là máy GỐC. Nhớ gửi kèm file golden.lock cho 2 bạn còn lại!"
fi

# ---------------------------------------------------------------------
echo "🧪 3/6: Kiểm tra golden-values.yaml có được chart nhận không (helm template)..."
RENDER="$(helm template "$RELEASE" "$CHART_DIR" -n "$NS" -f "$VALUES" \
          --set whisk.ingress.apiHostName="$API_HOST" 2>&1)" || { echo "$RENDER" | tail -20; echo "❌ helm template lỗi, kiểm tra golden-values.yaml"; exit 1; }
chk() {
  if echo "$RENDER" | grep -q -- "$1"; then echo "✅ $2"
  else echo "⚠️  KHÔNG thấy '$1' trong bản render -> $2 có thể chưa có hiệu lực"; fi
}
chk '600000'  "giới hạn gọi/phút đã nâng (hết 429)"
chk '2048m'   "userMemory 2048m"
chk 'ef725a6' "tag image đã ghim"
if echo "$RENDER" | grep -q 'kind: PersistentVolumeClaim'; then
  echo "⚠️  Bản render vẫn còn PersistentVolumeClaim -> k8s.persistence.enabled=false chưa ăn"
else
  echo "✅ Không còn PersistentVolumeClaim (CouchDB không lưu bền)"
fi

# ---------------------------------------------------------------------
echo "🐍 4/6: Tải sẵn image Python vào các node..."
preload_image() {
  local img="$1" nodes n
  nodes="$(kubectl get nodes -l openwhisk-role=invoker -o name 2>/dev/null | sed 's#node/##')"
  [ -n "$nodes" ] || nodes="$(kubectl get nodes -o name | sed 's#node/##')"
  for n in $nodes; do
    if docker ps --format '{{.Names}}' | grep -qx "$n"; then
      if docker exec "$n" crictl pull "$img" > /dev/null 2>&1; then echo "✅ $n: đã có $img"
      else echo "⚠️  $n: không tải được $img (kiểm tra mạng / giới hạn Docker Hub)"; fi
    elif command -v crictl &> /dev/null; then
      if sudo crictl pull "$img" > /dev/null 2>&1; then echo "✅ $n: đã có $img"; else echo "⚠️  $n: crictl pull lỗi"; fi
    else
      echo "⚠️  $n: không phải container k3d và không có crictl -> bỏ qua"
    fi
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
  if [ -z "$IMAGES" ]; then echo "⚠️  Không tìm thấy kind '$PY_KINDS' trong runtimes.json"; fi
  for img in $IMAGES; do preload_image "$img"; done
else
  echo "⏭  Bỏ qua tải sẵn image Python (--no-preload)"
fi

# ---------------------------------------------------------------------
if [ "$CLEAN" -eq 1 ]; then
  echo "🧹 --clean: Gỡ bản OpenWhisk cũ và xóa PVC (bản cũ đang bật lưu bền nên phải gỡ sạch)..."
  helm -n "$NS" uninstall "$RELEASE" 2>/dev/null || echo "   (không có release '$RELEASE' để gỡ)"
  kubectl -n "$NS" delete pvc --all --ignore-not-found > /dev/null 2>&1 || true
  kubectl -n "$NS" wait --for=delete pod --all --timeout=180s > /dev/null 2>&1 || true
  echo "✅ Đã dọn sạch namespace $NS"
fi

echo "🔥 5/6: Triển khai OpenWhisk theo Golden Config (helm upgrade --install)..."
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - > /dev/null
if ! helm upgrade --install "$RELEASE" "$CHART_DIR" -n "$NS" \
      -f "$VALUES" --set whisk.ingress.apiHostName="$API_HOST"; then
  echo "❌ helm lỗi. Nếu thông báo có 'StatefulSet ... forbidden' hoặc 'volumeClaimTemplates'"
  echo "   thì do đổi persistence trên bản đã cài. Chạy lại:  bash \"$HERE/install-golden.sh\" --clean"
  exit 1
fi
echo "✅ helm xong"

# ---------------------------------------------------------------------
echo "🧱 6/6: Khóa trần RAM, chờ pod sẵn sàng và kiểm tra nhanh..."
cap() {  # cap <tên> <limitMi> <requestMi> [KEY=VALUE ...]
  local name="$1" lim="$2" req="$3"; shift 3
  local obj
  obj="$(kubectl -n "$NS" get sts,deploy -o name | grep -E "/${RELEASE}-${name}$" | head -1 || true)"
  if [ -z "$obj" ]; then echo "⚠️  không thấy ${RELEASE}-${name}"; return 0; fi
  kubectl -n "$NS" set resources "$obj" \
    --limits=memory="${lim}Mi" --requests=memory="${req}Mi" > /dev/null
  if [ "$#" -gt 0 ]; then kubectl -n "$NS" set env "$obj" "$@" > /dev/null; fi
  echo "✅ $obj  limit=${lim}Mi  request=${req}Mi"
}
cap controller "$CONTROLLER_LIMIT" "$CONTROLLER_REQUEST"
cap invoker    "$INVOKER_LIMIT"    "$INVOKER_REQUEST"
cap kafka      "$KAFKA_LIMIT"      "$KAFKA_REQUEST"      "KAFKA_HEAP_OPTS=$KAFKA_HEAP"
cap couchdb    "$COUCHDB_LIMIT"    "$COUCHDB_REQUEST"
cap zookeeper  "$ZOOKEEPER_LIMIT"  "$ZOOKEEPER_REQUEST"  "JVMFLAGS=$ZOOKEEPER_HEAP"

if [ "$CAP_NODES" -eq 1 ]; then
  echo "🔒 --cap-nodes: Khóa trần RAM node k3d..."
  for n in $(docker ps --format '{{.Names}}' | grep -E "^k3d-${CLUSTER}-(server|agent)-[0-9]+$" || true); do
    case "$n" in *server*) m="$NODE_SERVER_MEM" ;; *) m="$NODE_AGENT_MEM" ;; esac
    docker update --memory "$m" --memory-swap "$m" "$n" > /dev/null && echo "✅ $n -> $m"
  done
fi

echo "⏳ Chờ tất cả pod sẵn sàng (tối đa ${TIMEOUT}s)..."
deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  # Pod kẹt Unknown (thường sau khi VM ngủ/khởi động lại) sẽ không tự hồi phục -> xóa cứng để K8s tạo lại
  STUCK="$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk '$3=="Unknown"||$3=="Init:Unknown"||$3=="NodeLost"{print $1}' || true)"
  if [ -n "$STUCK" ]; then
    echo "🩹 Xóa cứng pod kẹt Unknown: $(echo "$STUCK" | tr '\n' ' ')"
    echo "$STUCK" | xargs -r kubectl -n "$NS" delete pod --force --grace-period=0 > /dev/null 2>&1 || true
  fi
  BAD="$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk '
      $1 ~ /install-packages/ {next}      # job cài gói mẫu: không bắt buộc, không chờ
      $3=="Completed" || $3=="Succeeded" {next}
      $3=="Running" { split($2,a,"/"); if (a[1]==a[2]) next }
      {print $1" ("$3" "$2")"}' || true)"
  if [ -z "$BAD" ]; then echo "✅ Mọi pod đã Running/Completed"; break; fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "⚠️  Hết giờ chờ, pod chưa sẵn sàng:"; echo "$BAD" | sed 's/^/      /'
    echo "   Xem thêm: kubectl -n $NS get pods ; kubectl -n $NS describe pod <tên>"
    break
  fi
  sleep 10
done

echo "   Job install-packages (cài gói mẫu, KHÔNG bắt buộc cho action Python): $(kubectl -n "$NS" get job "${RELEASE}-install-packages" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)/1 hoàn thành"
echo "   Số invoker đang chạy: $(kubectl -n "$NS" get sts "${RELEASE}-invoker" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo '?')"
if curl -sk --max-time 10 "https://${API_HOST}:31001/" | grep -q 'api_paths\|description'; then
  echo "✅ Gateway gọi được https://${API_HOST}:31001/"
else
  echo "⚠️  Chưa gọi được https://${API_HOST}:31001/ (nginx/controller có thể chưa xong, thử lại sau 1-2 phút)"
fi
if kubectl -n "$NS" get pod "${RELEASE}-controller-0" -o yaml 2>/dev/null | grep -A1 'LIMITS_ACTIONS_INVOKES_PERMINUTE' | grep -q 600000; then
  echo "✅ Controller đang chạy với giới hạn 600000 lần/phút (hết 429)"
else
  echo "⚠️  Chưa xác nhận được giới hạn gọi trong env controller (chờ pod khởi động lại rồi chạy test-golden.sh)"
fi

IMG_FILE="$HERE/images-$(hostname).txt"
kubectl -n "$NS" get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sort -u > "$IMG_FILE"
echo "✅ Danh sách image đang chạy: $IMG_FILE"

echo "============================================================"
echo "✅ ÁP DỤNG GOLDEN CONFIG HOÀN TẤT!"
echo "============================================================"
echo "👉 BƯỚC TIẾP THEO BẠN CẦN LÀM:"
echo "1. Tạo action cho Gateway (CouchDB vừa được làm mới nên action cũ đã mất):  bash \"$HERE/deploy-actions.sh\""
echo "2. Chạy bài kiểm tra chứng minh 5 việc:  bash \"$HERE/test-golden.sh\""
echo "3. Đo RAM thật:  docker stats --no-stream   (tổng cụm phải <= 8 GB)"
echo "4. Gửi cho 2 bạn: golden-values.yaml, install-golden.sh, test-golden.sh, golden.lock"
echo "============================================================"
