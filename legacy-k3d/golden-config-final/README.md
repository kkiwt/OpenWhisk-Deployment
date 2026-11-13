# Hướng dẫn cài OpenWhisk theo Golden Config

Đây là hướng dẫn chính cho bộ cài trong `golden-config-final`. README này được viết theo `CaiDatOpenWhiskMoi.sh` hiện tại và thay cho README cũ không liên quan.

## 1. Quy trình hiện tại

`CaiDatOpenWhiskMoi.sh` là bộ cài chính, thực hiện cả tạo k3d, lấy Helm chart, kiểm tra và áp dụng Golden Config, giới hạn RAM, cấu hình `wsk`, rồi tạo action Gateway. Với quy trình thông thường, **không cần chạy riêng** `golden/install-golden.sh`.

Tuy vậy, không được xóa cả thư mục `golden/`: installer vẫn bắt buộc có `golden/golden-values.yaml` và `golden/deploy-actions.sh`. `golden/golden.lock` cần được đồng bộ giữa các máy để cả nhóm dùng cùng một chart. Các script kiểm thử và khôi phục chỉ cần dùng khi chạy các bước tương ứng.

| Đường dẫn | Vai trò | Khi nào cần? |
|---|---|---|
| `CaiDatOpenWhiskMoi.sh` | Cài mới hoặc cập nhật OpenWhisk và Golden Config | Bắt buộc |
| `XoaOpenWhiskDeCaiLai.sh` | Xóa k3d và OpenWhisk để làm lại từ đầu | Chỉ khi chủ động chấp nhận mất dữ liệu |
| `golden/golden-values.yaml` | Giá trị Helm: NodePort 31001, giới hạn invoke, image tag và persistence | Bắt buộc |
| `golden/golden.lock` | Hash/commit chart để các máy dùng cùng phiên bản | Giữ và chia sẻ cùng bản gốc; máy gốc có thể tự tạo nếu chưa có |
| `golden/deploy-actions.sh` | Tạo action `ping` và `test-thu` cho Gateway | Bắt buộc; installer tự gọi |
| `golden/test-all.sh` | Chạy kiểm thử tính năng và Golden | Tùy chọn; cần khi dùng `--test` |
| `golden/TestMoi.sh` | Kiểm tra action Node.js/web action | Tùy chọn; được gọi bởi `test-all.sh` |
| `golden/test-golden.sh` | Kiểm tra 5 yêu cầu Golden và Gateway | Tùy chọn; được gọi bởi `test-all.sh` |
| `golden/after-reboot.sh` | Kiểm tra và khôi phục sau khi mở lại máy ảo | Tùy chọn; dùng sau khi reboot |
| `golden/install-golden.sh` | Luồng áp dụng Golden cũ, chạy độc lập | Legacy; không dùng trong quy trình này |
| `golden/images-*.txt`, `golden/*report*.txt`, `golden/*debug*.txt` | Kết quả được sinh ra khi cài/test | Không phải đầu vào; có thể gửi để đối chiếu |
| `openwhisk-deploy-kube/` | Helm chart dependency | Installer dùng nếu có sẵn; nếu không thì tự clone |

**Lưu ý về file legacy:** `golden/install-golden.sh` không được `CaiDatOpenWhiskMoi.sh` gọi. Nó có tùy chọn và hành vi khác; bản hiện tại còn đặt persistence `false`, trong khi `golden-values.yaml` của quy trình chính bật persistence. Không chạy script legacy này để cài hoặc cập nhật theo README.

**Đối chiếu tài liệu phân công v3:** tài liệu đính kèm ghi CouchDB không lưu bền và tổng memory cap cụm không quá 7,15 GB; project hiện tại lại bật persistence và đặt node cap tổng 8 GiB. Theo yêu cầu hiện tại, tài liệu này giữ nguyên cấu hình của project; không đổi theo giá trị trong tài liệu cũ.

## 2. Cụm sau khi cài

Mỗi máy chạy một k3d cluster gồm 1 node server và 2 node agent. Ba máy trong nhóm thường được gán nhãn `c1`, `c2`, `c3`.

```text
Gateway/K6 trên mạng nhóm
        |
        | HTTPS, Tailscale IP, NodePort 31001
        v
k3d: 1 server + 2 agent
        |
        +-- namespace: openwhisk
        +-- release: owdev
        +-- controller, nginx, Kafka, CouchDB, 2 invoker
        +-- PVC cho dữ liệu bền vững
```

Mặc định installer tạo cluster `openwhisk-cluster`, namespace `openwhisk`, Helm release `owdev`, và dùng IP Tailscale của máy làm API host. Tổng memory cap của node k3d mặc định là 8 GiB: server `1536m`, mỗi agent `3328m`. Máy ảo cần RAM thật lớn hơn mức cap; khuyến nghị ít nhất 10 GB RAM và 4 CPU.

## 3. Điều kiện trước khi cài

Thực hiện trên Ubuntu Linux có Internet, tài khoản có quyền `sudo`, và đã đăng nhập cùng tailnet với các máy còn lại.

1. Đảm bảo máy ảo có ít nhất 10 GB RAM và 4 CPU. Nếu dùng VirtualBox, tắt máy ảo trước khi tăng RAM/CPU.
2. Cài và đăng nhập Tailscale, rồi kiểm tra:

   ```bash
   tailscale ip -4
   tailscale status
   ```

   Lệnh đầu tiên phải trả về IP Tailscale dạng `100.x.x.x`.
3. Kiểm tra Docker nếu đã cài:

   ```bash
   docker info
   ```

   Installer tự cài Docker nếu thiếu. Nếu vừa cài Docker, installer sẽ yêu cầu đăng xuất/đăng nhập lại để quyền Docker có hiệu lực; sau đó chạy lại installer.
4. Giữ nguyên cấu trúc bộ file. Các file values/action phải nằm trong `golden/` như bảng ở mục 1.
5. Nếu đây là máy thành viên, nhận `golden.lock` từ máy gốc và đặt vào `golden/golden.lock` trước khi cài. Tất cả máy phải dùng cùng lock.

Không chạy installer bằng `sudo`. Hãy chạy bằng user thường; script sẽ gọi `sudo` khi cần quyền quản trị. Installer tự cài các công cụ còn thiếu như Docker, `kubectl`, `k3d`, Helm và `wsk`. Tailscale không được installer cài hộ.

## 4. Chuẩn bị thư mục

Mở Terminal và vào thư mục đã giải nén. Thay đường dẫn mẫu bằng vị trí thực tế:

```bash
cd /duong/dan/toi/golden-config-final
pwd
ls
ls golden
bash ./CaiDatOpenWhiskMoi.sh --help
```

Kiểm tra các file bắt buộc:

```bash
test -f ./CaiDatOpenWhiskMoi.sh
test -f ./golden/golden-values.yaml
test -f ./golden/deploy-actions.sh
```

Nếu máy gốc chưa có `golden.lock`, installer sẽ tạo file sau khi chọn chart. Gửi chính file đó cho máy c1/c2/c3 còn lại; không để mỗi máy tự tạo lock riêng.

Có thể cấp quyền chạy một lần:

```bash
chmod +x ./CaiDatOpenWhiskMoi.sh ./XoaOpenWhiskDeCaiLai.sh ./golden/*.sh
```

Các lệnh trong README cũng có thể chạy bằng `bash ./ten-script.sh`, không bắt buộc phải cấp executable bit.

## 5. Cài mới lần đầu

Trước khi chạy, xác nhận không có dữ liệu OpenWhisk cần giữ. Nếu k3d cluster chưa tồn tại, chạy:

```bash
CLUSTER_NAME=c2 bash ./CaiDatOpenWhiskMoi.sh --test
```

Thay `c2` bằng vai trò của máy (`c1`, `c2` hoặc `c3`). `CLUSTER_NAME` dùng để đặt tên cluster trong dòng cấu hình Gateway; mặc định là `c2`.

Nếu muốn cài trước và kiểm thử sau, bỏ `--test`:

```bash
CLUSTER_NAME=c2 bash ./CaiDatOpenWhiskMoi.sh
```

Installer thực hiện các bước sau; không cần chạy `install-golden.sh` thủ công:

1. Kiểm tra không chạy bằng root, kiểm tra file Golden, Tailscale và RAM.
2. Cài công cụ còn thiếu. Nếu vừa cài Docker và user chưa có quyền, installer dừng để bạn đăng nhập lại.
3. Tạo k3d cluster 1 server + 2 agent, map NodePort `31001`, gán nhãn invoker và chờ nodes Ready.
4. Kiểm tra StorageClass mặc định, tải/kiểm tra Helm chart và đối chiếu `golden.lock`.
5. Chạy `helm template` để xác nhận các giá trị Golden được chart chấp nhận.
6. Tải sẵn image Python vào node invoker (trừ khi dùng `--no-preload`).
7. Cài OpenWhisk trực tiếp bằng `helm upgrade --install` và `golden/golden-values.yaml`.
8. Đặt resource cap cho controller, invoker, Kafka, CouchDB và ZooKeeper; chờ pod sẵn sàng.
9. Lấy guest key từ Kubernetes secret và cấu hình `wsk` trên máy.
10. Tự động chạy `golden/deploy-actions.sh` để tạo `ping` và `test-thu` trong namespace guest.
11. Lưu danh sách image vào `golden/images-<hostname>.txt`; nếu có `--test`, chạy thêm `golden/test-all.sh`.

Lần cài đầu có thể mất 10–20 phút do tải image và khởi động action runtime. Để terminal mở trong lúc installer chạy. Không cần mở `watch` để installer hoạt động; nếu muốn xem pod ở Terminal khác:

```bash
kubectl get nodes
kubectl -n openwhisk get pods -w
```

## 6. Nếu đã có k3d/OpenWhisk

Không chọn cài mới nếu muốn giữ cluster hiện tại. Dùng:

```bash
CLUSTER_NAME=c2 bash ./CaiDatOpenWhiskMoi.sh --redeploy
```

`--redeploy` giữ k3d cluster và PVC, bật cluster lên nếu cần, rồi cập nhật release OpenWhisk theo chart/values hiện tại. Nếu thay đổi persistence hoặc Helm báo lỗi StatefulSet/`volumeClaimTemplates`, chỉ dùng `--redeploy --clean` khi đã đồng ý xóa dữ liệu trên PVC.

| Lệnh | Tác động |
|---|---|
| `bash ./CaiDatOpenWhiskMoi.sh` | Cài mới; nếu cluster đã tồn tại, hỏi trước khi xóa cluster cũ |
| `bash ./CaiDatOpenWhiskMoi.sh --test` | Cài mới rồi chạy `golden/test-all.sh` |
| `bash ./CaiDatOpenWhiskMoi.sh --redeploy` | Giữ k3d và PVC, cập nhật/cài lại Helm release |
| `bash ./CaiDatOpenWhiskMoi.sh --redeploy --clean` | Giữ k3d nhưng gỡ Helm release và xóa PVC trước khi cài lại; mất dữ liệu OpenWhisk |
| Thêm `--no-preload` | Bỏ tải trước image Python; action Python lần đầu có thể khởi động chậm |
| Thêm `--yes` / `-y` | Bỏ qua xác nhận xóa cluster cũ trong luồng cài mới; chỉ dùng khi chắc chắn muốn xóa |

`--clean` không có tác dụng nếu không kèm `--redeploy`. Không dùng `--yes` theo thói quen: nếu cluster đã tồn tại và không có `--redeploy`, installer có thể xóa cluster cũ để tạo lại.

## 7. Tùy chọn cấu hình

Có thể truyền biến môi trường ngay trước lệnh. Các giá trị mặc định nằm trong `CaiDatOpenWhiskMoi.sh`:

| Biến | Mặc định | Ý nghĩa |
|---|---|---|
| `CLUSTER_NAME` | `c2` | Tên máy trong cấu hình Gateway (`c1`, `c2`, `c3`) |
| `API_HOST` | Tự lấy từ `tailscale ip -4` | IP Tailscale gắn vào API host; dùng khi tự động chọn sai IP |
| `CLUSTER` | `openwhisk-cluster` | Tên k3d cluster |
| `RELEASE` | `owdev` | Tên Helm release |
| `NS` | `openwhisk` | Kubernetes namespace |
| `TIMEOUT` | `900` giây | Thời gian tối đa chờ pod sẵn sàng |
| `NODE_CAP` | `1` | Giới hạn memory cho node k3d |
| `SERVER_MEM` | `1536m` | Memory cap node server |
| `AGENT_MEM` | `3328m` | Memory cap mỗi node agent |
| `TAINT_SERVER` | `1` | Không xếp workload OpenWhisk lên node server |
| `TOLERATE_SECONDS` | `3600` | Thời gian Kubernetes cho phép node tạm mất kết nối |
| `GOLDEN_DIR` | `$HERE/golden` | Thư mục chứa values, lock và script Gateway |
| `SRC_DIR` | `$HERE/openwhisk-deploy-kube` | Thư mục Helm chart OpenWhisk |
| `CHART_REPO` | Apache openwhisk-deploy-kube | Repo clone nếu chart chưa có |

Ví dụ nếu IP Tailscale không tự nhận diện đúng:

```bash
CLUSTER_NAME=c3 API_HOST=100.x.x.x bash ./CaiDatOpenWhiskMoi.sh
```

Các giới hạn resource cho từng pod (`CONTROLLER_LIMIT`, `INVOKER_LIMIT`, `KAFKA_LIMIT`, `COUCHDB_LIMIT`, `ZOOKEEPER_LIMIT` và các `*_REQUEST`) cũng có thể override qua environment. Nếu thay đổi, phải thống nhất cùng một bộ giá trị cho cả ba máy và kiểm tra lại RAM thực.

## 8. Kiểm tra sau khi cài

Installer tự chờ pod và cấu hình `wsk`, nhưng vẫn nên kiểm tra kết quả:

```bash
kubectl config current-context
kubectl get nodes -o wide
kubectl -n openwhisk get pods
kubectl -n openwhisk get pvc
kubectl -n openwhisk get job owdev-install-packages
wsk -i namespace list
curl -k "https://$(tailscale ip -4):31001/"
```

Mong đợi:

- Context là `k3d-openwhisk-cluster`; có 3 node Ready.
- Pod controller, nginx, Kafka, CouchDB và hai invoker sẵn sàng.
- PVC hiện có và ở trạng thái `Bound` vì persistence đang bật trong `golden/golden-values.yaml`.
- API trên cổng `31001` trả HTTP 200 và `wsk -i namespace list` gọi được OpenWhisk.
- Job `owdev-install-packages` không phải điều kiện để action Python hoạt động; installer/test ghi chú job này riêng.

Kiểm tra nhanh các hạn mục và chart:

```bash
kubectl -n openwhisk get pvc
kubectl -n openwhisk get pods
helm -n openwhisk list
```

Nếu chưa Ready, xem `kubectl -n openwhisk describe pod <ten-pod>` và log container init. Không chạy lại cài mới để xử lý một pod đang khởi động; hãy sửa nguyên nhân rồi thử `--redeploy`.

## 9. Action Gateway và bàn giao cấu hình

Bước 10 tự động tạo hai action guest `ping` và `test-thu`, sau đó in dòng cấu hình cho Gateway và lưu vào:

```text
golden/gateway-line-<c1|c2|c3>.txt
```

Gửi dòng này cho người quản lý Gateway để cập nhật `INITIAL_CLUSTERS` trong `gateway.py`. Dòng cấu hình có guest key dưới dạng Base64; Base64 **không phải mã hóa**. Chỉ gửi qua kênh riêng trong nhóm, không đưa lên repo công khai, issue, chat công khai hoặc README.

Nếu bước deploy action bị lỗi, chạy lại sau khi pod sẵn sàng:

```bash
CLUSTER_NAME=c2 API_HOST=100.x.x.x bash ./golden/deploy-actions.sh
```

Đổi `c2` và IP cho đúng máy. Nếu chỉ muốn kiểm tra actions Golden, không cần chạy Gateway trên máy này; Gateway là dịch vụ riêng của máy điều phối.

## 10. Chạy kiểm thử

Chạy cả kiểm tra tính năng và Golden:

```bash
bash ./golden/test-all.sh
```

Hoặc thêm `--test` ngay trong lệnh cài. `test-all.sh` chạy lần lượt `TestMoi.sh` và `test-golden.sh`; test Golden gửi 300 request mặc định và tạo action tạm, nên không chạy đồng thời với benchmark khác.

Các lệnh hữu ích:

```bash
bash ./golden/test-golden.sh
bash ./golden/test-golden.sh --restart-db
bash ./golden/test-golden.sh --compare ./golden/images-<may-khac>.txt
```

`--restart-db` tạm dừng/bật lại CouchDB; chỉ chạy khi chấp nhận gián đoạn dịch vụ và không có benchmark đang chạy. `--compare` so sánh danh sách image với máy khác.

Test Golden kiểm tra: giới hạn RAM; không bị 429 khi gọi dồn; PVC/persistence; chart và image được ghim; image Python và cold start. Test phụ kiểm tra API và tương thích Gateway.

Báo cáo được lưu trong `golden/`:

- `test-all-report-<hostname>.txt`: kết quả gộp nếu chạy `test-all.sh`.
- `golden-report-<hostname>.txt`: bảng tổng kết và chi tiết test Golden.
- `golden-debug-<hostname>.txt`: HTTP request/response khi cần debug.
- `images-<hostname>.txt`: image đang chạy để gửi/so sánh giữa máy.

**Đọc cả báo cáo, không chỉ nhìn exit code của installer:** `CaiDatOpenWhiskMoi.sh --test` gọi `test-all.sh` với `|| true`, nên installer có thể kết thúc dù test thất bại. Cần xem bảng tổng kết trong report và đảm bảo 5 mục chính là `ĐẠT`.

## 11. Sau khi tắt/mở máy ảo

Persistence đã bật, nên action và dữ liệu CouchDB được giữ qua reboot. Sau khi Docker đã lên, chạy:

```bash
bash ./golden/after-reboot.sh
```

Script chờ node Ready, xóa pod `Unknown`, kiểm tra marker khởi tạo CouchDB và chạy lại deploy action Gateway. Nếu marker mất, script hỏi trước khi gọi installer `--redeploy --clean`; nhánh này xóa PVC và có thể làm mất action/dữ liệu. Chỉ dùng `--auto` nếu chấp nhận để script tự động thực hiện nhánh cài lại này:

```bash
bash ./golden/after-reboot.sh --auto
```

## 12. Cập nhật cấu hình hoặc cài lại

Nếu sửa `golden/golden-values.yaml`, đồng bộ file mới cho cả ba máy. Trên từng máy, cập nhật release mà không xóa PVC bằng:

```bash
CLUSTER_NAME=c2 bash ./CaiDatOpenWhiskMoi.sh --redeploy
```

Nếu chỉ thay IP Tailscale, chạy lại deploy action để cập nhật dòng Gateway; có thể truyền `API_HOST` nếu cần. Nếu thay đổi cấu hình PVC/StatefulSet và Helm không cho update, chỉ dùng `--redeploy --clean` sau khi backup/xác nhận mất dữ liệu.

Không sửa riêng image tag, resource limit, persistence hoặc action trên một máy rồi so sánh với hai máy còn lại. `golden.lock` ghim chart; `golden-values.yaml` là cấu hình dùng chung.

## 13. Gỡ bỏ hoàn toàn - thao tác nguy hiểm

Chỉ dùng khi muốn xóa OpenWhisk và cluster k3d khỏi máy:

```bash
bash ./XoaOpenWhiskDeCaiLai.sh
```

Script yêu cầu xác nhận, sau đó gỡ Helm release/namespace, xóa k3d cluster và thư mục chart, xóa `~/.wskprops`, và xóa `golden.lock`. Script còn chạy `docker system prune -a --volumes -f`; thao tác này có thể xóa image, container và Docker volume **không liên quan đến OpenWhisk** trên máy. Kiểm tra các project Docker khác và backup dữ liệu trước khi đồng ý.

Lệnh này không cần dùng để cài mới trên máy sạch. Nó cũng không gỡ các CLI cài vào `/usr/local/bin`; phần gỡ công cụ nếu cần sẽ được script in hướng dẫn riêng.

## 14. Xử lý lỗi thường gặp

| Lỗi / hiện tượng | Kiểm tra và xử lý |
|---|---|
| Không thấy `golden-values.yaml` hoặc `deploy-actions.sh` | Đặt đúng file trong `golden/`; không chỉ copy riêng installer |
| Vừa cài Docker, script dừng | Đăng xuất/đăng nhập lại hoặc mở session mới để nhận quyền Docker, rồi chạy lại |
| `User chưa dùng được Docker` | Kiểm tra `docker info`, Docker daemon và group quyền của user; không chạy installer bằng sudo |
| Không lấy được IP Tailscale | Chạy `sudo tailscale up`, kiểm tra `tailscale ip -4`; thử `API_HOST=100.x.x.x` |
| `Chart KHÁC chart của máy gốc` | Dùng cùng `golden.lock`; kiểm tra `SRC_DIR` và clone chart. Không xóa lock để bỏ qua sai lệch trên máy thành viên |
| `helm template` không có PVC | Kiểm tra đúng `golden/golden-values.yaml`; file phải có `k8s.persistence.enabled: true` |
| PVC `Pending` | Chạy `kubectl get storageclass`; phải có StorageClass mặc định, k3d thường là `local-path` |
| Pod `Unknown`, `Pending`, `CrashLoopBackOff` | Xem `kubectl -n openwhisk get pods`, `describe pod` và logs; kiểm tra RAM VM, disk, Internet và Docker |
| Hết `TIMEOUT` | Chờ pod hồi phục, sửa nguyên nhân, rồi chạy `--redeploy`; tránh xóa cluster nếu muốn giữ dữ liệu |
| Helm báo lỗi StatefulSet/`volumeClaimTemplates` khi đổi persistence | Chỉ khi đã chấp nhận mất PVC mới dùng `--redeploy --clean` |
| API `https://<tailscale-ip>:31001` không trả HTTP 200 | Kiểm tra pod nginx/controller, port mapping, Tailscale và firewall; xem Test 0 trong `golden-debug-*.txt` |
| Test Gateway 404 | Chạy lại `golden/deploy-actions.sh`; đảm bảo actions được tạo bằng guest key và `CLUSTER_NAME` đúng |
| Test 2 có HTTP 202 | OpenWhisk đã nhận activation nhưng action chưa hoàn tất kịp; đọc tỷ lệ HTTP 200 và 429 trong report |
| Test không đạt RAM cap | Kiểm tra `docker stats --no-stream`, RAM VM và các cap `*_LIMIT`; thống nhất thay đổi cho cả ba máy |

## 15. Checklist bàn giao

- [ ] Mọi máy dùng cùng `golden/golden-values.yaml` và `golden/golden.lock`.
- [ ] Mỗi cluster có 3 node Ready, các pod chính sẵn sàng và PVC Bound.
- [ ] API NodePort `31001` truy cập được qua Tailscale.
- [ ] `wsk -i namespace list` kết nối được.
- [ ] Action `ping`/`test-thu` được tạo trong guest và dòng `gateway-line-<cluster>.txt` đã gửi riêng cho người quản lý Gateway.
- [ ] Đã đọc `golden/test-all-report-*.txt` và `golden/golden-report-*.txt`; 5 việc chính đều đạt.
- [ ] Đã đo `docker stats --no-stream` và gửi `golden/images-*.txt` nếu cần đối chiếu giữa ba máy.

Nếu hướng dẫn cũ trong `HUONG-DAN-CAI-DAT.md`, `HUONG-DAN-THANH-VIEN.md` hoặc `golden/HUONG-DAN.md` khác với file này, ưu tiên README này và `CaiDatOpenWhiskMoi.sh` hiện tại.
