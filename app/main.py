"""DocDB Monitor: management UI/API (public :8080) + Prometheus http_sd/probe (loopback :9100)."""
import logging
import os
import threading
import time

import uvicorn
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles

import discovery
from collector import Target, TargetPool, render
from store import ALLOWED_INTERVALS, NAME_RE, Connection, create_store, validate_uri

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("docdb.main")

STATIC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
REQUIRE_AUTH = os.getenv("REQUIRE_AUTH", "false").lower() == "true"
ALLOWED_PRINCIPALS = {p.strip().lower() for p in os.getenv("ALLOWED_PRINCIPALS", "").split(",") if p.strip()}

store = create_store()
pool = TargetPool()


def guard(request: Request) -> str:
    user = request.headers.get("x-ms-client-principal-name", "")
    if REQUIRE_AUTH:
        if not user:
            raise HTTPException(401, "Authentication required")
        if ALLOWED_PRINCIPALS and user.lower() not in ALLOWED_PRINCIPALS:
            raise HTTPException(403, "Not allowed")
    if request.method not in ("GET", "HEAD", "OPTIONS") and request.headers.get("x-requested-with") != "docdb-ui":
        raise HTTPException(403, "Missing CSRF header")
    return user or "local"


app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)


@app.middleware("http")
async def security_headers(request: Request, call_next):
    resp = await call_next(request)
    resp.headers["Content-Security-Policy"] = "default-src 'self'; frame-ancestors 'none'"
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["Cache-Control"] = "no-store"
    return resp


def _view(c: Connection) -> dict:
    d = c.__dict__.copy()
    d["status"] = pool.status.get(c.name)
    return d


def _check_settings(interval: str, name: str = None):
    if name is not None and not NAME_RE.match(name):
        raise HTTPException(400, "Name must match [a-z0-9-], max 40 chars")
    if interval not in ALLOWED_INTERVALS:
        raise HTTPException(400, f"Interval must be one of {', '.join(ALLOWED_INTERVALS)}")


def _host(uri: str) -> str:
    try:
        return validate_uri(uri)
    except ValueError as exc:
        raise HTTPException(400, str(exc))


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.get("/api/meta")
def meta(user: str = Depends(guard)):
    return {"intervals": list(ALLOWED_INTERVALS), "user": user, "backend": store.backend}


@app.get("/api/connections")
def list_connections(user: str = Depends(guard)):
    return [_view(c) for c in store.list()]


@app.post("/api/connections", status_code=201)
def create_connection(body: dict, user: str = Depends(guard)):
    name = str(body.get("name", ""))
    interval = str(body.get("interval", "1m"))
    _check_settings(interval, name)
    uri = str(body.get("uri", ""))
    host = _host(uri)
    if store.get(name):
        raise HTTPException(409, "Name already exists")
    c = Connection(name=name, host=host, interval=interval, enabled=bool(body.get("enabled", True)),
                   collstats=bool(body.get("collstats", True)), note=str(body.get("note", ""))[:200])
    store.save(c, uri)
    log.info("user=%s created connection=%s", user, name)
    return _view(c)


@app.put("/api/connections/{name}")
def update_connection(name: str, body: dict, user: str = Depends(guard)):
    cur = store.get(name)
    if not cur:
        raise HTTPException(404, "Not found")
    uri = body.get("uri") or None
    if uri:
        cur.host = _host(str(uri))
    cur.interval = str(body.get("interval", cur.interval))
    _check_settings(cur.interval)
    cur.enabled = bool(body.get("enabled", cur.enabled))
    cur.collstats = bool(body.get("collstats", cur.collstats))
    cur.note = str(body.get("note", cur.note))[:200]
    store.save(cur, str(uri) if uri else None)
    log.info("user=%s updated connection=%s", user, name)
    return _view(cur)


@app.delete("/api/connections/{name}", status_code=204)
def delete_connection(name: str, user: str = Depends(guard)):
    store.delete(name)
    pool.forget(name)
    log.info("user=%s deleted connection=%s", user, name)
    return Response(status_code=204)


@app.post("/api/test")
def test_connection(body: dict, user: str = Depends(guard)):
    uri = body.get("uri")
    if uri:
        _host(str(uri))
    elif body.get("name"):
        try:
            uri = store.get_uri(str(body["name"]))
        except Exception:
            raise HTTPException(404, "Not found")
    else:
        raise HTTPException(400, "uri or name required")
    t = Target(str(uri))
    try:
        r = t.scrape(collstats=False)
    finally:
        t.close()
    return {"up": bool(r["up"]), "error": r["error"], "commands": r["commands"], "duration": round(r["duration"], 2)}


@app.get("/api/discovery/clusters")
def discovery_clusters(user: str = Depends(guard)):
    try:
        return discovery.list_clusters()
    except Exception as exc:
        log.warning("discovery list failed: %s", str(exc)[:300])
        raise HTTPException(502, f"Cluster discovery failed: {str(exc)[:300]}")


@app.get("/api/discovery/clusters/{resource_group}/{name}/connection-strings")
def discovery_connection_strings(resource_group: str, name: str, user: str = Depends(guard)):
    try:
        return discovery.connection_strings(resource_group, name)
    except ValueError as exc:
        raise HTTPException(400, str(exc))
    except Exception as exc:
        log.warning("discovery connection strings failed: %s", str(exc)[:300])
        raise HTTPException(502, f"Connection string lookup failed: {str(exc)[:300]}")


@app.get("/")
def index():
    return FileResponse(os.path.join(STATIC, "index.html"))


app.mount("/static", StaticFiles(directory=STATIC), name="static")

# ---- internal (loopback) app for the Prometheus sidecar -------------------------------------------
internal = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)


_SHORT_TIMEOUT = {"5s": "4s", "10s": "8s", "15s": "12s"}  # scrape_timeout must be <= interval


@internal.get("/sd")
def sd():
    return [{"targets": ["127.0.0.1:9100"],
             "labels": {"__meta_docdb_name": c.name, "__meta_docdb_interval": c.interval,
                        "__meta_docdb_timeout": _SHORT_TIMEOUT.get(c.interval, "20s")}}
            for c in store.list() if c.enabled]


@internal.get("/probe")
def probe(target: str):
    conn = store.get(target)
    if not conn:
        return Response("unknown target\n", status_code=404)
    try:
        uri = store.get_uri(target)
        result = pool.scrape(target, uri, conn.collstats)
    except Exception as exc:
        log.warning("probe %s failed: %s", target, str(exc)[:200])
        result = {"up": 0, "commands": {}, "duration": 0.0, "error": str(exc)[:300]}
    return Response(render(result), media_type="text/plain; version=0.0.4")


def _run_internal():
    uvicorn.Server(uvicorn.Config(internal, host="127.0.0.1", port=9100, log_level="warning")).run()


if __name__ == "__main__":
    threading.Thread(target=_run_internal, daemon=True).start()
    uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("PORT", "8080")), log_level="info")
