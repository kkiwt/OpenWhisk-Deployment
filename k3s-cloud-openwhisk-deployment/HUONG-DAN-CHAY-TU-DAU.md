# CHẠY TỪ ĐẦU ĐẾN CUỐI: K3s thật trên CloudFly + OpenWhisk + Gateway

Dành cho **3 VM CloudFly trắng** (Ubuntu), đến lúc cụm **c4** nhận tải K6 qua Gateway và chịu được chaos F1–F5.

Ký hiệu:
- `$` = lệnh bạn gõ. Khối ngay sau = **kết quả mong đợi** (rút gọn; số/tên máy bạn sẽ khác).
- ⏱ = bước lâu, cứ để chạy. ⚠️ = chỗ hay sai.
- **IP trong tài liệu là minh họa.** Mọi số đo (P95, req/s…) trong ví dụ cũng chỉ minh họa, không đưa vào báo cáo; chỉ dùng số do K6 của bạn đo thật.

Tổng thời gian lần đầu: khoảng **75–100 phút** (phần lớn là chờ tải image).

## Ghi lại trong lúc làm (điền dần)

| Máy | Hostname | IP Tailscale |
|---|---|---|
| Master | `k3s-cloud-master` | `100.88.1.10` |
| Worker 1 | `k3s-cloud-w1` | `100.88.1.11` |
| Worker 2 | `k3s-cloud-w2` | `100.88.1.12` |
| Gateway (Máy 1) | | `100.88.1.1` |
| Dashboard | | `100.88.1.3` |

---

## PHẦN A: Chuẩn bị

### A1. Cấu hình VM

| Mục | Giá trị | Vì sao |
|---|---|---|
| OS | Ubuntu 22.04 hoặc 24.04, **cả 3 máy cùng bản** | Cùng kernel/containerd, đỡ lỗi lạ |
| Server | 2 vCPU / 4 GB | Control-plane + được phép chạy workload |
| Agent x2 | 2 vCPU / 2.5 GB mỗi máy | Chạy workload cùng server; có resource quota |
| Đĩa | ≥ 30 GB mỗi máy | Image OpenWhisk + PV `local-path` nằm trên đĩa node |
| Swap | **Tắt** (script tự tắt) | Swap làm JVM đẩy ra đĩa, P99 tăng vọt |

### A0. Máy Windows và công cụ quản trị

Windows không chạy k3s node native. Dùng Windows làm máy quản trị/Gateway/K6, còn
server và agent chạy Ubuntu VM (hoặc Ubuntu trong WSL2 cho môi trường lab).

Trên Windows PowerShell (Run as Administrator):

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\00-install-windows-prerequisites.ps1
```

Trên cả ba Ubuntu VM:

```bash
chmod +x scripts/*.sh openwhisk/*.sh actions/*.sh gateway/*.sh tests/*.sh
sudo ./scripts/00-install-linux-prerequisites.sh
```

Script Linux chỉ cài package hệ điều hành; K3s, Tailscale, Helm và `wsk` được
kiểm tra/cài theo từng bước để dễ phát hiện lỗi mạng hoặc quyền.

### A2. Kiểm tra trên từng VM

```bash
$ lsb_release -ds && free -m | head -2 && nproc && df -h / | tail -1 && swapon --show
```
```
Ubuntu 24.04.1 LTS
               total        used        free      shared  buff/cache   available
Mem:            7939         412        7120           4         406        7280
4
/dev/vda1        59G  3.2G   53G   6% /
```
(`swapon --show` không in gì = swap đã tắt.)

```bash
$ timedatectl | grep -E "synchronized|Time zone"
```
```
System clock synchronized: yes
```
⚠️ Phải `yes`. Mốc thời gian chaos ở phần J được so với log K6 chạy ở **máy khác**; lệch đồng hồ vài giây là lệch cả biểu đồ.

### A3. Firewall / Security Group của CloudFly

- Cho phép vào từ Internet: **chỉ SSH (22)**. Nên thêm **UDP 41641** để Tailscale kết nối trực tiếp (không bắt buộc, nhưng không có thì có thể phải đi qua relay DERP, chậm hơn).
- **KHÔNG mở** 6443, 10250, 8472, 31001 ra Internet/VPC. Toàn bộ chúng chỉ phục vụ trong tunnel Tailscale.
- Mạng ra Internet phải mở (tải image, `get.k3s.io`, Docker Hub).

### A4. Tạo auth key Tailscale MỚI + ACL

1. Tailscale admin console → **Settings → Keys → Generate auth key**: tick *Reusable*, đặt hạn 7–30 ngày, gắn tag `tag:k3s-cloud`.
2. ⚠️ Key đã dán vào chat trước đây thì **thu hồi (Revoke)**, đừng dùng lại.
3. Nếu tailnet của bạn đang dùng ACL mặc định (cho phép tất cả) thì bỏ qua bước này. Nếu đã tùy chỉnh ACL, **thêm** (không dán đè) các luật tương đương:

```json
{
  "tagOwners": { "tag:k3s-cloud": ["autogroup:admin"] },
  "acls": [
    { "action": "accept", "src": ["tag:k3s-cloud"],   "dst": ["tag:k3s-cloud:*"] },
    { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:k3s-cloud:22,6443,31001"] },
    { "action": "accept", "src": ["tag:k3s-cloud"],   "dst": ["autogroup:member:9000"] }
  ]
}
```
Ý nghĩa: node cloud nói chuyện tự do với nhau (gồm `udp:8472` VXLAN và `tcp:10250` kubelet); máy của nhóm (Gateway/K6) vào được SSH, API, NodePort; pod cloud đẩy được bản ghi về Dashboard cổng 9000.

### A5. Đưa repo lên 3 VM

```bash
# Trên máy bạn (đã có file zip):
$ scp k3s-cloud-openwhisk-deployment.zip ubuntu@<IP-PUBLIC-VM>:~/
$ ssh ubuntu@<IP-PUBLIC-VM>

# Trên VM:
$ sudo apt-get update && sudo apt-get install -y unzip
$ unzip -o k3s-cloud-openwhisk-deployment.zip && cd k3s-cloud-openwhisk-deployment
$ chmod +x scripts/*.sh openwhisk/*.sh actions/*.sh gateway/*.sh tests/*.sh
$ ls
```
```
actions  gateway  HUONG-DAN-CHAY-TU-DAU.md  openwhisk  README.md  scripts  tests
```
Lặp lại cho cả 3 VM.

---

## PHẦN B: Tailscale (cả 3 VM)

```bash
$ export TS_AUTHKEY='tskey-auth-...'     # key MỚI. Không ghi vào file, không dán vào chat
$ TS_HOSTNAME=k3s-cloud-master ./scripts/01-install-tailscale.sh
```
```
Installing Tailscale for ubuntu noble, using method apt
...
Installation complete! Log in to start using Tailscale by running: ...
✅ Tailscale IP của k3s-cloud-master: 100.88.1.10
100.88.1.10   k3s-cloud-master  tagged-devices  linux  -
100.88.1.1    may1-gateway      you@            linux  idle
...
```
Trên worker đổi `TS_HOSTNAME=k3s-cloud-w1` và `k3s-cloud-w2`.

**Kiểm tra đường đi giữa 3 VM (làm trên master):**
```bash
$ tailscale ping -c 3 100.88.1.11
```
```
pong from k3s-cloud-w1 (100.88.1.11) via 10.0.0.12:41641 in 1ms
```
⚠️ `via <ip>:41641` = **direct** (tốt). Nếu thấy `via DERP(sgp)` thì đang đi relay: chờ ~10 giây rồi ping lại; vẫn DERP thì kiểm tra UDP 41641 ở firewall VPC.

```bash
$ tailscale ping -c 2 100.88.1.1       # tới máy Gateway
```
Phải có `pong`. Không có → ACL (A4).

---

## PHẦN C: K3s master

```bash
$ ./scripts/02-setup-k3s-master.sh
```
```
✅ IP Tailscale của master: 100.88.1.10
▶ Chuẩn bị hệ điều hành (swap, inotify, ufw)...
▶ Cài K3s server v1.35.5+k3s1...
[INFO]  Using v1.35.5+k3s1 as release
[INFO]  systemd: Starting k3s
▶ Chờ master Ready...
NAME               STATUS   ROLES                  AGE   VERSION        INTERNAL-IP   ...
k3s-cloud-master   Ready    control-plane,master   40s   v1.35.5+k3s1   100.88.1.10   ...
✅ Master Ready
============================================================
✅ K3s master sẵn sàng. API: https://100.88.1.10:6443
   K3S_TOKEN đã lưu (chmod 600) tại: .../join.env
```

**Kiểm tra 3 điều quan trọng:**

```bash
$ sudo ss -ltnp | grep 6443
```
```
LISTEN 0 4096  100.88.1.10:6443  0.0.0.0:*  users:(("k3s-server",pid=...))
```
⚠️ Phải là `100.88.1.10:6443`, **không** phải `0.0.0.0:6443` hay `*:6443`. Đây là bằng chứng `--bind-address` có tác dụng.

```bash
$ kubectl get nodes -o wide        # INTERNAL-IP phải là 100.x
$ kubectl describe node k3s-cloud-master | grep -A1 Taints
```
```
Taints:             node-role.kubernetes.io/control-plane:NoSchedule
```

```bash
$ kubectl get pods -A
```
`coredns`, `local-path-provisioner`, `metrics-server` có thể Pending trong vài giây lúc server mới khởi động; chúng sẽ chạy khi node đủ Ready.

---

## PHẦN D: K3s worker (làm lần lượt trên w1 rồi w2)

**D1. Chép `join.env` từ master sang worker** (chứa K3S_TOKEN: chỉ chép qua SSH, đừng dán vào chat):
```bash
# Trên master:
$ scp join.env ubuntu@100.88.1.11:~/k3s-cloud-openwhisk-deployment/
$ scp join.env ubuntu@100.88.1.12:~/k3s-cloud-openwhisk-deployment/
```
(Dùng IP Tailscale của worker; cần SSH vào được qua tailnet, xem ACL A4.)

**D2. Trên worker:**
```bash
$ NODE_NAME=k3s-cloud-w1 ./scripts/03-setup-k3s-worker.sh
```
```
✅ IP Tailscale của worker: 100.88.1.11  |  master: 100.88.1.10
▶ Kiểm tra đường tới master...
pong from k3s-cloud-master (100.88.1.10) via 10.0.0.10:41641 in 1ms
✅ Supervisor của master trả lời
▶ Chuẩn bị hệ điều hành...
▶ Cài K3s agent v1.35.5+k3s1...
[INFO]  systemd: Starting k3s-agent
✅ Worker k3s-cloud-w1 đã gửi yêu cầu join.
```
Làm tương tự cho w2 (`NODE_NAME=k3s-cloud-w2`).

**D3. Trên master, kiểm tra:**
```bash
$ kubectl get nodes -o wide --show-labels | cut -c1-170
```
```
NAME               STATUS   ROLES                  VERSION        INTERNAL-IP   ... LABELS
k3s-cloud-master   Ready    control-plane,master   v1.35.5+k3s1   100.88.1.10   ...
k3s-cloud-w1       Ready    <none>                 v1.35.5+k3s1   100.88.1.11   ... openwhisk-role=invoker
k3s-cloud-w2       Ready    <none>                 v1.35.5+k3s1   100.88.1.12   ... openwhisk-role=invoker
```
⚠️ Nếu `ss -ltn` trên master vẫn đúng mà worker báo `Không gọi được .../ping`: 99% là ACL Tailscale hoặc master chưa lên tailnet.

---

## PHẦN E: Kiểm tra cụm (master)

```bash
$ ./scripts/04-verify-cluster.sh
```
```
▶ 1/6 Chờ 3 node Ready...
✅ 3 node Ready
▶ 2/6 INTERNAL-IP của mọi node phải là IP Tailscale (100.x)...
✅ Mọi node dùng IP Tailscale
▶ 3/6 Nhãn workload trên toàn bộ node...
✅ 3 node có nhãn openwhisk-role=invoker
✅ Không có taint NoSchedule
▶ 4/6 StorageClass mặc định...
✅ Có StorageClass mặc định
▶ 5/6 Đường Tailscale giữa các node (direct hay relay)...
   100.88.1.11 -> pong from k3s-cloud-w1 (100.88.1.11) via 10.0.0.12:41641 in 1ms
   MTU flannel.1 = 1230 (kỳ vọng 1230)
▶ 6/6 Pod<->pod và DNS xuyên node...
✅ Ping pod k3s-cloud-w1 -> k3s-cloud-w2 (10.42.2.4) OK
✅ DNS trong pod (CoreDNS) OK
============================================================
  ĐẠT: 7   |   CHƯA ĐẠT: 0
============================================================
```
**Phải `CHƯA ĐẠT: 0` mới đi tiếp.**

| Dòng ❌ | Nguyên nhân thường gặp |
|---|---|
| Ping pod xuyên node thất bại | ACL chặn `udp:8472`; `--flannel-iface` hai bên khác nhau; ufw chặn `tailscale0` |
| DNS trong pod thất bại | CoreDNS chưa chạy (`kubectl -n kube-system get pods`) hoặc cùng nguyên nhân dòng trên |
| Không có StorageClass | `kubectl -n kube-system get pods \| grep local-path` |
| MTU khác 1230 | Bình thường nếu Tailscale báo MTU khác 1280; quan trọng là không bị mất gói to |

---

## PHẦN F: OpenWhisk ⏱ (10–15 phút)

**F1. (Khuyến nghị) chép `golden.lock` từ bản triển khai chuẩn sang server** để script so mã băm chart:
```bash
$ scp legacy-k3d/golden-config-final/golden/golden.lock ubuntu@100.88.1.10:~/golden.lock    # chạy trên máy bạn
```

**F2. Mở Terminal 2 trên master để theo dõi:**
```bash
$ watch kubectl -n openwhisk get pods -o wide
```

**F3. Terminal 1:**
```bash
$ GOLDEN_LOCK=~/golden.lock ./openwhisk/install-openwhisk.sh
```

Installer mặc định khóa **2 invoker** (`INVOKER_REPLICAS=2`). Nếu cần cài lại
OpenWhisk mà vẫn giữ nguyên K3s, chạy:

```bash
$ ./openwhisk/uninstall-openwhisk.sh
$ GOLDEN_LOCK=~/golden.lock ./openwhisk/install-openwhisk.sh
```

Script uninstall yêu cầu nhập `DELETE OPENWHISK` để xác nhận và mặc định xóa
PVC trong namespace `openwhisk`. Nó không xóa K3s, Tailscale hoặc node. Muốn
giữ PVC:

```bash
$ DELETE_PVCS=0 ./openwhisk/uninstall-openwhisk.sh
```

Chỉ dùng `FORCE=1` khi chạy tự động và đã kiểm tra đúng context Kubernetes.
```
▶ 1/7 Kiểm tra môi trường...
✅ API host (worker, IP Tailscale): 100.88.1.11
▶ 2/7 Chart ghim commit 146d24925564...
✅ Chart khớp golden.lock
▶ 3/7 Kiểm tra render Helm...
✅ Render có '600000'
✅ Render có '1024m'
✅ Render có 'ef725a6'
▶ 4/7 helm upgrade --install...
Release "owdev" does not exist. Installing it now.
...
✅ helm xong
▶ 5/7 Khóa trần RAM pod...
✅ statefulset.apps/owdev-controller  limit=2048Mi request=1536Mi cpu=500m
✅ statefulset.apps/owdev-invoker  limit=1536Mi request=1024Mi cpu=500m
✅ statefulset.apps/owdev-kafka  limit=1536Mi request=1024Mi cpu=500m
✅ deployment.apps/owdev-couchdb  limit=1024Mi request=512Mi cpu=250m
✅ statefulset.apps/owdev-zookeeper  limit=512Mi request=256Mi cpu=100m
▶ 6/7 Chờ pod sẵn sàng (tối đa 900s, lần đầu thường 10-15 phút)...
   10:32:11  9 pod chưa xong
   10:36:41  4 pod chưa xong
✅ Mọi pod đã Running/Completed
✅ 2 invoker nằm trên 2 worker khác nhau
▶ 7/7 Tải sẵn image Python runtime vào các worker...
✅ Đã có openwhisk/action-python-v3.11:... trên mọi worker
✅ API trả lời: https://100.88.1.11:31001/
============================================================
✅ OPENWHISK ĐÃ SẴN SÀNG TRÊN K3S
```
Kết quả cuối ở Terminal 2 (rút gọn): `owdev-controller-0`, `owdev-invoker-0/1`, `owdev-kafka-0`, `owdev-zookeeper-0`, `owdev-couchdb-…`, `owdev-nginx-…` đều `1/1 Running`; `owdev-init-couchdb-…` là `Completed`. Job tùy chọn `owdev-install-packages` sẽ là `Completed` hoặc được installer dọn nếu bị kẹt. Bấm Ctrl+C.

⚠️ Vài pod **restart 1–2 lần** ngay sau bước 5 là bình thường (đặt trần RAM làm StatefulSet khởi động lại).
⚠️ Không có `GOLDEN_LOCK` thì script chỉ cảnh báo, vẫn chạy (chỉ đối chiếu theo commit).

**F4. Kiểm tra sau cài:**
```bash
$ kubectl -n openwhisk get pvc
```
```
NAME                          STATUS   VOLUME   CAPACITY   STORAGECLASS
owdev-couchdb-pvc             Bound    pvc-...  2Gi        local-path
owdev-kafka-pvc               Bound    ...
owdev-zookeeper-pvc-data      Bound    ...
```
```bash
$ kubectl top nodes        # metrics-server có sẵn trong K3s
```
Chạy lúc rảnh: mỗi worker dùng khoảng 2–4 GB RAM, master thấp hơn nhiều.

| Hiện tượng | Xử lý |
|---|---|
| Pod `Pending` | `kubectl -n openwhisk describe pod <tên>`: thiếu CPU/RAM thì xem bảng ngân sách đầu `custom-values.yaml` |
| Pod `Unknown` | Script tự xóa cứng; vẫn kẹt thì `kubectl -n openwhisk delete pod <tên> --force --grace-period=0` |
| Hết giờ chờ | Chạy lại script (idempotent); xem log: `kubectl -n openwhisk logs owdev-controller-0 -c wait-for-couchdb --tail=5` |
| Sau `helm upgrade` thấy trần RAM mất | Bình thường: chạy lại `install-openwhisk.sh` (bước 5 đặt lại) |

---

## PHẦN G: Action cho Gateway và K6

```bash
$ DASHBOARD_URL=http://100.88.1.3:9000 CLUSTER_NAME=c4 ./actions/deploy-actions.sh
```
```
▶ 1/4 Lấy khóa GUEST của cụm...
▶ 2/4 Tạo action (namespace guest)...
ok: updated action ping
ok: updated action test-thu
ok: updated action publish_result
ok: updated action A1
ok: updated action A2
ok: updated action A3
✅ Đã tạo action
▶ 3/4 Làm nóng + thử đúng kiểu Gateway gọi...
   test-thu  lạnh 8.412s -> nóng 0.087s (HTTP 200)
   A1        lạnh 6.512s -> nóng 0.142s (HTTP 200)
   A2        lạnh 6.773s -> nóng 0.295s (HTTP 200)
   A3        lạnh 7.008s -> nóng 0.604s (HTTP 200)
✅ Mọi action trả HTTP 200
▶ 4/4 Sinh cấu hình đăng ký vào Gateway...
✅ HOÀN TẤT. Cụm [c4] sẵn sàng nhận tải qua https://100.88.1.11:31001
```
⚠️ Cột "nóng" của `test-thu` phải **< 2 giây**: Gateway ping mỗi 2 giây với timeout 2 giây, chậm hơn là bị ngắt nhầm.
⚠️ Không có `DASHBOARD_URL` thì script đặt `SAMPLE_RATE=0` (A1–A3 không báo về Dashboard) và không tạo `publish_result`. Chạy lại với đủ biến khi Dashboard sẵn sàng.

**Gọi thử một action:**
```bash
$ source gateway/.env.cloud
$ curl -sk -X POST "$CLUSTER_C4_URL/api/v1/namespaces/_/actions/A1?blocking=true&result=true" \
    -H "Authorization: Basic $CLUSTER_C4_AUTH_B64" -H 'Content-Type: application/json' -d '{}'
```
```
{"action":"A1","cluster":"c4","duration_ms":50.1,"publish_status":"submitted","result":...,"status":"ok"}
```
`"publish_status":"skipped"` cũng đúng (mặc định chỉ 5% request báo về Dashboard).

**Kiểm tra pod cloud tới được Dashboard** (nếu dùng `DASHBOARD_URL`):
```bash
$ kubectl run curltest --rm -i --restart=Never --image=busybox:1.36.1 -- wget -qO- -T 5 http://100.88.1.3:9000/health
```
```
{"ok":true,"service":"openwhisk-dashboard","records":0}
```
Không ra → ACL thiếu `tag:k3s-cloud → :9000`, hoặc Dashboard đang bind `127.0.0.1` thay vì IP Tailscale.

---

## PHẦN H: Đăng ký c4 vào Gateway

**H1. Gateway của Máy 1 đang chạy và thấy 3 cụm cũ:**
```bash
$ curl -s http://100.88.1.1:8080/admin/clusters | python3 -m json.tool | head -20
```
`c1`, `c2`, `c3` đều `"up": true`.

**H2. Đăng ký c4 (chạy trên master, nơi có `gateway/.env.cloud`):**
```bash
$ ./gateway/register-cloud-cluster.sh http://100.88.1.1:8080
```
```
{"status":"ok","message":"Node c4 added/updated","nodes":["c1","c2","c3","c4"]}
✅ Đã đăng ký [c4]. Chờ vòng ping đầu tiên...
   c4: up fails=0
   ... (12 lần, mỗi 2 giây)
✅ 24s liên tục không có lỗi ping.
```
⚠️ Gateway đặt `up=true` ngay khi đăng ký, nên phải theo dõi cả 24 giây mới kết luận (script đã làm).

**H3. Chứng minh Gateway thật sự chia tải sang c4:**
```bash
$ for i in $(seq 1 12); do
    curl -s -X POST http://100.88.1.1:8080/invoke/ping -H 'Content-Type: application/json' -d '{}' \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["cluster"])'
  done | sort | uniq -c
```
```
      3 c1
      3 c2
      3 c3
      3 c4
```
(Round-robin trên 4 cụm. Lệch nhẹ vẫn chấp nhận; thiếu hẳn `c4` là chưa đạt.)

Mở thêm `http://100.88.1.1:8080/` trên trình duyệt: phải thấy thẻ **C4**.

⚠️ Đăng ký qua API **mất khi restart Gateway**. Muốn bền, làm theo phần ghi chú script in ra cuối (thêm vào `.env`, `ACTIVE=c1,c2,c3,c4`, sửa 2 chỗ `gateway.py`).

---

## PHẦN I: K6 (chạy ở Máy 1, như các thí nghiệm trước)

**I1. Smoke test (30 giây, 1 người dùng):**
```bash
$ k6 run -e GATEWAY_URL=http://100.88.1.1:8080 -e SCENARIO=smoke tests/load-test.js
```
Cuối bảng tổng kết (rút gọn, số minh họa):
```
     ✓ HTTP 200
     ✓ action trả status=ok
   ✓ checks.............................: 100.00%
     ow_cluster_hits{cluster:c1}........: 7
     ow_cluster_hits{cluster:c2}........: 7
     ow_cluster_hits{cluster:c3}........: 7
     ow_cluster_hits{cluster:c4}........: 7
   ✓ 'http_req_duration{action:A1}' p(95)<500
   ✓ ow_throttled_429.....................: 0
```
Thấy số của c4 khác 0 là Gateway đang chia tải cho cụm cloud.

**I2. Tải cố định 30 req/s, 5 phút:**
```bash
$ mkdir -p results
$ k6 run -e GATEWAY_URL=http://100.88.1.1:8080 -e SCENARIO=rate -e RATE=30 -e DURATION=5m \
    --summary-export results/c4_rate30.json tests/load-test.js
```
Các kịch bản khác: `SCENARIO=users` (người dùng đồng thời, 0→100 VU), `SCENARIO=stress` (tăng dần 40→160 req/s để tìm điểm gãy).

**I3. Đo RIÊNG năng lực c4 (bỏ qua Gateway)**: chép `gateway/.env.cloud` sang Máy 1 bằng scp rồi:
```bash
$ source gateway/.env.cloud
$ k6 run -e TARGET=direct -e OW_API="$CLUSTER_C4_URL" \
    -e OW_AUTH="$(echo "$CLUSTER_C4_AUTH_B64" | base64 -d)" -e CLUSTERS=c4 \
    -e SCENARIO=rate -e RATE=30 --summary-export results/e1a_c4.json tests/load-test.js
```

**I4. Đo CPU/RAM của c4 trong lúc chạy K6** (c4 dùng containerd, **không có `docker stats`**, nên `run_exp.sh`/`docker.csv` không thu được c4). Trên master, song song với K6:
```bash
$ while true; do echo "$(date -u +%FT%TZ),$(kubectl top nodes --no-headers | tr -s ' ' ',' | tr '\n' ';')"; sleep 5; done | tee results/c4_top.csv
```
Cột trong mỗi nhóm: `tên-node, CPU(cores), CPU%, RAM(bytes), RAM%`. Dừng bằng Ctrl+C khi K6 xong. Ghi rõ trong báo cáo rằng c4 đo bằng `kubectl top` còn c1–c3 đo bằng `docker stats`.

---

## PHẦN J: Chaos F1–F5 ⚠️ chỉ làm trên lab

### J1. Cài Chaos Mesh ⏱ (2–3 phút)
```bash
$ ./tests/install-chaos-mesh.sh
```
```
Release "chaos-mesh" does not exist. Installing it now.
deployment "chaos-controller-manager" successfully rolled out
daemon set "chaos-daemon" successfully rolled out
✅ Chaos Mesh sẵn sàng.
```
```bash
$ kubectl -n chaos-mesh get pods -o wide
```
`chaos-controller-manager` có 1 pod; `chaos-daemon` có **2 pod, chỉ trên 2 worker** (master bị taint). Nếu `chaos-daemon` lỗi: kiểm tra `socketPath` containerd của K3s: `ls /run/k3s/containerd/containerd.sock`.

### J2. Khung lịch đo (dùng cho mọi kịch bản): 60s bình thường, 120s lỗi, 120s hồi phục

`chaos.sh`/`run-chaos-exp.sh` không hỗ trợ c4 cho F1/F2/F4, nên làm thủ công theo lịch cùng chuẩn. Mốc ghi cùng định dạng `chaos.csv` để `analyze.py` đọc được.

**Máy 1: bấm K6 trước:**
```bash
$ k6 run -e GATEWAY_URL=http://100.88.1.1:8080 -e SCENARIO=rate -e RATE=30 -e DURATION=5m \
    --summary-export results/e5_f1_c4.json tests/load-test.js
```
**Master: chạy ngay sau đó** (ví dụ F1):
```bash
$ mkdir -p results; CSV=results/chaos-c4.csv
$ [ -f $CSV ] || echo "timestamp_utc,scenario,phase,target,note" > $CSV
$ mark() { echo "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ),$1,$2,c4,$3" >> $CSV; }

$ sleep 60                                                   # WARM
$ mark F1 start "chaos-mesh pod-kill owdev-invoker-0"
$ kubectl apply -f tests/chaos-pod-kill.yaml
$ kubectl -n openwhisk wait --for=condition=Ready pod/owdev-invoker-0 --timeout=300s
$ mark F1 stop "invoker Ready lại"
$ kubectl delete -f tests/chaos-pod-kill.yaml
```
Trong lúc đó, Terminal khác: `kubectl -n openwhisk get pod owdev-invoker-0 -w`
```
owdev-invoker-0   1/1   Terminating         0   2h
owdev-invoker-0   0/1   Init:0/1            0   2s
owdev-invoker-0   0/1   PodInitializing     0   20s
owdev-invoker-0   1/1   Running             0   38s
```
**Kết luận ghi báo cáo:** Kubernetes tự dựng lại invoker sau khoảng 30–60 giây; request trong khoảng đó chuyển sang invoker còn lại hoặc lỗi.

### J3. Các kịch bản còn lại (cùng khung J2, thay phần giữa)

| Mã | Gây lỗi | Gỡ lỗi |
|---|---|---|
| **F1** | `kubectl apply -f tests/chaos-pod-kill.yaml` | chờ invoker Ready (J2) |
| **F2** chết node | `ssh k3s-cloud-w1 'sudo k3s-killall.sh'` | `ssh k3s-cloud-w1 'sudo systemctl start k3s-agent'` rồi `kubectl wait --for=condition=Ready node/k3s-cloud-w1 --timeout=300s` |
| **F3a** trễ mạng | `kubectl apply -f tests/chaos-network-delay.yaml` (tự hết sau 120s) | `kubectl delete -f tests/chaos-network-delay.yaml` |
| **F3b** trễ tunnel thật | trên worker: `sudo tc qdisc add dev tailscale0 root netem delay 150ms 30ms 25%` | `sudo tc qdisc del dev tailscale0 root` |
| **F3c** đứt hẳn | Dùng `tests/chaos-network-delay.yaml` hoặc firewall Tailscale trên node K3s | Khôi phục rule/network sau thử nghiệm |
| **F4** chết cả cụm | `k3s-killall.sh` trên cả 2 worker, rồi `sudo systemctl stop k3s` ở master | `sudo systemctl start k3s` ở master, rồi `k3s-agent` ở 2 worker |
| **F5** trạm nhận chết | xem lệnh dưới | xem lệnh dưới |

⚠️ **F2/F4 và dữ liệu:** PV `local-path` gắn cứng vào node. Trước khi chọn node để giết, xem `kubectl -n openwhisk get pods -o wide`: node chứa CouchDB/Kafka bị giết thì các pod đó **Pending tới khi node về** (khác k3d). Mặc định K8s chờ ~40 giây mới đánh dấu NotReady và ~300 giây mới evict pod. Ghi nhận điều này vào báo cáo F2.

**F5 (chạy trên master):**
```bash
$ GUEST="$(kubectl -n openwhisk get secret owdev-whisk.auth -o jsonpath='{.data.guest}' | base64 -d)"
$ W="wsk -i --apihost https://100.88.1.11:31001 --auth $GUEST"
# gây lỗi: trỏ về địa chỉ chết
$ $W action update publish_result --param MODE dashboard --param TARGET_URL http://10.255.255.1:9
# sửa lỗi:
$ $W action update publish_result --param MODE dashboard --param TARGET_URL http://100.88.1.3:9000
```
Kỳ vọng: K6 vẫn OK, nhưng Dashboard không nhận thêm bản ghi của c4 → tách bạch **lỗi tính toán** và **lỗi báo cáo**.

### J4. Dọn sạch cuối buổi (bắt buộc)
```bash
$ kubectl get podchaos,networkchaos -A          # master: phải "No resources found"
$ sudo tc qdisc show dev tailscale0             # worker: không có dòng netem
$ sudo iptables -S OUTPUT | grep 31001          # Máy 1: không có luật DROP
$ kubectl get nodes                             # cả 3 node Ready
$ kubectl -n openwhisk get pods                 # mọi pod 1/1 Running
```
Gọi lại phần H3: Gateway phải chia đều cho cả 4 cụm trước khi đo kịch bản tiếp theo.

---

## PHẦN K: Mở lại VM ở những buổi sau

Không phải cài lại. Tailscale và K3s tự chạy lại khi VM bật (K3s đợi Tailscale có IP nhờ drop-in systemd). Persistence đang bật nên action còn nguyên.

```bash
# 1. Chờ ~2 phút sau khi VM lên, rồi trên master:
$ tailscale status | head -5
$ kubectl get nodes
$ kubectl -n openwhisk get pods
```
Pod `Unknown`:
```bash
$ kubectl -n openwhisk get pods --no-headers | awk '$3=="Unknown"||$3=="Init:Unknown"{print $1}' \
    | xargs -r kubectl -n openwhisk delete pod --force --grace-period=0
```
```bash
# 2. Làm nóng action (container nguội sau ~10 phút) và kiểm tra Gateway:
$ ./actions/deploy-actions.sh
$ curl -s http://100.88.1.1:8080/admin/clusters | python3 -m json.tool | grep -A4 '"c4"'
```
⚠️ **Đừng chạy `tailscale logout`** hay xóa máy khỏi tailnet: IP Tailscale mới sẽ khác IP đã ghi trong cert/node của K3s và cụm hỏng. Nếu bắt buộc phải đổi IP, cài lại cụm (phần L).
⚠️ Gateway restart thì phải đăng ký lại c4 (phần H) trừ khi đã làm bản bền vững.

---

## PHẦN L: Gỡ / cài lại

```bash
# Chỉ gỡ OpenWhisk (giữ K3s):
$ helm -n openwhisk uninstall owdev
$ kubectl -n openwhisk delete pvc --all            # ⚠️ mất action và dữ liệu CouchDB
$ GOLDEN_LOCK=~/golden.lock ./openwhisk/install-openwhisk.sh

# Gỡ K3s hoàn toàn:
$ /usr/local/bin/k3s-agent-uninstall.sh            # trên từng worker
$ /usr/local/bin/k3s-uninstall.sh                  # trên master
# Rời tailnet (xóa máy trong admin console để tên cũ không bị chiếm):
$ sudo tailscale down
```
Cài lại K3s sau khi gỡ: quay lại **PHẦN C**. Nhớ sinh lại `join.env`, token cũ không dùng được nữa.

---

## Lỗi hay gặp (tổng hợp)

| Triệu chứng | Nguyên nhân | Xử lý |
|---|---|---|
| `ss -ltn` thấy `0.0.0.0:6443` | Cờ `--bind-address` không ăn | Xem `journalctl -u k3s -n 50`; chạy lại `02` |
| k3s crash-loop sau reboot | Tailscale chưa có IP lúc k3s start | `systemctl cat k3s` phải có `10-after-tailscale.conf` |
| Worker join treo | ACL / master chưa lên tailnet | `curl -k https://<master>:6443/ping` phải ra `pong` |
| Ping pod xuyên node chết | `udp:8472` bị ACL/ufw chặn | A4, `ufw status` |
| `kubectl` báo x509 / connection refused | kubeconfig trỏ `127.0.0.1` | Script 02 đã đổi về IP Tailscale; kiểm tra `~/.kube/config` |
| K6 trả 404 `/invoke/A2` | Chưa chạy `deploy-actions.sh` | Phần G |
| K6 có nhiều HTTP 202 | Gọi lạnh (dựng container) | Làm nóng, chạy lại; đã tải sẵn image Python ở bước F |
| Gateway ngắt cầu dao c4 | `test-thu` chậm > 2s hoặc ACL chặn `tcp:31001` | Phần G (cột "nóng"), A4 |
| `NetworkChaos` apply OK nhưng không trễ | Sai nhãn pod hoặc sai socket containerd | `kubectl -n openwhisk get pods --show-labels`; J1 |

## Checklist nộp bài

- [ ] Ảnh/văn bản kết quả `04-verify-cluster.sh` (ĐẠT 7 / CHƯA ĐẠT 0)
- [ ] `kubectl get nodes -o wide` (3 node, INTERNAL-IP 100.x) và `kubectl -n openwhisk get pods -o wide`
- [ ] `sudo ss -ltnp | grep 6443` (bằng chứng bind Tailscale)
- [ ] `results/*.json` từ K6 + `results/c4_top.csv` + `results/chaos-c4.csv`
- [ ] Kết quả H3 (Gateway chia tải 4 cụm)
- [ ] Nêu rõ trong báo cáo: c4 là **K3s thật 3 VM**, c1–c3 là k3d trên một máy; c4 đo tài nguyên bằng `kubectl top`.
