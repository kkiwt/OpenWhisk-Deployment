"""
busy_work - mã nguồn chung của A1 / A2 / A3 (khác nhau ở tham số NAME và BUSY khi `wsk action update`).

Tính toán cơ bản: vòng lặp bận CPU đúng BUSY giây để mô phỏng việc nặng nhẹ khác nhau
(A1=0,05s / A2=0,20s / A3=0,50s). Dùng thời gian thực (perf_counter) chứ không dùng sleep, vì
sleep không chiếm CPU và sẽ che mất hiệu ứng tranh chấp CPU giữa các action pod trên worker 4 vCPU.

Báo kết quả về Dashboard theo kiểu "báo ngầm": bắn một request KHÔNG chặn tới action
`publish_result` rồi trả về ngay, nên Dashboard/trạm nhận hàng chết (kịch bản F5) không làm
chậm hay làm lỗi request của người dùng.
"""
import base64
import json
import os
import random
import ssl
import time
import urllib.request


def _publish(args, name, duration_ms):
    # Lấy mẫu để Dashboard không bị ngập: mặc định 5% (SAMPLE_RATE=0.05).
    if random.random() >= float(args.get("SAMPLE_RATE", 0.05)):
        return {"publish_status": "skipped"}

    api_host = os.environ.get("__OW_API_HOST", "")
    api_key = os.environ.get("__OW_API_KEY", "")
    if not api_host or not api_key:
        # Thiếu cờ `-a provide-api-key true` lúc tạo action (xem deploy-actions.sh).
        return {"publish_status": "missing_api_config"}

    record = {
        "req_id": os.environ.get("__OW_ACTIVATION_ID", ""),
        "cluster": args.get("CLUSTER", "c4"),
        "action": name,
        "status": "ok",
        "duration_ms": duration_ms,
        "ts": time.time(),
    }
    url = api_host.rstrip("/") + "/api/v1/namespaces/_/actions/publish_result?blocking=false"
    request = urllib.request.Request(
        url,
        data=json.dumps(record).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Basic " + base64.b64encode(api_key.encode()).decode("ascii"),
        },
        method="POST",
    )
    try:
        # Cert nginx của OpenWhisk là tự ký -> bỏ kiểm tra. Chỉ chấp nhận được vì địa chỉ này
        # nằm trong private network riêng; KHÔNG làm vậy với endpoint công khai.
        ctx = ssl._create_unverified_context()
        # timeout 0,5s: blocking=false chỉ cần 202 Accepted. Quá hạn thì bỏ, không ảnh hưởng request chính.
        with urllib.request.urlopen(request, timeout=0.5, context=ctx) as resp:
            return {"publish_status": "submitted", "publish_http_status": resp.status}
    except Exception as exc:  # noqa: BLE001 - mọi lỗi báo ngầm đều phải bị nuốt
        return {"publish_status": "failed", "publish_error": type(exc).__name__}


def main(args):
    name = args.get("NAME", "A1")
    busy = float(args.get("BUSY", 0.05))

    start = time.perf_counter()
    x = 0
    while time.perf_counter() - start < busy:
        x += 1
    duration_ms = round((time.perf_counter() - start) * 1000, 2)

    result = {
        "status": "ok",
        "cluster": args.get("CLUSTER", "c4"),
        "action": name,
        "result": x,
        "duration_ms": duration_ms,
    }
    result.update(_publish(args, name, duration_ms))
    return result
