"""Connection store.

KeyVaultStore : connection string = Key Vault secret value, settings = secret tags (production).
LocalFileStore: JSON file (local development only; connection strings are stored in clear text).
"""
import json
import os
import re
import threading
import time
from dataclasses import dataclass

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
ALLOWED_INTERVALS = ("5s", "10s", "15s", "30s", "1m", "2m", "5m")  # >5m makes Prometheus series go stale (5m lookback)
DEFAULT_INTERVAL = "1m"
KV_PREFIX = "docdb-"
APP_TAG = "docdb-monitor"
ALLOWED_HOST_SUFFIXES = tuple(
    s.strip().lower() for s in os.getenv("ALLOWED_HOST_SUFFIXES", "").split(",") if s.strip()
)


@dataclass
class Connection:
    name: str
    host: str = ""
    interval: str = DEFAULT_INTERVAL
    enabled: bool = True
    collstats: bool = True
    note: str = ""


def validate_uri(uri: str) -> str:
    """Return the host list (no credentials) or raise ValueError."""
    if not isinstance(uri, str) or len(uri) > 2000 or re.search(r"[\s\x00-\x1f]", uri):
        raise ValueError("Invalid connection string")
    if not (uri.startswith("mongodb://") or uri.startswith("mongodb+srv://")):
        raise ValueError("Connection string must start with mongodb:// or mongodb+srv://")
    rest = uri.split("://", 1)[1]
    authority = re.split(r"[/?]", rest, maxsplit=1)[0]
    hostpart = authority.rsplit("@", 1)[-1]
    hosts = [h for h in hostpart.split(",") if h]
    if not hosts:
        raise ValueError("Connection string has no host")
    if ALLOWED_HOST_SUFFIXES:
        for h in hosts:
            name = re.sub(r":\d+$", "", h).lower()
            if not name.endswith(ALLOWED_HOST_SUFFIXES):
                raise ValueError(f"Host not allowed: {name}")
    return hostpart[:200]


class Store:
    backend = ""

    def list(self) -> list:
        raise NotImplementedError

    def get(self, name: str):
        return next((c for c in self.list() if c.name == name), None)

    def get_uri(self, name: str) -> str:
        raise NotImplementedError

    def save(self, conn: Connection, uri=None) -> None:
        """uri=None keeps the existing connection string (settings-only update)."""
        raise NotImplementedError

    def delete(self, name: str) -> None:
        raise NotImplementedError


class LocalFileStore(Store):
    backend = "local-file"

    def __init__(self, path: str):
        self._path = path
        self._lock = threading.Lock()
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)

    def _load(self) -> dict:
        if not os.path.exists(self._path):
            return {}
        with open(self._path, encoding="utf-8") as f:
            return json.load(f)

    def _dump(self, data: dict) -> None:
        tmp = self._path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, self._path)

    def list(self) -> list:
        with self._lock:
            data = self._load()
        return [
            Connection(name=n, host=v.get("host", ""), interval=v.get("interval", DEFAULT_INTERVAL),
                       enabled=v.get("enabled", True), collstats=v.get("collstats", True), note=v.get("note", ""))
            for n, v in sorted(data.items())
        ]

    def get_uri(self, name: str) -> str:
        with self._lock:
            return self._load()[name]["uri"]

    def save(self, conn: Connection, uri=None) -> None:
        with self._lock:
            data = self._load()
            entry = data.get(conn.name, {})
            if uri is not None:
                entry["uri"] = uri
            elif "uri" not in entry:
                raise KeyError(conn.name)
            entry.update(host=conn.host, interval=conn.interval, enabled=conn.enabled,
                         collstats=conn.collstats, note=conn.note)
            data[conn.name] = entry
            self._dump(data)

    def delete(self, name: str) -> None:
        with self._lock:
            data = self._load()
            data.pop(name, None)
            self._dump(data)


class KeyVaultStore(Store):
    backend = "key-vault"
    LIST_TTL = 5.0      # seconds; /sd polls every ~30s, UI every ~15s
    URI_TTL = 300.0

    def __init__(self, vault_url: str):
        from azure.identity import DefaultAzureCredential
        from azure.keyvault.secrets import SecretClient

        cred = DefaultAzureCredential(managed_identity_client_id=os.getenv("AZURE_CLIENT_ID") or None)
        self._c = SecretClient(vault_url=vault_url, credential=cred)
        self._lock = threading.Lock()
        self._list_cache = (0.0, [])
        self._uri_cache = {}

    @staticmethod
    def _tags(c: Connection) -> dict:
        return {"app": APP_TAG, "host": c.host[:200], "interval": c.interval,
                "enabled": str(c.enabled).lower(), "collstats": str(c.collstats).lower(), "note": c.note[:200]}

    def list(self) -> list:
        with self._lock:
            ts, items = self._list_cache
            if time.time() - ts < self.LIST_TTL:
                return list(items)
        items = []
        for p in self._c.list_properties_of_secrets():
            t = p.tags or {}
            if p.name.startswith(KV_PREFIX) and t.get("app") == APP_TAG:
                items.append(Connection(
                    name=p.name[len(KV_PREFIX):], host=t.get("host", ""),
                    interval=t.get("interval", DEFAULT_INTERVAL), enabled=t.get("enabled", "true") == "true",
                    collstats=t.get("collstats", "true") == "true", note=t.get("note", "")))
        items.sort(key=lambda c: c.name)
        with self._lock:
            self._list_cache = (time.time(), items)
        return list(items)

    def get_uri(self, name: str) -> str:
        with self._lock:
            hit = self._uri_cache.get(name)
            if hit and time.time() - hit[1] < self.URI_TTL:
                return hit[0]
        value = self._c.get_secret(KV_PREFIX + name).value
        with self._lock:
            self._uri_cache[name] = (value, time.time())
        return value

    def _invalidate(self, name: str) -> None:
        with self._lock:
            self._list_cache = (0.0, [])
            self._uri_cache.pop(name, None)

    def save(self, conn: Connection, uri=None) -> None:
        from azure.core.exceptions import ResourceNotFoundError

        sname = KV_PREFIX + conn.name
        if uri is not None:
            try:  # re-creating a name that was deleted earlier (soft-delete)
                self._c.get_deleted_secret(sname)
                self._c.begin_recover_deleted_secret(sname).wait()
            except ResourceNotFoundError:
                pass
            self._c.set_secret(sname, uri, tags=self._tags(conn))
        else:
            self._c.update_secret_properties(sname, tags=self._tags(conn))
        self._invalidate(conn.name)

    def delete(self, name: str) -> None:
        self._c.begin_delete_secret(KV_PREFIX + name).wait()
        self._invalidate(name)


def create_store() -> Store:
    vault = os.getenv("KEY_VAULT_URL")
    if vault:
        return KeyVaultStore(vault)
    return LocalFileStore(os.getenv("DATA_FILE", os.path.join(os.path.dirname(__file__), "data", "connections.json")))
