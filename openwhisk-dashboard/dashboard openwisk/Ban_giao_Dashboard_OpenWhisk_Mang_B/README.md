 Bản nâng cấp giữ nguyên giao tiếp `POST /ingest`, `GET /api/stats`, trang web `/`, vòng đệm 5.000 sự kiện và cập nhật mỗi 2 giây. Có thêm hiển thị số request, RPS, độ trễ trung bình/P95, tỷ lệ thành công, thống kê C1–C3, tỷ trọng action, bảng kết quả và lọc khoảng thời gian.

## Tách biệt hệ thống hiện hữu

- Không chỉnh Docker, Kubernetes, Helm hoặc OpenWhisk.
- Không cần Auth Key của OpenWhisk để dashboard nhận dữ liệu.
- Dữ liệu từ action `publish_result` do TV2 gửi: `MODE=dashboard`, `TARGET_URL=http://<IP-TAILSCALE-MAY-3>:9000`.
- Máy chạy chuẩn theo tài liệu: **Máy 3 (TV3)**. Có thể thử trên máy hiện tại trước rồi chuyển bộ file sang máy 3.

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

Đây là cách thử trên VM hiện có; theo tài liệu phân công, bản Dashboard chính thức nên chạy trên **Máy 3**. Khi chuyển sang Máy 3, thay máy đích trong câu lệnh SCP/SSH tương ứng (không giả định IP hoặc quyền truy cập).

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

## 4. Ghép với OpenWhisk của nhóm

Nhờ TV2 thiết lập action `publish_result` theo tài liệu:

- `MODE=dashboard`
- `TARGET_URL=http://<IP-TAILSCALE-MAY-3>:9000`

Action sẽ gọi `POST <TARGET_URL>/ingest`. Dashboard không tham gia luồng khách chờ, đúng mô hình "báo ngầm". Khi K6 chạy và action publish_result gửi dữ liệu, dashboard sẽ cập nhật khoảng 2 giây/lần.

**Quan trọng:** Mặc định chỉ khoảng **5%** yêu cầu được gửi sang trạm nhận hàng (`SAMPLE_RATE=0.05`), nên số liệu trên dashboard chỉ phản ánh các **bản ghi được lấy mẫu**, **không phải RPS tổng của K6 hoặc cả hệ thống**. Khi demo có thể đặt `SAMPLE_RATE=1.0` sau khi nhóm đồng ý, rồi đổi về đúng cấu hình đo.

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

## 6. An toàn và tài nguyên

- **Chỉ mở port 9000 cho mạng nhóm/Tailscale.** Không đưa dashboard lên Internet công khai nếu không có kiểm soát truy cập.
- Có thể bật token nhận dữ liệu bằng `INGEST_TOKEN='<chuoi-bi-mat>' uvicorn ...`. Khi bật, máy gửi phải thêm header `X-Ingest-Token` vào request. **Không bật token trước khi TV2 cập nhật action gửi dữ liệu**, nếu không sẽ gặp 401.
- Không đặt OpenWhisk Auth Key/Base64 vào frontend hoặc trong JSON ingest.
- RAM mục tiêu từ tài liệu là **≤ 100 MB**, nhưng chỉ khẳng định đạt khi đo **RSS thực tế** trên máy của nhóm. Trong một terminal khác: `ps -o rss= -p $(pgrep -f 'uvicorn dashboard:app' | head -1)`, đơn vị KiB; chia 1024 để ra MiB.
- Vì theo dõi **các bản ghi đến /ingest**, trạng thái "Có bản ghi" của cụm không tương đương cluster **Healthy**. Không dùng Dashboard thay thế readiness/health check của Kubernetes.
- Tất cả bản ghi sẽ mất khi tiến trình dừng hoặc khởi động lại. Đây là đúng thiết kế **in-memory dự phòng**.

## 7. Kiểm thử code tự động

```bash
pip install pytest httpx
python -m pytest -q
```

Không chạy load test giả rồi ghi là số liệu thật. Khi đo E1/E5, dùng dữ liệu do K6, Gateway và action thực sự phát ra.
