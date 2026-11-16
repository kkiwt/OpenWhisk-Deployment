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
- 3 K3s agent: 4 GB RAM mỗi máy, cùng cấu hình với server.
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
sudo VPC_CIDR=192.168.1.0/24 NODE_IP=<private-ip> \
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

## 2. Cài OpenWhisk một lần, rồi deploy action

Nếu OpenWhisk **chưa được cài** trên cluster mới, chạy installer một lần:

```bash
API_HOST=<private-ip-server-or-agent> \
INVOKER_REPLICAS=2 \
  bash ./openwhisk/install-openwhisk.sh
```

Nếu OpenWhisk đã chạy rồi, **không chạy installer lại**. `deploy-demo.sh` chỉ
preflight cluster, deploy/update các Action Group 4 và thu evidence:

Trên server, chạy:

```bash
cd k3s-vpc-openwhisk-deployment
API_HOST=<private-ip-server-or-agent> \
  bash ./video-demo/deploy-demo.sh
```

Script sẽ:

- kiểm tra namespace, guest auth, NodePort `31001`, Invoker Ready và API;
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
bash ./video-demo/run-demo.sh concurrency 2
bash ./video-demo/run-demo.sh concurrency 8
bash ./video-demo/run-demo.sh concurrency 12
```

Ba mức này tương ứng 2, 8 và 12 RPS. Mỗi lần chạy tạo một thư mục evidence
riêng gồm `summary.json` và `metrics.csv`. K6 chỉ thu thập số liệu, không tự
kết luận hệ thống đạt hay không đạt hiệu năng.

Hoặc chạy K6 trực tiếp từ máy có route tới private VPC:

```bash
k6 run -e OW_API=https://<private-ip>:31001 \
  -e OW_AUTH="$(cat video-demo/evidence/.guest-auth)" -e SCENARIO=concurrency \
  -e RATE=8 -e DURATION=60s \
  --summary-export video-demo/evidence/k6-summary.json \
  --out csv=video-demo/evidence/k6-metrics.csv \
  video-demo/tests/video-load.js
```

Trong `summary.json`, các metric chính là:

- `demo_requests_total`
- `demo_requests_successful`
- `demo_requests_failed`
- `demo_latency_ms` với average, p90 và p95

Trong Grafana mở dashboard node/pod và quay:

- CPU/RAM các node;
- số action pod Running;
- restart/OOM;
- latency HTTP;
- Kafka/controller/invoker logs nếu có dashboard tương ứng.

### Cảnh D - failover

Chạy trên cluster thử nghiệm:

```bash
FAILOVER_MODE=invoker API_HOST=<private-ip> \
  bash ./video-demo/failover-demo.sh
```

Script lưu UID/node của Invoker cũ, đăng ký trap uncordon ngay sau khi xác định
node, cordon node, xóa pod cũ và xác nhận UID cũ biến mất. Nó chỉ chấp nhận
replacement có UID mới, Running, Ready và nằm trên node khác; replica còn lại
không được tính là recovery. Sau đó script ghi recovery time, gọi
`Group4_Action2` và kiểm tra 8/8 request song song.

Đây là bằng chứng **Invoker rescheduling/action availability**, không phải
cam kết full data HA cho CouchDB/Kafka. Node luôn được uncordon khi script kết
thúc, kể cả khi bước kiểm tra bị lỗi.

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

  Hoặc chạy toàn bộ health/evidence workflow:

  ```bash
  API_HOST=<private-ip> bash ./video-demo/run-demo.sh health
  PROMETHEUS_URL=http://<private-prometheus>:9090 \
    bash ./video-demo/run-demo.sh collect
  ```

  `collect-evidence.sh` tạo thư mục timestamp và thu node status/IP/labels/resource,
  pod status/placement/restart, PVC, events, Invoker logs, Prometheus metrics,
  failover logs và các JSON/CSV K6 trước đó. Guest authentication và secret
  không được copy vào evidence snapshot.

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

## 6. Troubleshooting

### Không tìm thấy guest auth

Chạy lại deploy action:

```bash
API_HOST=<private-ip> bash ./video-demo/deploy-demo.sh
```

Kiểm tra file local, không đưa file này vào Git:

```bash
test -s video-demo/evidence/.guest-auth
```

### K6 không chạy được

K6 phải được cài trên máy chạy test, không nhất thiết trên VPS:

```bash
k6 version
```

Kiểm tra NodePort và API trước:

```bash
API_HOST=<private-ip> bash ./video-demo/run-demo.sh health
```

### Failover không tìm thấy replacement

Kiểm tra:

```bash
kubectl -n openwhisk get pods -l name=owdev-invoker -o wide
kubectl get nodes --show-labels
kubectl -n openwhisk get events --sort-by=.lastTimestamp
```

Đảm bảo còn ít nhất một node khác Ready và không bị cordon. Nếu dùng
`FAILOVER_MODE=node`, nhớ đây là test destructive trên cluster demo và có thể
ảnh hưởng PVC `local-path`.
