import os
from datetime import datetime, timezone
import time


from fastapi import FastAPI, Response, Request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, generate_latest,Histogram

app = FastAPI(title="MarketMate")

START_TIME = datetime.now(timezone.utc)
REQUEST_COUNT = Counter("marketmate_http_requests_total", "Total HTTP requests", ["method", "path", "status"])
REQUEST_DURATION = Histogram("marketmate_http_request_duration_seconds", "HTTP request latency", ["method", "path"])

@app.middleware("http")
async def collect_metrics(request: Request, call_next):
    start = time.perf_counter()
    status = 500
    try:
        response = await call_next(request)
        status = response.status_code
        return response
    finally:
        route = request.scope.get("route")
        path = getattr(route, "path", "unmatched")
        if path != "/metrics":
            REQUEST_COUNT.labels(request.method, path, str(status)).inc()
            REQUEST_DURATION.labels(request.method, path).observe(time.perf_counter() - start)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/api/status")
def status():
    return {
        "name": "MarketMate",
        "environment": os.getenv("APP_ENV", "development"),
        "version": os.getenv("APP_IMAGE", "test"),
    }


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), headers={"Content-Type": CONTENT_TYPE_LATEST})
