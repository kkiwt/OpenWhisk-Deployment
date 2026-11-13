#!/bin/bash
# =====================================================================
#  chaos.sh - 5 TÌNH HUỐNG LỖI CHO ĐỒ ÁN OPENWHISK (Bước 3, Mảng C)
#
#  Mỗi tình huống có "start" (gây lỗi) và "stop" (sửa lỗi).
#  Mỗi lần gọi đều ghi một dòng mốc thời gian vào results/chaos.csv
#  để sau này ghép với biểu đồ K6.
#
#  CÁCH DÙNG
#     ./chaos.sh pod       start|stop   [--target c2]   # F1 Chết Pod
#     ./chaos.sh node      start|stop   [--target c2]   # F2 Chết Node
#     ./chaos.sh tailscale start|stop   [--target c3]   # F3 Đứt mạng
#     ./chaos.sh cluster   start|stop   [--target c3]   # F4 Chết cả cụm
#     ./chaos.sh station   start|stop                   # F5 Trạm nhận hàng chết
#
#     ./chaos.sh status        # xem đang có lỗi nào còn bật
#     ./chaos.sh reset         # TẮT HẾT mọi lỗi (chạy khi lỡ thoát giữa chừng)
#     ./chaos.sh list          # in bảng 5 tình huống
#
#  BIẾN TẮT
#     DRY=1 ./chaos.sh pod start      # chỉ in lệnh, KHÔNG thực thi (tập dượt)
#     TARGET=c3 ./chaos.sh pod start  # giống --target c3
#
#  QUAN TRỌNG: thử TỪNG tình huống một lần khi CHƯA có tải,
#  để chắc chắn lệnh chạy đúng, rồi mới chạy cùng K6.
# =====================================================================
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$HERE/chaos.conf"
[ -f "$CONF" ] || { echo "❌ Không thấy $CONF"; exit 2; }
# shellcheck disable=SC1090
source "$CONF"

RESULTS="$HERE/results"
CSV="$RESULTS/chaos.csv"
STATE="$HERE/.chaos-state"      # ghi nhớ lỗi nào đang bật
mkdir -p "$RESULTS" "$STATE"
[ -f "$CSV" ] || echo "timestamp_utc,scenario,phase,target,note" > "$CSV"

DRY="${DRY:-0}"

C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_C='\033[0;36m'; C_N='\033[0m'
say()  { echo -e "${C_C}$*${C_N}"; }
ok()   { echo -e "${C_G}✅ $*${C_N}"; }
warn() { echo -e "${C_Y}⚠️  $*${C_N}"; }
die()  { echo -e "${C_R}❌ $*${C_N}" >&2; exit 1; }

# --- ghi mốc thời gian ----------------------------------------------
log() {   # log <F1..F5> <start|stop> <target> [ghi chú]
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  echo "$ts,$1,$2,${3:--},${4:-}" >> "$CSV"
  echo -e "${C_Y}🕒 $ts  $1 $2  (cụm: ${3:--})${C_N}"
}

# --- chạy lệnh trên một cụm bất kỳ ----------------------------------
# Nếu cụm đó chính là máy này -> chạy thẳng. Nếu không -> chạy qua ssh.
ip_of()  { local v="IP_$1";  echo "${!v:-}"; }
ssh_of() { local v="SSH_$1"; echo "${!v:-}"; }

run_on() {  # run_on <cụm> <lệnh...>
  local c="$1"; shift
  local cmd="$*"
  if [ "$c" = "$ME" ]; then
    if [ "$DRY" = "1" ]; then echo "   [DRY-local] $cmd"; return 0; fi
    echo "   [local] $cmd"
    bash -lc "$cmd"
  else
    local host; host="$(ssh_of "$c")"
    [ -n "$host" ] || die "Chưa khai báo SSH_$c trong chaos.conf"
    if [ "$DRY" = "1" ]; then echo "   [DRY-ssh $host] $cmd"; return 0; fi
    echo "   [ssh $host] $cmd"
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" "$cmd"
  fi
}

run_here() {  # lệnh chạy trên MÁY NÀY (dùng cho F3 - chặn mạng đi ra)
  if [ "$DRY" = "1" ]; then echo "   [DRY-local] $*"; return 0; fi
  echo "   [local] $*"
  bash -lc "$*"
}

mark_on()  { touch "$STATE/$1"; }
mark_off() { rm -f "$STATE/$1"; }
is_on()    { [ -f "$STATE/$1" ]; }

# =====================================================================
#  F1 - CHẾT POD: xóa pod invoker, Kubernetes phải tự dựng lại
# =====================================================================
f_pod() {
  local phase="$1" t="$2"
  case "$phase" in
    start)
      log F1 start "$t" "xoa pod $INVOKER_POD"
      run_on "$t" "kubectl -n $NS delete pod $INVOKER_POD --force --grace-period=0"
      mark_on "F1-$t"
      ok "Đã xóa pod invoker của [$t]. Kubernetes sẽ TỰ dựng lại (không cần stop)."
      say "   Theo dõi: kubectl -n $NS get pod $INVOKER_POD -w"
      ;;
    stop)
      # Không cần sửa gì, chỉ chờ pod Ready rồi ghi mốc kết thúc
      log F1 stop "$t" "cho pod Ready tro lai"
      run_on "$t" "kubectl -n $NS wait --for=condition=Ready pod/$INVOKER_POD --timeout=300s" || \
        warn "Pod chưa Ready sau 300 giây, xem: kubectl -n $NS describe pod $INVOKER_POD"
      mark_off "F1-$t"
      ok "Pod invoker của [$t] đã trở lại."
      ;;
  esac
}

# =====================================================================
#  F2 - CHẾT NODE: tắt container node "công nhân" (agent) của cụm
# =====================================================================
f_node() {
  local phase="$1" t="$2"
  case "$phase" in
    start)
      log F2 start "$t" "docker stop $AGENT_NODE"
      run_on "$t" "docker stop $AGENT_NODE"
      mark_on "F2-$t"
      ok "Đã tắt node [$AGENT_NODE] của cụm [$t]."
      warn "Nhớ chạy: $HERE/chaos.sh node stop --target $t"
      ;;
    stop)
      log F2 stop "$t" "docker start $AGENT_NODE"
      run_on "$t" "docker start $AGENT_NODE"
      run_on "$t" "kubectl wait --for=condition=Ready node/$AGENT_NODE --timeout=300s" || \
        warn "Node chưa Ready sau 300 giây."
      mark_off "F2-$t"
      ok "Node [$AGENT_NODE] của cụm [$t] đã chạy lại."
      ;;
  esac
}

# =====================================================================
#  F3 - ĐỨT MẠNG TAILSCALE: chặn đường từ MÁY NÀY tới cụm đích
#       (chỉ chặn cổng 31001, KHÔNG chặn SSH nên vẫn sửa được từ xa)
# =====================================================================
f_tailscale() {
  local phase="$1" t="$2"
  local tip; tip="$(ip_of "$t")"
  [ -n "$tip" ] || die "Chưa khai báo IP_$t trong chaos.conf"
  [ "$t" != "$ME" ] || die "F3 dùng để chặn đường tới cụm KHÁC, không phải chính máy này."
  local RULE="OUTPUT -d $tip -p tcp --dport $OW_PORT -j DROP"
  case "$phase" in
    start)
      log F3 start "$t" "iptables DROP toi $tip:$OW_PORT"
      run_here "sudo iptables -I $RULE"
      mark_on "F3-$t"
      ok "Đã chặn đường từ máy này tới [$t] ($tip:$OW_PORT). SSH vẫn thông."
      warn "Nhớ chạy: $HERE/chaos.sh tailscale stop --target $t"
      ;;
    stop)
      run_here "sudo iptables -D $RULE" || warn "Không gỡ được luật (có thể đã gỡ rồi)."
      log F3 stop "$t" "go iptables DROP"
      mark_off "F3-$t"
      ok "Đã gỡ chặn tới [$t]."
      ;;
  esac
}

# =====================================================================
#  F4 - CHẾT CẢ CỤM: tắt toàn bộ container k3d của cụm đích
# =====================================================================
f_cluster() {
  local phase="$1" t="$2"
  case "$phase" in
    start)
      log F4 start "$t" "docker stop toan bo k3d-$K3D_CLUSTER"
      run_on "$t" "docker stop \$(docker ps -q --filter name=k3d-$K3D_CLUSTER)"
      mark_on "F4-$t"
      ok "Đã tắt toàn bộ cụm [$t]."
      warn "Nhớ chạy: $HERE/chaos.sh cluster stop --target $t. Cụm cần vài phút để ổn định lại."
      ;;
    stop)
      run_on "$t" "docker start \$(docker ps -aq --filter name=k3d-$K3D_CLUSTER)"
      log F4 stop "$t" "docker start toan bo k3d-$K3D_CLUSTER"
      mark_off "F4-$t"
      ok "Đã bật lại cụm [$t]."
      warn "CouchDB không lưu bền: nếu pod kẹt, chạy $GOLDEN_DIR/after-reboot.sh trên máy đó."
      ;;
  esac
}

# =====================================================================
#  F5 - TRẠM NHẬN HÀNG CHẾT: trỏ TARGET_URL của publish_result
#       trên CẢ 3 CỤM vào một địa chỉ chết -> Dashboard không nhận được gì
# =====================================================================
f_station() {
  local phase="$1"
  local url
  if [ "$phase" = "start" ]; then url="$BLACKHOLE_URL"; else url="$REAL_DASHBOARD_URL"; fi
  log F5 "$phase" "all" "TARGET_URL=$url"
  local done_any=0
  for c in c1 c2 c3; do
    local wp="$HOME/.wskprops.$c"
    if [ ! -f "$wp" ]; then
      warn "Bỏ qua [$c]: không có $wp (chạy $HERE/setup-wskprops.sh hoặc xin khóa của bạn cùng nhóm)."
      continue
    fi
    if [ "$DRY" = "1" ]; then
      echo "   [DRY] WSK_CONFIG_FILE=$wp wsk -i action update publish_result --param TARGET_URL $url"
    else
      if WSK_CONFIG_FILE="$wp" wsk -i action update publish_result \
            --param MODE dashboard --param TARGET_URL "$url" > /dev/null 2>&1; then
        ok "[$c] TARGET_URL -> $url"
        done_any=1
      else
        warn "[$c] không đổi được (cụm chưa chạy, hoặc chưa có action publish_result -> $HERE/deploy-actions-plus.sh)"
      fi
    fi
  done
  if [ "$phase" = "start" ]; then mark_on "F5"; else mark_off "F5"; fi
  [ "$done_any" = "1" ] || [ "$DRY" = "1" ] || warn "Không cụm nào được đổi. Xem lại ~/.wskprops.c*"
}

# =====================================================================
#  LỆNH PHỤ
# =====================================================================
cmd_status() {
  say "=== TRẠNG THÁI CÁC LỖI ĐANG BẬT ==="
  local n=0
  for f in "$STATE"/*; do
    [ -e "$f" ] || continue
    echo "   🔴 $(basename "$f") đang BẬT"
    n=$((n+1))
  done
  if [ "$n" -eq 0 ]; then ok "Không có lỗi nào đang bật."; fi
  echo
  say "=== LUẬT IPTABLES ĐANG CHẶN CỔNG $OW_PORT ==="
  sudo iptables -S OUTPUT 2>/dev/null | grep -- "--dport $OW_PORT" || echo "   (không có)"
  echo
  say "=== 10 DÒNG CUỐI CỦA chaos.csv ==="
  tail -10 "$CSV" | sed 's/^/   /'
}

cmd_reset() {
  say "🧹 Gỡ HẾT mọi lỗi đang bật..."
  for f in "$STATE"/*; do
    [ -e "$f" ] || continue
    local name tgt; name="$(basename "$f")"
    tgt="${name#*-}"
    if [ "$tgt" = "$name" ]; then tgt="$ME"; fi
    case "$name" in
      F1-*) f_pod       stop "$tgt" || true ;;
      F2-*) f_node      stop "$tgt" || true ;;
      F3-*) f_tailscale stop "$tgt" || true ;;
      F4-*) f_cluster   stop "$tgt" || true ;;
      F5)   f_station   stop        || true ;;
    esac
  done
  # quét thêm luật iptables sót lại
  while read -r rule; do
    [ -n "$rule" ] || continue
    warn "Gỡ luật sót: $rule"
    # shellcheck disable=SC2086
    sudo iptables -D ${rule#-A } || true
  done < <(sudo iptables -S OUTPUT 2>/dev/null | grep -- "--dport $OW_PORT" || true)
  ok "Đã dọn xong. Kiểm tra lại bằng: $HERE/chaos.sh status"
}

cmd_list() {
  cat <<'TXT'
┌──────┬───────────────────────┬──────────────────────────────────────────────┐
│ Mã   │ Tình huống            │ Việc script làm                              │
├──────┼───────────────────────┼──────────────────────────────────────────────┤
│ F1   │ Chết Pod              │ Xóa pod invoker, K8s tự dựng lại             │
│ F2   │ Chết Node             │ docker stop node agent của cụm               │
│ F3   │ Đứt mạng Tailscale    │ iptables DROP tới IP cụm, cổng 31001         │
│ F4   │ Chết cả cụm           │ docker stop mọi container k3d của cụm        │
│ F5   │ Trạm nhận hàng chết   │ TARGET_URL của publish_result -> địa chỉ chết│
└──────┴───────────────────────┴──────────────────────────────────────────────┘
TXT
}

# =====================================================================
#  PHÂN TÍCH THAM SỐ
# =====================================================================
SC="${1:-}"
if [ $# -gt 0 ]; then shift; fi
PHASE=""
if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then PHASE="$1"; shift; fi
TARGET="${TARGET:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    *) die "Tham số lạ: $1" ;;
  esac
done

case "$SC" in
  status) cmd_status; exit 0 ;;
  reset)  cmd_reset;  exit 0 ;;
  list)   cmd_list;   exit 0 ;;
  ""|-h|--help) sed -n '2,32p' "$0"; exit 0 ;;
esac

case "$PHASE" in
  start|stop) : ;;
  *) die "Thiếu start hoặc stop. Ví dụ: $HERE/chaos.sh pod start --target c2" ;;
esac

# cụm mặc định cho từng tình huống
if [ -z "$TARGET" ]; then
  case "$SC" in
    pod|node)        TARGET="$ME" ;;
    tailscale)       TARGET="c3"  ;;
    cluster)         TARGET="c3"  ;;
    station)         TARGET="all" ;;
  esac
fi
if [ "$DRY" = "1" ]; then warn "CHẾ ĐỘ TẬP DƯỢT (DRY=1): chỉ in lệnh, không thực thi."; fi

case "$SC" in
  pod)       f_pod       "$PHASE" "$TARGET" ;;
  node)      f_node      "$PHASE" "$TARGET" ;;
  tailscale) f_tailscale "$PHASE" "$TARGET" ;;
  cluster)   f_cluster   "$PHASE" "$TARGET" ;;
  station)   f_station   "$PHASE" ;;
  *) die "Không biết tình huống '$SC'. Xem: $HERE/chaos.sh list" ;;
esac
