# OpenWhisk Dashboard

Dashboard này nhận telemetry thật từ các action OpenWhisk, lưu tạm trong RAM và
hiển thị thống kê theo cluster/action. Dashboard **không tạo traffic** và không
đọc trực tiếp file kết quả K6.

## 1. Kiến trúc và luồng dữ liệu

```text
K6 (k6/)
  -> Gateway (openwhisk-gateway/:8080)
  -> OpenWhisk A1/A2/A3 trên K3s
  -> publish_result
  -> POST /ingest (:9000)
  -> Dashboard UI/API
```

Vai trò của các thư mục:

| Thư mục | Vai trò |
|---|---|
| `openwhisk-dashboard/` | Nhận và hiển thị telemetry |
| `openwhisk-dashboard/actions/` | Action gửi record từ OpenWhisk về Dashboard |
| `openwhisk-gateway/` | Cân bằng request K6 tới các cluster |
| `k6/` | Tạo tải và xuất `k6.json` |
| `k3s-cloud-openwhisk-deployment/` | Cài K3s/OpenWhisk và tạo `.wskprops` |

`duration_ms` trên Dashboard là thời gian chạy bên trong action, không phải
latency end-to-end của Gateway. RPS Dashboard là RPS của các record được sample,
không phải tổng RPS K6.

## 2. Yêu cầu

### Máy chạy Dashboard

- Linux Ubuntu hoặc Windows.
- Python 3.
- Linux: `python3-venv` và `python3-pip`.
- Có thể truy cập từ các node OpenWhisk qua Tailscale/private network.
- Port `9000` chỉ mở trong mạng tin cậy; không expose trực tiếp ra Internet.

### Khi deploy action

Máy chạy deploy cần:

- `wsk` OpenWhisk CLI.
- `curl`.
- Bash: Linux, Git Bash hoặc WSL trên Windows.
- File credential tương ứng:
  - Linux: `~/.wskprops.c1`, `~/.wskprops.c2`, `~/.wskprops.c3`.
  - Windows Git Bash: `$HOME/.wskprops.c1`, `$HOME/.wskprops.c2`, `$HOME/.wskprops.c3`.

Các file `.wskprops` chứa credential, không commit lên Git.

## 3. Cài đặt trên Linux

Từ repository root:

```bash
cd openwhisk-dashboard
bash install-linux.sh
```

Script sẽ:

1. Tạo virtualenv tại `openwhisk-dashboard/.venv`.
2. Cài package từ [`requirements.txt`](requirements.txt).
3. Tạo `.env` từ [`.env.example`](.env.example) nếu chưa có.
4. Giữ dependency của Dashboard tách khỏi Gateway và các project Python khác.

Nếu Ubuntu chưa có module venv:

```bash
sudo apt-get update
sudo apt-get install -y python3 python3-venv python3-pip curl
bash install-linux.sh
```

## 4. Cài đặt trên Windows

Mở PowerShell tại repository root:

```powershell
cd openwhisk-dashboard
.\install-windows.ps1
```

Script dùng Python launcher `py`, tạo `.venv` và cài các package cần thiết.
Nếu máy chưa có Python, cài Python 3 trước rồi mở PowerShell mới.

Deploy action từ Windows nên chạy bằng Git Bash hoặc WSL vì
`deploy-openwhisk-actions.sh` cần Bash và `wsk`.

## 5. Cấu hình `.env`

Sau khi cài, mở `openwhisk-dashboard/.env`:

```dotenv
DASHBOARD_BIND_HOST=0.0.0.0
DASHBOARD_PORT=9000

# Địa chỉ mà OpenWhisk node có thể truy cập được.
DASHBOARD_URL=http://100.x.x.x:9000

# Chỉ liệt kê cluster đã có .wskprops tương ứng.
CLUSTERS="c1 c2 c3"

# 0.05 = lấy mẫu 5%; dùng 1 chỉ cho smoke test ngắn.
SAMPLE_RATE=0.05

# Để trống nếu không dùng authentication cho /ingest.
INGEST_TOKEN=
```

Lưu ý:

- Không dùng `127.0.0.1` làm `DASHBOARD_URL` khi action chạy trên VM/cluster.
- `DASHBOARD_URL` phải là IP Tailscale/private IP của máy Dashboard.
- Nếu chỉ có cluster c2, đặt `CLUSTERS="c2"`.
- Nếu bật `INGEST_TOKEN`, phải deploy lại `publish_result` để token được truyền
  vào action.
- Không commit `.env`.

## 6. Chạy Dashboard

### Linux

```bash
cd openwhisk-dashboard
bash run-linux.sh
```

### Windows PowerShell

```powershell
cd openwhisk-dashboard
.\run-windows.ps1
```

Mặc định Dashboard chạy tại:

```text
http://0.0.0.0:9000
```

Mở trình duyệt bằng địa chỉ thật:

```text
http://<DASHBOARD-TAILSCALE-IP>:9000/
```

Có thể đổi host/port mà không sửa code:

```bash
DASHBOARD_BIND_HOST=100.x.x.x DASHBOARD_PORT=9000 bash run-linux.sh
```

Trên Windows:

```powershell
.\run-windows.ps1 -BindHost 100.x.x.x -Port 9000
```

Chỉ chạy **một worker**. Buffer dữ liệu nằm trong RAM của một process; chạy nhiều
worker sẽ làm dữ liệu bị chia thành nhiều buffer khác nhau.

## 7. Kiểm tra Dashboard

Kiểm tra health:

```bash
curl -s http://<DASHBOARD-TAILSCALE-IP>:9000/health
```

Kết quả hợp lệ có dạng:

```json
{"ok":true,"service":"openwhisk-dashboard","records":0}
```

Kiểm tra thống kê:

```bash
curl -s 'http://<DASHBOARD-TAILSCALE-IP>:9000/api/stats?window=60'
```

`records: 0` hoặc `count: 0` lúc mới khởi động là bình thường. Dữ liệu mất khi
Dashboard restart vì hiện tại chưa dùng database.

## 8. Deploy action telemetry lên OpenWhisk

### 8.1 Chuẩn bị `.wskprops`

K3s deployment tạo credential cho từng cluster. Đặt các file vào `$HOME`:

```bash
ls -la ~/.wskprops.c1 ~/.wskprops.c2 ~/.wskprops.c3
```

Chỉ cần file của cluster muốn deploy. Ví dụ chỉ deploy c2:

```bash
CLUSTERS="c2"
```

### 8.2 Deploy

Dashboard phải đang chạy trước:

```bash
cd openwhisk-dashboard
bash deploy-openwhisk-actions.sh
```

Script sẽ:

1. Đọc `DASHBOARD_URL`, `CLUSTERS`, `SAMPLE_RATE`, `INGEST_TOKEN` từ `.env`.
2. Gọi `GET /health` để kiểm tra đường mạng.
3. Deploy/cập nhật `publish_result`.
4. Deploy/cập nhật A1, A2, A3.
5. Gắn cluster name và sample rate vào action.

Có thể override tạm thời:

```bash
DASHBOARD_URL=http://100.x.x.x:9000 \
CLUSTERS="c2" \
SAMPLE_RATE=0.05 \
bash deploy-openwhisk-actions.sh
```

### 8.3 Kiểm tra action thật

Gọi A1 trên c2 và buộc sample 100% cho lần kiểm tra này:

```bash
WSK_CONFIG_FILE="$HOME/.wskprops.c2" \
  wsk -i action invoke A1 --blocking --result --param SAMPLE_RATE 1
```

Xem record:

```bash
curl -s 'http://100.x.x.x:9000/api/recent?limit=5&cluster=c2'
```

Record hợp lệ phải có:

```json
{
  "req_id": "activation-id-that",
  "cluster": "c2",
  "action": "A1",
  "status": "ok",
  "duration_ms": 42.3,
  "ts": 1790000000
}
```

## 9. Kết nối với Gateway và K6

Dashboard không thay thế Gateway hoặc K6. Chạy theo thứ tự:

1. Chạy Dashboard.
2. Deploy telemetry actions.
3. Chạy Gateway tại port `8080`.
4. Chạy K6 gửi traffic qua Gateway.

Ví dụ K6:

```bash
GATEWAY_URL=http://<GATEWAY-TAILSCALE-IP>:8080 \
  bash ../k6/run-load.sh 10 30s
```

Hoặc từ repository root:

```bash
bash k6/run-load.sh 10 30s
```

Trong PowerShell:

```powershell
.\k6\run-load.ps1 `
  -Rate 10 `
  -Duration 30s `
  -GatewayUrl http://<GATEWAY-TAILSCALE-IP>:8080
```

Traffic đi qua Gateway, nhưng record Dashboard được tạo bởi action
`publish_result`. Vì vậy cần cả hai điều kiện:

- K6/Gateway gọi được OpenWhisk.
- OpenWhisk node gọi được `DASHBOARD_URL:9000`.

K6 xuất kết quả đo vào `k6/results/`; Dashboard không tự import file `k6.json`.

## 10. API

| Method | Endpoint | Mô tả |
|---|---|---|
| `GET` | `/` | Giao diện Dashboard |
| `GET` | `/health` | Health check |
| `POST` | `/ingest` | Nhận telemetry |
| `GET` | `/api/stats?window=60` | Thống kê 10–900 giây |
| `GET` | `/api/recent?limit=25&cluster=all` | Record gần nhất |
| `GET` | `/api/export.csv` | Export tối đa 5.000 record |

### Gửi record thủ công

Chỉ dùng để kiểm tra kết nối, không dùng làm số liệu benchmark:

```bash
curl -X POST http://127.0.0.1:9000/ingest \
  -H 'Content-Type: application/json' \
  -d '{
    "req_id":"manual-check-1",
    "cluster":"c1",
    "action":"A1",
    "status":"ok",
    "duration_ms":12.5,
    "ts":1790000000
  }'
```

Nếu bật token:

```bash
curl -X POST http://127.0.0.1:9000/ingest \
  -H 'Content-Type: application/json' \
  -H 'X-Ingest-Token: <token>' \
  -d '{"req_id":"manual-check-2","cluster":"c1","action":"A1","status":"ok","duration_ms":12.5,"ts":1790000000}'
```

## 11. Quy tắc dữ liệu

`POST /ingest` yêu cầu các field:

- `req_id`: chuỗi tối đa 128 ký tự.
- `cluster`: chuỗi cluster, ví dụ `c1`.
- `action`: `A1`, `A2` hoặc `A3`.
- `status`: trạng thái, thường là `ok` hoặc `error`.
- `duration_ms`: số không âm, hữu hạn.
- `ts`: Unix timestamp hoặc chuỗi timestamp.

Giới hạn hiện tại:

- Payload tối đa 8 KiB.
- Tối đa 5.000 record trong RAM.
- Record trùng `cluster + req_id` chỉ được tính một lần.
- Buffer và thống kê mất khi process restart.

## 12. Kiểm thử

Kích hoạt virtualenv rồi chạy:

```bash
cd openwhisk-dashboard
source .venv/bin/activate
python -m pip install pytest httpx
python -m pytest -q tests/test_dashboard.py tests/test_actions.py \
  --import-mode=importlib
```

Windows:

```powershell
cd openwhisk-dashboard
.\.venv\Scripts\python.exe -m pip install pytest httpx
.\.venv\Scripts\python.exe -m pytest -q tests/test_dashboard.py tests/test_actions.py `
  --import-mode=importlib
```

Không dùng record thủ công hoặc `dashboard-ingest-test.js` để báo cáo benchmark.
Benchmark thật phải dùng traffic từ K6 → Gateway → OpenWhisk.

## 13. Bảo mật và vận hành

- Không expose port `9000` ra Internet.
- Không commit `.env`, `.wskprops` hoặc OpenWhisk auth.
- `INGEST_TOKEN` nên bật khi Dashboard nằm ngoài mạng riêng.
- Sau khi đổi `DASHBOARD_URL`, `SAMPLE_RATE` hoặc token, deploy lại actions.
- Không chạy nhiều Uvicorn workers.
- Dữ liệu hiện chỉ ở RAM; cần persistence thì phải thiết kế database riêng.
- Nếu Dashboard chết, action publisher có thể báo gửi thất bại nhưng không được
  coi đó là lỗi xử lý chính của action.

## 14. Xử lý lỗi nhanh

### Dashboard không khởi động

```bash
test -x .venv/bin/python
python3 --version
bash install-linux.sh
```

Windows:

```powershell
Test-Path .venv\Scripts\python.exe
.\install-windows.ps1
```

### `GET /health` không truy cập được

- Kiểm tra Dashboard đang bind `0.0.0.0` hoặc Tailscale IP.
- Kiểm tra firewall cho port `9000`.
- Không dùng `localhost` trong `DASHBOARD_URL` của action.
- Từ node OpenWhisk chạy:

```bash
curl -v http://<DASHBOARD-TAILSCALE-IP>:9000/health
```

### Deploy action báo thiếu `wskprops`

```bash
ls -la "$HOME"/.wskprops.*
```

Đặt đúng `CLUSTERS`, chỉ gồm cluster có file credential tương ứng.

### Dashboard nhận 401

- `INGEST_TOKEN` trong Dashboard và action publisher không giống nhau.
- Chạy lại `bash deploy-openwhisk-actions.sh` sau khi đổi token.
- Kiểm tra action `publish_result` đã được cập nhật trên đúng cluster.

### Dashboard không có record khi K6 đang chạy

Kiểm tra lần lượt:

```bash
curl -s http://<DASHBOARD-IP>:9000/health
curl -s http://<DASHBOARD-IP>:9000/api/recent?limit=5
WSK_CONFIG_FILE="$HOME/.wskprops.c2" wsk -i action invoke A1 \
  --blocking --result --param SAMPLE_RATE 1
```

Nếu gọi action trực tiếp có record nhưng K6 không tạo record, lỗi nằm ở
Gateway/OpenWhisk routing. Nếu gọi action trực tiếp cũng không có record, kiểm
tra `DASHBOARD_URL`, firewall/Tailscale và action `publish_result`.

## 15. Tài liệu liên quan

- [Root README](../README.md)
- [OpenWhisk Gateway](../openwhisk-gateway/)
- [K6 runner](../k6/)
- [K3s deployment](../k3s-cloud-openwhisk-deployment/README.md)
- [Integration notes](INTEGRATION.md)
