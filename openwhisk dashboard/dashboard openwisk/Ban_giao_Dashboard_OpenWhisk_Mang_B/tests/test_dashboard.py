"""Tests use explicitly constructed inputs; no performance metrics are invented."""
from fastapi.testclient import TestClient
import dashboard

client = TestClient(dashboard.app)


def setup_function():
    dashboard.records.clear()
    dashboard.seen_keys.clear()


def event(req_id="t1", cluster="c2", status="ok", duration=40):
    return {"req_id": req_id, "cluster": cluster, "action": "A1", "status": status, "duration_ms": duration, "ts": 1790000000}


def test_health_and_dashboard():
    assert client.get("/health").json()["ok"] is True
    assert client.get("/").status_code == 200


def test_ingest_statistics_and_recent():
    assert client.post("/ingest", json=event()).status_code == 200
    assert client.post("/ingest", json=event("t2", status="error", duration=100)).status_code == 200
    response = client.get("/api/stats?window=60").json()
    assert response["overview"]["count"] == 2
    assert response["overview"]["avg_ms"] == 70
    assert response["overview"]["success_rate"] == 50
    assert response["clusters"]["c2"]["count"] == 2
    assert len(client.get("/api/recent?limit=10").json()["items"]) == 2


def test_reject_malformed_and_duplicate():
    assert client.post("/ingest", json={"hello": 1}).status_code == 422
    assert client.post("/ingest", json=event(duration=-1)).status_code == 422
    assert client.post("/ingest", json=event()).json()["duplicate"] is False
    assert client.post("/ingest", json=event()).json()["duplicate"] is True
    assert client.get("/api/stats").json()["overview"]["count"] == 1


def test_buffer_is_bounded():
    for i in range(5002):
        dashboard.records.append({**event(str(i)), "received_at": 1790000000})
    assert len(dashboard.records) == 5000


def test_empty_means_no_success_rate():
    result = client.get("/api/stats").json()
    assert result["overview"]["count"] == 0
    assert result["overview"]["success_rate"] is None


def test_csv_export_uses_actual_records():
    client.post("/ingest", json=event())
    result = client.get("/api/export.csv")
    assert result.status_code == 200
    assert "req_id,cluster,action,status" in result.text
    assert "t1,c2,A1,ok" in result.text
