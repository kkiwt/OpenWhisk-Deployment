# OpenWhisk trên K3s thật (CloudFly) qua Tailscale

> Mới làm lần đầu? Đọc **HUONG-DAN-CHAY-TU-DAU.md**: từng lệnh kèm kết quả mong đợi.

Cụm 3 VM: **1 master** (control-plane, bị taint) + **2 worker** (toàn bộ pod OpenWhisk = 8 vCPU / 16 GB).
Mọi giao tiếp giữa node (API 6443, kubelet, VXLAN của flannel) đi trong tunnel Tailscale. Cụm này là **c4**,
đứng cạnh 3 cụm k3d c1–c3 sau cùng một Gateway.

```
Gateway/K6 ──Tailscale──▶ NodePort 31001 (worker) ──▶ nginx OpenWhisk ──▶ controller ──Kafka──▶ invoker x2 ──▶ action pod
```

## Chạy theo thứ tự

```bash
# 0) Trên MỌI VM: lấy repo về, rồi
export TS_AUTHKEY='tskey-auth-...'            # KHÔNG ghi vào file / commit
TS_HOSTNAME=k3s-cloud-master ./scripts/01-install-tailscale.sh     # (w1, w2 tương tự)

# 1) Master
./scripts/02-setup-k3s-master.sh              # sinh join.env (chứa K3S_TOKEN, chmod 600)

# 2) Từng worker (chép join.env sang, hoặc truyền K3S_URL/K3S_TOKEN bằng biến)
NODE_NAME=k3s-cloud-w1 ./scripts/03-setup-k3s-worker.sh

# 3) Master: kiểm tra, rồi cài OpenWhisk
./scripts/04-verify-cluster.sh                # phải CHƯA ĐẠT: 0
GOLDEN_LOCK=/đường/dẫn/golden.lock ./openwhisk/install-openwhisk.sh    # GOLDEN_LOCK tùy chọn

# 4) Action + đăng ký vào Gateway
DASHBOARD_URL=http://<ip-tailscale-dashboard>:9000 CLUSTER_NAME=c4 ./actions/deploy-actions.sh
./gateway/register-cloud-cluster.sh http://<ip-tailscale-gateway>:8080

# 5) Kiểm thử
k6 run -e GATEWAY_URL=http://<gateway>:8080 -e SCENARIO=smoke tests/load-test.js
./tests/install-chaos-mesh.sh && kubectl apply -f tests/chaos-pod-kill.yaml
```

Thứ tự `01 → 02 → 03` là bắt buộc: `--node-ip`/`--bind-address` lấy IP từ `tailscale0`.

## Quyết định thiết kế đáng biết

| Chọn | Lý do |
|---|---|
| `--bind-address` = IP Tailscale | API 6443 không lộ ra IP public/VPC. Kèm drop-in systemd để k3s đợi Tailscale sau reboot |
| `--flannel-iface tailscale0`, backend `vxlan` | Pod↔pod xuyên node được WireGuard mã hóa; `wireguard-native` sẽ mã hóa 2 lần |
| Master taint `NoSchedule` | Ngân sách 8 vCPU/16 GB là của 2 worker; giống cụm k3d |
| Nhãn `openwhisk-role=invoker` gắn lúc join | Không cần node-affinity/tolerations tự viết; khớp quy ước Golden |
| Cùng commit chart + tag image với `golden.lock` | So sánh công bằng với c1–c3 |
| Persistence bật (`local-path`) | Theo Golden hiện tại; PV gắn cứng vào node (xem F2) |
| Cửa vào = IP worker, không phải master | Master chỉ control-plane; đi qua nó thêm 1 chặng |

## Kịch bản chaos F1–F5 trên K3s thật

`chaos.sh` hiện cứng `docker stop` / tên node k3d cho F2, F4 nên **không dùng nguyên cho c4**. Tương đương:

| Mã | Cách làm trên c4 |
|---|---|
| F1 | `tests/chaos-pod-kill.yaml` (hoặc `kubectl delete pod owdev-invoker-0 --force --grace-period=0`) |
| F2 | Trên worker: `sudo k3s-killall.sh`; khôi phục `sudo systemctl start k3s-agent`. Pod giữ PVC (CouchDB/Kafka) sẽ **Pending tới khi node về**, vì `local-path` gắn PV vào node. Mặc định K8s evict sau 300s |
| F3 | `tests/chaos-network-delay.yaml` (trễ ở mức pod) hoặc `tc netem` trên `tailscale0`; đứt hẳn: iptables DROP từ máy Gateway tới `<ip>:31001` |
| F4 | `k3s-killall.sh` trên cả 2 worker, sau đó `sudo systemctl stop k3s` ở master |
| F5 | Chạy tay: `WSK_CONFIG_FILE=<props c4> wsk -i action update publish_result --param TARGET_URL <địa-chỉ-chết>` (vòng lặp của `chaos.sh` chỉ có c1–c3) |

## Bảo mật

- **Thu hồi (revoke) auth key Tailscale đã dán vào chat** và tạo key mới. Nên dùng key gắn tag (ví dụ `tag:k3s-cloud`) + ACL. Giữa các node k3s cần: `tcp:6443` (API), `tcp:10250` (kubelet), `udp:8472` (VXLAN của flannel; nó chạy BÊN TRONG tunnel nên ACL vẫn thấy và sẽ chặn nếu thiếu), ICMP. Từ máy Gateway tới worker cần `tcp:31001`; từ node cloud tới Dashboard cần `tcp:9000`.
- Cổng 6443 và 31001 **không** được mở trên interface public/VPC của VM.
- `join.env`, `gateway/.env.cloud`, `gateway/ow-cloud-auth.conf` chứa khóa: đã nằm trong `.gitignore`.
- API `/admin/*` của Gateway không có xác thực: chỉ bind trên IP Tailscale.

## Gỡ rối nhanh

| Hiện tượng | Kiểm tra |
|---|---|
| Worker join treo | `curl -k https://<master-ts>:6443/ping` phải ra `pong`; ACL Tailscale; `journalctl -u k3s-agent -n 50` |
| `04` báo ping pod xuyên node thất bại | `--flannel-iface` hai bên khác nhau, ufw chặn `tailscale0`, đường Tailscale đang qua DERP |
| PVC `Pending` | `kubectl get storageclass` phải có `local-path (default)` |
| K6 có HTTP 202 | OpenWhisk nhận nhưng chưa xong kịp (cold-start); chạy `deploy-actions.sh` để làm nóng |
| Gateway ngắt cầu dao c4 | `test-thu` phải trả < 2s khi nóng; cụm xa thì cần giữ container nóng |
