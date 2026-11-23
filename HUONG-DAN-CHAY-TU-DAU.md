# Hướng dẫn chạy bộ K3s VPC

Đây là bản triển khai private VPC, tách biệt với bộ triển khai mạng overlay cũ.

## 1. Chuẩn bị VPC

Tạo bốn VPS Ubuntu 22.04 trong cùng private network:

```text
c1-server
c1-agent1
c1-agent2
c1-agent3
```

Mở giữa các VPS: TCP 6443, TCP 10250, UDP 8472. Mở TCP 31001 từ
Gateway tới các node. Không mở các cổng này ra public Internet.

## 2. Cài K3s

Chạy script `00` và `01` trên cả bốn VPS. Đặt `NODE_IP` là private IP của
VPS và `FLANNEL_IFACE` là interface chứa IP đó, thường là `eth0`.

Chạy `02-setup-k3s-master.sh` trên server, chép `join.env` sang từng agent,
rồi chạy `03-setup-k3s-worker.sh`. Cuối cùng chạy `04-verify-cluster.sh`
trên server.

## 3. Cài OpenWhisk

Chỉ chạy sau khi bốn node đều `Ready` và kiểm tra pod-to-pod đạt:

```bash
API_HOST=<private-ip-node> \
  ./openwhisk/install-openwhisk.sh
```

Sau khi cài, kiểm tra:

```bash
kubectl get nodes -o wide
kubectl -n openwhisk get pods -o wide
curl -k https://<private-ip-node>:31001/
```

Installer mặc định chạy 2 invoker. Muốn đổi số lượng, đặt
`INVOKER_REPLICAS=<số-lượng>`; không có yêu cầu cố định phải chạy 3 invoker.

## 4. Kiểm chứng concurrency/failover

```bash
API_HOST=<private-ip-node> ./tests/validate-openwhisk.sh
```

Muốn mô phỏng mất một agent:

```bash
API_HOST=<private-ip-node> RUN_NODE_FAILOVER=1 \
  ./tests/validate-openwhisk.sh
```

Chỉ chạy chế độ failover trên cluster thử nghiệm vì script sẽ cordon và drain
một node. PVC `local-path` không tự sao chép dữ liệu sang node khác; muốn cam
kết failover dữ liệu cần thêm storage phân tán/backup.

