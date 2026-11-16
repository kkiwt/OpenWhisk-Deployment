#!/usr/bin/env bash
# =====================================================================
#  04-verify-cluster.sh - chạy trên MASTER bằng user thường (có ~/.kube/config)
#  Kiểm tra cụm đủ điều kiện cho OpenWhisk. Chỉ ĐỌC + 2 pod thử (tự xóa).
#  Điểm hay vỡ nhất của K3s trong VPC là pod<->pod xuyên node, nên test kỹ chỗ đó.
# =====================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
need_cmd kubectl
EXPECTED_NODES="${EXPECTED_NODES:-4}"
EXPECTED_INVOKER_NODES="${EXPECTED_INVOKER_NODES:-$EXPECTED_NODES}"
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

log "2/6 INTERNAL-IP của mọi node phải là IP private VPC..."
IPS="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')"
if [ -n "$IPS" ] && ! grep -Eq '(^|[[:space:]])(127\.|169\.254\.)' <<< "$IPS"; then
  good "Mọi node có InternalIP hợp lệ"
else
  bad "Có node thiếu InternalIP private: $IPS"
fi

log "3/6 Nhãn workload trên toàn bộ node..."
NW="$(kubectl get nodes -l openwhisk-role=invoker --no-headers | wc -l)"
if [ "$NW" -ge "$EXPECTED_INVOKER_NODES" ]; then
  good "$NW node có nhãn openwhisk-role=invoker"
else
  bad "Chỉ $NW/$EXPECTED_INVOKER_NODES node có nhãn invoker (kubectl label node <tên> openwhisk-role=invoker)"
fi
if kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.taints[*].effect}{"\n"}{end}' | grep -q 'NoSchedule'; then
  warn "Có node đang bị NoSchedule; workload sẽ không dùng được toàn bộ tài nguyên"
else
  good "Không có taint NoSchedule; server có thể chạy workload"
fi

log "4/6 StorageClass mặc định (cho PVC CouchDB/Kafka/ZooKeeper)..."
if kubectl get storageclass 2>/dev/null | grep -q '(default)'; then good "Có StorageClass mặc định"; else bad "Không có StorageClass mặc định (local-path-provisioner chưa lên?)"; fi

log "5/6 Network private giữa các node..."
for ip in $(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'); do
  if timeout 3 bash -c "</dev/tcp/$ip/10250" 2>/dev/null; then
    echo "   $ip:10250 -> OK"
  else
    bad "$ip:10250 không kết nối được; kiểm tra VPC firewall"
  fi
done
ip -o link show flannel.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="mtu") print "   MTU flannel.1 =", $(i+1)}' || true

log "6/6 Pod<->pod và DNS xuyên node (pod thử chạy trên 2 node)..."
mapfile -t WORKERS < <(kubectl get nodes -l openwhisk-role=invoker -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
if [ "${#WORKERS[@]}" -lt 2 ]; then
  bad "Cần >= 2 node có nhãn invoker để test xuyên node (đang có ${#WORKERS[@]})"
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
    bad "Ping pod xuyên node THẤT BẠI. Nghi: --flannel-iface sai hoặc VPC firewall chặn udp:8472/tcp:10250."
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
