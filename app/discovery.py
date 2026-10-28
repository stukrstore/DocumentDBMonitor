"""Discover Azure DocumentDB (Mongo vCore) clusters and their connection string templates via ARM.

Uses the app's managed identity. The ARM response never contains credentials: connection strings carry
`<user>:<password>` placeholders that the operator fills in from the UI.
"""
import json
import os
import re
import urllib.error
import urllib.request

API_VERSION = os.getenv("MONGOCLUSTER_API_VERSION", "2024-07-01")
ARM = "https://management.azure.com"
RG_RE = re.compile(r"^[A-Za-z0-9_.()\-]{1,90}$")
NAME_RE = re.compile(r"^[A-Za-z0-9\-]{3,40}$")

_cred = None


def _token() -> str:
    global _cred
    if _cred is None:
        from azure.identity import DefaultAzureCredential

        _cred = DefaultAzureCredential(managed_identity_client_id=os.getenv("AZURE_CLIENT_ID") or None)
    return _cred.get_token(f"{ARM}/.default").token


def _arm(method: str, path: str) -> dict:
    req = urllib.request.Request(
        f"{ARM}{path}", method=method, data=b"" if method == "POST" else None,
        headers={"Authorization": f"Bearer {_token()}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:  # noqa: S310 (fixed https ARM host)
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"ARM {exc.code}: {exc.read()[:300].decode('utf-8', 'replace')}") from None


def _sub() -> str:
    sub = os.getenv("AZURE_SUBSCRIPTION_ID", "")
    if not sub:
        raise RuntimeError("AZURE_SUBSCRIPTION_ID not configured")
    return sub


def list_clusters() -> list:
    data = _arm("GET", f"/subscriptions/{_sub()}/providers/Microsoft.DocumentDB/mongoClusters?api-version={API_VERSION}")
    out = []
    for c in data.get("value", []):
        p = c.get("properties", {})
        out.append({
            "name": c["name"],
            "resourceGroup": c["id"].split("/")[4],
            "location": c.get("location"),
            "state": p.get("clusterStatus") or p.get("provisioningState"),
            "publicNetworkAccess": p.get("publicNetworkAccess"),
            "privateEndpoint": bool(p.get("privateEndpointConnections")),
        })
    return sorted(out, key=lambda x: (x["resourceGroup"], x["name"]))


def connection_strings(resource_group: str, name: str) -> list:
    if not RG_RE.match(resource_group) or not NAME_RE.match(name):
        raise ValueError("invalid resource group or cluster name")
    path = (f"/subscriptions/{_sub()}/resourceGroups/{resource_group}/providers/Microsoft.DocumentDB/"
            f"mongoClusters/{name}/listConnectionStrings?api-version={API_VERSION}")
    data = _arm("POST", path)
    return [{"name": s.get("name", ""), "description": s.get("description", ""), "uri": s.get("connectionString", "")}
            for s in data.get("connectionStrings", [])]
