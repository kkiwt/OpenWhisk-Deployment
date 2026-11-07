# OpenWhisk Deployment & Chaos Experiments

Repository này chứa bộ cài các cluster OpenWhisk, Gateway cân bằng tải, Dashboard nhận telemetry thật, kịch bản K6 và công cụ gây lỗi có kiểm soát. README này là bản đồ chạy toàn bộ repo từ cài đặt đến đo/đối chiếu; chi tiết cài từng thành phần nằm trong README của thư mục tương ứng.

> Các địa chỉ Tailscale, tên user SSH và cluster trong `chaos/chaos.conf` là cấu hình theo môi trường hiện tại. Trước khi chạy trên máy khác, hãy kiểm tra và sửa chúng; không mặc định IP mẫu phù hợp với máy của bạn.

## 1. Luồng hệ thống

```text
K6 -> OpenWhisk Gateway (:8080) -> OpenWhisk cluster c1/c2/c3 (:31001)
												  |
												  +-> A1/A2/A3
															|
															+-> publish_result -> Dashboard (:9000)

chaos.sh ghi các mốc F1-F5 vào chaos/results/chaos.csv
K6 runner ghi kết quả tải; analyze.py ghép hai nguồn để vẽ biểu đồ
```

- Mỗi máy c1/c2/c3 chạy một cluster k3d/OpenWhisk độc lập.
- Gateway thường chạy trên một máy điều phối, nhận request ở port `8080`, chọn cluster và chuyển tiếp action.
- Dashboard nhận event do action OpenWhisk gửi đến `POST /ingest`; frontend không tự tạo benchmark.
- `SAMPLE_RATE=0.05` nghĩa là Dashboard chỉ nhận khoảng 5% activation được chọn mẫu. RPS trên Dashboard là tốc độ nhận event mẫu, không phải tổng RPS của K6.
- Công cụ Chaos làm thay đổi trạng thái cluster/mạng/action. Chỉ chạy trong môi trường thử nghiệm, không chạy lên hệ thống production.

## 2. Cấu trúc repository

| Thư mục | Chức năng | Điểm bắt đầu |
|---|---|---|
| `golden-config-final/` | Cài OpenWhisk theo Golden Config trên từng máy | [`CaiDatOpenWhiskMoi.sh`](golden-config-final/CaiDatOpenWhiskMoi.sh), [`README.md`](golden-config-final/README.md) |
| `openwhisk-gateway/` | Gateway FastAPI, trang quản trị và TUI | [`start.sh`](openwhisk-gateway/start.sh), [`gateway.py`](openwhisk-gateway/gateway.py) |
| `openwhisk dashboard/` | Dashboard FastAPI, action telemetry và deploy helper | [`README.md`](openwhisk%20dashboard/README.md), [`deploy-openwhisk-actions.sh`](openwhisk%20dashboard/deploy-openwhisk-actions.sh) |
| `k6/` | K6 scenario, runner đơn và runner lặp theo protocol | [`load.js`](k6/load.js), [`run_exp.sh`](k6/run_exp.sh), [`run_series.sh`](k6/run_series.sh) |
| `chaos/` | F1-F5, preflight, SSH/WSK setup, warmup và phân tích | [`chaos.conf`](chaos/chaos.conf), [`chaos.sh`](chaos/chaos.sh), [`HUONGDAN.md`](chaos/HUONGDAN.md) |

`golden-config-final/openwhisk-deploy-kube/` là Helm chart dependency của Apache OpenWhisk. README ở `golden-config-final/` mô tả bộ cài đang dùng; không dùng luồng legacy `golden/install-golden.sh` thay cho installer chính.

Trong `openwhisk dashboard/` còn có một bản bàn giao lồng trong `dashboard openwisk/Ban_giao_Dashboard_OpenWhisk_Mang_B/`. Bản chạy chính là `openwhisk dashboard/dashboard.py`; bản lồng là gói tài liệu/bàn giao riêng.

## 3. Yêu cầu môi trường

### Trên mỗi máy chạy cluster

- Ubuntu Linux, Internet và tài khoản user thường có quyền `sudo`.
- Tailscale đã đăng nhập cùng tailnet với Gateway, Dashboard và các cluster khác.
- Khuyến nghị VM có ít nhất 10 GB RAM, 4 CPU và khoảng 40 GB đĩa trống. Golden Config đặt tổng memory cap node mặc định 8 GiB; cap không thể tạo thêm RAM vật lý.
- Installer tự cài Docker, `kubectl`, k3d, Helm và `wsk` nếu thiếu. Tailscale phải được cài và kết nối trước.

### Trên máy Gateway/Dashboard/K6

- Python 3 và `python3-venv` cho Dashboard/Gateway.
- K6 CLI để chạy `k6/load.js`.
- Các máy và port cần thiết phải liên lạc được qua mạng riêng/Tailscale.

Không expose `31001`, `8080` hoặc `9000` công khai ra Internet. `gateway.py` có các endpoint quản trị không kèm xác thực; chỉ cho phép truy cập trên mạng tin cậy.

## 4. Cài ba OpenWhisk cluster

Thực hiện lần lượt trên từng máy c1, c2, c3. Mỗi máy cần cùng `golden-config-final/golden/golden-values.yaml` và cùng `golden.lock` của máy gốc.

1. Cài/đăng nhập Tailscale và lấy IP:

	```bash
	tailscale ip -4
	tailscale status
	```

2. Vào thư mục cài đặt:

	```bash
	cd /path/to/OpenWhisk-Deployment/golden-config-final
	test -f ./golden/golden-values.yaml
	test -f ./golden/deploy-actions.sh
	```

3. Nếu máy gốc chưa có `golden.lock`, chạy installer trước trên máy gốc để tạo lock, rồi chia sẻ đúng file đó cho hai máy còn lại. Không để mỗi máy tự tạo lock khác nhau.
4. Chạy installer với nhãn của máy:

	```bash
	CLUSTER_NAME=c1 bash ./CaiDatOpenWhiskMoi.sh --test
	```

	Trên hai máy khác thay `c1` bằng `c2` và `c3`. Bỏ `--test` nếu muốn cài trước rồi kiểm tra sau.
5. Installer tự tạo k3d, clone/kiểm tra chart, áp dụng Golden values, bật persistence, cấu hình `wsk` và tạo `ping`/`test-thu` cho Gateway. **Không chạy `golden/install-golden.sh` theo sau.**
6. Xác nhận từng máy:

	```bash
	kubectl config current-context
	kubectl get nodes -o wide
	kubectl -n openwhisk get pods
	kubectl -n openwhisk get pvc
	wsk -i namespace list
	curl -k "https://$(tailscale ip -4):31001/"
	```

	Cần có 3 node Ready, pod chính sẵn sàng, PVC ở trạng thái `Bound` và API NodePort `31001` trả HTTP 200.

Các flag, quy trình `--redeploy`, giới hạn RAM, kiểm thử và cảnh báo xóa PVC được mô tả đầy đủ tại [`golden-config-final/README.md`](golden-config-final/README.md). Cài mới trên máy đang có cluster có thể hỏi xóa cluster cũ; không xác nhận nếu muốn giữ dữ liệu.

**Đối chiếu với tài liệu phân công v3:** tài liệu đó ghi CouchDB không lưu bền và tổng giới hạn RAM cụm không quá 7,15 GB; project hiện tại lại bật PVC/persistence và đặt node cap tổng 8 GiB. Theo yêu cầu hiện tại, giữ nguyên installer, values và tests của project; không đổi Golden theo tài liệu cũ.

## 5. Cấu hình Gateway

Gateway chỉ cần chạy một bản trên máy điều phối. Sau khi cài từng cluster, `golden/deploy-actions.sh` tạo file `gateway-line-c1.txt`, `gateway-line-c2.txt` hoặc `gateway-line-c3.txt` có URL và guest credential dạng Base64. Dùng dòng đó để cấu hình biến môi trường; không chép credential vào `gateway.py`.

1. Trên máy Gateway, cấu hình URL và nhập Base64 guest auth trực tiếp vào prompt ẩn. Không paste credential vào file Python, terminal command, README hoặc Git:

	```bash
	export ACTIVE=c1,c2,c3
	export CLUSTER_C1_URL=https://<IP-C1>:31001
	read -r -s -p 'Base64 guest auth for c1: ' CLUSTER_C1_AUTH_B64; printf '\n'; export CLUSTER_C1_AUTH_B64
	export CLUSTER_C2_URL=https://<IP-C2>:31001
	read -r -s -p 'Base64 guest auth for c2: ' CLUSTER_C2_AUTH_B64; printf '\n'; export CLUSTER_C2_AUTH_B64
	export CLUSTER_C3_URL=https://<IP-C3>:31001
	read -r -s -p 'Base64 guest auth for c3: ' CLUSTER_C3_AUTH_B64; printf '\n'; export CLUSTER_C3_AUTH_B64
	```

	Chỉ nhập các cluster đã deploy xong; đặt `ACTIVE=c1,c2` nếu c3 chưa sẵn sàng. Dùng `gateway-line-cX.txt` làm nguồn URL/auth, nhưng giữ file đó và auth ngoài repo.
2. Khởi chạy:

	```bash
	cd /path/to/OpenWhisk-Deployment/openwhisk-gateway
	./start.sh
	```

	`start.sh` tạo virtualenv nếu chưa có, cài dependencies rồi chạy Uvicorn ở port `8080`. Giữ terminal này hoạt động. Mỗi lần mở terminal mới cần nhập lại biến môi trường; restart Gateway sau khi đổi cấu hình.
3. Xác nhận Gateway thấy các cluster:

	```bash
	curl -s http://127.0.0.1:8080/admin/clusters
	```

	Khi gọi từ máy khác, thay `127.0.0.1` bằng địa chỉ Gateway trên tailnet.

`gateway.py` đọc `CLUSTER_C1_URL`/`CLUSTER_C1_AUTH_B64` (tương tự c2/c3) từ environment khi khởi động. Nếu chưa cấu hình, cluster đó bị bỏ qua và có warning; `/admin/clusters` chỉ hiện các cluster đã nạp thành công.

## 6. Chạy Dashboard và nối telemetry thật

Dashboard và Gateway là hai ứng dụng riêng. Gateway proxy request; Dashboard chỉ nhận event telemetry và không nằm trên đường phản hồi chính của K6.

### Chạy Dashboard

Chọn máy có IP Tailscale mà các cluster truy cập được. Trên máy đó:

```bash
cd "/path/to/OpenWhisk-Deployment/openwhisk dashboard"
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python -m uvicorn dashboard:app --host <TAILSCALE_IP> --port 9000 --workers 1
```

Thay `<TAILSCALE_IP>` bằng IP thực của máy Dashboard. Dùng một worker vì bộ đệm dữ liệu nằm trong RAM của một process; dữ liệu mất khi server restart. Không dùng `127.0.0.1` làm `DASHBOARD_URL` vì các action trong cluster không thể truy cập loopback của máy host.

Kiểm tra:

```bash
curl http://<TAILSCALE_IP>:9000/health
curl 'http://<TAILSCALE_IP>:9000/api/stats?window=60'
```

### Deploy action telemetry trên từng cluster

Golden installer chỉ tạo `ping` và `test-thu`; nó **không** tạo A1/A2/A3 hay `publish_result`. Tạo file cấu hình WSK cho mỗi cluster bằng `chaos/setup-wskprops.sh` hoặc chuẩn bị `~/.wskprops.c1`, `~/.wskprops.c2`, `~/.wskprops.c3` an toàn. Sau đó từ folder Dashboard chạy:

```bash
DASHBOARD_URL=http://<TAILSCALE_IP>:9000 \
CLUSTERS="c1 c2 c3" SAMPLE_RATE=0.05 \
./deploy-openwhisk-actions.sh
```

Chỉ liệt kê cluster đã có `.wskprops.<cluster>`, ví dụ `CLUSTERS="c2"`. Script kiểm tra `/health`, cập nhật `publish_result`, rồi deploy A1/A2/A3 trên từng cluster đã chọn.

Xác minh một activation thật (thay c2 và địa chỉ Dashboard nếu cần):

```bash
WSK_CONFIG_FILE="$HOME/.wskprops.c2" wsk -i action invoke A1 \
  --blocking --result --param SAMPLE_RATE 1
curl -s 'http://<TAILSCALE_IP>:9000/api/recent?limit=5&cluster=c2'
```

Chỉ lần gọi này override sampling thành 100%; action vẫn giữ mặc định 5%. Record có activation ID thật. `duration_ms` là thời gian chạy bên trong action, không phải latency đầu-cuối của Gateway. Không diễn giải tốc độ record đã lấy mẫu thành tổng RPS hệ thống. Hướng dẫn endpoints, hợp đồng dữ liệu và kiểm thử nằm ở [`openwhisk dashboard/README.md`](openwhisk%20dashboard/README.md).

## 7. Chạy một lần đo K6

`k6/load.js` gửi request đến `POST /invoke/A1`, `/invoke/A2`, `/invoke/A3`. Mặc định chạy qua Gateway. `TARGET_MODE=direct` chuyển sang gọi trực tiếp OpenWhisk HTTPS cho E1a. Scenario mặc định chạy 50 request/giây trong 5 phút, chia xác suất 60% A1, 30% A2, 10% A3; ngưỡng mặc định P95 < 500 ms và lỗi < 1%.

`k6/run_exp.sh` chạy một lượt K6, ghi summary K6, Docker và CPU host mỗi giây. Dùng nó cho smoke/đo đơn hoặc E5 liên tục. Với E1/E2/E3 theo quy trình phân công, dùng `k6/run_series.sh` để tự warm-up 1 phút, lấy 3 lượt đo hợp lệ 5 phút, nghỉ 2 phút giữa các lượt, loại dropped iterations/CPU host >70%, và ghi median.

```bash
GATEWAY_URL=http://<GATEWAY_TAILSCALE_IP>:8080 \
TASKSET_CPUS=0,1 \
./k6/run_exp.sh e1b_rr 50
```

`TASKSET_CPUS` là tùy chọn; bỏ dòng này nếu không muốn ghim CPU hoặc `taskset` không có. Runner tạo thư mục riêng như `k6/results/e1b_rr_YYYYMMDD_HHMMSS/`, gồm:

- `k6.json`: K6 `--summary-export` (request count/rate, P50/P95, lỗi, dropped iterations).
- `docker.csv`: `timestamp_utc,host,container,cpu_percent,mem_usage`, đúng schema mà analyzer đọc.
- `host_cpu.csv`: CPU tổng trên máy chạy K6, dùng để loại lượt có CPU >70%.
- `run-info.txt`: tên lượt đo, rate, duration, target mode/URL và cấu hình VU.

Mặc định lấy Docker stats trên máy chạy runner. Có thể lấy mẫu thêm từ c2/c3 qua SSH không mật khẩu:

```bash
REMOTE_DOCKER_HOSTS="c2=user@100.x.2 c3=user@100.x.3" \
GATEWAY_URL=http://<GATEWAY_TAILSCALE_IP>:8080 \
./k6/run_series.sh e1b_rr 50
```

Chỉ thêm host đã được chuẩn bị SSH key và kiểm tra quyền Docker. SSH sampling mỗi giây có overhead; giữ cấu hình sampling giống nhau giữa các lượt và ghi rõ host nào đã được thu. Có thể đặt `DURATION`, `PRE_VUS`, `MAX_VUS`, `RESULTS_DIR`, `K6_BIN` hoặc `SSH_CONNECT_TIMEOUT` qua environment.

### E1a: gọi trực tiếp một cluster

`run_exp.sh` đọc `APIHOST` và `AUTH` từ file `.wskprops` mà không ghi auth vào command line, log hay `run-info.txt`. Ví dụ đo riêng c2:

```bash
WSK_CONFIG_FILE="$HOME/.wskprops.c2" \
TARGET_MODE=direct DIRECT_CLUSTER=c2 \
./k6/run_series.sh e1a_c2 10
```

Direct mode dùng HTTPS, guest auth trong header Basic và bỏ verify TLS cho certificate tự ký của lab. Chỉ gửi file `.wskprops` qua kênh an toàn; không commit hoặc in credential. Chạy riêng từng cluster, thay cả file và label c1/c2/c3. `run_series.sh` chạy các lượt chuẩn; `run_exp.sh` vẫn chạy **một lượt** để ghép với E5.

Series tạo thư mục `series_<name>_<timestamp>/` chứa `series-summary.csv`, log và `runs/` với thư mục warm-up cùng artifacts của từng lượt đo. CSV giữ kết quả hợp lệ/bị loại và có dòng `MEDIAN_VALID`.

Từ root repo:

```bash
k6 run \
  -e GATEWAY_URL=http://<GATEWAY_TAILSCALE_IP>:8080 \
  -e RATE=50 \
  -e DURATION=5m \
  ./k6/load.js
```

Chạy thử không gửi request:

```bash
k6 run -e DRY_RUN=1 -e RATE=1 -e DURATION=5s \
  -e GATEWAY_URL=http://<GATEWAY_TAILSCALE_IP>:8080 ./k6/load.js
```

### Chạy K6 kèm E5

`chaos/run-chaos-exp.sh` gọi `$K6_DIR/run_exp.sh`; `chaos.conf` mặc định đặt `K6_DIR` về thư mục `k6/` trong repo, nơi hiện đã có runner. Ví dụ:

```bash
cd ./chaos
WARM=60 HOLD=120 TAIL=120 \
	./run-chaos-exp.sh e5_pod 30 pod --target c2
```

Runner nhận `GATEWAY_URL` và `DURATION` từ script điều phối. Sau khi hoàn tất, nó in thư mục kết quả K6; mốc chaos nằm riêng ở `chaos/results/chaos.csv`.

## 8. Chuẩn bị và chạy Chaos F1-F5

Thực hiện trên máy thử nghiệm, sau khi Gateway và các cluster đã hoạt động.

1. Tạo cấu hình local từ template rồi sửa cho đúng lab hiện tại:

	```bash
	cd /path/to/OpenWhisk-Deployment/chaos
	cp chaos.conf.example chaos.conf
	nano chaos.conf
	```

	Điền `ME`, IP Tailscale c1/c2/c3, user SSH, `K3D_CLUSTER`, pod/node name, Gateway URL, Dashboard URL và action parameters. `chaos.conf` bị ignore khỏi Git vì chứa thông tin riêng của lab; chỉ commit thay đổi vào `chaos.conf.example` nếu cần cập nhật template.
2. Tạo SSH không mật khẩu tới các host cần điều khiển từ xa:

	```bash
	cd /path/to/OpenWhisk-Deployment/chaos
	./setup-ssh.sh
	./setup-ssh.sh --check
	```

	Máy đích cần SSH server. `chaos.sh` dùng SSH batch mode; nếu còn hỏi mật khẩu thì chưa sẵn sàng đo.
3. Tạo `.wskprops` cho các cluster mà F5 cần điều khiển. Mỗi file chứa guest auth, cần đặt quyền `600` (script tự làm); không commit hoặc chia sẻ công khai.
4. Deploy A1/A2/A3 và publisher trên cluster của từng máy nếu chưa có:

	```bash
	./deploy-actions-plus.sh
	```

	Lệnh này dùng `ME`, cluster credentials và `REAL_DASHBOARD_URL` trong `chaos.conf`. Nó chỉ deploy lên cluster cục bộ; dashboard helper ở mục 6 dùng `.wskprops` để deploy nhiều cluster.
5. Chạy preflight:

	```bash
	./check-ready.sh
	```

	Sửa các dòng ❌ trước khi gây lỗi. Chạy `./warmup.sh` ngay trước test Golden để làm nóng các action và tránh nhầm cold start thành lỗi Gateway.
6. Xem các tình huống và tập dượt:

	```bash
	./chaos.sh list
	DRY=1 ./chaos.sh pod start --target c2
	```

7. Chỉ sau khi đã kiểm tra lệnh DRY, chạy một tình huống thật. Kết thúc bằng stop/reset và xác nhận không còn lỗi:

	```bash
	./chaos.sh pod start --target c2
	./chaos.sh pod stop --target c2
	./chaos.sh status
	./chaos.sh reset
	```

| Mã | Lệnh | Tác động |
|---|---|---|
| F1 | `./chaos.sh pod start/stop --target cX` | Xóa invoker pod; `stop` chờ pod Ready trở lại |
| F2 | `./chaos.sh node start/stop --target cX` | Dừng/khởi động container k3d agent từ xa |
| F3 | `./chaos.sh tailscale start/stop --target cX` | Chặn/gỡ outbound tới IP cluster và port 31001 bằng iptables |
| F4 | `./chaos.sh cluster start/stop --target cX` | Dừng/khởi động các container của k3d cluster; gây gián đoạn lớn |
| F5 | `./chaos.sh station start/stop` | Đổi `TARGET_URL` của `publish_result` sang địa chỉ chết rồi khôi phục Dashboard URL |

F3 cần sudo và có thể để lại luật iptables nếu terminal bị ngắt. F4 có thể làm cụm mất kết nối trong vài phút. Sau bất kỳ lỗi nào, chạy `./chaos.sh status`; nếu có trạng thái/luật sót, chạy `./chaos.sh reset` và kiểm tra lại.

## 9. Phân tích kết quả

`chaos/chaos.sh` ghi timestamp start/stop vào `chaos/results/chaos.csv`. `chaos/analyze.py` đọc một thư mục kết quả K6 có `k6.json` và tùy chọn `docker.csv`; nó in bảng thống kê và lưu `bieudo-cpu-ram.png` trong thư mục run.

```bash
python3 -m pip install pandas matplotlib
python3 ./chaos/analyze.py /path/to/k6/results/<run> \
  ./chaos/results/chaos.csv
```

Nếu kết quả K6 của bạn không chứa `k6.json`/`docker.csv`, analyzer không thể tạo đầy đủ biểu đồ như mô tả. Lưu riêng output K6/Docker bằng runner phù hợp trước khi phân tích; không thay số đo thật bằng event mẫu Dashboard.

## 10. Phân tích số liệu và làm tiếp E1–E5

Sau một lượt đo, chạy analyzer với thư mục output. Với Chaos, truyền cả CSV mốc lỗi:

```bash
python3 ./chaos/analyze.py ./k6/results/<run> ./chaos/results/chaos.csv
```

Analyzer đọc `k6.json` và `docker.csv`, in các số K6 và CPU/RAM của Docker được lấy mẫu trên máy chạy runner, rồi lưu `bieudo-cpu-ram.png`. Nếu không có `docker.csv` hợp lệ hoặc không thấy container k3d, không được gọi kết quả đó là RAM tổng của các cluster.

Theo phân công v3, mỗi điểm đo làm nóng 1 phút, đo 5 phút, nghỉ 2 phút và lấy 3 lượt hợp lệ. `k6/run_series.sh <name> <rate>` tự chạy warm-up, lặp lượt đo (mặc định cần 3 hợp lệ, tối đa 5 lần thử), loại lượt có `dropped_iterations > 0` hoặc CPU host vượt 70%, và lưu median trong `series-summary.csv`. Có thể chỉnh `WARMUP_DURATION`, `MEASURE_DURATION`, `REPEATS`, `MAX_ATTEMPTS`, `COOLDOWN_SECONDS`, `MAX_HOST_CPU`. Script hỏi xác nhận trước khi gửi tải thật; `--yes` bỏ qua prompt.

Ngưỡng tham khảo của phân công là P95 dưới 500 ms, lỗi dưới 1% và không có HTTP 429. Script vẫn giữ các lượt có P95/lỗi vượt ngưỡng nếu không có dropped iterations và CPU quá cao; đó có thể là điểm gãy cần ghi nhận trong E1, không nên tự loại khỏi dữ liệu.

Các việc tiếp theo theo thứ tự:

1. **Golden Config:** dùng cấu hình hiện tại của project: persistence bật và node cap tổng 8 GiB; không áp dụng giá trị khác trong tài liệu cũ.
2. **Trạm nhận kết quả:** dùng Dashboard làm phương án tạm thời như đã thống nhất. Firebase/app Android và `push_events.py` chưa triển khai, chưa nằm trong đường chạy hiện tại.
3. **Chạy E1a:** direct mode đã được thêm; đo riêng từng cluster bằng `.wskprops.cX`, `TARGET_MODE=direct` và `DIRECT_CLUSTER=cX`. E1b trở đi dùng `gateway`.
4. **Chạy E1b/E2/E3:** dùng Gateway, đo c1-only rồi 2/3 cluster; policy hiện đổi qua `POST /admin/config?policy=rr` hoặc `policy=latency`. Ghi lại config, rate và output path cho từng run.
5. **E5 breaker:** theo project hiện tại, breaker giữ ngưỡng 10 lỗi liên tiếp và probe mỗi 2 giây. Tài liệu v3 ghi 3; không đổi code theo tài liệu cũ. Báo cáo thời gian phát hiện theo ngưỡng project đang chạy.
6. **Chạy E4/E5 sau khi thử DRY:** E4 cần áp/xóa `tc netem`; E5 cần chạy từng F1–F5 với breaker bật/tắt, nhiều lần lặp và ghi `chaos.csv`. Chỉ chạy trên lab.
7. **Đo resource:** cung cấp `REMOTE_DOCKER_HOSTS` cho các cluster có SSH key để lấy stats từ từng host. Kiểm tra dữ liệu từng host trong `docker.csv`; nếu không thu đủ ba host, ghi rõ giới hạn.
8. **Phân tích/đóng băng:** tổng hợp JSON/CSV theo run, rà `series-summary.csv`, sinh bảng/biểu đồ E1–E5; lưu Golden values/lock và phiên bản scripts, không để credential trong repo.

## 11. Kiểm thử mã nguồn

Kiểm tra cú pháp các script shell chính:

```bash
bash -n \
  ./golden-config-final/CaiDatOpenWhiskMoi.sh \
  ./golden-config-final/XoaOpenWhiskDeCaiLai.sh \
	./chaos/chaos.sh ./chaos/check-ready.sh ./chaos/run-chaos-exp.sh \
	./k6/run_exp.sh
```

Chạy test Dashboard trong môi trường Python của bạn:

```bash
cd "openwhisk dashboard"
python -m pip install -r requirements.txt pytest httpx
python -m pytest -q tests/test_dashboard.py tests/test_actions.py \
  --import-mode=importlib
```

Chỉ định rõ test files vì trong folder còn có bản bàn giao lồng chứa test trùng tên.

## 12. Bảo mật và dữ liệu

- Không đưa guest auth, Base64 auth, `~/.wskprops.*`, file `gateway-line-*` hoặc token vào README/repo công khai. Base64 không che giấu credential.
- Gateway có API quản trị không xác thực trong mã hiện tại; chỉ bind/mở port trên mạng riêng và giới hạn bằng firewall.
- Dashboard giữ tối đa 5.000 record trong RAM; restart sẽ xóa buffer. Dùng export CSV nếu cần lưu lại.
- Giới hạn truy cập port `31001`, `8080`, `9000` vào tailnet/mạng nhóm; không port-forward ra Internet.
- Chỉ chạy F1-F5 trên cluster thử nghiệm. Không chạy `XoaOpenWhiskDeCaiLai.sh` hoặc `--redeploy --clean` nếu chưa backup/chấp nhận mất dữ liệu. Script xóa toàn bộ còn gọi `docker system prune -a --volumes -f`, có thể xóa volume của project Docker khác.

## 13. Chẩn đoán nhanh

| Triệu chứng | Kiểm tra đầu tiên |
|---|---|
| Gateway trả 503 | `curl http://<gateway>:8080/admin/clusters`; kiểm tra cluster `up/available`, Tailscale và action `test-thu` |
| Gateway/action trả 404 | Golden tạo `ping`/`test-thu`; telemetry deploy helper tạo A1/A2/A3/`publish_result` trên từng cluster |
| Dashboard không có record | Kiểm tra `publish_result` đã deploy, `TARGET_URL` dùng IP truy cập được từ action, port 9000 mở trong tailnet, và chờ publisher bất đồng bộ hoàn tất |
| Dashboard count về 0 | API thống kê dùng cửa sổ 60/300/900 giây; xem `/api/recent` và chọn cửa sổ phù hợp |
| Chaos preflight báo SSH | Kiểm tra `SSH_cX`, sshd trên host đích và `./setup-ssh.sh --check` |
| F5 bỏ qua cluster | Thiếu `~/.wskprops.cX` hoặc auth không hợp lệ; tạo lại từ secret guest |
| K6 không kết nối | Kiểm tra `GATEWAY_URL`, Gateway đang nghe port 8080 và firewall/Tailscale |
| Test Gateway fail lúc đầu | Chạy `./chaos/warmup.sh` rồi chạy lại test ngay khi action còn nóng |
| `run-chaos-exp.sh` báo thiếu `run_exp.sh` | Kiểm tra `K6_DIR` trong `chaos/chaos.conf` có trỏ tới folder chứa `run_exp.sh` hay không |

## 14. Tài liệu thành phần

- Cài cluster, flags, persistence, test và recovery: [`golden-config-final/README.md`](golden-config-final/README.md).
- Dashboard, API, telemetry actions và cách deploy thật: [`openwhisk dashboard/README.md`](openwhisk%20dashboard/README.md).
- Các tình huống F1-F5 và cấu hình chaos: [`chaos/HUONGDAN.md`](chaos/HUONGDAN.md).
- Kịch bản thao tác chi tiết cũ: [`chaos/CHAY-TU-DAU-DEN-CUOI.md`](chaos/CHAY-TU-DAU-DEN-CUOI.md). Nếu ví dụ trong tài liệu này khác `chaos.conf`/script hiện tại, ưu tiên cấu hình và script hiện tại.