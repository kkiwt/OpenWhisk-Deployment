import json
import math
import urllib.request

def main(args):
    target = args.get("TARGET_URL", "").rstrip("/")
    mode = args.get("MODE", "dashboard")

    if mode != "dashboard" or not target:
        return {"sent": False, "error": "Invalid configuration"}

    fields = ("req_id", "cluster", "action", "status", "duration_ms", "ts")
    missing = [field for field in fields if field not in args]
    if missing:
        return {"sent": False, "error": "Missing fields: " + ", ".join(missing)}
    if any(not isinstance(args[field], str) or not args[field] for field in fields[:4]):
        return {"sent": False, "error": "Invalid event identity fields"}
    try:
        duration_ms = float(args["duration_ms"])
    except (TypeError, ValueError):
        return {"sent": False, "error": "Invalid duration_ms"}
    if not math.isfinite(duration_ms) or duration_ms < 0:
        return {"sent": False, "error": "Invalid duration_ms"}

    record = {field: args[field] for field in fields}
    record["duration_ms"] = duration_ms

    body = json.dumps(record).encode("utf-8")

    req = urllib.request.Request(
        target + "/ingest",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST"
    )

    try:
        with urllib.request.urlopen(req, timeout=3) as response:
            return {
                "sent": response.status == 200,
                "http_status": response.status,
                "dashboard_response": response.read().decode("utf-8")
            }
    except Exception as e:
        return {"sent": False, "error": str(e)}
