#!/bin/bash
# =====================================================================
#  check-ready.sh - KIỂM TRA ĐỦ ĐIỀU KIỆN TRƯỚC KHI GÂY LỖI
#
#  Gây lỗi khi hệ thống vốn đã hỏng thì số đo vô nghĩa. Chạy script này
#  trước mỗi buổi đo. Nó KHÔNG sửa gì, chỉ báo cáo.
#
#  CÁCH DÙNG:  ./check-ready.sh
# =====================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/chaos.conf"

PASS=0; FAIL=0
ok()  { echo "  ✅ $*"; PASS=$((PASS+1)); }
no()  { echo "  ❌ $*"; FAIL=$((FAIL+1)); }
inf() { echo "  ℹ️  $*"; }

echo "🔍 KIỂM TRA ĐIỀU KIỆN - máy này là cụm [$ME] - $(date '+%F %T')"

echo
echo "📋 1. Công cụ"
for c in kubectl docker wsk curl tailscale python3 iptables; do
  if command -v "$c" &>/dev/null; then ok "có $c"; else no "thiếu $c"; fi
done

echo
echo "📋 2. Cụm Kubernetes của máy này"
if kubectl get nodes &>/dev/null; then
  ok "kubectl nối được cụm"
  NOTREADY="$(kubectl get nodes --no-headers | awk '$2!="Ready"{print $1}')"
  if [ -z "$NOTREADY" ]; then ok "cả $(kubectl get nodes --no-headers | wc -l) node đều Ready"
  else no "node chưa Ready: $NOTREADY"; fi
  BAD="$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk '
      $1 ~ /install-packages/ {next}
      $3=="Completed"||$3=="Succeeded"{next}
      $3=="Running"{split($2,a,"/"); if(a[1]==a[2]) next}
      {print $1" ("$3")"}')"
  if [ -z "$BAD" ]; then ok "mọi pod OpenWhisk sẵn sàng"
  else no "pod chưa sẵn sàng: $(echo "$BAD" | tr '\n' ' ')"; fi
  if kubectl -n "$NS" get pod "$INVOKER_POD" &>/dev/null; then ok "có pod $INVOKER_POD (cho F1)"
  else no "không thấy pod $INVOKER_POD -> sửa INVOKER_POD trong chaos.conf"; fi
else
  no "kubectl KHÔNG nối được cụm"
fi

echo
echo "📋 3. Container k3d (cho F2 / F4)"
if docker ps --format '{{.Names}}' | grep -q "^k3d-${K3D_CLUSTER}"; then
  ok "đang chạy $(docker ps --format '{{.Names}}' | grep -c "^k3d-${K3D_CLUSTER}") container k3d-${K3D_CLUSTER}-*"
  if docker ps --format '{{.Names}}' | grep -qx "$AGENT_NODE"; then ok "có node $AGENT_NODE (cho F2)"
  else no "không thấy $AGENT_NODE -> sửa AGENT_NODE trong chaos.conf. Đang có:"; docker ps --format '    {{.Names}}' | grep k3d; fi
else
  no "không thấy container k3d-${K3D_CLUSTER}-* -> sửa K3D_CLUSTER trong chaos.conf"
fi

echo
echo "📋 4. Action trong namespace guest"
API_HOST="$(tailscale ip -4 2>/dev/null | head -1)"
GUEST_AUTH="$(kubectl -n "$NS" get secret "${RELEASE}-whisk.auth" -o jsonpath='{.data.guest}' 2>/dev/null | base64 -d 2>/dev/null)"
if [ -n "$API_HOST" ] && [ -n "$GUEST_AUTH" ]; then
  ok "IP Tailscale = $API_HOST, đọc được khóa guest"
  B64="$(printf '%s' "$GUEST_AUTH" | base64 -w0)"
  for a in ping test-thu A1 A2 A3 publish_result; do
    CODE="$(curl -sk --max-time 60 -o /dev/null -w '%{http_code}' \
      -H "Authorization: Basic $B64" \
      "https://${API_HOST}:${OW_PORT}/api/v1/namespaces/_/actions/${a}" 2>/dev/null)"
    if [ "$CODE" = "200" ]; then ok "có action $a"
    elif [ "$CODE" = "404" ]; then
      case "$a" in
        ping|test-thu) no "thiếu $a -> $GOLDEN_DIR/deploy-actions.sh" ;;
        *)             no "thiếu $a -> $HERE/deploy-actions-plus.sh" ;;
      esac
    else no "hỏi action $a trả HTTP $CODE"; fi
  done
else
  no "không lấy được IP Tailscale hoặc khóa guest"
fi

echo
echo "📋 5. Điều kiện cho chaos.sh"
for c in c1 c2 c3; do
  if [ "$c" = "$ME" ]; then inf "$c = máy này (chạy lệnh trực tiếp)"; continue; fi
  v="SSH_$c"; host="${!v:-}"
  if [ -z "$host" ]; then no "chưa khai báo SSH_$c"
  elif ssh -o BatchMode=yes -o ConnectTimeout=6 "$host" "echo ok" &>/dev/null; then ok "SSH tới $c ($host) OK"
  else no "SSH tới $c ($host) CHƯA được -> $HERE/setup-ssh.sh"; fi
done
for c in c1 c2 c3; do
  if [ -f "$HOME/.wskprops.$c" ]; then ok "có ~/.wskprops.$c (cho F5)"
  else no "thiếu ~/.wskprops.$c -> $HERE/setup-wskprops.sh"; fi
done
if sudo -n true 2>/dev/null; then ok "sudo không hỏi mật khẩu (F3 cần iptables)"
else inf "sudo sẽ hỏi mật khẩu -> chạy 'sudo -v' ngay trước khi dùng F3"; fi

echo
echo "📋 6. Gateway của Máy 1"
GCODE="$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "${GATEWAY_URL}/admin/clusters" 2>/dev/null)"
if [ "$GCODE" = "200" ]; then
  ok "Gateway $GATEWAY_URL đang chạy"
  curl -s --max-time 5 "${GATEWAY_URL}/admin/clusters" | head -c 600 | sed 's/^/     /'; echo
else
  inf "chưa gọi được Gateway ($GATEWAY_URL, HTTP ${GCODE:-000}). Bình thường nếu Máy 1 chưa bật."
fi

echo
echo "============================================================"
echo "  ĐẠT: $PASS    |    CHƯA ĐẠT: $FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] && echo "✅ Sẵn sàng gây lỗi." || echo "⚠️  Sửa các dòng ❌ trước khi đo."
