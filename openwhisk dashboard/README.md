# OpenWhisk Result Station

## Chuyển file từ Windows sang Ubuntu VM (nếu đang dùng SSH NAT port 2222)

Tải file ZIP từ cuộc trò chuyện về thư mục Downloads của Windows, rồi chạy **trong PowerShell Windows**:

```powershell
scp -P 2222 "$env:USERPROFILE\Downloads\openwhisk-dashboard.zip" kiet@127.0.0.1:~/
ssh -p 2222 kiet@127.0.0.1
```

Trong **Ubuntu**:

```bash
sudo apt-get install -y unzip python3-venv
cd ~
unzip openwhisk-dashboard.zip
```


## 1. Cài và chạy trên Ubuntu

```bash
cd ~/openwhisk-dashboard
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn dashboard:app --host 0.0.0.0 --port 9000 --workers 1
```

Mở `http://127.0.0.1:9000` trên máy chạy Dashboard, hoặc `http://<IP-TAILSCALE-MAY-3>:9000` từ máy cùng Tailscale. Để dừng, nhấn `Ctrl+C` ở terminal uvicorn.

Nếu chỉ muốn thử nội bộ trước, đổi `--host 0.0.0.0` thành `--host 127.0.0.1`.

Chạy một worker duy nhất vì bộ đệm dữ liệu nằm trong RAM của tiến trình; nhiều workers sẽ khiến mỗi worker nhìn thấy dữ liệu khác nhau.

## 2. Kiểm tra server mà chưa thêm dữ liệu

Tại terminal thứ hai:

```bash
curl -s http://127.0.0.1:9000/health
curl -s 'http://127.0.0.1:9000/api/stats?window=60'
```

Dashboard sẽ hiển thị **Chưa có dữ liệu** cho đến khi nhận một bản ghi thực. Đây là hành vi đúng, không phải lỗi. Dữ liệu lưu tạm trong RAM và mất khi restart dashboard.

## 3. Hợp đồng nhận dữ liệu (giữ đúng tài liệu nhóm)

```http
POST /ingest
Content-Type: application/json

{
  "req_id": "<activation-id>",
  "cluster": "c2",
  "action": "A1",
  "status": "ok",
  "duration_ms": 42.3,
  "ts": 1790000000
}
```

**Trên đây chỉ là cấu trúc minh họa, không phải số liệu thí nghiệm thật.** Các trường `req_id, cluster, action, status, duration_ms, ts` là bắt buộc. Mỗi cặp `cluster + req_id` được tính một lần để tránh đếm trùng khi gửi lại. Mỗi JSON bị giới hạn 8 KiB; tối đa 5.000 bản ghi được giữ trong RAM, quá giới hạn sẽ thay bản cũ nhất.

API trả `{"ok":true,"duplicate":false,"stored":1}` (số `stored` phụ thuộc dữ liệu thật).

## 4. Kết nối OpenWhisk thật

Dashboard chỉ đọc dữ liệu đã nhận; nó không tạo benchmark. Luồng thật là:

```text
K6 -> Gateway -> action A1/A2/A3 trên OpenWhisk
                     | activation ID, action, cluster, execution time
                     v
              publish_result -> POST /ingest -> Dashboard
```

Chạy Dashboard trên địa chỉ có thể truy cập từ các máy OpenWhisk (không dùng `127.0.0.1` hoặc SSH tunnel làm `DASHBOARD_URL`):

```bash
cd "openwhisk dashboard"
python -m uvicorn dashboard:app --host 0.0.0.0 --port 9000 --workers 1
```

Mỗi cluster cần có file `~/.wskprops.c1`, `~/.wskprops.c2` hoặc `~/.wskprops.c3`. Sau khi xác nhận địa chỉ dashboard từ cluster, deploy actions:

```bash
DASHBOARD_URL=http://<IP-TAILSCALE-DASHBOARD>:9000 \
CLUSTERS="c1 c2 c3" SAMPLE_RATE=0.05 \
./deploy-openwhisk-actions.sh
```

Chỉ deploy cluster đã cấu hình bằng `CLUSTERS="c2"` nếu chưa có credentials cho các cluster khác. Script kiểm tra `/health`, cập nhật `publish_result` và A1/A2/A3, không cần sửa IP trong mã nguồn. Không mở port 9000 công khai; chỉ cho phép mạng nhóm/Tailscale.

Xác minh bằng một activation OpenWhisk thật, sau đó xem record trên Dashboard:

```bash
WSK_CONFIG_FILE="$HOME/.wskprops.c2" wsk -i action invoke A1 \
  --blocking --result --param SAMPLE_RATE 1
curl -s 'http://<IP-TAILSCALE-DASHBOARD>:9000/api/recent?limit=5&cluster=c2'
```

Record thật có `req_id` là activation ID của OpenWhisk. `duration_ms` đo thời gian chạy bên trong action, không phải latency đầu-cuối của Gateway. Mặc định chỉ 5% activation được gửi (`SAMPLE_RATE=0.05`), vì vậy RPS trên Dashboard là tốc độ nhận **các record được lấy mẫu**, không phải tổng RPS của K6/Gateway/OpenWhisk. Chỉ dùng `SAMPLE_RATE=1` cho kiểm tra ngắn đã thống nhất với nhóm.

`actions/dashboard-ingest-test.js` là sender test, không phải nguồn benchmark; nó yêu cầu `CONFIRM_TEST_DATA=true` và `TARGET_URL` tường minh, đồng thời đánh dấu status `test_only`.

## 5. Endpoints

| Phương thức | Đường dẫn | Chức năng |
|---|---|---|
| GET | `/` | Giao diện Dashboard |
| GET | `/health` | Kiểm tra dashboard hoạt động |
| POST | `/ingest` | Nhận bản ghi JSON |
| GET | `/api/stats?window=60` | Thống kê (window 10–900 giây) |
| GET | `/api/recent?limit=25&cluster=all` | Bản ghi mới nhất |
| GET | `/api/export.csv` | Tải CSV các bản ghi đã nhận (tối đa 5.000) |

Frontend tự động lấy API mới mỗi 2 giây. Biểu đồ dùng **Chart.js 4.5.0 từ CDN** khi có Internet; khi CDN không tải được, biểu đồ vẫn có bản vẽ Canvas cơ bản để sử dụng ngoại tuyến.


## 6. Kiểm thử code tự động

```bash
pip install pytest httpx
python -m pytest -q tests/test_dashboard.py tests/test_actions.py --import-mode=importlib
```

Không chạy load test giả rồi ghi là số liệu thật. Khi đo E1/E5, dùng dữ liệu do K6, Gateway và action thực sự phát ra.
