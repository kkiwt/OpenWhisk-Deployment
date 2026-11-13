# CHAOS - Bước 3 Mảng C (gây lỗi có kiểm soát)

Thư mục này đặt tại `~/Desktop/chaos`. Nó **không sửa gì** trong `~/Desktop/golden`,
`CaiDatOpenWhiskMoi.sh` hay `XoaOpenWhiskDeCaiLai.sh`.

---

## 0. Trả lời nhanh 2 câu hỏi

### NOTE 1 - Máy mình có thiếu gateway không?

**Không.** `openwhisk-gateway/` là chương trình của Máy 1 (nhóm trưởng), chạy **một bản duy nhất**
cho cả nhóm. Máy của bạn là *cụm bị gọi tới*, không phải nơi chạy Gateway.
`HUONG-DAN.md` trong golden cũng ghi rõ điều này ở mục 4.

**Test 6 rớt vì 2 lý do khác, cả hai đều sửa được:**

| Hiện tượng trong report | Nguyên nhân thật | Cách sửa |
|---|---|---|
| `HTTP 404` | Chưa có action `ping` trong namespace guest. CouchDB cố ý **không lưu bền**, nên cứ cài lại cụm hoặc tắt/mở máy ảo là action biến mất. | `~/Desktop/golden/deploy-actions.sh` |
| `HTTP 000` (hay rớt "ngẫu nhiên") | Test 6 gọi với `--max-time 10`. Lần gọi đầu là **gọi lạnh**, OpenWhisk phải dựng container Python mới, trên máy ảo thường mất 10-20 giây (chính Test 5 cũng để `COLD_MAX=20`). Quá 10 giây thì curl trả 000, Test 6 kết luận "Gateway sẽ ngắt cụm" dù cụm hoàn toàn khỏe. | Chạy `./warmup.sh` **ngay trước** `test-golden.sh` |

Nên trước mỗi lần chấm điểm:

```bash
cd ~/Desktop/chaos && ./warmup.sh && ~/Desktop/golden/test-golden.sh
```

### NOTE 2 - Task của bạn Tấn Kiệt có liên quan tới máy mình không?

**Có, một phần, và phần đó nằm ở máy bạn.** Tấn Kiệt làm Dashboard + K6, nhưng cả hai
đều cần action nằm **trên từng cụm**:

- K6 bắn vào `POST /invoke/A1`, `/invoke/A2`, `/invoke/A3`. Gateway chia tải vòng tròn
  cho cả 3 cụm, nên **cụm của bạn phải có A1/A2/A3** trong namespace guest. Thiếu là
  Gateway nhận 404, ngắt cầu dao, và số liệu K6 sai hoàn toàn.
- Dashboard nhận dữ liệu từ action `publish_result`. Action này cũng phải có **trên cụm của bạn**.
- `golden/deploy-actions.sh` chỉ tạo `ping` và `test-thu`, **không tạo** 4 action kia.

Vì vậy thư mục này có sẵn `./deploy-actions-plus.sh` để tạo nốt. Đây chính là phần đang
thiếu trên máy bạn, chứ không phải gateway.

Mọi thứ còn lại của Tấn Kiệt (chạy Dashboard trên cổng 9000, chạy K6) đều ở Máy 1,
bạn không phải cài.

---

## 1. Cây thư mục

```
~/Desktop/
├── CaiDatOpenWhiskMoi.sh
├── XoaOpenWhiskDeCaiLai.sh
├── golden/                      <- giữ nguyên, không đụng vào
│   ├── install-golden.sh
│   ├── deploy-actions.sh
│   ├── after-reboot.sh
│   └── test-golden.sh
└── chaos/                       <- THƯ MỤC NÀY
    ├── chaos.conf               <- SỬA FILE NÀY TRƯỚC TIÊN
    ├── chaos.sh                 <- 5 tình huống lỗi (việc chính của Bước 3)
    ├── check-ready.sh           <- kiểm tra đủ điều kiện trước khi gây lỗi
    ├── deploy-actions-plus.sh   <- tạo A1/A2/A3 + publish_result
    ├── warmup.sh                <- làm nóng action, cứu Test 6
    ├── setup-wskprops.sh        <- tạo ~/.wskprops.c1/.c2/.c3 (cho F5)
    ├── setup-ssh.sh             <- SSH không mật khẩu sang 2 máy kia (F1/F2/F4)
    ├── run-chaos-exp.sh         <- chạy K6 + chèn lỗi theo lịch (thí nghiệm E5)
    ├── analyze.py               <- bảng số + biểu đồ (hỗ trợ Bước 4)
    ├── actions/
    │   ├── a_generic.py         <- mã dùng chung cho A1/A2/A3
    │   └── publish_result.py    <- giữ nguyên mã của Tấn Kiệt
    └── results/
        └── chaos.csv            <- mốc thời gian gây/sửa lỗi (tự sinh)
```

---

## 2. Cài đặt lần đầu (làm một lần)

```bash
cd ~/Desktop
# giải nén gói này ra đây, sẽ có thư mục chaos/
chmod +x chaos/*.sh chaos/analyze.py
cd chaos
```

### Bước 2.1 - Sửa `chaos.conf`

Mở bằng `nano chaos.conf` và kiểm tra **3 dòng quan trọng nhất**:

```bash
ME="c2"                    # máy này là cụm nào? HỎI LẠI NHÓM CHO CHẮC
IP_c1="100.64.0.1"      # Máy 1, nơi chạy Gateway
IP_c2="100.64.0.3"
IP_c3="100.64.0.2"
```

Lấy IP của chính máy mình: `tailscale ip -4`. Dòng nào trùng, đó là cụm của bạn.
Tên user SSH (`SSH_c1`, `SSH_c2`, `SSH_c3`) hỏi 2 bạn kia, dạng `tênuser@IP`
(xem bằng `whoami` trên máy họ).

### Bước 2.2 - Tạo nốt các action còn thiếu

```bash
./deploy-actions-plus.sh
```

Script tạo `A1`, `A2`, `A3`, `publish_result` trong namespace guest rồi gọi thử.
Mong đợi: cả 3 action trả `HTTP 200`.

> **Phải chạy lại** sau mỗi lần cài lại cụm hoặc tắt/mở máy ảo, y như `deploy-actions.sh`.

### Bước 2.3 - Chuẩn bị cho F5

```bash
./setup-wskprops.sh
```

Tạo `~/.wskprops.<cụm của bạn>`. Hai file còn lại cần khóa guest của 2 bạn kia.
Nhắn họ chạy:

```bash
kubectl -n openwhisk get secret owdev-whisk.auth -o jsonpath='{.data.guest}' | base64 -d
```

rồi bạn chạy (ví dụ cho c3):

```bash
./setup-wskprops.sh c3 100.64.0.2 'uuid:key-họ-gửi'
```

Thiếu file nào thì F5 bỏ qua cụm đó, vẫn chạy được nhưng số liệu không đủ 3 cụm.

### Bước 2.4 - Chuẩn bị cho F1/F2/F4 trên máy người khác

```bash
./setup-ssh.sh
```

Hỏi mật khẩu một lần cho mỗi máy, sau đó `ssh` không cần mật khẩu nữa.
Điều này **bắt buộc**: nếu `ssh` dừng lại hỏi mật khẩu giữa lúc đang đo,
mốc thời gian trong `chaos.csv` sẽ lệch và số liệu vứt đi.

Máy kia phải bật SSH server trước: `sudo apt install -y openssh-server`.

### Bước 2.5 - Kiểm tra tổng thể

```bash
./check-ready.sh
```

Script chỉ đọc, không sửa gì. Sửa hết các dòng ❌ rồi mới sang phần 3.

---

## 3. Năm tình huống lỗi

```bash
./chaos.sh list      # xem bảng tóm tắt
```

| Mã | Lệnh | Việc script làm | Mong đợi quan sát được |
|---|---|---|---|
| **F1** | `./chaos.sh pod start/stop` | Xóa cứng pod `owdev-invoker-0` | Kubernetes tự dựng lại trong ~30-60s. Vài request lỗi rồi tự hết. |
| **F2** | `./chaos.sh node start/stop` | `docker stop` node agent | Pod trên node đó mất, cụm vẫn chạy bằng node còn lại, chậm hơn. |
| **F3** | `./chaos.sh tailscale start/stop` | `iptables DROP` tới `IP:31001` | Gateway ping hỏng 3 lần liên tiếp → **ngắt cầu dao**, dồn tải sang 2 cụm kia. |
| **F4** | `./chaos.sh cluster start/stop` | `docker stop` toàn bộ container k3d của một cụm | Giống F3 nhưng nặng hơn, hồi phục lâu hơn (CouchDB mất dữ liệu). |
| **F5** | `./chaos.sh station start/stop` | Đổi `TARGET_URL` của `publish_result` sang địa chỉ chết | Cụm vẫn chạy, K6 vẫn OK, nhưng **Dashboard im lặng** — tách bạch lỗi tính toán và lỗi báo cáo. |

### Tập dượt trước (bắt buộc, làm khi CHƯA có tải)

```bash
DRY=1 ./chaos.sh pod start          # chỉ in lệnh, không thực thi
DRY=1 ./chaos.sh cluster start --target c3
```

Đọc kỹ dòng lệnh in ra. Tên pod/container trên máy bạn có thể khác, kiểm tra bằng:

```bash
docker ps --format '{{.Names}}' | grep k3d
kubectl get pods -n openwhisk
```

Sai thì sửa `AGENT_NODE` / `INVOKER_POD` / `K3D_CLUSTER` trong `chaos.conf`.

### Thử thật từng cái một

```bash
./chaos.sh pod start                 # trên cụm của chính mình, an toàn nhất
kubectl -n openwhisk get pod owdev-invoker-0 -w    # xem K8s dựng lại, Ctrl+C
./chaos.sh pod stop
```

Chọn cụm khác bằng `--target`:

```bash
./chaos.sh node start --target c3
./chaos.sh node stop  --target c3
```

### Hai lệnh cứu hộ

```bash
./chaos.sh status     # lỗi nào đang bật? luật iptables nào còn sót?
./chaos.sh reset      # TẮT HẾT. Chạy mỗi khi lỡ Ctrl+C giữa chừng.
```

> ⚠️ Quan trọng nhất là **F3**. Một luật `iptables` sót lại sẽ âm thầm chặn
> cụm đó mãi mãi và bạn sẽ debug nhầm hàng giờ. Luôn `./chaos.sh status`
> sau mỗi buổi làm.

---

## 4. Chạy thí nghiệm có tải (E5)

Cần Gateway (Máy 1) và K6 đang sẵn sàng. Nếu K6 của Tấn Kiệt nằm ở `~/Desktop/k6`:

```bash
./run-chaos-exp.sh e5_pod 30 pod --target c2
```

Kịch bản mặc định: 60 giây chạy bình thường → gây lỗi → giữ 120 giây → sửa lỗi →
chờ hồi phục 120 giây. Đổi bằng biến:

```bash
WARM=60 HOLD=180 TAIL=120 K6_DIR=~/Desktop/k6 \
  ./run-chaos-exp.sh e5_cluster 30 cluster --target c3
```

Mọi mốc thời gian được `chaos.sh` ghi vào `results/chaos.csv`, K6 ghi vào
`~/Desktop/k6/results/<tên>_<ngày giờ>/`.

### Vẽ biểu đồ (hỗ trợ Bước 4 của nhóm)

```bash
pip install pandas matplotlib
python3 analyze.py ~/Desktop/k6/results/e5_pod_20261104_193000_1234
```

In bảng req/s, P95, tỉ lệ lỗi, CPU/RAM đỉnh, và lưu `bieudo-cpu-ram.png`
với **vạch đỏ = lúc gây lỗi, vạch xanh = lúc sửa lỗi**. Ảnh đó dán thẳng vào báo cáo.

---

## 5. Quy trình một buổi làm việc hoàn chỉnh

```bash
# 1. Mở máy ảo, chờ Docker lên (~2 phút)
cd ~/Desktop/golden && ./after-reboot.sh

# 2. Tạo nốt action cho K6 và Dashboard
cd ~/Desktop/chaos && ./deploy-actions-plus.sh

# 3. Kiểm tra mọi thứ
./check-ready.sh

# 4. Làm nóng rồi chấm Golden (Test 6 sẽ ĐẠT)
./warmup.sh && ~/Desktop/golden/test-golden.sh

# 5. Gửi dòng cấu hình cho nhóm trưởng
cat ~/Desktop/golden/gateway-line-*.txt

# 6. Gây lỗi (tập dượt trước bằng DRY=1)
DRY=1 ./chaos.sh pod start
./chaos.sh pod start
./chaos.sh pod stop

# 7. Hết buổi: dọn sạch
./chaos.sh reset && ./chaos.sh status
```

---

## 6. Hay gặp

| Triệu chứng | Nguyên nhân | Xử lý |
|---|---|---|
| `test-golden.sh` Test 6 báo 404 | Mất action sau khi cài lại / mở máy | `~/Desktop/golden/deploy-actions.sh` |
| Test 6 báo 000 hoặc rớt thất thường | Gọi lạnh quá 10 giây | `./warmup.sh` rồi chạy test **ngay** |
| K6 trả 404 cho `/invoke/A2` | Cụm thiếu action A2 | `./deploy-actions-plus.sh` |
| `chaos.sh` báo "Chưa khai báo SSH_c3" | Thiếu dòng trong `chaos.conf` | Sửa `chaos.conf`, rồi `./setup-ssh.sh` |
| F3 chạy xong mà cụm vẫn không gọi được | Luật iptables còn sót | `./chaos.sh reset` |
| F5 bỏ qua hết 3 cụm | Chưa có `~/.wskprops.c*` | `./setup-wskprops.sh` |
| Sau F4, pod kẹt `Init:0/1` mãi | CouchDB không lưu bền, mất mốc khởi tạo | Trên máy đó: `~/Desktop/golden/after-reboot.sh` |
| `./chaos.sh` hỏi mật khẩu sudo giữa chừng | F3 cần iptables | Chạy `sudo -v` ngay trước khi đo |
