# KẾT QUẢ KIỂM THỬ — DASHBOARD MẢNG B

## Đã xác nhận thực tế trong buổi kiểm thử 02/11/2026

- Ubuntu 22.04.5, chạy `python -m uvicorn dashboard:app --host 127.0.0.1 --port 9000 --workers 1`: log `Application startup complete`.
- Windows nối tới Ubuntu bằng `ssh -p 2222 -N -L 19000:127.0.0.1:9000 ...`; Chrome mở `http://127.0.0.1:19000/`.
- Kiểm tra GET `/`: trả HTTP 200 qua SSH tunnel.
- Gửi thành công ba bản ghi JSON **GIẢ LẬP** (không qua OpenWhisk thật):

| req_id | cluster | action | status | duration_ms | POST /ingest |
|---|---|---|---|---:|---|
| test-001 | c1 | A1 | ok | 75 | chấp nhận |
| test-002 | c2 | A2 | ok | 120 | `ok=true`, `duplicate=false`, `stored=2` |
| test-003 | c3 | A3 | error | 200 | `ok=true`, `duplicate=false`, `stored=3` |

- Khi chọn cửa sổ 5 phút và ba bản ghi còn trong cửa sổ: **total=3; avg=131,7 ms; success=66,7%; C1/C2/C3 mỗi cụm có 1 bản ghi**. Biểu đồ và danh sách đã cập nhật đúng (ảnh ở `minh-chung/`).
- Vài phút sau, `/api/stats?window=300` trả `stored=3` nhưng `overview.count=0`: đúng vì dữ liệu đã ở ngoài cửa sổ 300 giây.
- Kiểm tra lại mã nguồn trong gói: `python -m pytest -q` -> **6 passed** (smoke + thống kê + chống trùng + giới hạn bộ đệm + empty + CSV).

## Chưa thử / chưa được xác nhận

- **C1 đã nối và xác minh** sau lần kiểm thử lịch sử ở trên: một activation A1 thật gửi record có activation ID tới Dashboard; `publish_result` trả HTTP 200 với `stored=1`.
- **C2/C3 chưa nối**; hiện chưa có file cấu hình `.wskprops.c2` và `.wskprops.c3` trong môi trường triển khai.
- **Chưa chuyển** Dashboard sang Máy 3 làm host chính thức.
- **Chưa đo** RSS <100MB hoặc tải dài với K6 trên máy nhóm.
- **Chưa khẳng định** throughput hay latency của OpenWhisk thật. Các số liệu trong ảnh chỉ là mock request gửi từ PowerShell.

## Tham chiếu

- `HUONG-DAN-THANH-VIEN.md`: cách dựng, chạy, test và tích hợp.
- `docs/Giai_thich_Dashboard_OpenWhisk_Mang_B.docx`: báo cáo giải thích kiến trúc và mã nguồn.
- `docs/So_do_kiem_thu_Windows_Ubuntu.png`: sơ đồ luồng đã kiểm thử.
- `docs/So_do_tich_hop_du_kien.png`: sơ đồ tích hợp dự kiến.
