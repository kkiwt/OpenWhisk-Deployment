# CHẠY TỪ ĐẦU ĐẾN CUỐI — toàn bộ lệnh terminal + output mong đợi

Dành cho **một cụm OpenWhisk** (máy ảo của bạn), từ lúc máy ảo trắng tinh
đến lúc hoàn thành Bước 3 Mảng C mà nhóm trưởng giao.

Ký hiệu:
- `$` = lệnh bạn gõ
- Khối sau mỗi lệnh = **output mong đợi** (rút gọn, máy bạn có thể khác chút về số/tên)
- ⏱ = bước lâu, cứ để chạy
- ⚠️ = chỗ hay sai

Tổng thời gian lần đầu: **khoảng 60–90 phút** (phần lớn là chờ tải image).

---

## PHẦN A — Máy ảo VirtualBox

### A1. Cấu hình máy ảo (làm khi VM đang TẮT)

VirtualBox → chọn VM → **Settings**:

| Mục | Giá trị | Vì sao |
|---|---|---|
| System → Base Memory | **≥ 10240 MB (10 GB)** | Trần RAM cụm là 8 GB. Máy chỉ 8 GB thì cụm sẽ kẹt `Unknown`. |
| System → Processors | **≥ 4 CPU** | Dưới 4 thì gọi lạnh quá 20 giây, Test 5 và Test 6 rớt. |
| Storage | **≥ 40 GB** | Image OpenWhisk + Python runtime khá nặng. |
| Network | NAT hoặc Bridged (có Internet) | Tailscale và Docker Hub đều cần mạng. |

Hệ điều hành: **Ubuntu 24.04**.

⚠️ `install-golden.sh` sẽ cảnh báo nếu VM dưới 9500 MB. Nó chỉ cảnh báo chứ không
tạo thêm RAM — phải tắt VM và tăng thật.

### A2. Kiểm tra sau khi bật VM

```bash
$ free -m | head -2
```
```
               total        used        free      shared  buff/cache   available
Mem:           10009         812        8745          12         451        8982
```

```bash
$ nproc && df -h / | tail -1
```
```
4
/dev/sda3        39G  8.2G   29G  23% /
```

⚠️ Dòng `total` phải **trên 9500**. Nếu không, tắt máy và quay lại A1.

---

## PHẦN B — Tailscale (nối 3 cụm lại với nhau)

```bash
$ curl -fsSL https://tailscale.com/install.sh | sh
```
```
Installing Tailscale for ubuntu 24.04, using method apt
...
Installation complete! Log in to start using Tailscale by running:
tailscale up
```

```bash
$ sudo tailscale up
```
```
To authenticate, visit:
        https://login.tailscale.com/a/xxxxxxxxxxxx
```
Mở link đó bằng trình duyệt, đăng nhập đúng tài khoản mà nhóm dùng chung.
Xong thì terminal hiện `Success.`

```bash
$ tailscale ip -4
```
```
100.64.0.2
```

👉 **Ghi lại số này.** Đây là IP cụm của bạn, lát nữa điền vào `chaos.conf` và gửi nhóm trưởng.

```bash
$ tailscale status
```
```
100.64.0.2   host_c2          vominhkiet5018@ linux   -
100.64.0.1   user_c1-inspiron-14... nkiet0651@      linux   idle
100.64.0.3    host_c3     ethancoding1310@ linux  idle
```

⚠️ Phải thấy đủ **3 máy**. Thiếu máy nào thì máy đó chưa bật — Gateway sẽ không gọi được.

```bash
$ ping -c 2 100.64.0.1
```
```
2 packets transmitted, 2 received, 0% packet loss, time 1002ms
```

---

## PHẦN C — Cài OpenWhisk

### C1. Chép script lên Desktop

Đặt `CaiDatOpenWhiskMoi.sh`, `XoaOpenWhiskDeCaiLai.sh` và thư mục `golden/` vào `~/Desktop`.

```bash
$ cd ~/Desktop && ls
```
```
CaiDatOpenWhiskMoi.sh  XoaOpenWhiskDeCaiLai.sh  golden
```

```bash
$ chmod +x CaiDatOpenWhiskMoi.sh XoaOpenWhiskDeCaiLai.sh golden/*.sh
$ ls golden/
```
```
after-reboot.sh  deploy-actions.sh  golden-values.yaml  golden.lock
HUONG-DAN.md     install-golden.sh  TestMoi.sh          test-golden.sh
```

⚠️ `golden.lock` phải là file **của máy gốc** (nhóm trưởng gửi). Nếu bạn tự sinh
file khác, Test 4 sẽ báo mã băm không khớp.

### C2. Tải trước image k3s (để thấy tiến độ thay vì treo im) ⏱

```bash
$ docker pull rancher/k3s:v1.35.5-k3s1
```
```
v1.35.5-k3s1: Pulling from rancher/k3s
...
Status: Downloaded newer image for rancher/k3s:v1.35.5-k3s1
```

⚠️ Nếu báo `permission denied ... docker.sock` nghĩa là chưa có quyền Docker.
Bỏ qua bước này, chạy C3 trước (nó tự cài Docker), rồi **đăng xuất/đăng nhập lại**.

### C3. Chạy script cài đặt ⏱ (~10 phút)

```bash
$ ./CaiDatOpenWhiskMoi.sh
```
```
🚀 BẮT ĐẦU CÀI ĐẶT HỆ THỐNG OPENWHISK...
✅ Đã tìm thấy IP Tailscale: 100.64.0.2
ℹ️  RAM của máy (VM): 10009 MB
📦 1/6: Đang cập nhật hệ thống và cài đặt Docker...
🛠 2/6: Đang cài đặt K3d, Kubectl, Helm và Wsk CLI...
🌐 3/6: Đang khởi tạo Kubernetes Cluster (K3d)...
   🔒 Khóa trần RAM node: server=1536m, mỗi agent=3328m
   🛡  Node server chỉ chạy điều khiển K3s, pod OpenWhisk sẽ chạy trên 2 agent
INFO[0042] Cluster 'openwhisk-cluster' created successfully!
🏷 4/6: Đang phân công nhiệm vụ cho 2 Invoker...
node/k3d-openwhisk-cluster-agent-0 labeled
node/k3d-openwhisk-cluster-agent-1 labeled
⚙️ 5/6: Chuẩn bị mã nguồn và cấu hình theo chuẩn đồ án...
🔥 6/6: Đang triển khai OpenWhisk Core...
✅ CÀI ĐẶT HOÀN TẤT!
```

⚠️ Nếu dòng cuối của phần Docker báo *"Vui lòng đăng xuất và đăng nhập lại"*,
hãy làm đúng vậy rồi chạy lại `./CaiDatOpenWhiskMoi.sh`.

### C4. Chờ pod lên ⏱ (10–15 phút) — mở **Terminal 2**

```bash
$ watch kubectl get pods -n openwhisk
```
Mong đợi cuối cùng:
```
NAME                                READY   STATUS      RESTARTS   AGE
owdev-alarmprovider-...             1/1     Running     0          12m
owdev-controller-0                  1/1     Running     0          12m
owdev-couchdb-...                   1/1     Running     0          13m
owdev-init-couchdb-...              0/1     Completed   0          13m
owdev-install-packages-...          0/1     Completed   0          11m
owdev-invoker-0                     1/1     Running     0          12m
owdev-invoker-1                     1/1     Running     0          12m
owdev-kafka-0                       1/1     Running     0          13m
owdev-nginx-...                     1/1     Running     0          12m
owdev-zookeeper-0                   1/1     Running     0          13m
```

Đủ `1/1 Running` thì bấm **Ctrl+C**.

Quay lại **Terminal 1**:

```bash
$ kubectl get jobs -n openwhisk
```
```
NAME                     COMPLETIONS   DURATION   AGE
owdev-init-couchdb       1/1           58s        13m
owdev-install-packages   1/1           2m14s      11m
```

### C5. Trỏ `wsk` vào cụm bằng khóa **guest**

⚠️ Phải là **guest**, không phải `system`. Gateway gọi đường dẫn `namespaces/_/`
nghĩa là namespace guest. Action tạo bằng khóa `system` thì Gateway không thấy → 404.

```bash
$ AUTH=$(kubectl get secret owdev-whisk.auth -n openwhisk -o jsonpath='{.data.guest}' | base64 -d)
$ wsk property set --apihost https://$(tailscale ip -4):31001 --auth "$AUTH"
```
```
ok: whisk auth set. Run 'wsk property get --auth' to see the value.
ok: whisk API host set to https://100.64.0.2:31001
```

```bash
$ wsk -i namespace list
```
```
namespaces
guest
```

⚠️ Ra `guest` là đúng. Ra `whisk.system` là bạn lỡ dùng khóa `system`, làm lại C5.

### C6. Test tính năng cơ bản

```bash
$ cd ~/Desktop/golden && bash TestMoi.sh
```
```
🚀 BẮT ĐẦU CHUỖI BÀI TEST TÍNH NĂNG SERVERLESS (TAILSCALE EDITION)...
✅ wsk đang dùng namespace: guest
📝 1. Tạo mã nguồn (hello.js)...
⚙️ 2. Đẩy code lên OpenWhisk (Tạo Action)...
ok: updated action test-thu
🌐 3. Mở khóa Action thành API Public...
🎯 4. Chạy test đơn (Single Request)...
--- KẾT QUẢ TỪ SERVERLESS ---
{
    "message": "Hello Kiệt, Serverless của Kiệt qua Tailscale chạy mượt rồi nhé!"
}
-----------------------------
🔥 5. KÍCH HOẠT TEST TẢI NHẸ...
{ "message": "Hello Kiet, ..." }      <- lặp lại 10 lần
✅ HOÀN TẤT BÀI TEST TÍNH NĂNG!
```

⚠️ **Chỉ chạy `TestMoi.sh` ở đây, đừng chạy lại sau Phần D.** Nó ghi đè `test-thu`
bằng action nodejs, mà `test-thu` chính là mục tiêu ping mặc định của Gateway.

---

## PHẦN D — Golden Config

### D1. Áp dụng Golden ⏱ (~10 phút)

```bash
$ cd ~/Desktop/golden && ./install-golden.sh --clean
```
```
🚀 BẮT ĐẦU ÁP DỤNG GOLDEN CONFIG CHO OPENWHISK...
🔎 1/6: Kiểm tra môi trường...
✅ kubectl nối được cụm: k3d-openwhisk-cluster
ℹ️  RAM của máy (VM): 10009 MB
✅ IP Tailscale của máy này: 100.64.0.2
📌 2/6: Ghim phiên bản chart (golden.lock)...
✅ Chart khớp golden.lock (a3f91c0e8b2d4176..., version 1.0.1)
🧪 3/6: Kiểm tra golden-values.yaml có được chart nhận không (helm template)...
✅ giới hạn gọi/phút đã nâng (hết 429)
✅ userMemory 2048m
✅ tag image đã ghim
✅ Không còn PersistentVolumeClaim (CouchDB không lưu bền)
🐍 4/6: Tải sẵn image Python vào các node...
✅ k3d-openwhisk-cluster-agent-0: đã có openwhisk/action-python-v3.11:...
✅ k3d-openwhisk-cluster-agent-1: đã có openwhisk/action-python-v3.11:...
🧹 --clean: Gỡ bản OpenWhisk cũ và xóa PVC...
✅ Đã dọn sạch namespace openwhisk
🔥 5/6: Triển khai OpenWhisk theo Golden Config...
✅ helm xong
🧱 6/6: Khóa trần RAM, chờ pod sẵn sàng và kiểm tra nhanh...
✅ statefulset.apps/owdev-controller  limit=1536Mi  request=1024Mi
✅ statefulset.apps/owdev-invoker     limit=1024Mi  request=768Mi
✅ statefulset.apps/owdev-kafka       limit=1024Mi  request=768Mi
✅ deployment.apps/owdev-couchdb      limit=768Mi   request=512Mi
✅ statefulset.apps/owdev-zookeeper   limit=384Mi   request=256Mi
⏳ Chờ tất cả pod sẵn sàng (tối đa 900s)...
✅ Mọi pod đã Running/Completed
✅ Gateway gọi được https://100.64.0.2:31001/
✅ Controller đang chạy với giới hạn 600000 lần/phút (hết 429)
✅ ÁP DỤNG GOLDEN CONFIG HOÀN TẤT!
```

⚠️ Nếu D1 báo **"Chart trên máy này KHÁC chart của máy gốc"**: xin nhóm trưởng nén
`openwhisk-deploy-kube` gửi sang, giải nén đè, rồi chạy lại. Đừng xóa `golden.lock`.

### D2. Tạo action `ping` và `test-thu` cho Gateway

⚠️ CouchDB không lưu bền, vừa `--clean` xong là action cũ mất sạch. Bắt buộc chạy bước này.

```bash
$ CLUSTER_NAME=c2 ./deploy-actions.sh
```
*(đổi `c2` thành cụm của bạn — hỏi nhóm trưởng)*
```
🚀 BẮT ĐẦU TẠO ACTION CHO GATEWAY (cụm c2)...
🔑 1/4: Lấy khóa GUEST của cụm...
✅ Đã có khóa guest
📝 2/4: Chuẩn bị mã nguồn ping.py...
⚙️ 3/4: Tạo action trong namespace guest...
ok: updated action ping
ok: updated action test-thu
✅ Đã tạo ping và test-thu
🎯 4/4: Thử gọi ĐÚNG kiểu Gateway gọi...
   Lần 1 (lạnh): HTTP 200, 8.412s  -> {"cluster":"c2","status":"ok","ts":1762...}
   Lần 2 (nóng, giới hạn 2 giây như Gateway): HTTP 200, 0.087s
✅ Gateway sẽ gọi được cụm này
👉 GỬI CHO TV1 (dán vào INITIAL_CLUSTERS trong gateway.py, thay dòng "c2"):

    "c2": ("https://100.64.0.2:31001", "MjNiYzQ2YjEt...Q="),
```

👉 **Chép dòng cuối gửi nhóm trưởng ngay.** Nó cũng nằm ở `golden/gateway-line-c2.txt`.

---

## PHẦN E — Thư mục chaos (phần thiếu + Bước 3)

### E1. Giải nén

```bash
$ cd ~/Desktop
$ unzip -o ~/Downloads/chaos.zip -d .
$ chmod +x chaos/*.sh chaos/analyze.py
$ cd chaos && ls
```
```
actions  analyze.py  CHAY-TU-DAU-DEN-CUOI.md  chaos.conf  chaos.sh
check-ready.sh  deploy-actions-plus.sh  HUONGDAN.md  results
run-chaos-exp.sh  setup-ssh.sh  setup-wskprops.sh  warmup.sh
```

### E2. Sửa `chaos.conf`

```bash
$ nano chaos.conf
```

Ba dòng bắt buộc kiểm tra:
```bash
ME="c2"                    # IP của bạn trùng dòng IP_c? nào thì điền đúng cái đó
IP_c1="100.64.0.1"
IP_c2="100.64.0.3"
IP_c3="100.64.0.2"
```
Và tên user SSH của 2 máy kia (họ chạy `whoami` để biết):
```bash
SSH_c1="user_c1@100.64.0.1"
SSH_c3="ubuntu@100.64.0.2"
```
Lưu bằng `Ctrl+O`, `Enter`, `Ctrl+X`.

⚠️ `ME` sai thì F3/F5 sẽ gây lỗi **nhầm máy của bạn khác**. Hỏi nhóm cho chắc.

### E3. Tạo nốt A1/A2/A3 + publish_result ⏱ (~1 phút)

Đây là phần `golden/deploy-actions.sh` **không** tạo, mà K6 và Dashboard lại cần.

```bash
$ ./deploy-actions-plus.sh
```
```
🔑 1/3: Lấy khóa GUEST của cụm...
✅ Đã có khóa guest
⚙️  2/3: Tạo A1 / A2 / A3 và publish_result (namespace guest)...
ok: updated action A1
ok: updated action A2
ok: updated action A3
ok: updated action publish_result
✅ Xong 4 action
🎯 3/3: Gọi thử đúng kiểu Gateway gọi...
   A1 -> HTTP 200  (6.233s)  {"action":"A1","cluster":"c2","duration_ms":50.1,...}
   A2 -> HTTP 200  (5.981s)  {"action":"A2","cluster":"c2","duration_ms":200.3,...}
   A3 -> HTTP 200  (6.104s)  {"action":"A3","cluster":"c2","duration_ms":500.2,...}
✅ HOÀN TẤT. Cụm [c2] đã sẵn sàng nhận tải K6 qua Gateway.
```

⚠️ Cả 3 phải là **HTTP 200**. Lần đầu chậm 5–10 giây là bình thường (gọi lạnh).

```bash
$ wsk -i action list
```
```
actions
/guest/publish_result       private python:3
/guest/A3                   private python:3
/guest/A2                   private python:3
/guest/A1                   private python:3
/guest/test-thu             private python:3
/guest/ping                 private python:3
```

### E4. Chuẩn bị F5 — file `.wskprops` cho 3 cụm

```bash
$ ./setup-wskprops.sh
```
```
🔑 Tạo file cấu hình cho cụm của MÁY NÀY (ME=c2)...
✅ Đã ghi /home/user/.wskprops.c2  (APIHOST=https://100.64.0.2:31001)

📋 Tình trạng 3 file:
   ❌ ~/.wskprops.c1  -> xin khóa guest của bạn giữ cụm c1 rồi chạy:
        ./setup-wskprops.sh c1 100.64.0.1 'uuid:key'
   ✅ ~/.wskprops.c2
   ❌ ~/.wskprops.c3  -> ...
```

Nhắn 2 bạn kia chạy trên máy họ:
```bash
kubectl -n openwhisk get secret owdev-whisk.auth -o jsonpath='{.data.guest}' | base64 -d
```
Họ gửi chuỗi `uuid:key`, bạn chạy:
```bash
$ ./setup-wskprops.sh c1 100.64.0.1 '23bc46b1-...:123zO3xZ...'
```
```
✅ Đã ghi /home/user/.wskprops.c1  (APIHOST=https://100.64.0.1:31001)
```

Thiếu file nào thì F5 bỏ qua cụm đó — vẫn chạy được, chỉ thiếu dữ liệu.

### E5. Chuẩn bị F1/F2/F4 — SSH không mật khẩu

Hai bạn kia phải bật SSH server trước, trên **máy họ**:
```bash
sudo apt install -y openssh-server && sudo systemctl enable --now ssh
```

Trên **máy bạn**:
```bash
$ ./setup-ssh.sh
```
```
🔑 Chưa có khóa SSH, đang tạo...
📤 c1 (user_c1@100.64.0.1): đang chép khóa (sẽ hỏi mật khẩu máy đó một lần)...
user_c1@100.64.0.1's password:
   ✅ Xong
📤 c3 (ubuntu@100.64.0.2): ...
   ✅ Xong

🧪 Thử lệnh thật mà chaos.sh sẽ dùng:
   c1: số container k3d đang chạy = 4
   c3: số container k3d đang chạy = 4
```

⚠️ Bắt buộc. Nếu `ssh` dừng lại hỏi mật khẩu giữa lúc đang đo, mốc thời gian trong
`chaos.csv` sẽ lệch và cả buổi đo vứt đi.

### E6. Kiểm tra tổng thể

```bash
$ ./check-ready.sh
```
```
🔍 KIỂM TRA ĐIỀU KIỆN - máy này là cụm [c2] - 2026-11-04 20:15:03

📋 1. Công cụ
  ✅ có kubectl ... ✅ có iptables

📋 2. Cụm Kubernetes của máy này
  ✅ kubectl nối được cụm
  ✅ cả 3 node đều Ready
  ✅ mọi pod OpenWhisk sẵn sàng
  ✅ có pod owdev-invoker-0 (cho F1)

📋 3. Container k3d (cho F2 / F4)
  ✅ đang chạy 4 container k3d-openwhisk-cluster-*
  ✅ có node k3d-openwhisk-cluster-agent-0 (cho F2)

📋 4. Action trong namespace guest
  ✅ IP Tailscale = 100.64.0.2, đọc được khóa guest
  ✅ có action ping ... ✅ có action publish_result

📋 5. Điều kiện cho chaos.sh
  ✅ SSH tới c1 (user_c1@100.64.0.1) OK
  ℹ️  c2 = máy này (chạy lệnh trực tiếp)
  ✅ SSH tới c3 (ubuntu@100.64.0.2) OK
  ✅ có ~/.wskprops.c1  ✅ có ~/.wskprops.c2  ✅ có ~/.wskprops.c3
  ℹ️  sudo sẽ hỏi mật khẩu -> chạy 'sudo -v' ngay trước khi dùng F3

📋 6. Gateway của Máy 1
  ✅ Gateway http://100.64.0.1:8080 đang chạy

============================================================
  ĐẠT: 23    |    CHƯA ĐẠT: 0
============================================================
✅ Sẵn sàng gây lỗi.
```

**Phải `CHƯA ĐẠT: 0`** mới đi tiếp. Mỗi dòng ❌ đều có kèm lệnh sửa.

---

## PHẦN F — Chấm điểm Golden (Test 6 sẽ ĐẠT)

```bash
$ cd ~/Desktop/chaos && ./warmup.sh
```
```
🔥 Làm nóng action: ping test-thu A1 A2 A3
   (Gateway ping mỗi 2 giây với timeout 2 giây, nên mục tiêu là lần gọi nóng < 2s)

  ping         ✅ lạnh 7.201s -> nóng 0.081s
  test-thu     ✅ lạnh 6.934s -> nóng 0.079s
  A1           ✅ lạnh 6.512s -> nóng 0.142s
  A2           ✅ lạnh 6.773s -> nóng 0.295s
  A3           ✅ lạnh 7.008s -> nóng 0.604s

✅ Container đã nóng. CHẠY NGAY (đừng chờ lâu, container nguội sau ~10 phút):
   ~/Desktop/golden/test-golden.sh
```

**Chạy ngay, đừng nghỉ giải lao:**

```bash
$ ~/Desktop/golden/test-golden.sh
```
⏱ khoảng 3–5 phút. Output mong đợi ở phần cuối:
```
============================================================
📊 TỔNG KẾT (host_c2)
============================================================
  (phụ)   Kết nối API                ĐẠT
  (phụ)   Tương thích Gateway        ĐẠT
  Việc 1  Khóa trần RAM              ĐẠT
  Việc 2  Hết lỗi 429                ĐẠT
  Việc 3  CouchDB không lưu bền      ĐẠT
  Việc 4  Ghim phiên bản             ĐẠT
  Việc 5  Tải sẵn image Python       ĐẠT
  Báo cáo lưu tại: /home/user/Desktop/golden/golden-report-host_c2.txt
============================================================
✅ CẢ 5 VIỆC ĐẠT!
```

👉 **Chụp màn hình bảng TỔNG KẾT này.** Đây là bằng chứng nộp báo cáo.

Nếu "Tương thích Gateway" vẫn KHÔNG ĐẠT, xem dòng `TEST 6` ở trên bảng:
- `HTTP 404` → thiếu action: `~/Desktop/golden/deploy-actions.sh`
- `HTTP 000` → vẫn gọi lạnh: chạy lại `./warmup.sh` rồi chạy test **ngay lập tức**

Kiểm tra RAM thật:
```bash
$ docker stats --no-stream | grep k3d
```
```
k3d-openwhisk-cluster-server-0    12.34%   1.102GiB / 1.5GiB
k3d-openwhisk-cluster-agent-0     28.91%   2.441GiB / 3.25GiB
k3d-openwhisk-cluster-agent-1     26.07%   2.318GiB / 3.25GiB
```
Tổng phải **≤ 8 GB**.

---

## PHẦN G — TASK CHÍNH: Bước 3, năm tình huống lỗi

### G1. Tập dượt trước (bắt buộc, khi CHƯA có tải)

`DRY=1` chỉ in lệnh, không thực thi. Đọc kỹ xem tên pod/container có đúng máy bạn không.

```bash
$ DRY=1 ./chaos.sh pod start
```
```
⚠️  CHẾ ĐỘ TẬP DƯỢT (DRY=1): chỉ in lệnh, không thực thi.
🕒 2026-11-04T13:22:10.431Z  F1 start  (cụm: c2)
   [DRY-local] kubectl -n openwhisk delete pod owdev-invoker-0 --force --grace-period=0
✅ Đã xóa pod invoker của [c2]...
```

```bash
$ DRY=1 ./chaos.sh node start
$ DRY=1 ./chaos.sh tailscale start --target c3
$ DRY=1 ./chaos.sh cluster start --target c3
$ DRY=1 ./chaos.sh station start
```

Đối chiếu tên thật:
```bash
$ docker ps --format '{{.Names}}' | grep k3d
$ kubectl get pods -n openwhisk | grep invoker
```
Lệch thì sửa `AGENT_NODE` / `INVOKER_POD` / `K3D_CLUSTER` trong `chaos.conf`.

### G2. F1 — Chết Pod (an toàn nhất, thử đầu tiên)

```bash
$ ./chaos.sh pod start
```
```
🕒 2026-11-04T13:25:02.118Z  F1 start  (cụm: c2)
   [local] kubectl -n openwhisk delete pod owdev-invoker-0 --force --grace-period=0
pod "owdev-invoker-0" force deleted
✅ Đã xóa pod invoker của [c2]. Kubernetes sẽ TỰ dựng lại (không cần stop).
   Theo dõi: kubectl -n openwhisk get pod owdev-invoker-0 -w
```

Terminal 2:
```bash
$ kubectl -n openwhisk get pod owdev-invoker-0 -w
```
```
owdev-invoker-0   0/1   Pending             0     0s
owdev-invoker-0   0/1   Init:0/1            0     2s
owdev-invoker-0   0/1   PodInitializing     0     18s
owdev-invoker-0   1/1   Running             0     34s
```
Ctrl+C khi thấy `1/1 Running`.

```bash
$ ./chaos.sh pod stop
```
```
🕒 2026-11-04T13:25:51.904Z  F1 stop  (cụm: c2)
   [local] kubectl -n openwhisk wait --for=condition=Ready pod/owdev-invoker-0 --timeout=300s
pod/owdev-invoker-0 condition met
✅ Pod invoker của [c2] đã trở lại.
```

**Kết luận ghi báo cáo:** Kubernetes tự hồi phục sau ~35 giây, không cần can thiệp tay.

### G3. F2 — Chết Node

```bash
$ ./chaos.sh node start
```
```
🕒 2026-11-04T13:31:12.550Z  F2 start  (cụm: c2)
   [local] docker stop k3d-openwhisk-cluster-agent-0
k3d-openwhisk-cluster-agent-0
✅ Đã tắt node [k3d-openwhisk-cluster-agent-0] của cụm [c2].
⚠️  Nhớ chạy './chaos.sh node stop --target c2' để bật lại.
```

```bash
$ kubectl get nodes
```
```
NAME                             STATUS     ROLES                  AGE   VERSION
k3d-openwhisk-cluster-agent-0    NotReady   <none>                 58m   v1.35.5+k3s1
k3d-openwhisk-cluster-agent-1    Ready      <none>                 58m   v1.35.5+k3s1
k3d-openwhisk-cluster-server-0   Ready      control-plane,master   58m   v1.35.5+k3s1
```

```bash
$ ./chaos.sh node stop
```
```
🕒 2026-11-04T13:34:40.112Z  F2 stop  (cụm: c2)
   [local] docker start k3d-openwhisk-cluster-agent-0
   [local] kubectl wait --for=condition=Ready node/... --timeout=300s
node/k3d-openwhisk-cluster-agent-0 condition met
✅ Node [...] của cụm [c2] đã chạy lại.
```

**Kết luận:** mất 1 invoker, cụm vẫn phục vụ bằng invoker còn lại, độ trễ tăng.

### G4. F3 — Đứt mạng Tailscale ⚠️ nguy hiểm nhất

```bash
$ sudo -v                                        # nhập mật khẩu TRƯỚC, đừng để nó hỏi giữa chừng
$ ./chaos.sh tailscale start --target c3
```
```
🕒 2026-11-04T13:40:05.773Z  F3 start  (cụm: c3)
   [local] sudo iptables -I OUTPUT -d 100.64.0.2 -p tcp --dport 31001 -j DROP
✅ Đã chặn đường từ máy này tới [c3] (100.64.0.2:31001). SSH vẫn thông.
⚠️  Nhớ chạy './chaos.sh tailscale stop --target c3' để gỡ chặn.
```

Chứng minh đã chặn (treo tới khi hết giờ):
```bash
$ curl -sk --max-time 5 https://100.64.0.2:31001/ ; echo "exit=$?"
```
```
exit=28
```
`28` = hết giờ, đúng như mong đợi. SSH vẫn vào được:
```bash
$ ssh ubuntu@100.64.0.2 'echo van-vao-duoc'
```
```
van-vao-duoc
```

```bash
$ ./chaos.sh tailscale stop --target c3
$ ./chaos.sh status
```
```
✅ Không có lỗi nào đang bật.

=== LUẬT IPTABLES ĐANG CHẶN CỔNG 31001 ===
   (không có)
```

⚠️ **Luôn chạy `status` sau F3.** Một luật sót lại sẽ âm thầm chặn cụm đó mãi
và bạn sẽ debug nhầm hàng giờ. Lỡ Ctrl+C giữa chừng thì `./chaos.sh reset`.

**Kết luận:** Gateway ping hỏng 3 lần liên tiếp → ngắt cầu dao, dồn tải sang 2 cụm kia.

### G5. F4 — Chết cả cụm

```bash
$ ./chaos.sh cluster start --target c3
```
```
🕒 2026-11-04T13:48:30.201Z  F4 start  (cụm: c3)
   [ssh ubuntu@100.64.0.2] docker stop $(docker ps -q --filter name=k3d-openwhisk-cluster)
✅ Đã tắt toàn bộ cụm [c3].
```

```bash
$ ./chaos.sh cluster stop --target c3
```
```
   [ssh ubuntu@100.64.0.2] docker start $(docker ps -aq --filter name=k3d-openwhisk-cluster)
✅ Đã bật lại cụm [c3].
⚠️  CouchDB không lưu bền: nếu pod kẹt, chạy ~/Desktop/golden/after-reboot.sh trên máy đó.
```

⚠️ Sau F4, cụm c3 gần như chắc chắn mất mốc khởi tạo CouchDB. Bạn giữ cụm c3 phải chạy:
```bash
cd ~/Desktop/golden && ./after-reboot.sh --auto
```
Báo trước cho bạn ấy, đừng tắt cụm người khác rồi biến mất.

### G6. F5 — Trạm nhận hàng chết

```bash
$ ./chaos.sh station start
```
```
🕒 2026-11-04T13:58:14.667Z  F5 start  (cụm: all)
✅ [c1] TARGET_URL -> http://10.255.255.1:9
✅ [c2] TARGET_URL -> http://10.255.255.1:9
✅ [c3] TARGET_URL -> http://10.255.255.1:9
```

Kiểm chứng: action vẫn chạy, chỉ là không gửi về Dashboard được.
```bash
$ wsk -i action invoke A1 --blocking --result --param SAMPLE_RATE 1
```
```json
{
    "action": "A1",
    "cluster": "c2",
    "duration_ms": 50.12,
    "publish_status": "submitted",
    "status": "ok"
}
```
Nhưng trên Máy 1, Dashboard không nhận thêm bản ghi nào:
```bash
$ curl -s http://100.64.0.1:9000/api/recent?limit=3
```
```
[]
```

```bash
$ ./chaos.sh station stop
```
```
✅ [c1] TARGET_URL -> http://100.64.0.1:9000
✅ [c2] TARGET_URL -> http://100.64.0.1:9000
✅ [c3] TARGET_URL -> http://100.64.0.1:9000
```

**Kết luận:** tách bạch được **lỗi tính toán** (cụm chết) và **lỗi báo cáo**
(cụm sống nhưng Dashboard mù) — đây là điểm hay nhất của F5 khi viết báo cáo.

### G7. Dọn sạch cuối buổi

```bash
$ ./chaos.sh reset && ./chaos.sh status
```
```
🧹 Gỡ HẾT mọi lỗi đang bật...
✅ Đã dọn xong. Kiểm tra lại bằng: ./chaos.sh status

=== TRẠNG THÁI CÁC LỖI ĐANG BẬT ===
✅ Không có lỗi nào đang bật.
=== LUẬT IPTABLES ĐANG CHẶN CỔNG 31001 ===
   (không có)
```

---

## PHẦN H — Thí nghiệm có tải (E5), khi Gateway và K6 đã sẵn sàng

Cần Máy 1 đang chạy Gateway (`./start.sh`) và có `run_exp.sh` của Tấn Kiệt.

```bash
$ curl -s http://100.64.0.1:8080/admin/clusters | python3 -m json.tool
```
```json
{
    "config": { "policy": "rr", "breaker_on": true, "probe_action": "test-thu" },
    "nodes": {
        "c1": { "available": true, "up": true, "fails": 0, "ewma_ms": 84.2 },
        "c2": { "available": true, "up": true, "fails": 0, "ewma_ms": 91.7 },
        "c3": { "available": true, "up": true, "fails": 0, "ewma_ms": 88.1 }
    }
}
```
Cả 3 cụm `"up": true` mới bắt đầu đo.

```bash
$ K6_DIR=~/Desktop/k6 ./run-chaos-exp.sh e5_pod 30 pod --target c2
```
```
============================================================
  Thí nghiệm : e5_pod
  Tải        : 30 request/giây trong 300s
  Tình huống : pod --target c2
  Lịch       : 60s bình thường -> gây lỗi -> 120s -> sửa lỗi -> 120s
============================================================
Bắt đầu? (y/n): y
⏳ Giai đoạn 1: chạy bình thường 60s...
💥 Giai đoạn 2: GÂY LỖI [pod]
🕒 ... F1 start (cụm: c2)
⏳ Giữ lỗi 120s...
🔧 Giai đoạn 3: SỬA LỖI [pod]
⏳ Giai đoạn 4: chờ hồi phục 120s...
✅ XONG. Kết quả K6 ở ~/Desktop/k6/results/, mốc lỗi ở results/chaos.csv
```

Lặp lại cho các tình huống khác:
```bash
$ ./run-chaos-exp.sh e5_node    30 node    --target c2
$ ./run-chaos-exp.sh e5_net     30 tailscale --target c3
$ ./run-chaos-exp.sh e5_cluster 30 cluster --target c3
$ ./run-chaos-exp.sh e5_station 30 station
```

### Vẽ biểu đồ

```bash
$ pip install pandas matplotlib
$ ls ~/Desktop/k6/results/
```
```
e5_pod_20261104_201500_8821  e5_node_20261104_203012_8933
```
```bash
$ python3 analyze.py ~/Desktop/k6/results/e5_pod_20261104_201500_8821
```
```
📂 /home/user/Desktop/k6/results/e5_pod_20261104_201500_8821

┌─ TÓM TẮT K6 ─────────────────────────────┐
│ Tổng số request   : 8974
│ Thực tế (req/giây): 29.9
│ Trung vị          : 118 ms
│ P95               : 467 ms
│ Tỉ lệ lỗi         : 0.82 %
└──────────────────────────────────────────┘

┌─ TÀI NGUYÊN (tổng các container k3d) ────┐
│ CPU  trung bình : 94 %
│ CPU  đỉnh       : 187 %
│ RAM  trung bình : 5412 MiB
│ RAM  đỉnh       : 6803 MiB (6.64 GiB)
└──────────────────────────────────────────┘

🕒 MỐC GÂY LỖI TRONG LẦN ĐO NÀY
   20:16:00  F1 start  (c2)
   20:18:02  F1 stop   (c2)

🖼  Đã lưu biểu đồ: .../bieudo-cpu-ram.png
```

Ảnh `bieudo-cpu-ram.png` có **vạch đỏ = gây lỗi, vạch xanh = sửa lỗi** — dán thẳng vào báo cáo.

---

## PHẦN I — Mở lại máy ảo ở những buổi sau

Không phải cài lại từ đầu. Mỗi lần bật VM:

```bash
# 1. Chờ Docker lên (~2 phút sau khi đăng nhập)
$ docker ps | head -2

# 2. Hồi phục cụm
$ cd ~/Desktop/golden && ./after-reboot.sh --auto
```
```
🚀 BẮT ĐẦU HỒI PHỤC SAU KHI MỞ MÁY...
🖥  1/5: Chờ các node k3d Ready...
🩹 2/5: Xóa cứng pod kẹt Unknown...
🗄  3/5: Kiểm tra dữ liệu khởi tạo của CouchDB...
   Danh sách CSDL trong CouchDB: ["_replicator","_users"]
⚠️  CouchDB MẤT dữ liệu khởi tạo (đúng như thiết kế 'không lưu bền').
🔥 4/5: Cài lại bằng install-golden.sh --clean...
...
🎯 5/5: Tạo lại action cho Gateway...
✅ HỒI PHỤC HOÀN TẤT!
```

```bash
# 3. Tạo lại A1/A2/A3 + publish_result (after-reboot.sh KHÔNG tạo 4 cái này)
$ cd ~/Desktop/chaos && ./deploy-actions-plus.sh

# 4. Kiểm tra
$ ./check-ready.sh

# 5. Gửi lại dòng cấu hình cho nhóm trưởng nếu IP Tailscale đổi
$ tailscale ip -4 && cat ~/Desktop/golden/gateway-line-*.txt
```

⚠️ Bước 3 rất hay bị quên. Quên là K6 trả 404 và Gateway ngắt cụm bạn.

---

## PHẦN J — Khi cần cài lại sạch sẽ

```bash
$ cd ~/Desktop && ./XoaOpenWhiskDeCaiLai.sh
```
```
⚠️ CẢNH BÁO: Quá trình này sẽ XÓA SẠCH cụm OpenWhisk và dữ liệu liên quan!
Bác có chắc chắn muốn tiếp tục không? (y/n): y
🛟 0/5: Cứu các file Golden...
🧹 1/5: Gỡ cài đặt Helm Release của OpenWhisk...
🔥 3/5: Đập bỏ cụm K3d Cluster...
🐳 5/5: Dọn dẹp hệ thống Docker...
✅ ĐÃ XÓA SẠCH DẤU VẾT CỦA OPENWHISK!
   (các file Golden được giữ nguyên trong thư mục golden/)
```

⚠️ Script này xóa `golden/golden.lock`. **Xin lại file của máy gốc** trước khi
chạy `install-golden.sh`, nếu không bạn sẽ tự sinh lock mới và Test 4 không khớp 3 máy.

Rồi quay lại **PHẦN C3**.

---

## Nộp gì cho nhóm trưởng

| File | Lấy ở đâu |
|---|---|
| `golden-report-<tên-máy>.txt` | `~/Desktop/golden/` — bảng TỔNG KẾT 5 việc |
| `images-<tên-máy>.txt` | `~/Desktop/golden/` — để đối chiếu image 3 máy |
| `gateway-line-c?.txt` | `~/Desktop/golden/` — dòng dán vào `gateway.py` |
| `results/chaos.csv` | `~/Desktop/chaos/` — mốc thời gian 5 tình huống |
| `bieudo-cpu-ram.png` | trong từng thư mục kết quả K6 |
| Ảnh chụp bảng TỔNG KẾT | màn hình sau `test-golden.sh` |

Nén lại:
```bash
$ cd ~/Desktop && zip -r nopbai-$(hostname).zip \
    golden/golden-report-*.txt golden/images-*.txt golden/gateway-line-*.txt \
    chaos/results/chaos.csv
```
```
  adding: golden/golden-report-host_c2.txt (deflated 71%)
  adding: golden/images-host_c2.txt (deflated 62%)
  adding: golden/gateway-line-c2.txt (deflated 18%)
  adding: chaos/results/chaos.csv (deflated 74%)
```
