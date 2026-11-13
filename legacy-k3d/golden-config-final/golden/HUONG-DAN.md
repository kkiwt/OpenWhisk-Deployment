# Golden Config OpenWhisk - Hướng dẫn thực hiện (bản có Gateway và hồi phục sau khi mở máy)

## 1. Bố cục thư mục

```
~/Desktop/
├── CaiDatOpenWhiskMoi.sh
├── XoaOpenWhiskDeCaiLai.sh
├── golden/                         <- TẤT CẢ file của bạn để ở đây
│   ├── golden-values.yaml
│   ├── install-golden.sh           <- áp dụng Golden Config
│   ├── test-golden.sh              <- chứng minh 5 việc (+ Test 6 phụ: tương thích Gateway)
│   ├── deploy-actions.sh           <- MỚI: tạo action ping/test-thu cho Gateway
│   ├── after-reboot.sh             <- MỚI: hồi phục sau khi tắt/mở máy ảo
│   ├── TestMoi.sh
│   └── golden.lock                 (tự sinh)
└── openwhisk-deploy-kube/          <- do CaiDatOpenWhiskMoi.sh tải về
```

Thư mục `openwhisk-gateway/` của nhóm trưởng là của TV1, chạy ở Máy 1. **Không cần chạy** trên máy này (xem mục 4).

## 2. Quy trình chạy từ đầu

```bash
# Terminal 1
cd ~/Desktop
chmod +x CaiDatOpenWhiskMoi.sh XoaOpenWhiskDeCaiLai.sh golden/*.sh
./XoaOpenWhiskDeCaiLai.sh                       # bấm y
docker pull rancher/k3s:v1.35.5-k3s1            # tải trước để thấy tiến độ
./CaiDatOpenWhiskMoi.sh

# Terminal 2
watch kubectl get pods -n openwhisk             # chờ pod chính 1/1 Running, Ctrl+C khi xong

# Terminal 1
kubectl get jobs -n openwhisk                   # owdev-install-packages  Complete 1/1
AUTH=$(kubectl get secret owdev-whisk.auth -n openwhisk -o jsonpath='{.data.guest}' | base64 -d)
wsk property set --apihost https://$(tailscale ip -4):31001 --auth "$AUTH"
wsk -i namespace list                           # ra: guest
cd ~/Desktop/golden && bash TestMoi.sh

./install-golden.sh --clean                     # áp dụng Golden, khoảng 10 phút
./deploy-actions.sh                             # tạo action cho Gateway
./test-golden.sh                                # chụp bảng TỔNG KẾT
```

## 3. Vì sao Test 2 báo 0/300 (đã sửa)

`test-golden.sh` bản cũ dùng `xargs -I{}` rồi gửi body `-d '{}'`. `xargs` thay mọi `{}` bằng số thứ tự, nên body thành `1`, `2`, ... không phải JSON object, server trả **400**. Bản mới dùng `-I __N__` nên body giữ nguyên `{}`. Đây là lỗi của script test, không phải của Golden Config. Bằng chứng việc 2 độc lập với phép thử tải: phản hồi `GET /` của cụm có `actions_per_minute: 600000`.

## 4. Gateway (thư mục openwhisk-gateway)

Gateway là chương trình của TV1 chạy ở Máy 1, chia yêu cầu cho 3 cụm. Phía cụm của bạn cần đáp ứng:

| Điều Gateway cần | Cách đáp ứng |
|---|---|
| Gọi bằng khóa **guest** (base64 trong `gateway.py` giải mã ra khóa guest mặc định), đường dẫn `namespaces/_/` | Dùng khóa guest: `deploy-actions.sh` tạo action bằng khóa guest |
| Có action `test-thu` (mục tiêu ping mặc định) và `ping` (tài liệu nhóm) | `deploy-actions.sh` tạo cả hai |
| Mỗi cụm một dòng cấu hình: IP Tailscale + base64 của khóa | `deploy-actions.sh` in sẵn dòng cần gửi cho TV1, lưu ở `gateway-line-c2.txt` |
| Ping mỗi 2 giây, timeout 2 giây, hỏng 3 lần thì ngắt cụm | Action phải trả lời nhanh hơn 2 giây khi đã nóng |

Nếu bạn là cụm c3 thì chạy `CLUSTER_NAME=c3 ./deploy-actions.sh`.

Nếu sau này muốn chạy thử Gateway trên máy mình: **xóa thư mục `venv/` trước** (nó được tạo trên máy khác, Python 3.14, đường dẫn `/home/kkiwt/...`), rồi `./start.sh` sẽ tự tạo venv mới. Cũng phải sửa IP và base64 trong `gateway.py`: dòng c1 đang là IP của máy khác, c2 và c3 vẫn là chỗ trống.

## 5. Sau khi tắt/mở lại máy ảo

```bash
cd ~/Desktop/golden
./after-reboot.sh            # hỏi trước khi cài lại; thêm --auto để không hỏi
```

Script chờ node Ready, xóa cứng pod Unknown, kiểm tra CouchDB, cài lại nếu cần, rồi tạo lại action cho Gateway.

Để biết nguyên nhân thật sự khi pod bị kẹt (chạy ngay sau khi mở máy):

```bash
kubectl -n openwhisk get pods
kubectl -n openwhisk logs owdev-controller-0 -c wait-for-couchdb --tail=5
kubectl -n openwhisk exec deploy/owdev-couchdb -- curl -s -u whisk_admin:some_passw0rd http://127.0.0.1:5984/_all_dbs
```

Cách đọc: log `wait-for-couchdb` cứ lặp "not ready, waiting 5 seconds" và `_all_dbs` không có `ow_kube_couchdb_initialized_marker` thì controller và invoker đang chờ mốc khởi tạo mà CouchDB không lưu bền đã làm mất.

## 6. Bàn giao cho 2 thành viên

Gửi `CaiDatOpenWhiskMoi.sh`, `XoaOpenWhiskDeCaiLai.sh` và thư mục `golden/` (kèm `golden.lock` của máy gốc). Mỗi bạn làm mục 2 (đặt `CLUSTER_NAME=c2` hoặc `c3` khi chạy `deploy-actions.sh`) và gửi lại `golden-report-<máy>.txt`, `images-<máy>.txt`, `gateway-line-<tên>.txt`.
