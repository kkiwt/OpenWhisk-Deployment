# Hướng dẫn cài cụm OpenWhisk theo Golden Config (dành cho TV1 và TV3)

Mục tiêu: máy của bạn chạy một cụm OpenWhisk **giống hệt** cụm của TV2 (cấu hình, phiên bản, giới hạn RAM, giới hạn gọi), để cả 3 cụm so sánh công bằng. Làm đúng từng bước, **không tự sửa file nào**.

Mỗi máy đóng vai một cụm. TV1: Máy 1 = **c1**. TV3: Máy 3 = **c3**. (TV2: Máy 2 = c2.)

## 0. Điều kiện trước khi bắt đầu

| Cần có | Cách kiểm tra |
|---|---|
| Ubuntu (máy ảo hoặc máy thật), RAM **>= 10 GB**, CPU **>= 4 nhân** | `free -m` (cột total), `nproc` |
| Tailscale đã đăng nhập, cùng mạng với 2 bạn còn lại | `tailscale ip -4` ra IP dạng 100.x.x.x |
| Mạng Internet ổn định (lần đầu tải vài trăm MB) | `curl -I https://registry-1.docker.io` |
| Tài khoản có quyền `sudo` | |

Nếu dùng VirtualBox: tắt hẳn máy ảo, tăng RAM và CPU trong Settings > System, rồi bật lại. Trong Ubuntu tắt Automatic Suspend (Settings > Power). **Đừng dùng "Save the machine state"**, hãy dùng Shut Down.

## 1. Các file bạn nhận được

Từ TV2, nhận một thư mục gồm:

```
CaiDatOpenWhiskMoi.sh
XoaOpenWhiskDeCaiLai.sh
golden/
├── golden-values.yaml     cấu hình chuẩn
├── golden.lock            dấu vân tay của chart, BẮT BUỘC có (nếu thiếu, hỏi TV2)
├── install-golden.sh      áp dụng Golden Config
├── test-golden.sh         kiểm tra 5 việc
├── deploy-actions.sh      tạo action cho Gateway
├── after-reboot.sh        hồi phục sau khi mở lại máy
└── TestMoi.sh             thử nhanh chức năng
```

Đặt vào máy như sau (thư mục `golden/` nằm **cạnh** hai script cài/xóa, không nằm trong `openwhisk-deploy-kube`):

```
~/Desktop/
├── CaiDatOpenWhiskMoi.sh
├── XoaOpenWhiskDeCaiLai.sh
└── golden/
```

Cấp quyền chạy:

```bash
cd ~/Desktop
chmod +x CaiDatOpenWhiskMoi.sh XoaOpenWhiskDeCaiLai.sh golden/*.sh
```

## 2. Các bước chạy

Dùng 2 cửa sổ Terminal: **Terminal 1** để chạy lệnh, **Terminal 2** để theo dõi pod.

### Bước 1. Xóa sạch bản cũ (chỉ khi máy từng cài OpenWhisk)
```bash
cd ~/Desktop && ./XoaOpenWhiskDeCaiLai.sh        # bấm y
```
Máy mới chưa cài gì thì bỏ qua bước này.

### Bước 2. Tải trước image (để thấy tiến độ)
```bash
docker pull rancher/k3s:v1.35.5-k3s1
docker pull ghcr.io/k3d-io/k3d-tools:5.9.0
```
Nếu báo `timeout` hoặc `toomanyrequests`, đợi vài phút rồi chạy lại.

### Bước 3. Cài OpenWhisk bản thường
```bash
cd ~/Desktop && ./CaiDatOpenWhiskMoi.sh
```
Nếu script bảo "đăng xuất rồi đăng nhập lại" (vừa cài Docker) thì làm theo rồi chạy lại. Khi chạy sẽ thấy dòng "RAM của máy": nếu cảnh báo dưới 9500 MB thì quay lại mục 0 để tăng RAM.

### Bước 4. Chờ pod chạy hết (Terminal 2)
```bash
watch kubectl get pods -n openwhisk
```
Chờ 10-15 phút tới khi **controller, invoker-0, invoker-1, nginx, kafka, couchdb** đều `1/1 Running`, rồi Ctrl+C. Ở Terminal 1:
```bash
kubectl get jobs -n openwhisk        # owdev-install-packages  phải là Complete 1/1
```
Không cần chờ các pod `install-packages` cũ thôi hiện `Error` hay `Unknown`, chỉ cần job báo Complete.

### Bước 5. Áp dụng Golden Config
```bash
cd ~/Desktop/golden
./install-golden.sh --clean
```
Mất khoảng 10 phút. Script tự: kiểm tra RAM, **so chart với `golden.lock`**, tải sẵn image Python, cài lại theo Golden, đặt trần RAM, chờ pod sẵn sàng.

Nếu thấy dòng **"Chart KHÁC chart của máy gốc"** và script dừng: báo TV2 nén thư mục `~/Desktop/openwhisk-deploy-kube` của họ gửi cho bạn, giải nén đè lên thư mục cùng tên trên máy bạn, rồi chạy lại bước 5.

### Bước 6. Tạo action cho Gateway (đặt đúng tên cụm của bạn)
```bash
# TV1 (Máy 1):
CLUSTER_NAME=c1 ./deploy-actions.sh
# TV3 (Máy 3):
CLUSTER_NAME=c3 ./deploy-actions.sh
```
Cuối script in một dòng dạng `"c1": ("https://100.x.x.x:31001", "<chuỗi dài>"),` và lưu trong file `gateway-line-<tên>.txt`. **TV1 dán dòng này vào `gateway.py`** (trong `INITIAL_CLUSTERS`); TV3 gửi dòng của mình cho TV1.

### Bước 7. Kiểm tra 5 việc
```bash
./test-golden.sh
```
Chờ khoảng 2-3 phút. Cuối cùng có bảng **TỔNG KẾT**. Mục tiêu: Việc 1 đến 5 đều **ĐẠT**; hai mục "(phụ)" cũng nên đạt.

Một vài hiện tượng bình thường: vài lần gọi trả `202` ở Test 2 (hệ thống nhận nhưng khởi động container lạnh chưa kịp) không phải lỗi, miễn là không có `429` và tỉ lệ thành công >= 90%. Test 5 có thể tự thử lại tối đa 3 lần.

### Bước 8. Gửi kết quả về cho TV2
Tất cả nằm trong `~/Desktop/golden/`:

| File | Dùng để làm gì |
|---|---|
| `golden-report-<tên-máy>.txt` | Báo cáo 5 việc |
| `images-<tên-máy>.txt` | So sánh image 3 máy |
| `gateway-line-<c1 hoặc c3>.txt` | Cấu hình để dán vào Gateway |
| ảnh chụp bảng TỔNG KẾT | Bằng chứng |

TV2 sẽ so sánh: `./test-golden.sh --compare images-<máy-bạn>.txt` phải báo "CÙNG danh sách image".

## 3. Sau mỗi lần tắt/mở lại máy

Chờ 1-2 phút cho Docker lên, rồi:

```bash
cd ~/Desktop/golden
./after-reboot.sh
```

Vì CouchDB **không lưu bền** (đúng yêu cầu), sau khi mở máy lại dữ liệu và action sẽ mất. Script này kiểm tra, cài lại nếu cần (khoảng 10 phút) và tạo lại action cho Gateway. Thêm `--auto` nếu không muốn bị hỏi. Chạy `./test-golden.sh` sau đó để chắc chắn.

## 4. Gặp lỗi thì làm gì

| Hiện tượng | Cách xử lý |
|---|---|
| Pod kẹt `Unknown` sau khi mở máy | `./after-reboot.sh` |
| `HTTP 000` hoặc test báo không kết nối được | Xem phần "Chẩn đoán" mà Test 0 tự in; thử `curl -sk https://127.0.0.1:31001/` |
| Bước 3 đứng ở "Starting node ..." lâu | Có thể đang tải image không hiện tiến độ; chạy `docker pull rancher/k3s:v1.35.5-k3s1` ở Terminal 2 để xem |
| Pod `OOMKilled` hoặc máy chậm đơ | RAM máy ảo thiếu; kiểm tra `free -m`, tăng RAM như mục 0 |
| `deploy-actions.sh` báo không đọc được khóa guest | Cụm chưa chạy xong; chờ pod Running rồi chạy lại |
| Test 6 báo 404 | Chưa tạo action; chạy `CLUSTER_NAME=... ./deploy-actions.sh` |

Khi cần nhờ giúp, gửi cho TV2: **ảnh chụp lỗi**, file `golden-report-*.txt` và `golden-debug-*.txt`, cùng kết quả của `kubectl get pods -n openwhisk` và `kubectl get nodes`.

## 5. Quy tắc chung

1. Không sửa `golden-values.yaml` hay bảng trần RAM ở đầu `install-golden.sh`. Muốn đổi thì báo nhóm, cả 3 máy đổi cùng lúc.
2. Cả 3 máy dùng **cùng một bản** của mọi file trong gói này.
3. Máy nào cài lại cụm thì chạy lại từ bước 5 và bước 6.
