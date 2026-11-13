# Cài đặt OpenWhisk + Golden Config (bản gộp)

Tài liệu này chỉ mô tả quá trình cài đặt: từ máy đã có Tailscale đến khi cụm chạy đủ Golden Config và qua được test.

## 1. Bố cục thư mục

```
~/Desktop/
├── XoaOpenWhiskDeCaiLai.sh       giữ nguyên như cũ: xóa sạch cụm để cài lại
├── CaiDatOpenWhiskMoiHon.sh      MỚI: cài cụm + Golden Config trong 1 lần chạy
├── HUONG-DAN-CAI-DAT.md          file này
├── golden/
│   ├── golden-values.yaml        Golden Config (đã bật lưu bền)
│   ├── golden.lock               ghim phiên bản chart (lấy của máy gốc)
│   ├── deploy-actions.sh         tạo action ping/test-thu cho Gateway (installer tự gọi)
│   ├── after-reboot.sh           hồi phục sau khi tắt/mở máy ảo
│   ├── TestMoi.sh                test tính năng serverless
│   ├── test-golden.sh            test 5 việc Golden Config
│   └── test-all.sh               MỚI: chạy TestMoi.sh + test-golden.sh trong 1 lệnh
└── openwhisk-deploy-kube/        installer tự tải về
```

Không còn dùng `CaiDatOpenWhiskMoi.sh` và `golden/install-golden.sh`. Hai file này đã gộp vào `CaiDatOpenWhiskMoiHon.sh`, có thể xóa.

## 2. Trước khi cài

- Tailscale đã chạy: `tailscale ip -4` ra địa chỉ `100.x.x.x`.
- Máy ảo có từ 10 GB RAM trở lên (trần cụm là 8 GB).
- Máy gốc gửi file `golden/golden.lock` cho 2 máy còn lại. Máy chưa có file này sẽ tự tạo và trở thành máy gốc.

## 3. Cài đặt

```bash
cd ~/Desktop
chmod +x *.sh golden/*.sh

./XoaOpenWhiskDeCaiLai.sh          # chỉ khi muốn làm lại từ đầu, bấm y
./CaiDatOpenWhiskMoiHon.sh --test  # cài + test luôn, khoảng 15-20 phút
```

Nếu máy là cụm c1 hoặc c3 (mặc định là c2):

```bash
CLUSTER_NAME=c3 ./CaiDatOpenWhiskMoiHon.sh --test
```

Không cần mở terminal thứ hai để `watch kubectl get pods`. Script tự chờ và cứ khi số pod chưa xong thay đổi thì in một dòng tiến độ.

### Script làm gì (11 bước)

| Bước | Việc | Trước đây phải làm tay |
|---|---|---|
| 1 | Kiểm tra Tailscale, RAM máy ảo, thư mục `golden/` | |
| 2 | Cài công cụ còn thiếu: Docker, kubectl, k3d, helm, wsk | |
| 3 | Tạo cụm k3d (1 server + 2 agent, trần RAM node, taint server), gắn nhãn invoker, kiểm tra StorageClass `local-path` | |
| 4 | Tải chart, so với `golden.lock` (có `GIT_COMMIT` thì tự chuyển chart về đúng commit đó) | |
| 5 | `helm template` kiểm tra Golden Config: 600000 lần/phút, userMemory 2048m, tag ef725a6, có PVC | |
| 6 | Tải sẵn image Python vào các node invoker | |
| 7 | `helm install` một lần duy nhất bằng `golden-values.yaml` | cài chart mặc định, xong rồi `install-golden.sh --clean` gỡ đi cài lại |
| 8 | Đặt trần RAM pod, chờ mọi pod Running, xóa cứng pod kẹt Unknown | `watch kubectl get pods` |
| 9 | Trỏ `wsk` vào cụm bằng khóa guest | lấy secret, chạy `wsk property set` bằng tay |
| 10 | `deploy-actions.sh`: tạo `ping` và `test-thu`, in dòng cấu hình Gateway | chạy riêng |
| 11 | Lưu `images-<máy>.txt`, nếu có `--test` thì chạy `test-all.sh` | chạy riêng |

### Các tùy chọn

| Lệnh | Khi nào dùng |
|---|---|
| `./CaiDatOpenWhiskMoiHon.sh` | cài từ đầu, không test |
| `./CaiDatOpenWhiskMoiHon.sh --test` | cài từ đầu rồi test luôn |
| `./CaiDatOpenWhiskMoiHon.sh --redeploy` | giữ cụm k3d và dữ liệu, chỉ áp lại `golden-values.yaml` sau khi sửa |
| `./CaiDatOpenWhiskMoiHon.sh --redeploy --clean` | giữ cụm k3d nhưng gỡ sạch OpenWhisk và PVC rồi cài lại |
| thêm `--yes` | không hỏi xác nhận khi xóa cụm cũ |
| thêm `--no-preload` | bỏ bước tải sẵn image Python |

Nếu cụm k3d đã có sẵn, chạy không kèm `--redeploy` thì script hỏi trước khi xóa. Lý do: giờ dữ liệu đã lưu bền, xóa cụm là mất hết action.

## 4. Lưu bền (thay đổi chính trong `golden-values.yaml`)

```yaml
k8s:
  persistence:
    enabled: true                 # tạo PVC cho CouchDB, Kafka, ZooKeeper, Redis
    hasDefaultStorageClass: true  # dùng StorageClass mặc định: local-path có sẵn trong k3d
    explicitStorageClass: null
```

Sau khi bật lưu bền:

- Tắt/mở máy ảo hay CouchDB khởi động lại thì action và mốc khởi tạo vẫn còn, không phải cài lại.
- Dữ liệu chỉ mất khi chạy `XoaOpenWhiskDeCaiLai.sh` (xóa cụm) hoặc `--redeploy --clean`.
- Kiểm tra: `kubectl -n openwhisk get pvc`, các PVC phải ở trạng thái `Bound`.

## 5. Test

```bash
cd ~/Desktop/golden
./test-all.sh                # TestMoi.sh rồi test-golden.sh, in bảng tổng hợp
./test-all.sh --restart-db   # thêm bài tắt/bật CouchDB để chứng minh lưu bền
```

Hai bài chạy lần lượt chứ không song song, vì test-golden đo thời gian gọi lạnh và bắn 300 request, chạy chung sẽ làm sai số đo. Bài sau vẫn chạy dù bài trước lỗi.

| Phần | Nội dung | Đạt khi |
|---|---|---|
| A. TestMoi.sh | tạo action Node.js `hello-web`, bật web action, gọi 1 lần bằng wsk và 10 lần bằng curl | 10/10 lần gọi có `message` |
| B. test-golden.sh | Việc 1 trần RAM, Việc 2 hết 429, Việc 3 lưu bền (PVC Bound, CouchDB gắn PVC, còn mốc khởi tạo), Việc 4 ghim phiên bản, Việc 5 image Python; thêm Test 6 tương thích Gateway | cả 5 việc ĐẠT |

Action của TestMoi đổi tên từ `test-thu` thành `hello-web` vì `test-thu` là action Gateway dùng để ping. Nếu TestMoi ghi đè thì `test-thu` thành Node.js và mất tham số `CLUSTER`.

File kết quả nằm trong `golden/`:

- `test-all-report-<máy>.txt`: báo cáo gộp cả hai phần
- `golden-report-<máy>.txt`, `golden-debug-<máy>.txt`: báo cáo và nhật ký riêng của test-golden
- `images-<máy>.txt`, `gateway-line-<cụm>.txt`: gửi cho nhóm trưởng

## 6. Sau khi tắt/mở máy ảo

```bash
cd ~/Desktop/golden && ./after-reboot.sh --auto
```

Vì đã lưu bền, script thường chỉ chờ pod lên lại. Chỉ khi CouchDB mất mốc khởi tạo (hiếm), nó mới gọi `CaiDatOpenWhiskMoiHon.sh --redeploy --clean`.

## 7. Lỗi hay gặp

| Triệu chứng | Cách xử lý |
|---|---|
| `Vừa cài Docker. Đăng xuất rồi đăng nhập lại` | đăng xuất/đăng nhập (hoặc `newgrp docker`) rồi chạy lại |
| `Chart trên máy này KHÁC chart của máy gốc` | xin máy gốc file `golden.lock` mới (có dòng `GIT_COMMIT`) rồi chạy lại |
| `StatefulSet ... forbidden` / `volumeClaimTemplates` khi `--redeploy` | do đổi persistence trên bản đã cài: chạy `--redeploy --clean` |
| PVC `Pending` | `kubectl get storageclass` phải có `local-path (default)` |
| Pod chưa sẵn sàng khi hết giờ | `kubectl -n openwhisk get pods`, rồi chạy lại `./CaiDatOpenWhiskMoiHon.sh --redeploy` |
| Máy không phải máy gốc, vừa chạy `XoaOpenWhiskDeCaiLai.sh` | script xóa này xóa luôn `golden.lock`, nên chép lại file của máy gốc trước khi cài |
