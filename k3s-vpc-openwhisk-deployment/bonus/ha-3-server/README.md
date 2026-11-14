# Bonus: 3-server K3s HA

Thư mục này là phần mở rộng tùy chọn để dựng một cluster K3s mới với
**3 server dùng embedded-etcd**. Flow chính bên ngoài thư mục này vẫn là
1 server + agent và không bị thay đổi.

## Cách dùng

### Server đầu tiên

```bash
sudo VPC_CIDR=10.0.0.0/24 \
  NODE_IP=<server-1-private-ip> NODE_NAME=c1-server-1 \
  FLANNEL_IFACE=<vpc-interface> CLUSTER_INIT=1 \
  ./bonus/ha-3-server/setup-server-ha.sh
```

Chép `join.env` sang cùng vị trí trên server 2 và server 3.

### Server thứ hai/thứ ba

```bash
sudo VPC_CIDR=10.0.0.0/24 \
  NODE_IP=<server-2-private-ip> NODE_NAME=c1-server-2 \
  FLANNEL_IFACE=<vpc-interface> CLUSTER_INIT=0 \
  ./bonus/ha-3-server/setup-server-ha.sh
```

Lặp lại cho server 3. Mở TCP `2379-2380` giữa ba server, cùng TCP `6443`,
`10250` và UDP `8472` như cluster thường.

## Lưu ý

- Đây là cluster mới hoặc cluster được rebuild; không chuyển nóng cluster
  một-server dùng SQLite sang embedded-etcd HA.
- Quorum etcd là `2/3`, chịu được một server control-plane bị mất.
- Sau khi đủ server, join agent bằng `scripts/03-setup-k3s-worker.sh`.
- `INVOKER_REPLICAS` trong `openwhisk/install-openwhisk.sh` vẫn độc lập.
- Nếu có 3 server + 3 agent, chạy verify bằng:

```bash
EXPECTED_NODES=6 EXPECTED_INVOKER_NODES=6 \
  ./scripts/04-verify-cluster.sh
```
