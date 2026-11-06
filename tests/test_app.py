from fastapi.testclient import TestClient
from prometheus_client.parser import text_string_to_metric_families

from app.main import app

client = TestClient(app)


def metric_value(name):
    response = client.get("/metrics")
    assert response.status_code == 200
    for family in text_string_to_metric_families(response.text):
        for sample in family.samples:
            if sample.name == name:
                return sample.value
    raise AssertionError(f"Metric {name} is missing")


def test_health():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_status(monkeypatch):
    monkeypatch.setenv("APP_ENV", "staging")
    monkeypatch.setenv("APP_IMAGE", "registry.example.com/task:abc123")
    response = client.get("/api/status")
    assert response.status_code == 200
    assert response.json() == {
        "name": "MarketMate",
        "environment": "staging",
        "version": "registry.example.com/task:abc123",
    }


def test_status_defaults(monkeypatch):
    monkeypatch.delenv("APP_ENV", raising=False)
    monkeypatch.delenv("APP_IMAGE", raising=False)
    response = client.get("/api/status")
    assert response.status_code == 200
    assert response.json() == {
        "name": "MarketMate", "environment": "development", "version": "test"
    }


def test_metrics_count_status_requests():
    before = metric_value("api_status_requests_total")
    client.get("/api/status")
    assert metric_value("api_status_requests_total") == before + 1
