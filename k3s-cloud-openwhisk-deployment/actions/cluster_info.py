"""
cluster_info - dùng cho hai action `ping` và `test-thu`.

`test-thu` là action mà Gateway FastAPI hiện có ping mỗi 2 giây (timeout 2 giây, hỏng 10 lần
liên tiếp thì ngắt cầu dao). Vì vậy hàm này phải CỰC NHẸ: không import thư viện nặng, không
gọi mạng, không ghi đĩa. Mọi giây thừa ở đây đều có thể khiến Gateway ngắt nhầm cụm.

Trả về thông tin giúp phân biệt "request đã vào cụm nào, pod nào" khi đọc kết quả K6.
"""
import os
import platform
import socket
import time


def _cgroup_mem_limit_mb():
    # Trong container, RAM *thật sự được phép dùng* nằm ở cgroup chứ không phải /proc/meminfo
    # (cái này hiện RAM của cả worker). cgroup v2 trước, v1 dự phòng.
    for path in ("/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory/memory.limit_in_bytes"):
        try:
            raw = open(path).read().strip()
            return None if raw == "max" else round(int(raw) / 1048576)
        except (OSError, ValueError):
            continue
    return None


def main(args):
    return {
        "status": "ok",
        "cluster": args.get("CLUSTER", "c4"),
        "platform": args.get("PLATFORM", "k3s-cloudfly"),
        # Với invoker dùng Kubernetes container factory, hostname = tên action pod.
        "action_pod": socket.gethostname(),
        "python": platform.python_version(),
        "cpu_count": os.cpu_count(),
        "loadavg": [round(x, 2) for x in os.getloadavg()],
        "mem_limit_mb": _cgroup_mem_limit_mb(),
        "activation_id": os.environ.get("__OW_ACTIVATION_ID"),
        "ts": time.time(),
    }
