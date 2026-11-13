#!/bin/bash
# =====================================================================
#  test-golden.sh - CHỨNG MINH 5 VIỆC CỦA GOLDEN CONFIG ĐÃ HOÀN THÀNH
#
#   Test 1  Khóa trần RAM         (trần từng pod + tổng RAM cả cụm khi có tải)
#   Test 2  Hết lỗi 429           (300 lần gọi dồn dập, không được có 429)
#   Test 3  CouchDB lưu bền       (có PVC Bound, CouchDB gắn PVC, còn mốc khởi tạo)
#   Test 4  Ghim phiên bản        (mã băm chart khớp golden.lock + tag image, không có :latest)
#   Test 5  Tải sẵn image Python  (image có sẵn trong node + gọi lạnh nhanh)
#   (Test 0 và Test 6 là phụ: gọi được API, tương thích Gateway)
#
#  Cách dùng (chạy trong thư mục golden/, hoặc qua ./test-all.sh):
#     ./test-golden.sh
#     ./test-golden.sh --restart-db                  # thêm Test 3b: tắt/bật CouchDB, action phải còn
#     ./test-golden.sh --compare images-maykhac.txt  # so image với máy khác
#     DEBUG=1 ./test-golden.sh                       # in chi tiết từng lần gọi API
#
#  Kết quả được lưu vào:  golden-report-<tên-máy>.txt   (dán vào báo cáo)
#  Nhật ký gọi API:       golden-debug-<tên-máy>.txt    (xem khi có test lỗi)
#
#  Biến môi trường (không bắt buộc):
#     RAM_CAP_MIB=8192   trần tổng RAM cả cụm (8 GiB = 8192 MiB)
#     N=300 P=10         số lần gọi và số luồng song song ở Test 2
#     COLD_MAX=20        số giây tối đa cho lần gọi lạnh đầu tiên ở Test 5
#     AUTH=user:pass     tài khoản OpenWhisk (mặc định tự đọc từ secret của cụm)
#     RESTART_DB=1       giống --restart-db
# =====================================================================
set -uo pipefail

RELEASE="${RELEASE:-owdev}"; NS="${NS:-openwhisk}"
RAM_CAP_MIB="${RAM_CAP_MIB:-8192}"
N="${N:-300}"; P="${P:-10}"; COLD_MAX="${COLD_MAX:-20}"
DEBUG="${DEBUG:-0}"
RESTART_DB="${RESTART_DB:-0}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOLDEN_ROOT="$(cd "$HERE/.." && pwd)"
SRC_DIR="${SRC_DIR:-$GOLDEN_ROOT/openwhisk-deploy-kube}"
[ -d "$SRC_DIR" ] && SRC_DIR="$(cd "$SRC_DIR" && pwd)"
CHART_DIR="$SRC_DIR/helm/openwhisk"
LOCK="$HERE/golden.lock"
HOST="$(hostname)"
REPORT="$HERE/golden-report-$HOST.txt"
IMG_FILE="$HERE/images-$HOST.txt"
DBG="$HERE/golden-debug-$HOST.txt"; : > "$DBG"

COMPARE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --compare) COMPARE="${2:-}"; shift
               [ -f "$COMPARE" ] || { echo "❌ Không thấy file $COMPARE"; exit 2; } ;;
    --restart-db) RESTART_DB=1 ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "❌ Tham số lạ: $1"; exit 2 ;;
  esac
  shift
done

exec > >(tee "$REPORT") 2>&1

# --- khung kết quả -------------------------------------------------------
declare -A VERDICT
TFAIL=0; CUR=""
begin() { CUR="$1"; TFAIL=0; echo; echo "📋 $2"; }
good()  { echo "  ✅ $*"; }
bad()   { echo "  ❌ $*"; TFAIL=1; }
note()  { echo "  ℹ️  $*"; }
end()   { if [ "$TFAIL" -eq 0 ]; then VERDICT[$CUR]="ĐẠT"; else VERDICT[$CUR]="KHÔNG ĐẠT"; fi; }

find_obj() { kubectl -n "$NS" get sts,deploy -o name 2>/dev/null | grep -E "/${RELEASE}-$1$" | head -1 || true; }

live_images() {
  kubectl -n "$NS" get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null | sort -u
}

mem_total_mib() {   # tổng RAM các container k3d (MiB)
  docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' 2>/dev/null | grep '^k3d-' | python3 -c '
import sys, re
t = 0.0
f = {"B": 1/1048576, "kB": 1/1024, "KiB": 1/1024, "MiB": 1, "MB": 0.9537, "GiB": 1024, "GB": 953.7}
for l in sys.stdin:
    m = re.search(r"([\d.]+)\s*(KiB|MiB|GiB|kB|MB|GB|B)\s*/", l)
    if m: t += float(m.group(1)) * f[m.group(2)]
print(int(t))'
}

couch_dbs() {   # in danh sách CSDL trong CouchDB
  local u p
  u="$(kubectl -n "$NS" get secret "${RELEASE}-db.auth" -o jsonpath='{.data.db_username}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  p="$(kubectl -n "$NS" get secret "${RELEASE}-db.auth" -o jsonpath='{.data.db_password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  kubectl -n "$NS" exec "deploy/${RELEASE}-couchdb" -- curl -s -u "${u:-whisk_admin}:${p:-some_passw0rd}" http://127.0.0.1:5984/_all_dbs 2>/dev/null || true
}

curl_msg() {
  case "$1" in
    0)  echo "thành công" ;;
    6)  echo "không phân giải được tên máy" ;;
    7)  echo "kết nối bị TỪ CHỐI: cổng 31001 chưa mở hoặc nginx chưa chạy" ;;
    28) echo "HẾT GIỜ, không có phản hồi: sai IP, Tailscale chưa thông, hoặc bị chặn" ;;
    35|60) echo "lỗi TLS/SSL" ;;
    52) echo "máy chủ đóng kết nối mà không trả lời" ;;
    56) echo "kết nối bị ngắt giữa chừng" ;;
    *)  echo "mã lỗi curl $1 (xem: man curl, mục EXIT CODES)" ;;
  esac
}
# ow METHOD URL [BODY]  ->  đặt OW_CODE, OW_RC, OW_TIME, OW_BODY, OW_ERR
ow() {
  local method="$1" url="$2" data="${3-}" out
  local args=()
  if [ -n "$data" ]; then args=(-H 'Content-Type: application/json' -d "$data"); fi
  out="$(curl -sS -k --max-time "${OW_TIMEOUT:-90}" -u "$AUTH" -X "$method" "${args[@]}" \
        -o "/tmp/ow_body.$$" -w '%{http_code} %{time_total}' "$url" 2>"/tmp/ow_err.$$")"; OW_RC=$?
  OW_CODE="${out%% *}"; OW_TIME="${out##* }"
  OW_BODY="$(head -c 500 "/tmp/ow_body.$$" 2>/dev/null)"; OW_ERR="$(cat "/tmp/ow_err.$$" 2>/dev/null)"
  {
    echo "--- $(date +%T) $method $url"
    echo "    HTTP=$OW_CODE curl_exit=$OW_RC time=${OW_TIME}s"
    if [ -n "$OW_ERR" ];  then echo "    stderr: $OW_ERR"; fi
    if [ -n "$OW_BODY" ]; then echo "    body: $OW_BODY"; fi
  } >> "$DBG"
  if [ "$DEBUG" = "1" ]; then tail -5 "$DBG" | sed 's/^/        [debug] /'; fi
  rm -f "/tmp/ow_body.$$" "/tmp/ow_err.$$"
  return 0
}
why() {  # in lý do thất bại của lần ow() gần nhất
  echo "     HTTP=$OW_CODE, curl_exit=$OW_RC -> $(curl_msg "$OW_RC")"
  if [ -n "$OW_ERR" ];  then echo "     stderr: $OW_ERR"; fi
  if [ -n "$OW_BODY" ]; then echo "     body  : ${OW_BODY:0:300}"; fi
}

echo "🚀 BẮT ĐẦU KIỂM TRA GOLDEN CONFIG - máy: $HOST - $(date '+%F %T')"

# --- kiểm tra môi trường -------------------------------------------------
for c in kubectl docker curl python3 sha256sum; do
  command -v "$c" &> /dev/null || { echo "❌ Thiếu lệnh '$c'"; exit 2; }
done
kubectl get nodes &> /dev/null || { echo "❌ kubectl không nối được cụm"; exit 2; }
API_HOST="${API_HOST:-$(tailscale ip -4 2>/dev/null | head -1)}"
[ -n "$API_HOST" ] || { echo "❌ Không lấy được IP Tailscale (đặt API_HOST=100.x.x.x)"; exit 2; }
BASE="https://$API_HOST:31001/api/v1/namespaces/_/actions"

# Tài khoản: ưu tiên biến AUTH, sau đó đọc guest/system auth từ secret của cụm.
AUTH_SRC="biến AUTH"
if [ -z "${AUTH:-}" ]; then
  for k in guest system; do   # thử khóa guest trước, không có thì dùng khóa system
    AUTH="$(kubectl -n "$NS" get secret "${RELEASE}-whisk.auth" -o jsonpath="{.data.$k}" 2>/dev/null | base64 -d 2>/dev/null || true)"
    [ -n "$AUTH" ] && break
  done
  AUTH_SRC="secret ${RELEASE}-whisk.auth"
  if [ -z "$AUTH" ]; then
    echo "❌ Không đọc được auth từ secret ${RELEASE}-whisk.auth. Đặt AUTH=user:key hoặc sửa secret trước khi chạy test." >&2
    exit 2
  fi
fi
echo "ℹ️  API: https://$API_HOST:31001  |  Release: $RELEASE/$NS  |  Tài khoản lấy từ: $AUTH_SRC"

# =========================================================================
# TEST 0 - KẾT NỐI (phụ)
# =========================================================================
begin 0 "TEST 0: Kết nối tới OpenWhisk API"
NOTREADY=""
for _ in $(seq 1 12); do   # chờ tối đa ~2 phút cho pod ổn định
  NOTREADY="$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk '$1 ~ /install-packages/{next} $3=="Completed"||$3=="Succeeded"{next} $3=="Running"{split($2,a,"/"); if(a[1]==a[2]) next} {print $1" ("$3" "$2")"}' || true)"
  [ -z "$NOTREADY" ] && break; sleep 10
done
if [ -z "$NOTREADY" ]; then good "Mọi pod OpenWhisk đã sẵn sàng"
else
  bad "Pod chưa sẵn sàng:"; echo "$NOTREADY" | sed 's/^/     /'
  if echo "$NOTREADY" | grep -q 'Unknown'; then
    note "Có pod kẹt Unknown. Dọn bằng: kubectl -n $NS get pods --no-headers | awk '\$3==\"Unknown\"||\$3==\"Init:Unknown\"{print \$1}' | xargs -r kubectl -n $NS delete pod --force --grace-period=0"
  fi
fi
note "Job install-packages (cài gói mẫu, không bắt buộc cho action Python): $(kubectl -n "$NS" get job "${RELEASE}-install-packages" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)/1 hoàn thành - bỏ qua trong kiểm tra pod"
ow GET "https://$API_HOST:31001/"
if [ "$OW_CODE" = "200" ]; then good "Gọi được https://$API_HOST:31001/ (HTTP 200, ${OW_TIME}s)"
else
  bad "KHÔNG gọi được https://$API_HOST:31001/"; why
  echo "  🔧 Chẩn đoán:"
  echo "     Dịch vụ nginx:"; kubectl -n "$NS" get svc "${RELEASE}-nginx" 2>&1 | sed 's/^/        /'
  echo "     Cổng 31001 trên máy này:"; (ss -ltn 2>/dev/null | grep -E ':31001\b' || echo "(không có tiến trình nào nghe cổng 31001)") | sed 's/^/        /'
  echo "     Container k3d và cổng:"; docker ps --format '{{.Names}}  {{.Ports}}' 2>/dev/null | grep k3d | sed 's/^/        /'
  echo "     Thử lại bằng 127.0.0.1:"
  ow GET "https://127.0.0.1:31001/"
  if [ "$OW_CODE" = "200" ]; then
    note "127.0.0.1:31001 chạy được => cụm ổn, vấn đề nằm ở IP Tailscale $API_HOST"
    note "Kiểm tra: tailscale status ; tailscale ip -4  (Gateway máy khác sẽ KHÔNG gọi được cho tới khi sửa)"
    note "Các test bên dưới sẽ chạy qua 127.0.0.1"
    API_HOST="127.0.0.1"; BASE="https://$API_HOST:31001/api/v1/namespaces/_/actions"
  else why; fi
fi
end

# =========================================================================
# TEST 4 - GHIM PHIÊN BẢN
# =========================================================================
begin 4 "TEST 4: Ghim phiên bản chart và image"
if [ -f "$LOCK" ] && [ -d "$CHART_DIR" ]; then
  LHASH="$(grep '^CHART_SHA256=' "$LOCK" | cut -d= -f2 || true)"
  CHASH="$( cd "$CHART_DIR" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1 )"
  note "golden.lock: $(tr '\n' ' ' < "$LOCK")"
  if [ -n "$LHASH" ] && [ "$LHASH" = "$CHASH" ]; then good "Mã băm chart đang dùng trùng golden.lock (${CHASH:0:16}...)"
  else bad "Mã băm chart (${CHASH:0:16}...) KHÁC golden.lock (${LHASH:0:16}...)"; fi
elif [ ! -f "$LOCK" ]; then
  bad "Không thấy golden.lock (chạy CaiDatOpenWhiskMoi.sh trước)"
else
  bad "Không thấy thư mục chart: $CHART_DIR"
fi
live_images > "$IMG_FILE"
note "Đã lưu danh sách image đang chạy: $IMG_FILE"
UNPINNED="$(grep -E ':latest$|^[^:]+$|^[^:]*/[^:/]+$' "$IMG_FILE" || true)"
if [ -z "$UNPINNED" ]; then good "Không có image dùng :latest hoặc thiếu tag"
else bad "Image chưa ghim tag:"; echo "$UNPINNED" | sed 's/^/        /'; fi
REQUIRED="openwhisk/controller:ef725a6 openwhisk/invoker:ef725a6 openwhisk/ow-utils:ef725a6 zookeeper:3.4 wurstmeister/kafka:2.12-2.3.1 apache/couchdb:2.3 nginx:1.21.1"
OPTIONAL="openwhisk/apigateway:1.0.0 redis:4.0"
for i in $REQUIRED; do
  if grep -qE "(^|/)${i//./\\.}$" "$IMG_FILE"; then good "$i"; else bad "Thiếu hoặc sai tag: $i"; fi
done
for i in $OPTIONAL; do
  if grep -qE "(^|/)${i//./\\.}$" "$IMG_FILE"; then good "$i"; else note "Không thấy $i (không bắt buộc)"; fi
done
note "Số invoker đang chạy: $(kubectl -n "$NS" get sts "${RELEASE}-invoker" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo '?') (3 máy phải bằng nhau)"
end

# =========================================================================
# TEST 3 - COUCHDB LƯU BỀN
# =========================================================================
begin 3 "TEST 3: CouchDB lưu bền (PersistentVolumeClaim)"
PVCS="$(kubectl -n "$NS" get pvc --no-headers 2>/dev/null || true)"
NPVC="$(printf '%s' "$PVCS" | grep -c . || true)"
NBOUND="$(printf '%s\n' "$PVCS" | awk '$2=="Bound"' | grep -c . || true)"
if [ "$NPVC" -eq 0 ]; then
  bad "Namespace $NS KHÔNG có PVC nào -> k8s.persistence.enabled=true chưa có hiệu lực"
elif [ "$NBOUND" -eq "$NPVC" ]; then
  good "Có $NPVC PVC, tất cả đều Bound"
else
  bad "Chỉ $NBOUND/$NPVC PVC Bound (PVC Pending = thiếu StorageClass hoặc pod chưa lên)"
fi
[ -n "$PVCS" ] && printf '%s\n' "$PVCS" | awk '{printf "        %-40s %-8s %s\n", $1, $2, $6}'
CDB="$(find_obj couchdb)"
if [ -n "$CDB" ]; then
  CLAIM="$(kubectl -n "$NS" get "$CDB" -o jsonpath='{.spec.template.spec.volumes[*].persistentVolumeClaim.claimName}')"
  if [ -n "$CLAIM" ]; then
    good "$CDB gắn PVC: $CLAIM"
    note "StorageClass: $(kubectl -n "$NS" get pvc "$CLAIM" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo '?')"
  else
    bad "$CDB KHÔNG gắn PVC (dùng emptyDir -> mất dữ liệu khi pod khởi động lại)"
  fi
else bad "Không thấy ${RELEASE}-couchdb"; fi
ALLDBS="$(couch_dbs)"
if echo "$ALLDBS" | grep -q 'ow_kube_couchdb_initialized_marker'; then
  good "CouchDB có mốc khởi tạo ow_kube_couchdb_initialized_marker"
else
  bad "Không thấy mốc khởi tạo trong CouchDB (danh sách: ${ALLDBS:-<không đọc được>})"
fi
[ "$RESTART_DB" = "1" ] || note "Muốn chứng minh thật sự (tắt/bật CouchDB, action vẫn còn): bash \"$HERE/test-golden.sh\" --restart-db"
end

# =========================================================================
# TEST 5 - TẢI SẴN IMAGE PYTHON  (chạy TRƯỚC Test 2 để lần gọi còn "lạnh")
# =========================================================================
begin 5 "TEST 5: Tải sẵn image Python"
PYIMG="$(python3 - "$CHART_DIR/runtimes.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for fam in d.get("runtimes", {}).values():
    for r in fam:
        if r.get("kind") == "python:3":
            i = r["image"]
            n = i["name"] + ":" + i.get("tag", "latest")
            print((i["prefix"] + "/" + n) if i.get("prefix") else n)
PY
)"
if [ -z "$PYIMG" ]; then bad "Không đọc được image python:3 từ $CHART_DIR/runtimes.json"
else
  note "Image runtime của python:3 = $PYIMG"
  NAME="${PYIMG%%:*}"; TAG="${PYIMG##*:}"
  NODES="$(kubectl get nodes -l openwhisk-role=invoker -o name 2>/dev/null | sed 's#node/##')"
  [ -n "$NODES" ] || NODES="$(kubectl get nodes -o name | sed 's#node/##')"
  for n in $NODES; do
    if docker exec "$n" crictl images 2>/dev/null | grep -F "$NAME" | grep -qF "$TAG"; then good "Node $n đã có image Python"
    else bad "Node $n CHƯA có image Python"; fi
  done
fi
COLD_OK=0
for TRY in 1 2 3; do
  COLD="golden-cold-$RANDOM"
  ow PUT "$BASE/$COLD?overwrite=true" '{"exec":{"kind":"python:3","code":"def main(args):\n    return {\"status\":\"ok\"}"}}'
  if [ "$OW_CODE" != "200" ]; then bad "Không tạo được action thử:"; why; break; fi
  ow POST "$BASE/$COLD?blocking=true&result=true" '{}'
  C_CODE="$OW_CODE"; C_TIME="$OW_TIME"
  ow DELETE "$BASE/$COLD"
  if [ "$C_CODE" = "200" ] && python3 -c "import sys; sys.exit(0 if float('$C_TIME') <= $COLD_MAX else 1)"; then
    good "Gọi lạnh action mới (lần thử $TRY): ${C_TIME}s (<= ${COLD_MAX}s, HTTP 200)"; COLD_OK=1; break
  fi
  note "Lần thử $TRY: HTTP $C_CODE, ${C_TIME}s (202 = hệ thống nhận nhưng chưa xong kịp; có thể còn đang khởi động) - thử lại sau 5 giây"
  sleep 5
done
if [ "$COLD_OK" -eq 0 ] && [ "$TFAIL" -eq 0 ]; then
  bad "Cả 3 lần gọi lạnh đều không đạt (HTTP 200 trong ${COLD_MAX}s). Xem $DBG"
fi
end

# =========================================================================
# TEST 2 - HẾT 429   (đồng thời lấy mẫu RAM lúc có tải cho Test 1)
# =========================================================================
begin 2 "TEST 2: Không còn lỗi 429 khi gọi dồn dập ($N lần, $P luồng)"
ow PUT "$BASE/golden-ping?overwrite=true" '{"exec":{"kind":"python:3","code":"def main(args):\n    return {\"status\":\"ok\"}"}}'
if [ "$OW_CODE" != "200" ]; then bad "Không tạo được action thử:"; why; fi
ow POST "$BASE/golden-ping?blocking=true&result=true" '{}'
if [ "$OW_CODE" = "200" ]; then good "Gọi thử 1 lần trước khi bắn tải: HTTP 200 (${OW_TIME}s)"
else bad "Gọi thử 1 lần trước khi bắn tải thất bại:"; why; fi
TMP="$(mktemp)"
( seq 1 "$N" | xargs -P "$P" -I __N__ curl -sS -k -o /dev/null -w '%{http_code}\n' --max-time 90 -u "$AUTH" -H 'Content-Type: application/json' \
    -X POST "$BASE/golden-ping?blocking=true&result=true" -d '{}' > "$TMP" 2>>"$DBG" ) &
LOADPID=$!
sleep 6
MEM_LOAD="$(mem_total_mib)"
wait "$LOADPID"
echo "  Phân bố mã trả về:"; sort "$TMP" | uniq -c | sed 's/^/        /'
C202="$(grep -c '^202$' "$TMP" || true)"
C429="$(grep -c '^429$' "$TMP" || true)"; C200="$(grep -c '^200$' "$TMP" || true)"; C000="$(grep -c '^000$' "$TMP" || true)"
if [ "$C202" -gt 0 ]; then note "$C202 lần HTTP 202 = hệ thống đã nhận nhưng chưa xong kịp (khởi động lạnh container), KHÔNG phải lỗi giới hạn"; fi
if [ "$C429" -eq 0 ]; then good "0 lỗi 429"; else bad "Có $C429 lỗi 429 -> giới hạn gọi chưa được nâng"; fi
if [ "$C000" -gt 0 ]; then bad "$C000 lần KHÔNG KẾT NỐI ĐƯỢC (HTTP 000) - xem Test 0 và file $DBG"; fi
if [ "$C200" -ge $(( N * 9 / 10 )) ]; then good "$C200/$N lần thành công (HTTP 200)"
else bad "Chỉ $C200/$N lần thành công"; fi
rm -f "$TMP"
ow DELETE "$BASE/golden-ping"
end

# =========================================================================
# TEST 1 - KHÓA TRẦN RAM
# =========================================================================
begin 1 "TEST 1: Khóa trần RAM"
for c in controller invoker kafka couchdb; do
  o="$(find_obj "$c")"
  if [ -z "$o" ]; then bad "Không thấy ${RELEASE}-$c"; continue; fi
  lim="$(kubectl -n "$NS" get "$o" -o jsonpath='{.spec.template.spec.containers[*].resources.limits.memory}')"
  if [ -n "$lim" ]; then good "$o có trần RAM = $lim"; else bad "$o CHƯA có trần RAM"; fi
done
MEM_IDLE="$(mem_total_mib)"; MEM_LOAD="${MEM_LOAD:-0}"
MEM_MAX="$(( MEM_LOAD > MEM_IDLE ? MEM_LOAD : MEM_IDLE ))"
note "Tổng RAM các container k3d: lúc có tải = ${MEM_LOAD} MiB, hiện tại = ${MEM_IDLE} MiB"
if [ "$MEM_MAX" -eq 0 ]; then bad "Không đo được RAM (docker stats không thấy container k3d-*)"
elif [ "$MEM_MAX" -le "$RAM_CAP_MIB" ]; then good "Đỉnh ${MEM_MAX} MiB <= trần ${RAM_CAP_MIB} MiB ($(python3 -c "print(round($MEM_MAX/1024,2))") GiB)"
else bad "Đỉnh ${MEM_MAX} MiB > trần ${RAM_CAP_MIB} MiB -> hạ bảng trần ở đầu CaiDatOpenWhiskMoi.sh rồi chạy lại với --redeploy"; fi
note "Chi tiết từng container: docker stats --no-stream | grep k3d-"
end

# =========================================================================
# TEST 6 (phụ) - TƯƠNG THÍCH GATEWAY CỦA TV1
# Gateway gọi bằng khóa GUEST, header Authorization: Basic, namespace "_", action "ping"
# =========================================================================
begin 6 "TEST 6 (phụ): Tương thích Gateway (khóa guest, action ping)"
GAUTH="$(kubectl -n "$NS" get secret "${RELEASE}-whisk.auth" -o jsonpath='{.data.guest}' 2>/dev/null | base64 -d 2>/dev/null || true)"
if [ -z "$GAUTH" ]; then note "Không đọc được khóa guest từ secret, bỏ qua Test 6"
else
  GB64="$(printf '%s' "$GAUTH" | base64 -w0)"
  gw_call() {  # gw_call <giây tối đa>  -> đặt GCODE, GTIME, GRC, GBODY
    local out
    out="$(curl -sk --max-time "$1" -o /tmp/gw_body.$$ -w '%{http_code} %{time_total}' \
          -H "Authorization: Basic $GB64" -H 'Content-Type: application/json' \
          -X POST "$BASE/ping?blocking=true&result=true" -d '{}' 2>>"$DBG")"; GRC=$?
    GCODE="${out%% *}"; GTIME="${out##* }"
    GBODY="$(head -c 120 /tmp/gw_body.$$ 2>/dev/null)"; rm -f /tmp/gw_body.$$
    echo "--- $(date +%T) Test 6 ping (max $1s): HTTP=$GCODE curl_exit=$GRC time=${GTIME}s body=$GBODY" >> "$DBG"
  }
  # Lần 1 = khởi động: action ping có thể đang "lạnh" (nhất là ngay sau đợt tải của Test 2),
  # Gateway thật ping liên tục nên luôn nóng -> cho tối đa 60 giây, thử lại 3 lần.
  for TRY in 1 2 3; do
    gw_call 60
    note "Lần $TRY khởi động (tối đa 60s): HTTP ${GCODE:-000}, ${GTIME}s, $(curl_msg "$GRC") ${GBODY}"
    [ "$GCODE" = "200" ] || [ "$GCODE" = "404" ] || [ "$GCODE" = "401" ] && break
    sleep 5
  done
  if [ "$GCODE" = "404" ]; then bad "HTTP 404: chưa có action ping trong namespace guest -> chạy bash \"$HERE/deploy-actions.sh\""
  elif [ "$GCODE" = "401" ]; then bad "HTTP 401: khóa guest bị từ chối"
  elif [ "$GCODE" != "200" ]; then bad "Không gọi được ping sau 3 lần (HTTP ${GCODE:-000}). Xem $DBG"
  else
    # Lần 2 = đúng như Gateway: timeout 2 giây
    gw_call 2
    note "Gọi giống Gateway (timeout 2s): HTTP ${GCODE:-000}, ${GTIME}s"
    if [ "$GCODE" = "200" ]; then good "Gateway sẽ gọi được cụm này (action ping trong namespace guest, < 2s)"
    else bad "Action đã nóng nhưng vẫn không trả lời trong 2s ($(curl_msg "$GRC")) -> Gateway sẽ ngắt nhầm cụm này"; fi
  fi
fi
end

# =========================================================================
# TEST 3b (tùy chọn --restart-db) - TẮT/BẬT COUCHDB, ACTION PHẢI CÒN
# Chạy cuối cùng vì CouchDB tạm ngừng ~1 phút, không làm ảnh hưởng các test khác.
# =========================================================================
if [ "$RESTART_DB" = "1" ]; then
  begin 3b "TEST 3b: Tắt/bật lại CouchDB, action đã tạo phải còn"
  CDB="$(find_obj couchdb)"
  PERSIST="golden-persist-$RANDOM"
  ow PUT "$BASE/$PERSIST?overwrite=true" '{"exec":{"kind":"python:3","code":"def main(args):\n    return {\"status\":\"ok\"}"}}'
  if [ "$OW_CODE" != "200" ] || [ -z "$CDB" ]; then bad "Không tạo được action $PERSIST hoặc không thấy CouchDB"; why
  else
    good "Đã tạo action $PERSIST"
    kubectl -n "$NS" scale "$CDB" --replicas=0 > /dev/null
    kubectl -n "$NS" wait --for=delete pod -l "name=${RELEASE}-couchdb" --timeout=120s > /dev/null 2>&1 || sleep 20
    note "Đã tắt CouchDB (replicas=0), bật lại..."
    kubectl -n "$NS" scale "$CDB" --replicas=1 > /dev/null
    if kubectl -n "$NS" rollout status "$CDB" --timeout=300s > /dev/null 2>&1; then good "CouchDB đã chạy lại"
    else bad "CouchDB chưa chạy lại sau 300s"; fi
    FOUND=0
    for _ in $(seq 1 24); do   # controller cần vài giây để nối lại CouchDB
      ow GET "$BASE/$PERSIST"
      [ "$OW_CODE" = "200" ] && { FOUND=1; break; }
      sleep 5
    done
    if [ "$FOUND" -eq 1 ]; then good "Action $PERSIST VẪN CÒN sau khi CouchDB khởi động lại -> lưu bền hoạt động"
    else bad "Không đọc lại được action $PERSIST sau khi CouchDB khởi động lại"; why; fi
    if couch_dbs | grep -q 'ow_kube_couchdb_initialized_marker'; then good "Mốc khởi tạo vẫn còn"
    else bad "Mất mốc khởi tạo sau khi CouchDB khởi động lại"; fi
    ow DELETE "$BASE/$PERSIST"
  fi
  end
  [ "${VERDICT[3b]}" = "ĐẠT" ] || VERDICT[3]="KHÔNG ĐẠT"
fi

# =========================================================================
# SO SÁNH VỚI MÁY KHÁC (không bắt buộc)
# =========================================================================
if [ -n "$COMPARE" ]; then
  echo; echo "🔁 SO SÁNH image với $COMPARE (bỏ qua image action động)"
  if diff <(grep -v '/action-' "$IMG_FILE" | sort) <(grep -v '/action-' "$COMPARE" | sort); then
    echo "  ✅ Hai máy chạy CÙNG danh sách image"
  else
    echo "  ❌ Có khác biệt (dòng < là máy này, > là máy kia)"; VERDICT[4]="KHÔNG ĐẠT"
  fi
fi

# =========================================================================
echo; echo "============================================================"
echo "📊 TỔNG KẾT ($HOST)"
echo "============================================================"
names=( [1]="Khóa trần RAM" [2]="Hết lỗi 429" [3]="CouchDB lưu bền" [4]="Ghim phiên bản" [5]="Tải sẵn image Python" )
ALLOK=1
printf '  (phụ)   %-26s %s\n' "Kết nối API" "${VERDICT[0]:-bỏ qua}"
printf '  (phụ)   %-26s %s\n' "Tương thích Gateway" "${VERDICT[6]:-bỏ qua}"
for i in 1 2 3 4 5; do
  printf '  Việc %s  %-26s %s\n' "$i" "${names[$i]}" "${VERDICT[$i]:-chưa chạy}"
  [ "${VERDICT[$i]:-}" = "ĐẠT" ] || ALLOK=0
done
[ "$RESTART_DB" = "1" ] && printf '          %-26s %s\n' "(3b) tắt/bật CouchDB" "${VERDICT[3b]:-chưa chạy}"
echo "  Báo cáo lưu tại: $REPORT"
echo "  Nhật ký gọi API: $DBG"
echo "============================================================"
if [ "$ALLOK" -eq 1 ]; then echo "✅ CẢ 5 VIỆC ĐẠT!"; exit 0
else echo "⚠️  CÒN VIỆC KHÔNG ĐẠT - xem các dòng ❌ phía trên"; exit 1; fi
