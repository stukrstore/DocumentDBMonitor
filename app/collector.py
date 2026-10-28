"""Per-target scraping + Prometheus exposition (multi-target 'probe' pattern).

The `cluster` label is NOT emitted here; Prometheus adds it through relabeling (see prom config in deploy.ps1).
"""
import hashlib
import logging
import os
import threading
import time

from prometheus_client import CollectorRegistry, generate_latest
from prometheus_client.core import CounterMetricFamily, GaugeMetricFamily
from pymongo import MongoClient

log = logging.getLogger("docdb.collector")

LONG_QUERY_SECS = int(os.getenv("LONG_QUERY_SECS", "5"))
COLLSTATS_INTERVAL_SECS = int(os.getenv("COLLSTATS_INTERVAL_SECS", "600"))
COLLSTATS_MAX_COLLECTIONS = int(os.getenv("COLLSTATS_MAX_COLLECTIONS", "100"))
SKIP_DBS = {"admin", "local", "config"}
CURRENTOP_MAX_NS = 10


def _num(d, *path):
    """Walk nested dicts; return a number or None when the path is missing/non-numeric."""
    for p in path:
        if not isinstance(d, dict):
            return None
        d = d.get(p)
    return d if isinstance(d, (int, float)) and not isinstance(d, bool) else None


class Target:
    def __init__(self, uri: str):
        self.client = MongoClient(
            uri, appname="docdb-monitor", serverSelectionTimeoutMS=5000, connectTimeoutMS=5000,
            socketTimeoutMS=15000, maxPoolSize=2)
        self._cs_ts = 0.0
        self._cs_rows: list = []
        self._db_rows: list = []
        self._shard_rows: list = []
        self._warned: set = set()

    def close(self) -> None:
        try:
            self.client.close()
        except Exception:
            pass

    def _try(self, result: dict, command: str, fn):
        try:
            value = fn()
            result["commands"][command] = 1
            return value
        except Exception as exc:  # unsupported/forbidden command must not break other metrics
            result["commands"][command] = 0
            if command not in self._warned:
                self._warned.add(command)
                log.warning("%s failed: %s", command, str(exc)[:800])
            return None

    def _collstats(self) -> list:
        rows = []
        for dbname in self.client.list_database_names():
            if dbname in SKIP_DBS:
                continue
            for coll in self.client[dbname].list_collection_names():
                if len(rows) >= COLLSTATS_MAX_COLLECTIONS:
                    return rows
                try:
                    doc = next(self.client[dbname][coll].aggregate([{"$collStats": {"storageStats": {}}}]), None)
                    if doc:
                        st = doc.get("storageStats", {})
                        rows.append((dbname, coll, st.get("size", 0), st.get("count", 0),
                                     st.get("storageSize", 0), st.get("totalIndexSize", 0),
                                     st.get("avgObjSize", 0), st.get("nindexes", 0)))
                except Exception:
                    pass
        return rows

    def _shard_dist(self) -> list:
        """Per-shard (db, collection, shard, documents, bytes). Tries $shardedDataDistribution, then per-shard $collStats docs."""
        rows = []
        probe: list = []
        try:
            for doc in self.client.admin.aggregate([{"$shardedDataDistribution": {}}]):
                db, _, coll = str(doc.get("ns", "")).partition(".")
                if db in SKIP_DBS:
                    continue
                for sh in doc.get("shards", []):
                    rows.append((db, coll, str(sh.get("shardName", "")), sh.get("numOwnedDocuments", 0),
                                 sh.get("ownedSizeBytes", 0)))
            if rows:
                return rows
        except Exception:
            pass
        for dbname in self.client.list_database_names():
            if dbname in SKIP_DBS:
                continue
            for coll in self.client[dbname].list_collection_names():
                if len(rows) >= COLLSTATS_MAX_COLLECTIONS * 4:
                    return rows
                for doc in self.client[dbname][coll].aggregate([{"$collStats": {"storageStats": {}}}]):
                    shard = doc.get("shard")
                    if shard:
                        st = doc.get("storageStats", {})
                        rows.append((dbname, coll, str(shard), st.get("count", 0), st.get("size", 0)))
                    probe = probe or sorted(doc.keys()) + sorted((doc.get("storageStats") or {}).keys())
                if not rows:
                    # collStats command variant: {"sharded": true, "shards": {name: {count, size}}}
                    cs = self.client[dbname].command("collStats", coll)
                    for name, st in (cs.get("shards") or {}).items():
                        rows.append((dbname, coll, str(name), st.get("count", 0), st.get("size", 0)))
                    probe = probe or ["collStats:"] + sorted(cs.keys())
        if not rows:
            raise RuntimeError(f"no per-shard statistics exposed; fields seen: {probe}")
        return rows

    def _dbstats(self) -> list:
        rows = []
        for dbname in self.client.list_database_names():
            if dbname in SKIP_DBS:
                continue
            st = self.client[dbname].command("dbStats")
            rows.append((dbname, st.get("dataSize", 0), st.get("storageSize", 0), st.get("indexSize", 0),
                         st.get("objects", 0), st.get("collections", 0)))
        return rows

    def scrape(self, collstats: bool = True) -> dict:
        start = time.time()
        result = {"up": 0, "commands": {}, "duration": 0.0, "error": ""}
        admin = self.client.admin
        try:
            admin.command("ping")
            result["up"] = 1
        except Exception as exc:
            result["error"] = str(exc)[:300]
            result["duration"] = time.time() - start
            return result

        result["serverStatus"] = self._try(result, "serverStatus", lambda: admin.command("serverStatus"))

        inprog = self._try(result, "currentOp",
                           lambda: admin.command({"currentOp": 1, "active": True}).get("inprog", []))
        if inprog is not None:
            secs = [op.get("secs_running", 0) for op in inprog]
            by_op: dict = {}
            by_ns: dict = {}
            for op in inprog:
                by_op[op.get("op") or "unknown"] = by_op.get(op.get("op") or "unknown", 0) + 1
                ns = op.get("ns")
                if ns:
                    by_ns[ns] = by_ns.get(ns, 0) + 1
            top_ns = sorted(by_ns.items(), key=lambda kv: -kv[1])[:CURRENTOP_MAX_NS]
            result["currentOp"] = {"active": len(secs),
                                   "long": sum(1 for s in secs if s >= LONG_QUERY_SECS),
                                   "max_secs": max(secs, default=0),
                                   "by_op": by_op, "by_ns": top_ns}

        if collstats:
            if time.time() - self._cs_ts > COLLSTATS_INTERVAL_SECS:
                rows = self._try(result, "collStats", self._collstats)
                if rows is not None:
                    self._cs_rows, self._cs_ts = rows, time.time()
                    dbrows = self._try(result, "dbStats", self._dbstats)
                    if dbrows is not None:
                        self._db_rows = dbrows
            result["collStats"] = self._cs_rows
            result["dbStats"] = self._db_rows
            result["shardStats"] = self._shard_rows

        result["duration"] = time.time() - start
        return result


class _ResultCollector:
    def __init__(self, r: dict):
        self.r = r

    def collect(self):
        r = self.r
        up = GaugeMetricFamily("docdb_up", "1 if the cluster is reachable")
        up.add_metric([], r["up"])
        dur = GaugeMetricFamily("docdb_scrape_duration_seconds", "Scrape duration")
        dur.add_metric([], r["duration"])
        cmd = GaugeMetricFamily("docdb_command_success", "1 if the admin command succeeded", labels=["command"])
        for c, ok in r["commands"].items():
            cmd.add_metric([c], ok)
        yield from (up, dur, cmd)

        ss = r.get("serverStatus")
        if ss:
            yield from self._server_status(ss)

        co = r.get("currentOp")
        if co:
            for name, key, doc in (("docdb_currentop_active", "active", "Active operations"),
                                   ("docdb_currentop_long_running", "long", f"Operations running >= {LONG_QUERY_SECS}s"),
                                   ("docdb_currentop_max_secs_running", "max_secs", "Longest running operation (s)")):
                g = GaugeMetricFamily(name, doc)
                g.add_metric([], co[key])
                yield g
            bo = GaugeMetricFamily("docdb_currentop_by_type", "Active operations by op type", labels=["op"])
            for k, v in co.get("by_op", {}).items():
                bo.add_metric([k], v)
            bn = GaugeMetricFamily("docdb_currentop_by_namespace", "Active operations by namespace (top N)", labels=["ns"])
            for k, v in co.get("by_ns", []):
                bn.add_metric([k], v)
            yield from (bo, bn)

        rows = r.get("collStats")
        if rows:
            lbl = ["db", "collection"]
            fams = [GaugeMetricFamily(n, d, labels=lbl) for n, d in (
                ("docdb_collection_size_bytes", "Collection data size"),
                ("docdb_collection_documents", "Collection document count"),
                ("docdb_collection_storage_size_bytes", "Collection storage size"),
                ("docdb_collection_index_size_bytes", "Collection total index size"),
                ("docdb_collection_avg_object_size_bytes", "Collection average object size"),
                ("docdb_collection_indexes", "Collection index count"))]
            for row in rows:
                for fam, v in zip(fams, row[2:]):
                    fam.add_metric([row[0], row[1]], v)
            yield from fams

        shrows = r.get("shardStats")
        if shrows:
            sd = GaugeMetricFamily("docdb_shard_collection_documents", "Documents per shard per collection",
                                   labels=["db", "collection", "shard"])
            sb = GaugeMetricFamily("docdb_shard_collection_size_bytes", "Data bytes per shard per collection",
                                   labels=["db", "collection", "shard"])
            for db, coll, shard, docs, size in shrows:
                sd.add_metric([db, coll, shard], docs)
                sb.add_metric([db, coll, shard], size)
            yield from (sd, sb)

        dbrows = r.get("dbStats")
        if dbrows:
            fams = [GaugeMetricFamily(n, d, labels=["db"]) for n, d in (
                ("docdb_db_data_size_bytes", "Database data size"),
                ("docdb_db_storage_size_bytes", "Database storage size"),
                ("docdb_db_index_size_bytes", "Database index size"),
                ("docdb_db_objects", "Database object count"),
                ("docdb_db_collections", "Database collection count"))]
            for row in dbrows:
                for fam, v in zip(fams, row[1:]):
                    fam.add_metric([row[0]], v)
            yield from fams

    @staticmethod
    def _server_status(ss: dict):
        """Emit only the serverStatus sections the engine actually returns (DocumentDB subsets vary)."""
        v = _num(ss, "uptime")
        if v is not None:
            g = GaugeMetricFamily("docdb_uptime_seconds", "Server uptime")
            g.add_metric([], v)
            yield g

        conn = GaugeMetricFamily("docdb_connections", "Connections", labels=["state"])
        for state in ("current", "available"):
            conn.add_metric([state], _num(ss, "connections", state) or 0)
        yield conn
        v = _num(ss, "connections", "totalCreated")
        if v is not None:
            c = CounterMetricFamily("docdb_connections_created", "Connections created")
            c.add_metric([], v)
            yield c

        def counter(name, doc, label, section, keys):
            fam, found = CounterMetricFamily(name, doc, labels=[label]), False
            for k in keys:
                val = _num(ss, *section, k)
                if val is not None:
                    fam.add_metric([k], val)
                    found = True
            return fam if found else None

        def gauge(name, doc, label, section, keys, scale=1):
            fam, found = GaugeMetricFamily(name, doc, labels=[label]), False
            for k in keys:
                val = _num(ss, *section, k)
                if val is not None:
                    fam.add_metric([k], val * scale)
                    found = True
            return fam if found else None

        ops = CounterMetricFamily("docdb_opcounters", "Operation counters", labels=["type"])
        for t, val in ss.get("opcounters", {}).items():
            ops.add_metric([t], val)
        yield ops

        specs = (
            counter("docdb_network_bytes", "Network bytes", "direction", ("network",), ("bytesIn", "bytesOut")),
            counter("docdb_network_requests", "Requests received", "kind", ("network",), ("numRequests",)),
            gauge("docdb_memory_bytes", "Process memory", "type", ("mem",), ("resident", "virtual"), 1048576),
            counter("docdb_document_ops", "Document operations", "type", ("metrics", "document"),
                    ("inserted", "updated", "deleted", "returned")),
            gauge("docdb_cursors_open", "Open cursors", "type", ("metrics", "cursor", "open"),
                  ("total", "noTimeout", "pinned")),
            counter("docdb_cursors_timed_out", "Timed-out cursors", "kind", ("metrics", "cursor"), ("timedOut",)),
            gauge("docdb_global_lock_queue", "Operations queued on the global lock", "type",
                  ("globalLock", "currentQueue"), ("total", "readers", "writers")),
            gauge("docdb_global_lock_clients", "Active clients", "type", ("globalLock", "activeClients"),
                  ("total", "readers", "writers")),
            counter("docdb_asserts", "Assertions", "type", ("asserts",),
                    ("regular", "warning", "msg", "user", "rollovers")),
            counter("docdb_query_executor", "Query executor counters", "type", ("metrics", "queryExecutor"),
                    ("scanned", "scannedObjects")),
            counter("docdb_operation_events", "Operation events", "type", ("metrics", "operation"),
                    ("scanAndOrder", "writeConflicts")),
        )
        for fam in specs:
            if fam is not None:
                yield fam

        lat_us = CounterMetricFamily("docdb_op_latency_micros", "Cumulative op latency (us)", labels=["type"])
        lat_ops = CounterMetricFamily("docdb_op_latency_ops", "Ops counted for latency", labels=["type"])
        found = False
        for t in ("reads", "writes", "commands", "transactions"):
            lat, n = _num(ss, "opLatencies", t, "latency"), _num(ss, "opLatencies", t, "ops")
            if lat is not None and n is not None:
                lat_us.add_metric([t], lat)
                lat_ops.add_metric([t], n)
                found = True
        if found:
            yield from (lat_us, lat_ops)


def render(result: dict) -> bytes:
    reg = CollectorRegistry(auto_describe=False)
    reg.register(_ResultCollector(result))
    return generate_latest(reg)


class TargetPool:
    """Keeps one MongoClient per connection (re-created when the connection string changes)."""

    def __init__(self):
        self._lock = threading.Lock()
        self._targets: dict = {}
        self.status: dict = {}

    def scrape(self, name: str, uri: str, collstats: bool) -> dict:
        key = hashlib.sha256(uri.encode()).hexdigest()
        with self._lock:
            entry = self._targets.get(name)
            if entry is None or entry[0] != key:
                if entry:
                    entry[1].close()
                entry = (key, Target(uri))
                self._targets[name] = entry
        result = entry[1].scrape(collstats)
        self.status[name] = {"up": bool(result["up"]), "duration": round(result["duration"], 2),
                             "ts": time.time(), "error": result["error"], "commands": result["commands"]}
        return result

    def forget(self, name: str) -> None:
        with self._lock:
            entry = self._targets.pop(name, None)
        if entry:
            entry[1].close()
        self.status.pop(name, None)
