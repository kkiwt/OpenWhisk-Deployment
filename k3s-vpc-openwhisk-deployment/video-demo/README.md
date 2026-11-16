# Kịch bản demo Serverless OpenWhisk trên K3s VPC

Folder này là kịch bản quay video và lấy bằng chứng cho đề bài:

Tài liệu tổng hợp toàn bộ topology, quy trình và mục tiêu nằm tại
[DEPLOYMENT-SCENARIO.md](DEPLOYMENT-SCENARIO.md).

```text
Client -> OpenWhisk NodePort -> Controller -> Kafka queue -> Invoker
       -> action pod Python/Node.js -> HTTP response
```

Kịch bản chứng minh:

1. Hạ tầng K3s private VPC chạy OpenWhisk Controller, Invoker, Kafka, CouchDB.
2. Action Python chạy được qua HTTP API.
3. Nhiều request được xử lý song song bởi nhiều Invoker/action pod.
4. Khi một Invoker/worker bị lỗi, Kubernetes tạo lại workload trên node còn lại.
5. Prometheus/Grafana được dùng để đối chiếu request, pod, CPU, RAM và queue.

## Mô hình phần cứng

- 1 K3s server: khoảng 4 GB RAM, vừa control-plane vừa chạy workload.
- 3 K3s agent: khoảng 2.5 GB RAM mỗi máy.
- Khuyến nghị `INVOKER_REPLICAS=2` cho demo; có thể tăng lên 3 nếu còn headroom.
- K6 chạy ngoài cluster để không cạnh tranh RAM với action.

> Failover của Invoker/action được chứng minh ở đây. Với `local-path` storage, không
> tuyên bố CouchDB/Kafka chịu mất node hoàn toàn; muốn chứng minh failover dữ liệu cần
> storage phân tán hoặc backup/restore.

## 1. Chuẩn bị VPC

Copy file cấu hình trên máy quản trị:

```bash
cp video-demo/config/demo.env.example video-demo/config/demo.env
vi video-demo/config/demo.env
```

Điền private IP và interface VPC cho 4 máy. Mở trong private security group:

```text
TCP 6443, 10250, 31001
UDP 8472
```

Trên cả server và agent:

```bash
./scripts/00-install-linux-prerequisites.sh
sudo VPC_CIDR=10.0.0.0/24 NODE_IP=<private-ip> \
  FLANNEL_IFACE=<vpc-interface> ./scripts/01-setup-vpc-network.sh
```

Bootstrap server:

```bash
sudo NODE_IP=<server-private-ip> FLANNEL_IFACE=<vpc-interface> \
  NODE_NAME=demo-server ./scripts/02-setup-k3s-master.sh
```

Lấy token trên server:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

Join từng agent:

```bash
sudo NODE_IP=<agent-private-ip> FLANNEL_IFACE=<vpc-interface> \
  NODE_NAME=demo-agent1 \
  K3S_URL=https://<server-private-ip>:6443 \
  K3S_TOKEN='<token>' ./scripts/03-setup-k3s-worker.sh
```

Đổi `NODE_NAME` cho agent2 và agent3, rồi trên server:

```bash
EXPECTED_NODES=4 EXPECTED_INVOKER_NODES=4 ./scripts/04-verify-cluster.sh
```

## 2. Cài OpenWhisk và deploy action

Trên server, chạy:

```bash
cd k3s-vpc-openwhisk-deployment
API_HOST=<private-ip-server-or-agent> \
INVOKER_REPLICAS=2 \
  bash ./video-demo/deploy-demo.sh
```

Script sẽ:

- cài OpenWhisk bằng cấu hình VPC hiện có và chart commit đã pin;
- áp dụng giới hạn RAM/CPU phù hợp máy nhỏ;
- preload Python và Node.js runtime;
- tạo `ping`, `node-info`, `Group4_Action1`, `Group4_Action2`,
  `Group4_Action3`, `node-demo`;
- chạy smoke test;
- tạo thư mục evidence theo timestamp.

## 3. Kịch bản quay video

### Cảnh A - topology và routing

```bash
bash ./video-demo/collect-evidence.sh
kubectl get nodes -o wide
kubectl -n openwhisk get pods -o wide
```

Nói rõ luồng: NodePort vào nginx/controller, request được controller đưa vào
Kafka queue, invoker chọn runtime, Kubernetes tạo action pod cách ly.

### Cảnh B - một action Python

```bash
bash ./video-demo/run-demo.sh smoke
```

Hiển thị response có `action`, `activation_id`, `action_pod` và `duration_ms`.
Đối chiếu `action_pod` với `kubectl -n openwhisk get pods -o wide` để chứng minh
runtime đang chạy trên node nào.

Gọi thêm action Node.js:

```bash
curl -sk -u "$(cat video-demo/evidence/.guest-auth)" \
  -H 'Content-Type: application/json' \
  -X POST "https://<private-ip>:31001/api/v1/namespaces/_/actions/node-demo?blocking=true&result=true" \
  -d '{}'
```

### Cảnh C - concurrency

```bash
bash ./video-demo/run-demo.sh concurrency
```

Hoặc chạy K6 từ máy có route tới private VPC:

```bash
k6 run -e OW_API=https://<private-ip>:31001 \
  -e OW_AUTH="$(cat video-demo/evidence/.guest-auth)" -e SCENARIO=concurrency \
  -e DURATION=60s video-demo/tests/video-load.js
```

Trong Grafana mở dashboard node/pod và quay:

- CPU/RAM các node;
- số action pod Running;
- restart/OOM;
- latency HTTP;
- Kafka/controller/invoker logs nếu có dashboard tương ứng.

### Cảnh D - failover

Chạy trên cluster thử nghiệm:

```bash
FAILOVER_MODE=invoker bash ./video-demo/failover-demo.sh
```

Script sẽ chọn node agent có Invoker, cordon node, xóa Invoker pod trên node
đó, chờ pod mới lên node khác, gọi `Group4_Action2`, rồi chạy 8 request song song.
Đây là bằng chứng **Invoker rescheduling/action availability**, không phải
cam kết full data HA cho CouchDB/Kafka. Cuối cùng script uncordon node và ghi
bằng chứng.

Để mô phỏng drain worker mạnh hơn:

```bash
FAILOVER_MODE=node FAILOVER_NODE=demo-agent1 bash ./video-demo/failover-demo.sh
```

Chỉ dùng chế độ này trên cluster demo vì nó có thể làm các pod stateful bị
di chuyển/không sẵn sàng khi đang dùng `local-path`; đây vẫn không phải kiểm
chứng full data HA.

## 4. Prometheus/Grafana

Folder `monitoring/` có query và checklist panel. Đặt URL Prometheus nếu muốn
script lấy snapshot metric:

```bash
PROMETHEUS_URL=http://<private-prometheus>:9090 \
  bash ./video-demo/collect-evidence.sh
```

Nếu Prometheus nằm trong Kubernetes, có thể port-forward tạm thời:

```bash
kubectl -n monitoring port-forward svc/prometheus 9090:9090
```

Các metric quan trọng cho báo cáo:

- `container_cpu_usage_seconds_total`
- `container_memory_working_set_bytes`
- `kube_pod_status_phase`
- `kube_pod_container_status_restarts_total`
- `kube_node_status_condition`

Kết luận báo cáo nên phân biệt rõ:

- **concurrency**: nhiều activation/action pod xử lý đồng thời;
- **failover**: Invoker/action được tái tạo trên node còn sống;
- **data HA**: chưa được cam kết với `local-path`.

## 5. Dọn cluster sau khi quay

```bash
bash ./openwhisk/uninstall-openwhisk.sh
```

Không xóa cluster nếu còn cần giữ evidence trong Grafana.
