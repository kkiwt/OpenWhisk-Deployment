# Legacy k3d deployment

Thư mục này chứa toàn bộ luồng cũ dựa trên **Docker + k3d**:

- `golden-config-final/`: installer Golden Config, values và script quản lý k3d.
- `chaos/`: F1-F5 điều khiển container k3d, analyzer và helper SSH/WSK.

Đây là mã lịch sử để tái hiện thí nghiệm cũ, **không dùng cho triển khai mới**.
Luồng hiện hành nằm tại [`../k3s-cloud-openwhisk-deployment/`](../k3s-cloud-openwhisk-deployment/).

Các script trong thư mục này vẫn cần Docker/k3d và có thể xóa hoặc dừng container
khác nếu chạy nhầm lệnh cleanup. Kiểm tra dữ liệu trước khi dùng
`golden-config-final/XoaOpenWhiskDeCaiLai.sh`.
