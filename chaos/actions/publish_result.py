"""
publish_result - nhận bản ghi từ A1/A2/A3 rồi đẩy sang Dashboard.
Giữ nguyên mã của bạn Tấn Kiệt (openwhisk dashboard/actions/publish_result.py)
để Dashboard không phải sửa gì.

Tham số TARGET_URL chính là thứ mà chaos.sh F5 đổi sang địa chỉ chết.
"""
import json
import time
import urllib.request


def main(args):
    target = args.get("TARGET_URL", "").rstrip("/")
    mode = args.get("MODE", "dashboard")

    if mode != "dashboard" or not target:
        return {"sent": False, "error": "Invalid configuration"}

    record = {
        "req_id": args.get("req_id") or "test-" + str(int(time.time() * 1000)),
        "cluster": args.get("cluster", "c1"),
        "action": args.get("action", "A1"),
        "status": args.get("status", "ok"),
        "duration_ms": float(args.get("duration_ms", 0)),
        "ts": args.get("ts", time.time()),
    }

    body = json.dumps(record).encode("utf-8")
    req = urllib.request.Request(
        target + "/ingest",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=3) as response:
            return {
                "sent": response.status == 200,
                "http_status": response.status,
                "dashboard_response": response.read().decode("utf-8"),
            }
    except Exception as e:
        return {"sent": False, "error": str(e)}
