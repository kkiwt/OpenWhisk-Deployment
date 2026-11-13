# OpenWhisk Deployment trên K3s

Repository này triển khai OpenWhisk trên cụm **K3s thật**, chạy qua mạng
Tailscale/private network, sau đó cung cấp Gateway, Dashboard telemetry và K6
load test.

> **Luồng hiện hành là K3s.** Phần k3d/Docker cũ đã được chuyển vào
> [`legacy-k3d/`](legacy-k3d/) và chỉ dùng để tham khảo hoặc tái hiện thí nghiệm
> cũ.

## 1. Kiến trúc tổng thể

```text
                         Tailscale/private network

 Windows host
   |-- kubectl / Helm / k9s
   |-- K6 hoặc trình duyệt
   |
   +--> Gateway :8080 -------------------------------+
   |                                                  |
   +--> Dashboard :9000 <--- publish_result <--- OpenWhisk actions
                                                      |
 Gateway -> NodePort :31001 -> K3s server/agents -> OpenWhisk
                                                   -> A1/A2/A3
```

### Topology K3s mục tiêu

| Node | RAM | Vai trò |
|---|---:|---|
| K3s server | 4 GB | Control plane và được phép chạy workload |
| K3s agent 1 | 2.5 GB | Workload |
| K3s agent 2 | 2.5 GB | Workload |

Tổng RAM danh nghĩa khoảng 9 GB nhưng không phải toàn bộ dành cho action. K3s,
containerd, OpenWhisk core, Kafka/CouchDB, Tailscale và hệ điều hành đều cần
RAM. Cấu hình trong repository đã giảm `containerPool.userMemory`, giới hạn
resource và cho phép server cùng chạy workload để tránh lãng phí node 4 GB.

## 2. Cấu trúc repository

| Thư mục | Chức năng | Bắt đầu từ |
|---|---|---|
| [`k3s-cloud-openwhisk-deployment/`](k3s-cloud-openwhisk-deployment/) | Cài K3s/OpenWhisk, actions và test K3s | [`README.md`](k3s-cloud-openwhisk-deployment/README.md) |
| [`openwhisk-gateway/`](openwhisk-gateway/) | Gateway FastAPI, load balancing và admin API | [`run-linux.sh`](openwhisk-gateway/run-linux.sh) |
| [`openwhisk-dashboard/`](openwhisk-dashboard/) | Nhận telemetry và hiển thị Dashboard | [`README.md`](openwhisk-dashboard/README.md) |
| [`k6/`](k6/) | K6 scenario, installer và load runner | [`run-load.sh`](k6/run-load.sh) |
| [`legacy-k3d/`](legacy-k3d/) | Luồng cũ dùng Docker/k3d | [`README.md`](legacy-k3d/README.md) |

Các file cấu hình local như `.env`, `.wskprops.*`, `join.env` và credential
không được commit.

## 3. Quyết định quan trọng

- **K3s là luồng chính**, không cần Docker/k3d trên node Linux mới.
- K3s dùng **containerd**, không dùng Docker socket.
- K3s server **không bị taint `NoSchedule` mặc định**.
- Cả server và hai agent đều có label `openwhisk-role=invoker`.
- Các node cluster giao tiếp qua `tailscale0`.
- OpenWhisk được cấu hình với Kubernetes container factory.
- Dashboard chỉ nhận telemetry thật; không tự tạo benchmark.
- K6 chỉ tạo traffic; kết quả K6 nằm trong `k6/results/`, không tự nhập vào Dashboard.
- Gateway có endpoint admin, vì vậy chỉ bind trong mạng tin cậy.
- Dashboard dùng một worker và buffer RAM; restart sẽ mất record.

## 4. Chuẩn bị môi trường

### 4.1 Windows host

Windows không chạy K3s node native trong thiết kế này. Windows dùng để:

- SSH vào Ubuntu VM.
- Chạy `kubectl`, Helm và K9s.
- Chạy K6.
- Chạy Gateway/Dashboard nếu máy có Python và các VM truy cập được.

PowerShell:

```powershell
cd k3s-cloud-openwhisk-deployment
.\scripts\00-install-windows-prerequisites.ps1
.\scripts\05-install-k9s.ps1
```

Script Windows cài Git, `kubectl`, Helm và Tailscale qua `winget`. Nếu máy chưa
có `winget`, cài App Installer từ Microsoft Store trước.

### 4.2 Ubuntu VM

Chạy trên **cả server và hai agent**:

```bash
cd k3s-cloud-openwhisk-deployment
sudo bash scripts/00-install-linux-prerequisites.sh
sudo bash scripts/05-install-k9s.sh
```

Bootstrap Linux cài các package cần cho K3s/OpenWhisk, `kubectl`, Helm và
OpenWhisk CLI `wsk`. Tailscale được cài và đăng nhập ở bước riêng.

### 4.3 Mạng

Đảm bảo các máy cùng Tailscale tailnet hoặc cùng private network. Tối thiểu:

- K3s API: TCP `6443`.
- Kubelet: TCP `10250`.
- Flannel VXLAN trong tunnel: UDP `8472`.
- OpenWhisk NodePort: TCP `31001`.
- Gateway: TCP `8080`.
- Dashboard: TCP `9000`.

Không mở `6443`, `31001`, `8080` hoặc `9000` công khai nếu không cần.

## 5. Cài cụm K3s

### Bước 1: Tailscale

Trên từng Ubuntu VM, đăng nhập cùng tailnet. Không ghi auth key vào Git:

```bash
cd k3s-cloud-openwhisk-deployment
export TS_AUTHKEY='tskey-auth-...'
TS_HOSTNAME=k3s-cloud-master bash scripts/01-install-tailscale.sh
```

Đổi hostname cho agent:

```bash
TS_HOSTNAME=k3s-cloud-agent-1 bash scripts/01-install-tailscale.sh
TS_HOSTNAME=k3s-cloud-agent-2 bash scripts/01-install-tailscale.sh
```

Thu hồi auth key nếu đã chia sẻ nhầm; nên dùng key có tag và ACL giới hạn.

### Bước 2: K3s server

Trên server 4 GB:

```bash
cd k3s-cloud-openwhisk-deployment
sudo -E bash scripts/02-setup-k3s-master.sh
```

Script sẽ:

- Bind K3s vào IP Tailscale.
- Dùng `tailscale0` cho Flannel.
- Không taint server mặc định.
- Gắn label `openwhisk-role=invoker`.
- Sinh file `join.env` chứa token, phải bảo vệ như secret.

Kiểm tra:

```bash
sudo kubectl get nodes -o wide
sudo cat /etc/rancher/k3s/k3s.yaml
```

Nếu quản trị từ Windows, copy kubeconfig bằng kênh an toàn rồi đổi `server`
thành địa chỉ Tailscale của server. Không commit kubeconfig.

### Bước 3: K3s agents

Trên mỗi agent, chép `join.env` an toàn hoặc truyền biến tương đương:

```bash
cd k3s-cloud-openwhisk-deployment
sudo -E NODE_NAME=k3s-cloud-agent-1 bash scripts/03-setup-k3s-worker.sh
```

Agent thứ hai:

```bash
sudo -E NODE_NAME=k3s-cloud-agent-2 bash scripts/03-setup-k3s-worker.sh
```

### Bước 4: Verify cluster

Trên server:

```bash
cd k3s-cloud-openwhisk-deployment
bash scripts/04-verify-cluster.sh
```

Verify phải thấy ba node `Ready`, đủ label workload, pod networking hoạt động
và không có taint chặn scheduling trên server.

Theo dõi trực tiếp:

```bash
k9s
```

K9s dùng kubeconfig hiện tại; kiểm tra trước bằng:

```bash
kubectl get nodes
kubectl get pods -A
```

### Bước 5: Cài OpenWhisk

Chỉ chạy sau khi đủ ba node:

```bash
cd k3s-cloud-openwhisk-deployment
bash openwhisk/install-openwhisk.sh
```

Script cài chart, áp dụng resource policy và kiểm tra các pod core. Có thể dùng
lock file Golden nếu môi trường yêu cầu:

```bash
GOLDEN_LOCK=/path/to/golden.lock \
  bash openwhisk/install-openwhisk.sh
```

Resource policy nằm tại
[`k3s-resource-policy.yaml`](k3s-cloud-openwhisk-deployment/k3s-resource-policy.yaml).
Policy này bảo vệ RAM bằng `LimitRange` và `ResourceQuota`, nhưng vẫn phải theo
dõi `kubectl top nodes` sau khi deploy thật.

## 6. Chạy OpenWhisk Dashboard

Dashboard nhận dữ liệu từ actions, không phải từ file K6. Đọc hướng dẫn đầy đủ
tại [`openwhisk-dashboard/README.md`](openwhisk-dashboard/README.md).

### Linux

```bash
cd openwhisk-dashboard
bash install-linux.sh
bash run-linux.sh
```

### Windows

```powershell
cd openwhisk-dashboard
.\install-windows.ps1
.\run-windows.ps1
```

Sau khi cài, sửa `.env`:

```dotenv
DASHBOARD_BIND_HOST=0.0.0.0
DASHBOARD_PORT=9000
DASHBOARD_URL=http://<DASHBOARD-TAILSCALE-IP>:9000
CLUSTERS="c1 c2 c3"
SAMPLE_RATE=0.05
INGEST_TOKEN=
```

Kiểm tra:

```bash
curl -s http://<DASHBOARD-TAILSCALE-IP>:9000/health
curl -s 'http://<DASHBOARD-TAILSCALE-IP>:9000/api/stats?window=60'
```

Không dùng `127.0.0.1` làm `DASHBOARD_URL` nếu action chạy trong cluster.

## 7. Deploy telemetry actions

Action telemetry nằm trong [`openwhisk-dashboard/actions/`](openwhisk-dashboard/actions/).
Mỗi cluster cần file credential:

```text
~/.wskprops.c1
~/.wskprops.c2
~/.wskprops.c3
```

Chỉ tạo file cho cluster đã sẵn sàng. Sau đó:

```bash
cd openwhisk-dashboard
bash deploy-openwhisk-actions.sh
```

Deploy helper sẽ:

1. Đọc cấu hình từ `.env`.
2. Gọi Dashboard `/health`.
3. Deploy `publish_result`.
4. Deploy A1, A2, A3.
5. Gắn cluster name, sample rate và ingest token.

Nếu chỉ deploy c2:

```bash
CLUSTERS="c2" bash deploy-openwhisk-actions.sh
```

Kiểm tra một activation thật:

```bash
WSK_CONFIG_FILE="$HOME/.wskprops.c2" \
  wsk -i action invoke A1 --blocking --result --param SAMPLE_RATE 1

curl -s 'http://<DASHBOARD-TAILSCALE-IP>:9000/api/recent?limit=5&cluster=c2'
```

`SAMPLE_RATE=1` chỉ nên dùng cho smoke test ngắn. Benchmark bình thường dùng
sample rate thấp hơn để giảm traffic telemetry.

## 8. Chạy Gateway

Gateway đọc cấu hình cluster từ `openwhisk-gateway/.env`.

### Linux

```bash
cd openwhisk-gateway
bash install-linux.sh
bash run-linux.sh
```

### Windows

```powershell
cd openwhisk-gateway
.\install-windows.ps1
.\run-windows.ps1
```

Gateway mặc định lắng nghe port `8080`. Cấu hình mẫu:

```dotenv
ACTIVE=c1,c2,c3
GATEWAY_BIND_HOST=0.0.0.0
GATEWAY_PORT=8080
CLUSTER_C1_URL=https://<C1-TAILSCALE-IP>:31001
CLUSTER_C1_AUTH_B64=<base64-auth-c1>
CLUSTER_C2_URL=https://<C2-TAILSCALE-IP>:31001
CLUSTER_C2_AUTH_B64=<base64-auth-c2>
CLUSTER_C3_URL=https://<C3-TAILSCALE-IP>:31001
CLUSTER_C3_AUTH_B64=<base64-auth-c3>
```

Kiểm tra:

```bash
curl -s http://<GATEWAY-TAILSCALE-IP>:8080/admin/clusters
```

Endpoint `/admin/*` hiện không có authentication. Chỉ bind Gateway trong mạng
Tailscale/private network.

## 9. Chạy K6

K6 gửi request tới Gateway:

```text
POST /invoke/A1
POST /invoke/A2
POST /invoke/A3
```

### Cài K6

Linux Debian/Ubuntu:

```bash
bash k6/install-linux.sh
```

Windows PowerShell:

```powershell
.\k6\install-windows.ps1
```

### Smoke/load test nhanh

Linux:

```bash
GATEWAY_URL=http://<GATEWAY-TAILSCALE-IP>:8080 \
  bash k6/run-load.sh 10 30s
```

Windows:

```powershell
.\k6\run-load.ps1 `
  -Rate 10 `
  -Duration 30s `
  -GatewayUrl http://<GATEWAY-TAILSCALE-IP>:8080
```

Kết quả được lưu trong `k6/results/quick_<timestamp>/k6.json`.

### Scenario trực tiếp

Có thể chạy trực tiếp K6:

```bash
k6 run \
  -e GATEWAY_URL=http://<GATEWAY-TAILSCALE-IP>:8080 \
  -e RATE=50 \
  -e DURATION=5m \
  k6/load.js
```

Chạy thử không gửi request:

```bash
k6 run \
  -e DRY_RUN=1 \
  -e RATE=1 \
  -e DURATION=5s \
  -e GATEWAY_URL=http://<GATEWAY-TAILSCALE-IP>:8080 \
  k6/load.js
```

### Runner protocol đầy đủ

`run_exp.sh` và `run_series.sh` dành cho protocol đo nhiều lượt, có warm-up,
cooldown, median và kiểm tra CPU host:

```bash
GATEWAY_URL=http://<GATEWAY-TAILSCALE-IP>:8080 \
  bash k6/run_exp.sh e1b_rr 50

GATEWAY_URL=http://<GATEWAY-TAILSCALE-IP>:8080 \
  bash k6/run_series.sh e1b_rr 50
```

Lưu ý: hai runner protocol cũ thu thập `docker stats`, nên phù hợp với môi
trường có Docker. K3s production dùng containerd; dùng `run-load.sh` cho smoke
test K3s hoặc thay phần collector nếu cần đo resource containerd.

## 10. Các endpoint chính

### Dashboard

| Method | Endpoint | Mục đích |
|---|---|---|
| `GET` | `:9000/` | Giao diện |
| `GET` | `:9000/health` | Health check |
| `POST` | `:9000/ingest` | Nhận telemetry |
| `GET` | `:9000/api/stats?window=60` | Thống kê |
| `GET` | `:9000/api/recent?limit=25` | Record gần nhất |
| `GET` | `:9000/api/export.csv` | Export record |

### Gateway

| Method | Endpoint | Mục đích |
|---|---|---|
| `POST` | `:8080/invoke/A1` | Gọi A1 qua Gateway |
| `POST` | `:8080/invoke/A2` | Gọi A2 qua Gateway |
| `POST` | `:8080/invoke/A3` | Gọi A3 qua Gateway |
| `GET` | `:8080/admin/clusters` | Xem trạng thái cluster |

## 11. Kiểm thử

Dashboard:

```bash
cd openwhisk-dashboard
source .venv/bin/activate
python -m pip install pytest httpx
python -m pytest -q tests/test_dashboard.py tests/test_actions.py \
  --import-mode=importlib
```

K3s:

```bash
cd k3s-cloud-openwhisk-deployment
bash scripts/04-verify-cluster.sh
```

Kiểm tra Python compile:

```bash
python -m py_compile \
  openwhisk-dashboard/dashboard.py \
  openwhisk-gateway/gateway.py
```

Không dùng dữ liệu gửi thủ công hoặc test sender để báo cáo benchmark. Số liệu
benchmark phải đến từ K6 → Gateway → OpenWhisk thật.

## 12. Resource và giới hạn

Các giới hạn chính hiện tại:

- `containerPool.userMemory=1024m`.
- LimitRange đặt request/default thấp để bảo vệ node nhỏ.
- ResourceQuota giới hạn tổng request/limit và số pod.
- Dashboard giữ tối đa 5.000 record trong RAM.
- Dashboard payload tối đa 8 KiB.
- OpenWhisk action mặc định được sample 5%.

Nếu pod bị `Pending`, kiểm tra:

```bash
kubectl get pods -A
kubectl describe pod -n openwhisk <pod-name>
kubectl describe resourcequota -A
kubectl top nodes
```

Không tự tăng quota hoặc memory action khi chưa kiểm tra RAM thực tế. Server 4 GB
cần giữ đủ vùng an toàn cho control plane.

## 13. Troubleshooting

### Worker không join được

```bash
curl -k https://<SERVER-TAILSCALE-IP>:6443/ping
journalctl -u k3s-agent -n 100 --no-pager
tailscale status
```

Kiểm tra token, ACL Tailscale, IP Tailscale và hostname node.

### Node Ready nhưng pod cross-node lỗi

Kiểm tra:

```bash
ip addr show tailscale0
kubectl get nodes -o wide
kubectl get pods -A -o wide
```

Hai node phải dùng đúng interface Tailscale/Flannel. Kiểm tra firewall không
chặn traffic trong `tailscale0`.

### Dashboard không nhận dữ liệu

1. Kiểm tra Dashboard:

   ```bash
   curl -s http://<DASHBOARD-IP>:9000/health
   ```

2. Từ node OpenWhisk kiểm tra cùng URL.
3. Kiểm tra `DASHBOARD_URL` không dùng localhost.
4. Kiểm tra action đã deploy lại sau khi đổi `.env`.
5. Nếu có token, kiểm tra `INGEST_TOKEN` hai bên giống nhau.

### Gateway báo cluster down

```bash
curl -s http://<GATEWAY-IP>:8080/admin/clusters
kubectl get svc -A
curl -k https://<CLUSTER-IP>:31001
```

Kiểm tra NodePort, auth Base64, certificate tự ký và route Tailscale.

### K6 có lỗi hoặc latency cao

- Chạy smoke test rate thấp trước.
- Kiểm tra Gateway health và OpenWhisk core pod.
- Kiểm tra `dropped_iterations`, P95 và error rate trong `k6.json`.
- Không chạy nhiều workload cùng lúc trên server 4 GB.
- Đảm bảo action đã được warm-up nếu đang đo cold-start khác với warm path.

### K9s không thấy cluster

```bash
kubectl config current-context
kubectl get nodes
k9s
```

K9s dùng kubeconfig của shell hiện tại. Trên Windows, đặt `KUBECONFIG` tới file
kubeconfig đã copy an toàn từ K3s server.

## 14. Bảo mật

- Không commit `.env`, `.wskprops.*`, `join.env`, kubeconfig hoặc Tailscale key.
- Thu hồi credential nếu đã dán vào chat/log.
- Chỉ dùng Tailscale/private network cho `6443`, `31001`, `8080`, `9000`.
- Bật `INGEST_TOKEN` nếu Dashboard có thể bị truy cập bởi máy không tin cậy.
- Gateway admin API chưa có auth; không expose public.
- Không ghi OpenWhisk auth vào source code, K6 result hoặc README.
- Dùng `chmod 600` cho `.env`, `.wskprops.*`, `join.env` trên Linux.

## 15. Legacy k3d

Phần cũ nằm tại [`legacy-k3d/`](legacy-k3d/):

- [`legacy-k3d/golden-config-final/`](legacy-k3d/golden-config-final/):
  installer/Golden Config cũ.
- [`legacy-k3d/chaos/`](legacy-k3d/chaos/): chaos experiment dùng Docker/k3d.

Không dùng các script legacy cho cụm K3s mới. Đặc biệt, `docker stop`, tên node
k3d và Docker socket không áp dụng cho K3s/containerd.

## 16. Thứ tự chạy nhanh

```text
1. Windows: cài kubectl/Helm/K9s hoặc chuẩn bị Ubuntu VM.
2. Ubuntu: cài prerequisite Linux trên cả 3 VM.
3. Cài Tailscale và xác nhận các VM nhìn thấy nhau.
4. Cài K3s server.
5. Join hai K3s agent.
6. Verify ba node Ready và có label workload.
7. Cài OpenWhisk.
8. Chạy Dashboard.
9. Deploy A1/A2/A3 + publish_result.
10. Chạy Gateway.
11. Chạy K6 smoke test.
12. Mới bắt đầu benchmark hoặc chaos experiment.
```

Tài liệu chi tiết theo thành phần:

- [K3s/OpenWhisk deployment](k3s-cloud-openwhisk-deployment/README.md)
- [K3s walkthrough](k3s-cloud-openwhisk-deployment/HUONG-DAN-CHAY-TU-DAU.md)
- [Dashboard guide](openwhisk-dashboard/README.md)
- [Gateway source and scripts](openwhisk-gateway/)
- [K6 scripts](k6/)
- [Legacy k3d guide](legacy-k3d/README.md)
