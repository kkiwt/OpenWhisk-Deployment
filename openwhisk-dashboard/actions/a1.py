import time
import os
import json
import base64
import ssl
import random
import urllib.request


def publish_result(args, duration_ms, action_name):
    sample_rate = float(args.get("SAMPLE_RATE", 0.05))

    if random.random() > sample_rate:
        return {"publish_status": "skipped"}

    api_host = os.environ.get("__OW_API_HOST", "")
    api_key = os.environ.get("__OW_API_KEY", "")

    if not api_host or not api_key:
        return {"publish_status": "missing_api_config"}
    activation_id = os.environ.get("__OW_ACTIVATION_ID", "")
    if not activation_id:
        return {"publish_status": "missing_activation_id"}

    record = {
        "req_id": activation_id,
        "cluster": args.get("CLUSTER", "c2"),
        "action": action_name,
        "status": "ok",
        "duration_ms": duration_ms,
        "ts": time.time()
    }

    url = (
        api_host.rstrip("/")
        + "/api/v1/namespaces/_/actions/publish_result"
        + "?blocking=false"
    )

    auth = base64.b64encode(
        api_key.encode("utf-8")
    ).decode("ascii")

    request = urllib.request.Request(
        url,
        data=json.dumps(record).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Basic " + auth
        },
        method="POST"
    )

    try:
        context = ssl._create_unverified_context()

        with urllib.request.urlopen(
            request, timeout=0.5, context=context
        ) as response:
            return {
                "publish_status": "submitted",
                "publish_http_status": response.status
            }

    except Exception as e:
        return {
            "publish_status": "failed",
            "publish_error": type(e).__name__
        }


def main(args):
    action_name = args.get("ACTION_NAME", "A1")
    busy = float(args.get("BUSY", 0.05))
    start = time.perf_counter()
    x = 0

    while time.perf_counter() - start < busy:
        x += 1

    duration_ms = round(
        (time.perf_counter() - start) * 1000, 2
    )

    publish_info = publish_result(args, duration_ms, action_name)

    result = {
        "status": "ok",
        "cluster": args.get("CLUSTER", "c2"),
        "action": action_name,
        "result": x,
        "duration_ms": duration_ms
    }

    result.update(publish_info)
    return result
