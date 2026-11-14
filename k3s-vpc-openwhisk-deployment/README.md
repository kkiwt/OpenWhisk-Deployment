# OpenWhisk trên K3s Private VPC

Bộ này dành cho một cluster K3s trong cùng private network. Không dùng
Tailscale; mọi địa chỉ node là private IP của VPC.

## Thứ tự cài đặt

Trên cả bốn VPS:

```bash
./scripts/00-install-linux-prerequisites.sh
sudo VPC_CIDR=10.0.0.0/24 NODE_IP=<private-ip> \
  FLANNEL_IFACE=<vpc-interface> ./scripts/01-setup-vpc-network.sh
```

Trên server:

```bash
sudo NODE_IP=<private-ip-server> \
  FLANNEL_IFACE=<vpc-interface> \
  NODE_NAME=c1-server ./scripts/02-setup-k3s-master.sh
```

Trên từng agent:

```bash
sudo NODE_IP=<private-ip-agent> \
  FLANNEL_IFACE=<vpc-interface> \
  NODE_NAME=c1-agent1 \
  K3S_URL=https://<private-ip-server>:6443 \
  K3S_TOKEN='<token-trong-join.env>' \
  ./scripts/03-setup-k3s-worker.sh
```

Đổi `NODE_NAME` cho `c1-agent2` và `c1-agent3`. Sau khi đủ bốn node:

```bash
./scripts/04-verify-cluster.sh
```

## Cổng private VPC

- TCP `6443`: K3s API server
- TCP `10250`: kubelet giữa các node
- UDP `8472`: Flannel VXLAN giữa các node
- TCP `31001`: OpenWhisk HTTPS NodePort từ Gateway

Chỉ mở các cổng này trong private network/security group, không mở public.

## Cài OpenWhisk

```bash
API_HOST=<private-ip-node-co-nodeport> \
./openwhisk/install-openwhisk.sh
```

NodePort `31001` được kube-proxy phục vụ trên mọi node. `API_HOST` phải là
private IP mà máy chạy test có thể truy cập. Số invoker mặc định là 2 và có
thể đổi bằng `INVOKER_REPLICAS=<số-lượng>`.

Gateway không bắt buộc. Có thể chạy action và load test trực tiếp qua NodePort
trong VPC.

## Load test trực tiếp

Lấy auth của namespace guest trên server rồi chạy K6 từ máy có route tới VPC:

```bash
OW_AUTH="$(kubectl -n openwhisk get secret owdev-whisk.auth \
  -o jsonpath='{.data.guest}' | base64 -d)"
k6 run -e OW_API=https://<private-ip-node>:31001 \
  -e OW_AUTH="$OW_AUTH" tests/load-test.js
```

Test chaos chọn invoker theo label, không phụ thuộc số lượng replica:

```bash
kubectl apply -f tests/chaos-pod-kill.yaml
kubectl apply -f tests/chaos-network-delay.yaml
```

## Kiểm chứng yêu cầu đề bài

Sau khi deploy action, chạy smoke test + concurrency:

```bash
API_HOST=<private-ip-node> ./tests/validate-openwhisk.sh
```

Để kiểm tra worker failover bằng cách cordon/drain một node:

```bash
API_HOST=<private-ip-node> RUN_NODE_FAILOVER=1 \
  ./tests/validate-openwhisk.sh
```

Bài kiểm tra này là destructive đối với node được chọn; chỉ chạy trên cluster
thử nghiệm. `INVOKER_REPLICAS` vẫn là biến cấu hình độc lập, không bị ép thành
3. Failover của action/invoker được kiểm chứng tự động; các thành phần có PVC
local-path (đặc biệt CouchDB/Kafka) vẫn cần storage phân tán hoặc backup riêng
nếu yêu cầu chịu mất hẳn node mà không gián đoạn dữ liệu.

