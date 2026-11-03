#!/usr/bin/env python3
"""Idempotent Nexus blob stores + repositories from compact catalog.json."""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from base64 import b64encode
from typing import Any


# Shared defaults — not repeated in catalog.json
CACHE_MIN = 1440
DOCKER_PROXY = {
    "v1Enabled": True,
    "forceBasicAuth": False,
}
DOCKER_GROUP = {
    "v1Enabled": True,
    "forceBasicAuth": False,
}
DOCKER_PROXY_INDEX = {
    "indexType": "REGISTRY",
    "cacheForeignLayers": False,
}
# Host file cert/alpine.key, mounted at /init/alpine.key by compose.
ALPINE_KEY_PATH = os.environ.get("NEXUS_ALPINE_SIGNING_KEY", "/init/alpine.key")


def log(msg: str) -> None:
    print(f"nexus-ensure-repos: {msg}", flush=True)


def env(name: str, default: str | None = None) -> str:
    val = os.environ.get(name, default)
    if val is None or val == "":
        raise SystemExit(f"missing env {name}")
    return val


def load_alpine_key() -> str:
    """RSA PKCS#8 PEM from compose-generated cert/alpine.key."""
    with open(ALPINE_KEY_PATH, encoding="utf-8") as fh:
        key = fh.read().strip()
    if "PRIVATE KEY" not in key:
        raise RuntimeError(f"invalid alpine signing key: {ALPINE_KEY_PATH}")
    return key + "\n"


class Nexus:
    def __init__(self, base: str, user: str, password: str) -> None:
        self.base = base.rstrip("/")
        token = b64encode(f"{user}:{password}".encode()).decode()
        self.headers = {
            "Authorization": f"Basic {token}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        }

    def request(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
        retries: int = 12,
    ) -> tuple[int, Any]:
        data = None
        if body is not None:
            data = json.dumps(body).encode()

        last_code = 0
        last_payload: Any = None
        for attempt in range(1, retries + 1):
            req = urllib.request.Request(
                f"{self.base}{path}",
                data=data,
                headers=self.headers,
                method=method,
            )
            try:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    raw = resp.read()
                    code = resp.getcode()
                    if not raw:
                        return code, None
                    return code, json.loads(raw.decode())
            except urllib.error.HTTPError as exc:
                raw = exc.read()
                try:
                    payload = json.loads(raw.decode()) if raw else None
                except json.JSONDecodeError:
                    payload = raw.decode(errors="replace") if raw else None
                last_code, last_payload = exc.code, payload
                if exc.code == 429 and attempt < retries:
                    log(f"HTTP 429 on {method} {path} (try {attempt}/{retries})")
                    time.sleep(3)
                    continue
                return exc.code, payload
        return last_code, last_payload

    def exists_typed(self, fmt: str, typ: str, name: str) -> bool:
        code, _ = self.request(
            "GET",
            f"/service/rest/v1/repositories/{fmt}/{typ}/{name}",
        )
        return code == 200

    def blobstore_names(self) -> set[str]:
        code, rows = self.request("GET", "/service/rest/v1/blobstores")
        if code != 200 or not isinstance(rows, list):
            raise RuntimeError(f"list blobstores HTTP {code}: {rows}")
        return {b["name"] for b in rows}


def expand_catalog(raw: dict[str, Any]) -> tuple[
    list[str],
    list[dict[str, Any]],
    list[dict[str, Any]],
    list[dict[str, Any]],
]:
    """Turn compact catalog into flat hosted/proxy/group entries."""
    blobs = list(raw.get("blobStores") or [])

    hosted: list[dict[str, Any]] = []
    for fmt, items in (raw.get("hosted") or {}).items():
        if isinstance(items, list):
            specs = {name: {} for name in items}
        else:
            specs = items
        for name, spec in specs.items():
            extra = spec if isinstance(spec, dict) else {}
            hosted.append({
                "name": name,
                "format": fmt,
                "blobStore": extra.get("blob", fmt),
                "writePolicy": extra.get("writePolicy", "ALLOW"),
            })

    proxies: list[dict[str, Any]] = []
    for fmt, items in (raw.get("proxies") or {}).items():
        for name, spec in items.items():
            if isinstance(spec, str):
                remote, extra = spec, {}
            else:
                remote = spec["remote"]
                extra = {k: v for k, v in spec.items() if k != "remote"}
            entry: dict[str, Any] = {
                "name": name,
                "format": fmt,
                "blobStore": extra.get("blob", fmt),
                "remoteUrl": remote,
            }
            if fmt == "docker":
                entry["indexType"] = extra.get("index", "REGISTRY")
            # PyPI simple-index path. Default /simple (pypi.org). Empty string for
            # indexes that ARE the simple root (download.pytorch.org/whl).
            if fmt == "pypi" and "indexPath" in extra:
                entry["indexPath"] = extra["indexPath"]
            proxies.append(entry)

    groups: list[dict[str, Any]] = []
    for fmt, items in (raw.get("groups") or {}).items():
        for name, spec in items.items():
            if isinstance(spec, list):
                members, extra = spec, {}
            else:
                members = list(spec["members"])
                extra = {k: v for k, v in spec.items() if k != "members"}
            groups.append({
                "name": name,
                "format": fmt,
                "blobStore": extra.get("blob", fmt),
                "members": members,
            })

    return blobs, hosted, proxies, groups


def hosted_payload(entry: dict[str, Any]) -> dict[str, Any]:
    fmt = entry["format"]
    strict = fmt != "raw"
    body: dict[str, Any] = {
        "name": entry["name"],
        "online": True,
        "storage": {
            "blobStoreName": entry["blobStore"],
            "strictContentTypeValidation": strict,
            "writePolicy": entry.get("writePolicy", "ALLOW"),
        },
        "component": {
            "proprietaryComponents": False,
        },
    }
    if fmt == "docker":
        body["docker"] = dict(DOCKER_PROXY)
    if fmt == "raw":
        body["raw"] = {"contentDisposition": "INLINE"}
    if fmt == "cargo":
        body["cargo"] = {"requireAuthentication": False}
    return body


def proxy_payload(entry: dict[str, Any]) -> dict[str, Any]:
    fmt = entry["format"]
    strict = fmt != "raw"
    body: dict[str, Any] = {
        "name": entry["name"],
        "online": True,
        "storage": {
            "blobStoreName": entry["blobStore"],
            "strictContentTypeValidation": strict,
        },
        "proxy": {
            "remoteUrl": entry["remoteUrl"],
            "contentMaxAge": CACHE_MIN,
            "metadataMaxAge": CACHE_MIN,
        },
        "negativeCache": {
            "enabled": True,
            "timeToLive": CACHE_MIN,
        },
        "httpClient": {
            "blocked": False,
            "autoBlock": True,
            "connection": {
                "enableCircularRedirects": False,
                "enableCookies": False,
                "useTrustStore": False,
            },
        },
    }
    if fmt == "docker":
        body["storage"]["writePolicy"] = "ALLOW"
        body["docker"] = dict(DOCKER_PROXY)
        body["dockerProxy"] = {
            **DOCKER_PROXY_INDEX,
            "indexType": entry.get("indexType", "REGISTRY"),
        }
    if fmt == "nuget":
        body["nugetProxy"] = {
            "queryCacheItemMaxAge": 3600,
            "nugetVersion": "V3",
        }
    if fmt == "raw":
        body["raw"] = {"contentDisposition": "INLINE"}
    # Do not set pypi.removeQuarantined — it requires IQ Firewall Server.
    # Nexus REST maps "suffix" -> internal pypi.indexPath (default /simple).
    if fmt == "pypi" and "indexPath" in entry:
        body["pypi"] = {
            "suffix": entry["indexPath"],
            "removeQuarantinedVersions": False,
        }
    if fmt == "cargo":
        body["cargo"] = {"requireAuthentication": False}
    if fmt == "alpine":
        body["alpineSigning"] = {"keypair": entry["alpineKey"]}
    return body


def group_payload(
    entry: dict[str, Any],
    members: list[str] | None = None,
) -> dict[str, Any]:
    fmt = entry["format"]
    strict = fmt != "raw"
    body: dict[str, Any] = {
        "name": entry["name"],
        "online": True,
        "storage": {
            "blobStoreName": entry["blobStore"],
            "strictContentTypeValidation": strict,
        },
        "group": {
            "memberNames": list(
                members if members is not None else entry["members"]
            ),
        },
    }
    if fmt == "docker":
        body["docker"] = dict(DOCKER_GROUP)
    if fmt == "raw":
        body["raw"] = {"contentDisposition": "INLINE"}
    if fmt == "cargo":
        body["cargo"] = {"requireAuthentication": False}
    if fmt == "alpine":
        body["alpineSigning"] = {"keypair": entry["alpineKey"]}
    return body


def ensure_eula(nx: Nexus) -> None:
    """Accept Community Edition EULA (required before many REST calls)."""
    code, cur = nx.request("GET", "/service/rest/v1/system/eula")
    if code != 200 or not isinstance(cur, dict):
        log(f"eula get failed HTTP {code}: {cur}")
        return
    if cur.get("accepted") is True:
        log("EULA already accepted")
        return
    body = dict(cur)
    body["accepted"] = True
    code, payload = nx.request("POST", "/service/rest/v1/system/eula", body)
    if code in (200, 204):
        log("EULA accepted")
    else:
        log(f"EULA accept failed HTTP {code}: {payload}")


def ensure_anonymous(nx: Nexus) -> None:
    """Allow unauthenticated pulls (nx-anonymous role)."""
    code, cur = nx.request("GET", "/service/rest/v1/security/anonymous")
    if code != 200 or not isinstance(cur, dict):
        log(f"anonymous get failed HTTP {code}: {cur}")
        return
    body = {
        "enabled": True,
        "userId": cur.get("userId") or "anonymous",
        "realmName": cur.get("realmName") or "NexusAuthorizingRealm",
    }
    if cur.get("enabled") is True:
        log("anonymous access already enabled")
        return
    code, payload = nx.request("PUT", "/service/rest/v1/security/anonymous", body)
    if code in (200, 204):
        log("anonymous access enabled")
    else:
        log(f"anonymous enable failed HTTP {code}: {payload}")


def ensure_blobstores(nx: Nexus, names: list[str]) -> None:
    existing = nx.blobstore_names()
    for name in names:
        if name in existing:
            log(f"blobstore exists {name}")
            continue
        code, payload = nx.request(
            "POST",
            "/service/rest/v1/blobstores/file",
            {"name": name, "path": name},
        )
        if code in (200, 201, 204):
            log(f"blobstore created {name}")
            existing.add(name)
        else:
            raise RuntimeError(f"blobstore {name} HTTP {code}: {payload}")


def ensure_typed_repos(
    nx: Nexus,
    typ: str,
    items: list[dict[str, Any]],
    payload_fn,
) -> list[str]:
    failed: list[str] = []
    for entry in items:
        name = entry["name"]
        fmt = entry["format"]
        body = payload_fn(entry)

        if nx.exists_typed(fmt, typ, name):
            code, payload = nx.request(
                "PUT",
                f"/service/rest/v1/repositories/{fmt}/{typ}/{name}",
                body,
            )
            if code in (200, 204):
                log(f"{typ} updated {name}")
            else:
                log(f"{typ} update skipped {name} HTTP {code}: {payload}")
            continue

        code, payload = nx.request(
            "POST",
            f"/service/rest/v1/repositories/{fmt}/{typ}",
            body,
        )
        if code in (200, 201):
            log(f"{typ} created {name}")
        else:
            log(f"{typ} create failed {name} HTTP {code}: {payload}")
            failed.append(name)
    return failed


def ensure_hosted(nx: Nexus, items: list[dict[str, Any]]) -> list[str]:
    return ensure_typed_repos(nx, "hosted", items, hosted_payload)


def ensure_proxies(nx: Nexus, items: list[dict[str, Any]]) -> list[str]:
    return ensure_typed_repos(nx, "proxy", items, proxy_payload)


def available_members(
    nx: Nexus,
    fmt: str,
    members: list[str],
) -> list[str]:
    out: list[str] = []
    for name in members:
        if nx.exists_typed(fmt, "hosted", name):
            out.append(name)
            continue
        if nx.exists_typed(fmt, "proxy", name):
            out.append(name)
            continue
        if nx.exists_typed(fmt, "group", name):
            out.append(name)
            continue
        if nx.exists_typed("docker", "group", name):
            out.append(name)
            continue
        log(f"group member missing (skip for now): {name}")
    return out


def run_groovy(nx: Nexus, name: str, content: str) -> str:
    """Create, run, delete a temporary Groovy script. Returns result text."""
    nx.request("DELETE", f"/service/rest/v1/script/{name}")
    code, payload = nx.request(
        "POST",
        "/service/rest/v1/script",
        {"name": name, "type": "groovy", "content": content},
    )
    if code not in (200, 201, 204):
        raise RuntimeError(f"script create HTTP {code}: {payload}")

    req = urllib.request.Request(
        f"{nx.base}/service/rest/v1/script/{name}/run",
        data=b"",
        method="POST",
        headers={
            **nx.headers,
            "Content-Type": "text/plain",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            raw = resp.read().decode()
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode(errors="replace")
        nx.request("DELETE", f"/service/rest/v1/script/{name}")
        raise RuntimeError(f"script run HTTP {exc.code}: {raw}") from exc
    nx.request("DELETE", f"/service/rest/v1/script/{name}")
    try:
        data = json.loads(raw)
        return str(data.get("result", raw))
    except json.JSONDecodeError:
        return raw


def apply_pypi_index_paths(nx: Nexus, proxies: list[dict[str, Any]]) -> None:
    """Force pypi.indexPath via Groovy (REST empty suffix is ignored by Nexus)."""
    special = [
        (e["name"], e["indexPath"])
        for e in proxies
        if e.get("format") == "pypi" and "indexPath" in e
    ]
    if not special:
        return
    pairs = ", ".join(
        f'"{name}": "{path}"'
        for name, path in special
    )
    groovy = f"""
import org.sonatype.nexus.repository.manager.RepositoryManager
def rm = container.lookup(RepositoryManager.class.name)
def wanted = [{pairs}] as Map
def out = []
wanted.each {{ name, indexPath ->
  def repo = rm.get(name)
  if (repo == null) {{
    out << (name + ":missing")
    return
  }}
  def cfg = repo.getConfiguration().copy()
  def pypi = cfg.getAttributes().computeIfAbsent("pypi", {{ k -> new HashMap() }})
  pypi.put("indexPath", indexPath)
  rm.update(cfg)
  out << (name + ":indexPath=" + indexPath)
}}
return out.join(",")
"""
    result = run_groovy(nx, "self-hosted-pypi-indexpath", groovy)
    log(f"pypi indexPath: {result}")


def ensure_groups(nx: Nexus, items: list[dict[str, Any]]) -> list[str]:
    failed: list[str] = []
    for entry in items:
        name = entry["name"]
        fmt = entry["format"]
        wanted = list(entry["members"])
        members = available_members(nx, fmt, wanted)
        if not members:
            log(f"group {name} has no available members yet")
            failed.append(name)
            continue
        if members != wanted:
            missing = [m for m in wanted if m not in members]
            log(f"group {name} partial members; missing={missing}")

        body = group_payload(entry, members)
        if nx.exists_typed(fmt, "group", name):
            code, payload = nx.request(
                "PUT",
                f"/service/rest/v1/repositories/{fmt}/group/{name}",
                body,
            )
            if code in (200, 204):
                log(f"group updated {name}")
            else:
                log(f"group update skipped {name} HTTP {code}: {payload}")
            continue

        code, payload = nx.request(
            "POST",
            f"/service/rest/v1/repositories/{fmt}/group",
            body,
        )
        if code in (200, 201):
            log(f"group created {name}")
        else:
            log(f"group create failed {name} HTTP {code}: {payload}")
            failed.append(name)
    return failed


def main() -> int:
    catalog_path = env("NEXUS_CATALOG", "/init/catalog.json")
    with open(catalog_path, encoding="utf-8") as fh:
        raw = json.load(fh)

    blobs, hosted, proxies, groups = expand_catalog(raw)

    nx = Nexus(
        env("NEXUS_URL", "http://127.0.0.1:8081"),
        env("NEXUS_ADMIN_USER", "admin"),
        env("NEXUS_ADMIN_PASSWORD"),
    )

    ensure_eula(nx)
    ensure_anonymous(nx)
    ensure_blobstores(nx, blobs)

    alpine_key = None
    if any(e["format"] == "alpine" for e in (*proxies, *groups)):
        alpine_key = load_alpine_key()
        for entry in (*proxies, *groups):
            if entry["format"] == "alpine":
                entry["alpineKey"] = alpine_key

    hosted_failed = ensure_hosted(nx, hosted)
    proxy_failed = ensure_proxies(nx, proxies)
    apply_pypi_index_paths(nx, proxies)
    group_failed = ensure_groups(nx, groups)

    log(
        "done "
        f"blobs={len(blobs)} "
        f"hosted={len(hosted)} "
        f"proxies={len(proxies)} "
        f"groups={len(groups)} "
        f"hosted_failed={hosted_failed} "
        f"proxy_failed={proxy_failed} "
        f"group_failed={group_failed}"
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001
        log(f"error: {exc}")
        sys.exit(1)
