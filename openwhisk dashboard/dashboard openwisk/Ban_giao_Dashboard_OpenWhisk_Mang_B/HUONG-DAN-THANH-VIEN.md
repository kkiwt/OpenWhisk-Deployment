
## 1. Dashboard dùng để làm gì?

Dashboard là **trạm nhận kết quả**: nhận bản ghi từ action `publish_result` qua HTTP, lưu tạm vào RAM, tính toán thống kê, rồi hiển thị lên trình duyệt. Dashboard không thay thế Gateway và không nằm trên đường request chính của K6.



## 2. Những gì đã làm

- Backend `dashboard.py` bằng **Python FastAPI**, chạy bằng Uvicorn cổng **9000**, **1 worker**.
- Frontend gồm `static/index.html`, `static/style.css`, `static/app.js`, biểu đồ Chart.js; trang tự lấy số liệu mỗi **2 giây**.
- Các API: `GET /`, `GET /health`, `POST /ingest`, `GET /api/stats`, `GET /api/recent`, `GET /api/export.csv`.
- Chỉ lưu tối đa **5.000 bản ghi** trong RAM; khi đầy tự loại bản ghi cũ; chống đếm trùng theo cặp `(cluster, req_id)`.
- Hiển thị số request, RPS trung bình theo cửa sổ thời gian, thời gian xử lý trung bình/P95, tỷ lệ thành công, thống kê từng cụm C1–C3, phân bố action, bảng nhật ký và nút xuất CSV.
- Đã chạy trên **Ubuntu 22.04 VM** và mở trên **Windows Chrome** bằng SSH tunnel.
- Đã gửi **3 bản ghi GIẢ LẬP** qua `POST /ingest`, quan sát biểu đồ hiển thị đúng: trong cửa sổ 5 phút, có 3 bản ghi; độ trễ trung bình **131,7 ms**, tỷ lệ thành công **66,7%**.
- Kiểm thử tự động mã nguồn: **6/6 test pass** khi đóng gói (thành viên khác có thể chạy lại).

> **Phân biệt:** Các số trong ảnh minh chứng là dữ liệu do PowerShell gửi để thử Dashboard, **không phải benchmark K6 hay số liệu đo OpenWhisk thật**.

## 3. Cấu trúc gói bàn giao

```text
Ban_giao_Dashboard_OpenWhisk_Mang_B/
├── dashboard.py                   # Backend nhận JSON, xử lý thống kê
├── requirements.txt               # FastAPI, Uvicorn
├── static/
│   ├── index.html                 # Khung giao diện
│   ├── style.css                  # Thiết kế giao diện
│   └── app.js                     # Lấy API và cập nhật biểu đồ
├── tests/test_dashboard.py        # Bộ unit test
├── check-dashboard.sh             # Kiểm tra API chỉ đọc, không gửi mock data
├── HUONG-DAN-THANH-VIEN.md        # Hướng dẫn này
├── KET-QUA-KIEM-THU.md            # Kết quả đã kiểm chứng và giới hạn
├── docs/
│   ├── Giai_thich_Dashboard_OpenWhisk_Mang_B.docx
│   ├── So_do_kiem_thu_Windows_Ubuntu.png
│   └── So_do_tich_hop_du_kien.png
└── minh-chung/
    └── Dashboard_3_cum_du_lieu_gia_lap.png
```

## 4. Hướng dẫn cài và chạy trên Ubuntu

Cần Python 3 và `python3-venv`. Sau khi giải nén file ZIP và vào thư mục chứa `dashboard.py`, chạy:

```bash
sudo apt update
sudo apt install -y python3-venv unzip
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python -m uvicorn dashboard:app --host 127.0.0.1 --port 9000 --workers 1
```

Khi thành công, terminal báo `Application startup complete` và `Uvicorn running on http://127.0.0.1:9000`. **Giữ nguyên terminal chạy Uvicorn**.

### Mở trên Windows khi Ubuntu là VirtualBox NAT, SSH qua cổng 2222

Mở **PowerShell khác** trên Windows:

```powershell
ssh -p 2222 -N -L 19000:127.0.0.1:9000 <user-ubuntu>@127.0.0.1
```

Trên Chrome tự nhập `http://127.0.0.1:19000/`. Cần giữ cả terminal Uvicorn lẫn terminal SSH tunnel. `Ctrl+C` để dừng khi không dùng nữa. Đây là cách kiểm thử nội bộ, **chưa giúp các cụm OpenWhisk từ máy khác truy cập cổng 9000**.

### Khi chuyển sang Máy 3 của nhóm

Sau khi thống nhất với nhóm, có thể chạy `--host 0.0.0.0 --port 9000` để nhận kết nối qua Tailscale, đồng thời **giới hạn quyền truy cập cổng 9000 trong mạng nhóm**. Không mở cổng này công khai trên Internet. Dùng **IP Tailscale thực tế của Máy 3**, không dùng IP minh họa.

## 5. Tự kiểm tra Dashboard

Trong terminal khác (hoặc trên máy có thể truy cập cổng đã mở):

```bash
curl -s http://127.0.0.1:9000/health
curl -s 'http://127.0.0.1:9000/api/stats?window=300'
bash check-dashboard.sh http://127.0.0.1:9000
```

`check-dashboard.sh` chỉ thực hiện các **GET** an toàn, không tạo dữ liệu giả hoặc sửa cluster.

Để chạy unit test:

```bash
source .venv/bin/activate
python -m pip install pytest httpx
python -m pytest -q
```

### Định dạng dữ liệu mà Dashboard nhận

```json
{
  "req_id": "activation-id-hoac-id-test",
  "cluster": "c1",
  "action": "A1",
  "status": "ok",
  "duration_ms": 75,
  "ts": "2026-11-02T10:00:00+07:00"
}
```

Gửi HTTP `POST /ingest`, `Content-Type: application/json`. Cả sáu trường `req_id`, `cluster`, `action`, `status`, `duration_ms`, `ts` đều bắt buộc. Không bao giờ gửi Auth Key/OpenWhisk guest key trong JSON.

## 6. Kết nối với OpenWhisk thật

Dashboard nhận dữ liệu thật qua `POST /ingest`; không cần đổi backend để nối
OpenWhisk. Trong workspace chính, luồng C1 đã được triển khai và xác minh bằng
một activation A1 thật. C2/C3 chỉ được nối sau khi có `~/.wskprops.c2` và
`~/.wskprops.c3` tương ứng.

```text
K6 -> Gateway (TV1) -> OpenWhisk C1/C2/C3 (TV2)
                                 |
                       Kết quả được báo ngầm
                                 v
                      action publish_result
                                 |
                           POST /ingest
                                 v
                      Dashboard FastAPI (Máy 3)
                                 |
                    RAM deque (tối đa 5.000)
                                 |
                         GET /api/stats
                                 |
                      Chrome / Chart.js
```

Trong workspace chính, dùng `deploy-openwhisk-actions.sh` ở folder
`openwhisk dashboard` để cấu hình `publish_result` và A1/A2/A3. Dashboard URL
phải là địa chỉ Tailscale mà cluster truy cập được, không phải `127.0.0.1` hay
địa chỉ SSH tunnel:

```bash
DASHBOARD_URL=http://<IP-TAILSCALE-DASHBOARD>:9000 \
CLUSTERS="c1 c2 c3" SAMPLE_RATE=0.05 \
./deploy-openwhisk-actions.sh
```

Chỉ đưa các cluster đã có `.wskprops` vào `CLUSTERS`. Action gửi JSON tới
`POST <TARGET_URL>/ingest` bằng `publish_result`; Dashboard không nhận hay lưu
OpenWhisk Auth Key. Giới hạn port 9000 trong mạng nhóm/Tailscale.

**Lưu ý rất quan trọng khi đo:** Theo tài liệu nhóm, `SAMPLE_RATE` mặc định khoảng **0,05** (5%). Khi đó, Dashboard chỉ đếm **các bản ghi thực sự được gửi về trạm**, không thể gọi đó là toàn bộ RPS của K6/Gateway/OpenWhisk. Muốn demo 100% bản ghi phải thống nhất với nhóm đổi `SAMPLE_RATE=1.0`.

## 7. Những việc còn cần làm

1. Chuyển/triển khai Dashboard lên Máy 3 hoặc thống nhất máy chủ chính thức.
2. Xác nhận kết nối Tailscale tới `:9000` trong phạm vi nhóm.
3. TV2 cấu hình `publish_result` và thử một **bản ghi thực** từ OpenWhisk.
4. Test end-to-end: K6 → Gateway → OpenWhisk → publish_result → Dashboard.
5. Đo RAM RSS trên máy triển khai để xác nhận mục tiêu tài liệu là **≤100 MB**; chưa được xác nhận.

Không cần xóa/cài lại cluster hay thay đổi Golden Config chỉ để chạy Dashboard.

## 8. Chú ý khi sử dụng và báo cáo

- Dữ liệu lưu trong RAM sẽ **mất khi dừng Dashboard**; dùng xuất CSV nếu cần lưu lại.
- Nhãn **"Có bản ghi"** chỉ có nghĩa là Dashboard từng nhận dữ liệu, **không phải cluster đang Healthy**.
- Chạy Uvicorn **1 worker** để tất cả request cùng nhìn thấy một bộ đệm RAM.
- Giao diện dùng Chart.js CDN khi có Internet và có Canvas fallback cơ bản.
- Không đưa `~/.wskprops`, file Auth Key, Base64 Basic Auth, mật khẩu CouchDB hay `ow-private-values.yaml` vào ZIP bàn giao.
