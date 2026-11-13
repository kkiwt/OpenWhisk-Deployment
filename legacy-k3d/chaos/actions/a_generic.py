"""
Action A1 / A2 / A3 dùng chung một mã nguồn.
Khác nhau ở tham số BUSY (số giây bận CPU) và NAME, truyền lúc tạo action.

Action tự gửi kết quả về publish_result (bất đồng bộ) theo tỉ lệ SAMPLE_RATE,
giống hệt a1.py mà bạn Tấn Kiệt đã kiểm thử với Dashboard.
"""
import base64
import json
import os
import random
import ssl
import time
import urllib.request


def publish_result(args, name, duration_ms):
    sample_rate = float(args.get("SAMPLE_RATE", 0.05))
    if random.random() > sample_rate:
        return {"publish_status": "skipped"}

    api_host = os.environ.get("__OW_API_HOST", "")
    api_key = os.environ.get("__OW_API_KEY", "")
    if not api_host or not api_key:
        # thiếu -a provide-api-key true lúc tạo action
        return {"publish_status": "missing_api_config"}

    record = {
        "req_id": os.environ.get("__OW_ACTIVATION_ID"),
        "cluster": args.get("CLUSTER", "c2"),
        "action": name,
        "status": "ok",
        "duration_ms": duration_ms,
        "ts": time.time(),
    }

    url = (api_host.rstrip("/")
           + "/api/v1/namespaces/_/actions/publish_result?blocking=false")
    auth = base64.b64encode(api_key.encode("utf-8")).decode("ascii")

    request = urllib.request.Request(
        url,
        data=json.dumps(record).encode("utf-8"),
        headers={"Content-Type": "application/json",
                 "Authorization": "Basic " + auth},
        method="POST",
    )
    try:
        context = ssl._create_unverified_context()
        with urllib.request.urlopen(request, timeout=0.5,
                                    context=context) as response:
            return {"publish_status": "submitted",
                    "publish_http_status": response.status}
    except Exception as e:
        return {"publish_status": "failed", "publish_error": type(e).__name__}


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
        "cluster": args.get("CLUSTER", "c2"),
        "action": name,
        "result": x,
        "duration_ms": duration_ms,
    }
    result.update(publish_result(args, name, duration_ms))
    return result
