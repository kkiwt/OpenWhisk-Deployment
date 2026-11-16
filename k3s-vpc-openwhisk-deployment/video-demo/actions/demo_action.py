"""Small telemetry-rich action used by the video scenario."""
import os
import socket
import time


def main(args):
    name = str(args.get("NAME", "Group4_Action1"))
    busy = float(args.get("BUSY", 0.05))
    start = time.perf_counter()
    value = 0
    while time.perf_counter() - start < busy:
        value += 1
    return {
        "status": "ok",
        "group": args.get("GROUP", "Group 4"),
        "action": name,
        "cluster": args.get("CLUSTER", "k3s-vpc-demo"),
        "activation_id": os.environ.get("__OW_ACTIVATION_ID", ""),
        "action_pod": socket.gethostname(),
        "duration_ms": round((time.perf_counter() - start) * 1000, 2),
        "work_units": value,
        "timestamp": time.time(),
    }
