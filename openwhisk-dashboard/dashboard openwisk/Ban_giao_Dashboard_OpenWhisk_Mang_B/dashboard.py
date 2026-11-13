"""OpenWhisk multi-cluster result station (TV3 / Track B).

One process, in-memory ring buffer (up to 5,000 records). No database,
no OpenWhisk auth key, and no changes to OpenWhisk clusters.
"""
from __future__ import annotations

import hmac
import csv
import io
import math
import os
import time
from collections import Counter, deque
from pathlib import Path
from statistics import mean
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles

BASE_DIR = Path(__file__).resolve().parent
MAX_RECORDS = 5000
MAX_PAYLOAD_BYTES = 8192
INGEST_TOKEN = os.getenv("INGEST_TOKEN", "")
DEFAULT_CLUSTERS = ("c1", "c2", "c3")

app = FastAPI(title="OpenWhisk Result Dashboard", version="1.0.0", docs_url="/docs")
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")

records: deque[dict[str, Any]] = deque(maxlen=MAX_RECORDS)
seen_keys: set[tuple[str, str]] = set()
started_at = time.time()


def _percentile(vals: list[float], percentile: int = 95) -> float:
    if not vals:
        return 0.0
    vals = sorted(vals)
    pos = (len(vals) - 1) * percentile / 100
    low, high = int(math.floor(pos)), int(math.ceil(pos))
    return round(vals[low] + (vals[high] - vals[low]) * (pos - low), 2)


def _is_success(status: str) -> bool:
    return status.lower() in {"ok", "success", "succeeded", "completed", "200", "201", "202"}


def _stats_for(items: list[dict[str, Any]], window: int) -> dict[str, Any]:
    durations = [x["duration_ms"] for x in items]
    success = sum(_is_success(x["status"]) for x in items)
    n = len(items)
    return {
        "count": n,
        "rps": round(n / window, 3),
        "avg_ms": round(mean(durations), 2) if durations else 0.0,
        "p95_ms": _percentile(durations),
        "success_rate": round(success * 100 / n, 2) if n else None,
        "error_rate": round((n - success) * 100 / n, 2) if n else None,
    }


@app.get("/")
async def homepage() -> FileResponse:
    return FileResponse(BASE_DIR / "static" / "index.html")


@app.get("/health")
async def health() -> dict[str, Any]:
    return {"ok": True, "service": "openwhisk-dashboard", "records": len(records)}


@app.post("/ingest")
async def ingest(request: Request, x_ingest_token: str | None = Header(default=None)) -> dict[str, Any]:
    if INGEST_TOKEN and not hmac.compare_digest(x_ingest_token or "", INGEST_TOKEN):
        raise HTTPException(status_code=401, detail="Invalid ingest token")
    payload = await request.body()
    if len(payload) > MAX_PAYLOAD_BYTES:
        raise HTTPException(status_code=413, detail="Payload too large")
    try:
        import json
        value = json.loads(payload)
    except (ValueError, UnicodeDecodeError):
        raise HTTPException(status_code=400, detail="Invalid JSON") from None
    if not isinstance(value, dict):
        raise HTTPException(status_code=422, detail="Expected a JSON object")
    fields = ("req_id", "cluster", "action", "status", "duration_ms", "ts")
    missing = [field for field in fields if field not in value]
    if missing:
        raise HTTPException(status_code=422, detail="Missing fields: " + ", ".join(missing))
    for field in ("req_id", "cluster", "action", "status"):
        if not isinstance(value[field], str) or not 0 < len(value[field]) <= 128:
            raise HTTPException(status_code=422, detail=f"Invalid {field}")
    if not isinstance(value["duration_ms"], (int, float)) or isinstance(value["duration_ms"], bool) or not math.isfinite(value["duration_ms"]) or value["duration_ms"] < 0:
        raise HTTPException(status_code=422, detail="Invalid duration_ms")
    if not isinstance(value["ts"], (int, float, str)) or isinstance(value["ts"], str) and len(value["ts"]) > 100:
        raise HTTPException(status_code=422, detail="Invalid ts")

    key = (value["cluster"], value["req_id"])
    if key in seen_keys:
        return {"ok": True, "duplicate": True, "stored": len(records)}
    if len(records) == MAX_RECORDS:
        old = records[0]
        seen_keys.discard((old["cluster"], old["req_id"]))
    record = {field: value[field] for field in fields}
    record["duration_ms"] = round(float(record["duration_ms"]), 3)
    record["received_at"] = time.time()
    records.append(record)
    seen_keys.add(key)
    return {"ok": True, "duplicate": False, "stored": len(records)}


@app.get("/api/stats")
async def get_stats(window: int = Query(default=60, ge=10, le=900)) -> dict[str, Any]:
    now = time.time()
    items = [e for e in records if e["received_at"] >= now - window]
    by_cluster: dict[str, list[dict[str, Any]]] = {c: [] for c in DEFAULT_CLUSTERS}
    for item in items:
        by_cluster.setdefault(item["cluster"], []).append(item)

    cluster_stats = {key: _stats_for(values, window) for key, values in sorted(by_cluster.items())}
    for key, values in by_cluster.items():
        cluster_stats[key]["last_seen"] = max((x["received_at"] for x in values), default=None)

    actions = dict(Counter(e["action"] for e in items).most_common(12))
    successes = Counter(e["cluster"] for e in items if _is_success(e["status"]))
    failures = Counter(e["cluster"] for e in items if not _is_success(e["status"]))
    start_second = math.floor(now) - window + 1
    timestamps = list(range(start_second, start_second + window))
    per_second = {c: [0] * window for c in by_cluster}
    for item in items:
        offset = int(item["received_at"]) - start_second
        if 0 <= offset < window:
            per_second[item["cluster"]][offset] += 1

    return {
        "now": now,
        "window": window,
        "stored": len(records),
        "max_records": MAX_RECORDS,
        "overview": _stats_for(items, window),
        "clusters": cluster_stats,
        "actions": actions,
        "results_by_cluster": {c: {"success": successes[c], "error": failures[c]} for c in sorted(by_cluster)},
        "timeline": {"seconds": timestamps, "by_cluster": per_second},
    }


@app.get("/api/recent")
async def get_recent(limit: int = Query(default=25, ge=1, le=100), cluster: str = "all") -> dict[str, Any]:
    matches = (e for e in reversed(records) if cluster == "all" or e["cluster"] == cluster)
    selected = []
    for e in matches:
        selected.append(e)
        if len(selected) >= limit:
            break
    return {"items": selected}


@app.get("/api/export.csv")
async def export_csv() -> Response:
    """Download only observed records; CSV cell formula injection is neutralized."""
    output = io.StringIO()
    writer = csv.writer(output)
    fields = ("received_at", "req_id", "cluster", "action", "status", "duration_ms", "ts")
    writer.writerow(fields)
    for item in records:
        row = []
        for field in fields:
            value = item[field]
            if isinstance(value, str) and value.lstrip().startswith(("=", "+", "-", "@")):
                value = "'" + value
            row.append(value)
        writer.writerow(row)
    return Response(
        content="\ufeff" + output.getvalue(),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": 'attachment; filename="openwhisk-results.csv"'},
    )
