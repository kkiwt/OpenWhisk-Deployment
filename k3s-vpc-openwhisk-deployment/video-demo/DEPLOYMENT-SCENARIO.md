# Kịch bản triển khai và quay video
# Apache OpenWhisk trên K3s Private VPC - Group 4

Tài liệu này mô tả toàn bộ kịch bản triển khai, vận hành, kiểm thử và quay
video cho đề tài Serverless Apache OpenWhisk trên K3s. Có thể gửi nguyên file
cho một AI khác để phân tích tiếp.

## 1. Mục tiêu đề tài

Xây dựng một nền tảng Serverless gồm:

```text
Client
  -> K3s NodePort / OpenWhisk NGINX
  -> OpenWhisk Controller
  -> Kafka queue
  -> Invoker
  -> Kubernetes action pod
  -> Python hoặc Node.js runtime
  -> HTTP response
```

Kịch bản phải chứng minh:

1. Hạ tầng OpenWhisk chạy ổn định trên K3s private VPC.
2. Client gọi Action qua HTTP API.
3. Các request đồng thời được phân phối qua nhiều Invoker/action pod.
4. Khi một Invoker hoặc worker gặp sự cố, workload được tái lập trên node còn
   khả dụng.
5. Prometheus/Grafana ghi nhận được trạng thái node, pod, CPU, RAM, restart và
   các dấu hiệu queue/backpressure.

## 2. Hạ tầng và vai trò node

Cả bốn máy đều là VPS có cùng cấu hình:

- CPU: 4 vCPU
- RAM: 4 GB
- OS: Ubuntu 22.04 LTS
- Kubernetes distribution: K3s `v1.35.5+k3s1`
- Container runtime: containerd
- Mạng: private VPC, không dùng Tailscale trong flow này

| Node | Private IP | Vai trò |
|---|---:|---|
| `c1-server` | `192.168.1.5` | K3s server; control-plane, Kubernetes API, scheduler, controller-manager; được phép chạy workload |
| `c1-agent1` | `192.168.1.102` | K3s agent; worker chạy Invoker/action pod |
| `c1-agent2` | `192.168.1.46` | K3s agent; worker chạy Invoker/action pod |
| `c1-agent3` | `192.168.1.242` | K3s agent; worker chạy Invoker/action pod |

### Quyết định quan trọng

Server **không bị taint để cấm workload**. Server vẫn có thể chạy OpenWhisk
core, Invoker và action pod. Lý do là mỗi máy chỉ có 4 GB RAM; nếu dồn toàn bộ
workload sang agent thì server vẫn phải giữ control-plane nhưng tài nguyên bị
lãng phí.

Flow chính dùng:

```text
1 server + 3 agent
2 OpenWhisk Invoker replica
server được phép chạy workload
```

Ba server embedded-etcd HA không thuộc flow video chính. Đó là một biến thể
bonus riêng và không được trộn vào kịch bản này.

## 3. Mạng private VPC

Các cổng cần cho private security group/firewall:

| Port | Protocol | Mục đích |
|---:|---|---|
| `6443` | TCP | K3s Kubernetes API |
| `10250` | TCP | Kubelet giữa control-plane và agent |
| `8472` | UDP | Flannel VXLAN pod-to-pod |
| `31001` | TCP | OpenWhisk HTTPS NodePort |
| `2379-2380` | TCP | Chỉ dùng cho bonus embedded-etcd HA, không cần flow chính |

Không cần public exposure cho OpenWhisk nếu máy quay/test có route tới private
VPC. Client gọi trực tiếp:

```text
https://192.168.1.5:31001
```

NodePort được kube-proxy phục vụ trên các node, nhưng dùng `192.168.1.5` làm
địa chỉ demo giúp dễ trình bày và dễ quay màn hình.

## 4. Thành phần phần mềm

### K3s

- Kubernetes API và control-plane chạy trên `c1-server`.
- K3s dùng containerd, không phụ thuộc Docker socket.
- Flannel cung cấp pod network xuyên node.
- `local-path` cung cấp persistent volume mặc định.

### OpenWhisk

| Thành phần | Vai trò |
|---|---|
| NGINX/NodePort | Cửa vào HTTPS cho client |
| Controller | Nhận activation request và điều phối |
| Kafka | Queue giữa Controller và Invoker |
| Invoker | Nhận activation, quản lý action container/pod |
| CouchDB | Lưu metadata/action/activation theo chart |
| ZooKeeper | Điều phối Kafka theo chart hiện tại |
| Redis/API Gateway phụ trợ | Thành phần chart OpenWhisk tùy cấu hình |
| Action pod | Runtime cách ly cho Python/Node.js action |

### Giới hạn tài nguyên

Cấu hình VPC hiện tại dùng:

```text
Action memory profile: 128 MB
Invoker userMemory:    1024 MB mỗi Invoker
Invoker replicas:      2
```

Về accounting lý thuyết:

```text
1024 MB / 128 MB = 8 action slots mỗi Invoker
2 Invoker = khoảng 16 slots toàn cụm
```

Đây là capacity accounting, không phải cam kết luôn có 16 container Running.
Action pod chỉ được tạo theo nhu cầu. CPU Invoker, cold start, quota, node
pressure và queue có thể làm throughput thực tế thấp hơn.

Namespace có ResourceQuota/LimitRange để tránh action làm cạn RAM:

```text
requests.memory: 6500Mi
limits.memory:   8000Mi
requests.cpu:    5
limits.cpu:      8
pods:             45
```

## 5. Các action của Group 4

File [demo_action.py](actions/demo_action.py) là một code template dùng chung.
Khi deploy, cùng một code được tạo thành ba action độc lập:

| Tên action | Runtime | CPU busy mô phỏng | Mục đích |
|---|---|---:|---|
| `Group4_Action1` | Python 3 | 50 ms | workload nhẹ |
| `Group4_Action2` | Python 3 | 200 ms | workload trung bình |
| `Group4_Action3` | Python 3 | 500 ms | workload nặng |
| `node-demo` | Node.js 18 | không busy loop | chứng minh đa runtime |
| `ping` | Python 3 | 10 ms | health/smoke check |
| `node-info` | Python 3 | 10 ms | action telemetry nhẹ |

Response Python có các trường:

```json
{
  "status": "ok",
  "group": "Group 4",
  "action": "Group4_Action2",
  "activation_id": "...",
  "action_pod": "...",
  "duration_ms": 200,
  "work_units": 123456
}
```

Tên `Group4_Action1/2/3` cố ý không dùng `A1/A2/A3`, tránh nhầm với action
thuộc demo cũ hoặc hệ thống khác.

## 6. Cấu trúc folder demo

```text
video-demo/
├── README.md
├── DEPLOYMENT-SCENARIO.md
├── config/
│   └── demo.env.example
├── actions/
│   ├── demo_action.py
│   ├── node_demo.js
│   └── deploy-demo-actions.sh
├── tests/
│   └── video-load.js
├── monitoring/
│   └── prometheus-queries.md
├── deploy-demo.sh
├── run-demo.sh
├── failover-demo.sh
├── collect-evidence.sh
└── evidence/
    └── .gitkeep
```

Folder này là scenario overlay. Nó tái sử dụng installer K3s/OpenWhisk ở cấp
VPC, không copy lại toàn bộ hạ tầng:

```text
k3s-vpc-openwhisk-deployment/scripts/
k3s-vpc-openwhisk-deployment/openwhisk/
k3s-vpc-openwhisk-deployment/k3s-resource-policy.yaml
```

## 7. Quy trình triển khai đầy đủ

### Bước 0 - Chuẩn bị repository

Trên server hoặc máy quản trị có quyền truy cập VPC:

```bash
git clone <repository-url>
cd OpenWhisk-Deployment/k3s-vpc-openwhisk-deployment
```

K6 nên chạy ngoài cluster để không chiếm RAM/CPU của VPS.

### Bước 1 - Chuẩn bị cả bốn VPS

Trên từng node:

```bash
./scripts/00-install-linux-prerequisites.sh

sudo VPC_CIDR=192.168.1.0/24 \
  NODE_IP=<private-ip-cua-node> \
  FLANNEL_IFACE=<vpc-interface> \
  ./scripts/01-setup-vpc-network.sh
```

`FLANNEL_IFACE` phải là interface thực sự mang IP private VPC trên máy đó.
Không đoán tên interface; kiểm tra bằng:

```bash
ip -br addr
ip route
```

### Bước 2 - Bootstrap K3s server

Trên `c1-server`:

```bash
sudo NODE_IP=192.168.1.5 \
  FLANNEL_IFACE=<vpc-interface> \
  NODE_NAME=c1-server \
  ./scripts/02-setup-k3s-master.sh
```

Lấy token join:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

### Bước 3 - Join ba agent

Trên `c1-agent1`:

```bash
sudo NODE_IP=192.168.1.102 \
  FLANNEL_IFACE=<vpc-interface> \
  NODE_NAME=c1-agent1 \
  K3S_URL=https://192.168.1.5:6443 \
  K3S_TOKEN='<token>' \
  ./scripts/03-setup-k3s-worker.sh
```

Trên `c1-agent2`, đổi IP và tên:

```bash
sudo NODE_IP=192.168.1.46 \
  FLANNEL_IFACE=<vpc-interface> \
  NODE_NAME=c1-agent2 \
  K3S_URL=https://192.168.1.5:6443 \
  K3S_TOKEN='<token>' \
  ./scripts/03-setup-k3s-worker.sh
```

Trên `c1-agent3`:

```bash
sudo NODE_IP=192.168.1.242 \
  FLANNEL_IFACE=<vpc-interface> \
  NODE_NAME=c1-agent3 \
  K3S_URL=https://192.168.1.5:6443 \
  K3S_TOKEN='<token>' \
  ./scripts/03-setup-k3s-worker.sh
```

### Bước 4 - Kiểm tra cluster

Trên `c1-server`:

```bash
EXPECTED_NODES=4 \
EXPECTED_INVOKER_NODES=4 \
  ./scripts/04-verify-cluster.sh
```

Phải kiểm tra được:

- 4 node Ready;
- InternalIP đúng private VPC;
- cả 4 node có label `openwhisk-role=invoker`;
- server không còn taint NoSchedule chặn workload;
- StorageClass `local-path`;
- kubelet TCP `10250`;
- pod-to-pod và DNS xuyên node.

### Bước 5 - Cài OpenWhisk một lần, rồi deploy action

Nếu đây là cluster mới và OpenWhisk chưa được cài, trên `c1-server` chạy một
lần:

```bash
API_HOST=192.168.1.5 \
INVOKER_REPLICAS=2 \
  bash ./openwhisk/install-openwhisk.sh
```

Nếu OpenWhisk đã Running, không chạy installer lại. Dùng `deploy-demo.sh`:

```bash
API_HOST=192.168.1.5 \
  bash ./video-demo/deploy-demo.sh
```

Script `deploy-demo.sh` chỉ:

1. Kiểm tra namespace, guest auth, NodePort `31001`, Invoker Ready và API.
2. Tạo/update toàn bộ action Group 4.
3. Gọi thử từng action.
4. Lưu guest auth trong `video-demo/evidence/.guest-auth`.
5. Thu snapshot node/pod/log/resource.

Nó không gọi Helm, không đổi chart, không đổi K3s và không sửa PVC.

## 8. Quy trình chạy demo

### Cảnh 1 - Topology

```bash
kubectl get nodes -o wide
kubectl get nodes --show-labels
kubectl -n openwhisk get pods -o wide
```

Mục tiêu hình ảnh:

- thấy `c1-server`, `c1-agent1`, `c1-agent2`, `c1-agent3`;
- thấy Invoker replicas trên nhiều node;
- thấy Controller, Kafka, CouchDB, ZooKeeper;
- thấy action pod được tạo trong namespace `openwhisk`.

### Cảnh 2 - Python action

```bash
API_HOST=192.168.1.5 bash ./video-demo/run-demo.sh smoke
```

Kết quả cần chỉ ra:

- HTTP 200;
- `group = Group 4`;
- `action = Group4_Action2`;
- có `activation_id`;
- có `action_pod`;
- có `duration_ms`.

Đối chiếu tên `action_pod` với:

```bash
kubectl -n openwhisk get pods -o wide
```

### Cảnh 3 - Node.js action

```bash
curl -sk \
  -u "$(cat video-demo/evidence/.guest-auth)" \
  -H 'Content-Type: application/json' \
  -X POST \
  'https://192.168.1.5:31001/api/v1/namespaces/_/actions/node-demo?blocking=true&result=true' \
  -d '{}'
```

Kết quả phải có:

```json
{
  "status": "ok",
  "group": "Group 4",
  "runtime": "nodejs",
  "version": "..."
}
```

### Cảnh 4 - Concurrency

```bash
API_HOST=192.168.1.5 bash ./video-demo/run-demo.sh concurrency 2
API_HOST=192.168.1.5 bash ./video-demo/run-demo.sh concurrency 8
API_HOST=192.168.1.5 bash ./video-demo/run-demo.sh concurrency 12
```

Mỗi lần chạy tạo `summary.json` và `metrics.csv` trong evidence. Các metric
custom gồm tổng request, successful request, failed request và latency average,
P90, P95. K6 chỉ thu thập và xuất số liệu; không tự kết luận hệ thống đạt
ngưỡng hiệu năng.

Hoặc chạy trực tiếp K6:

```bash
k6 run \
  -e OW_API=https://192.168.1.5:31001 \
  -e OW_AUTH="$(cat video-demo/evidence/.guest-auth)" \
  -e SCENARIO=concurrency \
  -e RATE=8 \
  -e DURATION=60s \
  --summary-export video-demo/evidence/k6-summary.json \
  --out csv=video-demo/evidence/k6-metrics.csv \
  video-demo/tests/video-load.js
```

K6 gửi workload theo tỷ lệ:

```text
60% Group4_Action1
30% Group4_Action2
10% Group4_Action3
```

Mục tiêu không phải tuyên bố 8 RPS là giới hạn tuyệt đối. Mục tiêu là quay
được request đồng thời, action pod, CPU/RAM và latency để chứng minh pipeline
Serverless hoạt động.

Trong Grafana cần quay cùng thời điểm:

- CPU/RAM 4 node;
- CPU/RAM Invoker;
- số pod OpenWhisk Running/Pending;
- action pod tạo mới hoặc được reuse;
- pod restart/OOM;
- latency/error rate của K6;
- node Ready và event Kubernetes.

### Cảnh 5 - Invoker rescheduling

```bash
API_HOST=192.168.1.5 \
  FAILOVER_MODE=invoker \
  bash ./video-demo/failover-demo.sh
```

Flow:

1. Chọn Invoker đang chạy trên agent.
2. Lưu tên, UID, node và Ready state của Invoker cũ.
3. Đăng ký trap uncordon ngay sau khi xác định node.
4. Cordon node đó để scheduler không đặt pod mới vào.
5. Xóa Invoker pod cũ.
6. Xác nhận UID cũ biến mất.
7. StatefulSet/Deployment tạo pod replacement có UID mới.
8. Chỉ chấp nhận replacement Running, Ready và nằm trên node khác.
9. Ghi recovery time.
10. Gọi `Group4_Action2`.
11. Gửi 8 request `Group4_Action2` song song.
12. Xác nhận 8/8 HTTP 200.
13. Luôn uncordon node cũ.

Đây là bằng chứng:

```text
Invoker pod recovery
Kubernetes rescheduling
action availability sau lỗi Invoker
```

Đây **không phải** bằng chứng hoàn chỉnh cho:

```text
CouchDB data HA
Kafka data HA
Mất toàn bộ node stateful mà không gián đoạn
```

Lý do là storage hiện dùng K3s `local-path`, PV gắn với node nơi volume được
provision. Muốn tuyên bố data HA cần Longhorn, NFS, Ceph hoặc storage phân tán
khác và một bài test riêng.

## 9. Monitoring và evidence

### Evidence filesystem

Chạy:

```bash
PROMETHEUS_URL=http://<private-prometheus>:9090 \
  bash ./video-demo/collect-evidence.sh
```

Mỗi lần tạo một thư mục timestamp dưới:

```text
video-demo/evidence/
```

Có thể chứa:

- `nodes.txt`
- `node-ip.txt`
- `nodes-labels.txt`
- `node-resources.txt`
- `pods.txt`
- `pods-all.txt`
- `pod-placement.txt`
- `pod-restarts.txt`
- `pvc.txt`
- `events.txt`
- `top-nodes.txt`
- `top-pods.txt`
- `invokers.txt`
- log từng Invoker
- kết quả Prometheus query
- log failover
- JSON/CSV K6 của các mức 2/8/12 RPS

Guest authentication và secret không được copy vào evidence snapshot.

### Prometheus/Grafana panels

Dùng query trong [monitoring/prometheus-queries.md](monitoring/prometheus-queries.md):

```promql
sum by (instance) (
  rate(container_cpu_usage_seconds_total{container!="",container!="POD"}[5m])
)

sum by (namespace,pod) (
  container_memory_working_set_bytes{namespace="openwhisk"}
)

kube_pod_container_status_restarts_total{namespace="openwhisk"}

kube_node_status_condition
```

Dashboard nên có marker thời gian:

```text
T0: bắt đầu concurrency
T1: peak request
T2: cordon/delete Invoker
T3: Invoker mới Running
T4: 8/8 request sau failover
```

## Troubleshooting

### K6 không chạy hoặc API không sẵn sàng

```bash
API_HOST=192.168.1.5 bash ./video-demo/run-demo.sh health
k6 version
```

K6 nên chạy ngoài cluster. Nếu health fail, kiểm tra NodePort `31001`, route
private VPC và certificate tự ký.

### Không tìm thấy Invoker replacement

```bash
kubectl -n openwhisk get pods -l name=owdev-invoker -o wide
kubectl get nodes --show-labels
kubectl -n openwhisk get events --sort-by=.lastTimestamp
```

Phải còn một node khác Ready và không bị cordon. Script không coi Invoker
replica còn lại là replacement.

### Prometheus không có số liệu

Đặt `PROMETHEUS_URL` tới Prometheus có thể truy cập từ máy chạy `kubectl` hoặc
port-forward service Prometheus. Nếu không đặt URL, evidence sẽ ghi rõ rằng
Prometheus API snapshot chưa được thu thập, không bịa số liệu thay thế.

### Giới hạn failover

`FAILOVER_MODE=invoker` kiểm tra Invoker pod recovery. `FAILOVER_MODE=node`
thực hiện drain có kiểm soát và có thể ảnh hưởng pod stateful/PVC
`local-path`; không dùng kết quả này để tuyên bố full data HA.

## 10. Kết quả mong đợi

### Hạ tầng

- 4/4 node Ready.
- OpenWhisk core pod Running.
- 2 Invoker replica Running.
- NodePort `31001` truy cập được từ máy test.

### Action

- Python `Group4_Action1/2/3` trả HTTP 200.
- Node.js `node-demo` trả HTTP 200.
- Response có Group 4 và activation metadata.

### Concurrency

- Nhiều request được xử lý trong cùng khoảng thời gian.
- Có thể quan sát nhiều action pod hoặc container slot được reuse.
- CPU/RAM tăng tương ứng với workload.
- Không có OOM/restart ngoài dự kiến.

### Failover

- Invoker pod cũ bị xóa.
- Invoker pod mới lên node khác.
- `Group4_Action2` vẫn trả HTTP 200.
- 8 request sau failover đều trả HTTP 200.

## 11. Những điều không nên nói quá trong báo cáo

Không nên viết:

```text
Hệ thống đã có full high availability cho toàn bộ dữ liệu.
Cluster chịu mất bất kỳ node nào mà không ảnh hưởng.
8 RPS là năng lực tối đa tuyệt đối.
16 action container luôn được tạo sẵn.
```

Nên viết chính xác:

```text
Hệ thống chứng minh được Invoker/action rescheduling trên K3s.
Server vẫn tham gia chạy workload để phù hợp ngân sách RAM.
Capacity action được tính theo memory slot nhưng container tạo theo demand.
Storage local-path còn là giới hạn đối với data failover.
Concurrency cần được đánh giá cùng CPU/RAM/latency thực tế.
```

## 12. Checklist trước khi quay

- [ ] 4 VPS đúng IP và đúng role.
- [ ] Private firewall mở đúng port.
- [ ] 4 node Ready.
- [ ] Pod-to-pod xuyên node OK.
- [ ] OpenWhisk NodePort `31001` OK.
- [ ] `Group4_Action1/2/3` đã deploy.
- [ ] `node-demo` trả được Node.js response.
- [ ] `video-demo/evidence/.guest-auth` tồn tại và không commit.
- [ ] Prometheus/Grafana truy cập được.
- [ ] Đã quay topology trước khi tạo tải.
- [ ] Đã thu evidence trước và sau concurrency.
- [ ] Đã thu evidence trước và sau failover.
- [ ] Đã uncordon node sau bài failover.
- [ ] Báo cáo ghi rõ giới hạn `local-path`.

## 13. Tóm tắt một câu cho video

> Group 4 triển khai Apache OpenWhisk trên K3s private VPC gồm một server
> control-plane có thể chạy workload và ba agent worker; request đi qua
> Controller, Kafka và Invoker để tạo runtime Python/Node.js cách ly, sau đó
> workload đồng thời và lỗi Invoker được kiểm chứng bằng K6, Kubernetes và
> Prometheus/Grafana.
