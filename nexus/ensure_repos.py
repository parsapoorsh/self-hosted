#!/usr/bin/env python3
"""Idempotent Nexus blob stores + repositories from catalog.json."""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from base64 import b64encode
from typing import Any


def log(msg: str) -> None:
    print(f"nexus-ensure-repos: {msg}", flush=True)


def env(name: str, default: str | None = None) -> str:
    val = os.environ.get(name, default)
    if val is None or val == "":
        raise SystemExit(f"missing env {name}")
    return val


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
    ) -> tuple[int, Any]:
        data = None
        if body is not None:
            data = json.dumps(body).encode()
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
            return exc.code, payload

    def exists_typed(self, fmt: str, typ: str, name: str) -> bool:
        """True only when the typed REST resource responds (ignores list ghosts)."""
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


def proxy_payload(entry: dict[str, Any]) -> dict[str, Any]:
    fmt = entry["format"]
    body: dict[str, Any] = {
        "name": entry["name"],
        "online": True,
        "storage": {
            "blobStoreName": entry["blobStore"],
            "strictContentTypeValidation": entry.get(
                "strictContentTypeValidation",
                True,
            ),
        },
        "proxy": {
            "remoteUrl": entry["remoteUrl"],
            "contentMaxAge": entry.get("contentMaxAge", 1440),
            "metadataMaxAge": entry.get("metadataMaxAge", 1440),
        },
        "negativeCache": {
            "enabled": True,
            "timeToLive": entry.get("negativeCacheTtl", 1440),
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
        body["storage"]["writePolicy"] = entry.get("writePolicy", "ALLOW")
        body["docker"] = entry.get(
            "docker",
            {"v1Enabled": False, "forceBasicAuth": True},
        )
        body["dockerProxy"] = entry.get(
            "dockerProxy",
            {"indexType": "REGISTRY", "cacheForeignLayers": False},
        )
    if fmt == "nuget":
        body["nugetProxy"] = entry.get(
            "nugetProxy",
            {"queryCacheItemMaxAge": 3600, "nugetVersion": "V3"},
        )
    if fmt == "raw":
        body["raw"] = entry.get("raw", {"contentDisposition": "INLINE"})
    if fmt == "pypi" and entry.get("pypi"):
        body["pypi"] = entry["pypi"]
    if fmt == "npm" and entry.get("npm"):
        body["npm"] = entry["npm"]
    if fmt == "cargo" and entry.get("cargo"):
        body["cargo"] = entry["cargo"]
    return body


def group_payload(
    entry: dict[str, Any],
    members: list[str] | None = None,
) -> dict[str, Any]:
    fmt = entry["format"]
    body: dict[str, Any] = {
        "name": entry["name"],
        "online": True,
        "storage": {
            "blobStoreName": entry["blobStore"],
            "strictContentTypeValidation": entry.get(
                "strictContentTypeValidation",
                True,
            ),
        },
        "group": {
            "memberNames": list(members if members is not None else entry["members"]),
        },
    }
    if fmt == "docker":
        body["docker"] = entry.get(
            "docker",
            {"v1Enabled": True, "forceBasicAuth": False},
        )
    if fmt == "raw":
        body["raw"] = entry.get("raw", {"contentDisposition": "INLINE"})
    if fmt == "cargo" and entry.get("cargo"):
        body["cargo"] = entry["cargo"]
    return body


def ensure_blobstores(nx: Nexus, items: list[dict[str, Any]]) -> None:
    existing = nx.blobstore_names()
    for item in items:
        name = item["name"]
        if name in existing:
            log(f"blobstore exists {name}")
            continue
        path = item.get("path", name)
        code, payload = nx.request(
            "POST",
            "/service/rest/v1/blobstores/file",
            {"name": name, "path": path},
        )
        if code in (200, 201, 204):
            log(f"blobstore created {name}")
            existing.add(name)
        else:
            raise RuntimeError(f"blobstore {name} HTTP {code}: {payload}")


def create_proxy(nx: Nexus, entry: dict[str, Any]) -> bool:
    name = entry["name"]
    fmt = entry["format"]
    body = proxy_payload(entry)
    code, payload = nx.request(
        "POST",
        f"/service/rest/v1/repositories/{fmt}/proxy",
        body,
    )
    if code in (200, 201):
        log(f"proxy created {name}")
        return True
    log(f"proxy create failed {name} HTTP {code}: {payload}")
    return False


def ensure_proxies(nx: Nexus, items: list[dict[str, Any]]) -> list[str]:
    """Ensure proxies. Returns names that failed (for retry/logging)."""
    failed: list[str] = []
    for entry in items:
        name = entry["name"]
        fmt = entry["format"]
        body = proxy_payload(entry)

        if nx.exists_typed(fmt, "proxy", name):
            code, payload = nx.request(
                "PUT",
                f"/service/rest/v1/repositories/{fmt}/proxy/{name}",
                body,
            )
            if code in (200, 204):
                log(f"proxy updated {name}")
                continue
            # Repo already present; startup/state races are non-fatal.
            log(f"proxy update skipped {name} HTTP {code}: {payload}")
            continue

        # Not present via typed API — create (covers fresh boot and cleaned ghosts).
        if not create_proxy(nx, entry):
            failed.append(name)
    return failed


def available_members(
    nx: Nexus,
    fmt: str,
    members: list[str],
) -> list[str]:
    """Keep catalog order; only members that exist (group members may be group or proxy)."""
    out: list[str] = []
    for name in members:
        # Docker groups can nest the "docker" group; check proxy then group.
        if nx.exists_typed(fmt, "proxy", name):
            out.append(name)
            continue
        if nx.exists_typed(fmt, "group", name):
            out.append(name)
            continue
        # nested docker group used by ghcr/k8s/quay
        if nx.exists_typed("docker", "group", name):
            out.append(name)
            continue
        log(f"group member missing (skip for now): {name}")
    return out


def ensure_groups(
    nx: Nexus,
    items: list[dict[str, Any]],
) -> list[str]:
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
                # Group already present; state races during boot are non-fatal.
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
    catalog_path = env(
        "NEXUS_CATALOG",
        "/init/catalog.json",
    )
    with open(catalog_path, encoding="utf-8") as fh:
        catalog = json.load(fh)

    nx = Nexus(
        env("NEXUS_URL", "http://127.0.0.1:8081"),
        env("NEXUS_ADMIN_USER", "admin"),
        env("NEXUS_ADMIN_PASSWORD"),
    )

    ensure_blobstores(nx, catalog.get("blobStores", []))
    proxies = catalog.get("proxies", [])
    proxy_failed = ensure_proxies(nx, proxies)
    group_failed = ensure_groups(nx, catalog.get("groups", []))

    log(
        "done "
        f"blobs={len(catalog.get('blobStores', []))} "
        f"proxies={len(proxies)} "
        f"groups={len(catalog.get('groups', []))} "
        f"proxy_failed={proxy_failed} "
        f"group_failed={group_failed}"
    )
    # Soft-fail unreachable remotes (DNS) and empty groups so bootstrap can
    # finish; entrypoint retries the whole bootstrap on the next loop if needed.
    # Fresh boots still create everything that is reachable.
    if group_failed and not any(
        nx.exists_typed(g["format"], "group", g["name"])
        for g in catalog.get("groups", [])
    ):
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 — surface to bootstrap retry loop
        log(f"error: {exc}")
        sys.exit(1)
