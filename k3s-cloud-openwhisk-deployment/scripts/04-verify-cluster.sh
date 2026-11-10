#!/usr/bin/env bash
# =====================================================================
#  04-verify-cluster.sh - chạy trên MASTER bằng user thường (có ~/.kube/config)
#  Kiểm tra cụm đủ điều kiện cho OpenWhisk. Chỉ ĐỌC + 2 pod thử (tự xóa).
#  Điểm hay vỡ nhất của K3s-over-Tailscale là pod<->pod xuyên node, nên test kỹ chỗ đó.
# =====================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
need_cmd kubectl
EXPECTED_NODES="${EXPECTED_NODES:-3}"
PASS=0; FAIL=0
good() { ok "$*"; PASS=$((PASS+1)); }
bad()  { printf '%s❌ %s%s\n' "$C_R" "$*" "$C_N"; FAIL=$((FAIL+1)); }

log "1/6 Chờ ${EXPECTED_NODES} node Ready..."
for _ in $(seq 1 60); do
  N="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)"
  [ "$N" -ge "$EXPECTED_NODES" ] && break; sleep 5
done
if [ "$N" -ge "$EXPECTED_NODES" ]; then good "$N node Ready"; else bad "Chỉ $N/$EXPECTED_NODES node Ready"; fi
kubectl get nodes -o wide

log "2/6 INTERNAL-IP của mọi node phải là IP Tailscale (100.x)..."
BADIP="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' | awk '$2 !~ /^100\./')"
if [ -z "$BADIP" ]; then good "Mọi node dùng IP Tailscale"; else bad "Node sai IP (thiếu --node-ip?): $BADIP"; fi

log "3/6 Nhãn invoker + taint master..."
NW="$(kubectl get nodes -l openwhisk-role=invoker --no-headers | wc -l)"
if [ "$NW" -ge $((EXPECTED_NODES-1)) ]; then good "$NW worker có nhãn openwhisk-role=invoker"; else bad "Chỉ $NW worker có nhãn invoker (kubectl label node <tên> openwhisk-role=invoker)"; fi
if kubectl get nodes -l 'node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].spec.taints[*].key}' | grep -q 'control-plane'; then
  good "Master có taint control-plane:NoSchedule"
else
  warn "Master KHÔNG bị taint: pod OpenWhisk có thể chạy trên master (TAINT_MASTER=0?)"
fi

log "4/6 StorageClass mặc định (cho PVC CouchDB/Kafka/ZooKeeper)..."
if kubectl get storageclass 2>/dev/null | grep -q '(default)'; then good "Có StorageClass mặc định"; else bad "Không có StorageClass mặc định (local-path-provisioner chưa lên?)"; fi

log "5/6 Đường Tailscale giữa các node (direct hay relay)..."
for ip in $(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'); do
  OUT="$(tailscale ping -c 2 --timeout 3s "$ip" 2>&1 | tail -n 1 || true)"
  echo "   $ip -> $OUT"
  [[ "${OUT,,}" == *derp* ]] && warn "   $ip đang đi qua relay DERP -> độ trễ cao. Kiểm tra UDP 41641 / firewall VPC."
done
ip -o link show flannel.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="mtu") print "   MTU flannel.1 =", $(i+1), "(kỳ vọng 1230)"}' || true

log "6/6 Pod<->pod và DNS xuyên node (pod thử chạy ghim trên 2 worker)..."
mapfile -t WORKERS < <(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
if [ "${#WORKERS[@]}" -lt 2 ]; then
  bad "Cần >= 2 worker để test xuyên node (đang có ${#WORKERS[@]})"
else
  cleanup() { kubectl delete pod nettest-0 nettest-1 --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
  trap cleanup EXIT
  for i in 0 1; do
    # nodeName ghim thẳng pod vào node (bỏ qua scheduler) để chắc chắn khác node.
    kubectl run "nettest-$i" --image=busybox:1.36.1 --restart=Never \
      --overrides="{\"spec\":{\"nodeName\":\"${WORKERS[$i]}\"}}" -- sleep 300 >/dev/null
  done
  kubectl wait --for=condition=Ready pod/nettest-0 pod/nettest-1 --timeout=180s >/dev/null || bad "Pod thử không Ready (pull busybox lỗi?)"
  IP1="$(kubectl get pod nettest-1 -o jsonpath='{.status.podIP}')"
  if kubectl exec nettest-0 -- ping -c 3 -W 3 "$IP1" >/dev/null 2>&1; then
    good "Ping pod ${WORKERS[0]} -> ${WORKERS[1]} (${IP1}) OK"
  else
    bad "Ping pod xuyên node THẤT BẠI. Nghi: --flannel-iface sai, ufw chặn tailscale0, ACL Tailscale chặn udp:8472 (VXLAN) / tcp:10250 (kubelet)."
  fi
  if kubectl exec nettest-0 -- nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then
    good "DNS trong pod (CoreDNS) OK"
  else
    bad "DNS trong pod thất bại (CoreDNS chưa chạy hoặc forward lỗi)"
  fi
fi

echo "============================================================"
echo "  ĐẠT: $PASS   |   CHƯA ĐẠT: $FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] && ok "Cụm sẵn sàng. Bước tiếp: ./openwhisk/install-openwhisk.sh" || { warn "Sửa các dòng ❌ trước khi cài OpenWhisk."; exit 1; }
