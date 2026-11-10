"""
publish_result - nhận bản ghi từ A1/A2/A3 rồi đẩy sang Dashboard (POST <TARGET_URL>/ingest).

Cố ý TÁCH thành action riêng thay vì để A1/A2/A3 gọi thẳng Dashboard: nếu Dashboard chết hoặc
chậm, chỉ action này bị treo (ở chế độ blocking=false, không ai chờ nó), còn đường xử lý
request của người dùng vẫn nguyên vẹn. Tham số TARGET_URL là thứ kịch bản F5 sẽ đổi sang địa chỉ chết.
"""
import json
import math
import urllib.request


def main(args):
    target = str(args.get("TARGET_URL", "")).rstrip("/")
    if args.get("MODE", "dashboard") != "dashboard" or not target:
        return {"sent": False, "error": "Invalid configuration"}

    fields = ("req_id", "cluster", "action", "status", "duration_ms", "ts")
    missing = [f for f in fields if f not in args]
    if missing:
        # Không bịa số liệu để lấp chỗ trống: Dashboard chỉ được nhận bản ghi thật.
        return {"sent": False, "error": "Missing fields: " + ", ".join(missing)}
    if any(not isinstance(args[f], str) or not args[f] for f in fields[:4]):
        return {"sent": False, "error": "Invalid event identity fields"}
    try:
        duration = float(args["duration_ms"])
    except (TypeError, ValueError):
        return {"sent": False, "error": "Invalid duration_ms"}
    if not math.isfinite(duration) or duration < 0:
        return {"sent": False, "error": "Invalid duration_ms"}

    record = {f: args[f] for f in fields}
    record["duration_ms"] = duration

    headers = {"Content-Type": "application/json"}
    if args.get("INGEST_TOKEN"):  # Dashboard hỗ trợ header X-Ingest-Token khi bật INGEST_TOKEN
        headers["X-Ingest-Token"] = str(args["INGEST_TOKEN"])

    req = urllib.request.Request(target + "/ingest", data=json.dumps(record).encode("utf-8"),
                                 headers=headers, method="POST")
    try:
        # timeout 3s: đủ cho Tailscale; quá hạn thì thôi (F5 sẽ rơi vào nhánh này).
        with urllib.request.urlopen(req, timeout=3) as resp:
            return {"sent": resp.status == 200, "http_status": resp.status}
    except Exception as exc:  # noqa: BLE001
        return {"sent": False, "error": str(exc)}
