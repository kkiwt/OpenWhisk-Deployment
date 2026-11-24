# Apache OpenWhisk trên K3s Private VPC

Repository thống nhất cho bài triển khai Apache OpenWhisk trên cụm K3s private VPC gồm 1 server và 3 agent.

Cấu hình chính được đối chiếu với snapshot `kubectl` và tài liệu báo cáo đã thu thập; repository không thay đổi cluster đang chạy và không khẳng định trạng thái live hiện tại.

## Thông tin đồ án & Nhóm thực hiện

- **Đề tài:** Triển khai Apache OpenWhisk (FaaS) trên cụm K3s
- **Môn học:** NT533.R11 – Hệ tính toán phân bố (Khoa Mạng máy tính và Truyền thông – UIT, ĐHQG-HCM)
- **Giảng viên hướng dẫn:** ThS. Bùi Thanh Bình
- **Thời gian thực hiện:** 19/10/2026 – 24/11/2026
- **Tài nguyên đính kèm:** [Slide & Video Demo (Google Drive)](https://drive.google.com/drive/folders/1p7qtjHbbh17_ExblE2Q9gG1A46oyFwal?usp=sharing)

### Thành viên Nhóm 4

| STT | Họ và tên | MSSV | Vai trò |
|---:|---|---|---|
| 1 | Nguyễn Tuấn Kiệt | `24520907` | Trưởng nhóm |
| 2 | Võ Minh Kiệt | `24520918` | Thành viên |
| 3 | Trương Tấn Kiệt | `24520917` | Thành viên |

---

## Kiến trúc triển khai

```text
Client
  -> NGINX Edge Gateway (:8081) [tùy chọn] / OpenWhisk NodePort (:31001)
  -> OpenWhisk Controller
  -> Kafka
  -> Invoker
  -> Kubernetes action pod
  -> Python/Node.js runtime
  -> HTTP response
```

| Node | Private IP ghi nhận | Vai trò |
|---|---:|---|
| `server` | `192.168.1.5` | K3s control-plane và workload |
| `agent1` | `192.168.1.102` | K3s worker/Invoker |
| `agent2` | `192.168.1.46` | K3s worker/Invoker |
| `agent3` | `192.168.1.242` | K3s worker/Invoker |



## Cấu hình chính

| Thành phần | Giá trị repository |
|---|---|
| Release/Namespace | `owdev` / `openwhisk` |
| Invoker replicas mặc định | 2 |
| Invoker limit/request | 1024Mi / 512Mi |
| Invoker CPU request/limit | 500m / 500m |
| Controller limit/request | 1280Mi / 768Mi |
| Controller CPU request/limit | 500m / 500m |
| Kafka limit/request | 1024Mi / 512Mi |
| CouchDB limit/request | 640Mi / 384Mi |
| ZooKeeper limit/request | 384Mi / 128Mi |
| Action memory default | 128Mi |
| Invoker userMemory pool | 1024Mi |
| HPA API | `autoscaling/v2` |
| HPA target | CPU average utilization 30% |
| HPA replicas | min 2, max 3 |
| OpenWhisk NodePort | 31001 |

`openwhisk/custom-values.yaml` giữ chart values; `openwhisk/install-openwhisk.sh`
áp resource sau Helm vì các resource core không hoàn toàn được chart values
điều khiển.

## Cấu trúc

```text
scripts/                 Cài và kiểm tra K3s
openwhisk/               OpenWhisk Helm values và installer
actions/                 Source và deploy action
tests/                   Validation, chaos và k6
k6/                      Script benchmark
video-demo/              Kịch bản, evidence và failover
invoker-hpa.yaml         HPA chính thức của Invoker
k3s-resource-policy.yaml LimitRange và ResourceQuota namespace
```

Các thư mục backup, bản sao dự án và file secret đã bị loại khỏi repository.
Chart upstream không được commit khi .gitignore chặn thư mục clone; installer
sẽ clone commit ghim `146d24925564e2871f4cc6506d4e92098968457d`.

## Yêu cầu

- Ubuntu 22.04.
- Cùng private VPC/security group.
- Quyền sudo trên server và agent.
- Route private tới cụm.
- `kubectl`, `helm`, `curl`, `git`, `python3`.
- k6 trên máy chạy benchmark.

Cổng private:

| Cổng | Giao thức | Mục đích |
|---:|---|---|
| 6443 | TCP | Kubernetes API |
| 10250 | TCP | Kubelet |
| 8472 | UDP | Flannel VXLAN |
| 31001 | TCP | OpenWhisk HTTPS |

## Triển khai

### 1. Chuẩn bị cả 4 node

```bash
./scripts/00-install-linux-prerequisites.sh

sudo VPC_CIDR=<vpc-cidr> NODE_IP=<private-ip> \
  FLANNEL_IFACE=<vpc-interface> \
  ./scripts/01-setup-vpc-network.sh
```

### 2. Khởi tạo server

```bash
sudo NODE_IP=<server-private-ip> \
  FLANNEL_IFACE=<vpc-interface> \
  NODE_NAME=c1-server \
  ./scripts/02-setup-k3s-master.sh
```


### 3. Join agent

```bash
sudo NODE_IP=<agent-private-ip> \
  FLANNEL_IFACE=<vpc-interface> \
  NODE_NAME=c1-agent1 \
  K3S_URL=https://<server-private-ip>:6443 \
  K3S_TOKEN='<token>' \
  ./scripts/03-setup-k3s-worker.sh
```

Thay `c1-agent1` bằng `c1-agent2` và `c1-agent3`.

### 4. Kiểm tra cụm

```bash
EXPECTED_NODES=4 EXPECTED_INVOKER_NODES=4 \
  ./scripts/04-verify-cluster.sh
```

### 5. Cài OpenWhisk

```bash
API_HOST=<node-private-ip> INVOKER_REPLICAS=2 \
  ./openwhisk/install-openwhisk.sh
```

### 6. Áp HPA chính thức

```bash
kubectl apply -f invoker-hpa.yaml
kubectl -n openwhisk get hpa owdev-invoker-hpa
kubectl -n openwhisk describe hpa owdev-invoker-hpa
```

HPA quản lý `StatefulSet/owdev-invoker`; không scale namespace hay Controller.
Khả năng scale tối đa 3 replica phụ thuộc đủ node, Metrics Server và CPU
request của Invoker.

### 7. Deploy action

```bash
API_HOST=<node-private-ip> CLUSTER_NAME=cloud \
  ./actions/deploy-actions.sh
```

## Validation

```bash
API_HOST=<node-private-ip> \
  ./tests/validate-openwhisk.sh
```

Test failover chỉ chạy trên cluster thử nghiệm vì có cordon/drain:

```bash
API_HOST=<node-private-ip> RUN_NODE_FAILOVER=1 \
  ./tests/validate-openwhisk.sh
```

Benchmark:

```bash
OW_AUTH="$(kubectl -n openwhisk get secret owdev-whisk.auth \
  -o jsonpath='{.data.guest}' | base64 -d)"

k6 run \
  -e OW_API=https://<node-private-ip>:31001 \
  -e OW_AUTH="$OW_AUTH" \
  tests/load-test.js
```

## Gateway Nginx

Gateway Nginx dùng `least_conn`, upstream tới NodePort 31001 trên server/agent,
timeout đọc 65 giây và retry tối đa 2 upstream. Cấu hình mẫu:

```bash
gateway/nginx-upstream.conf
```

File auth sinh ra bởi deployment không được commit. Chỉ bind Gateway trên
private network vì API đăng ký cluster không có xác thực.

## Storage và HA

PersistentVolume mặc định là `local-path`. Đây là storage node-local và không
tự nhân bản dữ liệu CouchDB/Kafka/ZooKeeper. Flow hiện tại được xem là
Invoker/action rescheduling, không tự động chứng minh full data HA.

## Bảo mật

Không commit:

- K3S_TOKEN hoặc `join.env`
- Guest auth hoặc basic auth
- API key
- Private key, certificate và kubeconfig
- File `.env` sinh ra lúc chạy


