#!/usr/bin/env python3
"""Idempotent Nexspence blob stores + repositories from compact catalog.json.

Uses the Nexus-compatible REST API at /service/rest/v1/.
"""
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
ALPINE_KEY_PATH = os.environ.get(
    "NEXSPENCE_ALPINE_SIGNING_KEY",
    os.environ.get("NEXUS_ALPINE_SIGNING_KEY", "/init/alpine.key"),
)
# Formats Nexspence does not implement (skip quietly if still in catalog).
UNSUPPORTED_FORMATS = frozenset({
    "composer",
})


def log(msg: str) -> None:
    print(f"nexspence-ensure-repos: {msg}", flush=True)


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


class Api:
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
                    text = raw.decode(errors="replace")
                    # SPA fallback for unknown routes is HTML 200 — treat as missing.
                    if text.lstrip().startswith("<!DOCTYPE") or text.lstrip().startswith("<html"):
                        return 404, None
                    try:
                        return code, json.loads(text)
                    except json.JSONDecodeError:
                        return code, text
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
        # Nexspence serves GET by name only (typed GET falls through to the SPA).
        code, payload = self.request(
            "GET",
            f"/service/rest/v1/repositories/{name}",
        )
        if code != 200 or not isinstance(payload, dict):
            return False
        if payload.get("name") != name:
            return False
        if fmt and payload.get("format") not in (None, fmt):
            # docker group members may be docker format under another type.
            if not (fmt == "docker" and payload.get("format") == "docker"):
                if payload.get("format") != fmt:
                    return False
        if typ and payload.get("type") not in (None, typ, "hosted", "proxy", "group"):
            pass
        return True

    def repo_names(self) -> set[str]:
        code, rows = self.request("GET", "/service/rest/v1/repositories")
        if code != 200 or not isinstance(rows, list):
            return set()
        return {r["name"] for r in rows if isinstance(r, dict) and "name" in r}

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
        if fmt in UNSUPPORTED_FORMATS:
            log(f"skip unsupported hosted format: {fmt}")
            continue
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
        if fmt in UNSUPPORTED_FORMATS:
            log(f"skip unsupported proxy format: {fmt}")
            continue
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
        if fmt in UNSUPPORTED_FORMATS:
            log(f"skip unsupported group format: {fmt}")
            continue
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
    return {
        "name": entry["name"],
        "online": True,
        # Nexspence: per-repo anonymous (no global /security/anonymous).
        "allowAnonymous": True,
        "storage": {
            "blobStoreName": entry["blobStore"],
            "writePolicy": entry.get("writePolicy", "ALLOW"),
        },
    }


def proxy_payload(entry: dict[str, Any]) -> dict[str, Any]:
    # Nexspence accepts proxyConfig.remote_url (not Nexus proxy.remoteUrl).
    proxy_cfg: dict[str, Any] = {
        "remote_url": entry["remoteUrl"],
    }
    if entry.get("format") == "pypi" and "indexPath" in entry:
        # Best-effort; ignored if unsupported.
        proxy_cfg["index_path"] = entry["indexPath"]
    return {
        "name": entry["name"],
        "online": True,
        "allowAnonymous": True,
        "storage": {
            "blobStoreName": entry["blobStore"],
        },
        "proxyConfig": proxy_cfg,
    }


def group_payload(
    entry: dict[str, Any],
    members: list[str] | None = None,
) -> dict[str, Any]:
    member_names = list(members if members is not None else entry["members"])
    return {
        "name": entry["name"],
        "online": True,
        "allowAnonymous": True,
        "storage": {
            "blobStoreName": entry["blobStore"],
        },
        "formatConfig": {
            "member_names": member_names,
        },
    }


def ensure_blobstores(api: Api, names: list[str]) -> None:
    existing = api.blobstore_names()
    for name in names:
        if name in existing:
            log(f"blobstore exists {name}")
            continue
        code, payload = api.request(
            "POST",
            "/service/rest/v1/blobstores/local",
            {"name": name, "path": name},
        )
        if code in (200, 201, 204):
            log(f"blobstore created {name}")
            existing.add(name)
        else:
            raise RuntimeError(f"blobstore {name} HTTP {code}: {payload}")


def ensure_typed_repos(
    api: Api,
    typ: str,
    items: list[dict[str, Any]],
    payload_fn,
) -> list[str]:
    failed: list[str] = []
    for entry in items:
        name = entry["name"]
        fmt = entry["format"]
        body = payload_fn(entry)

        if api.exists_typed(fmt, typ, name):
            code, payload = api.request(
                "PUT",
                f"/service/rest/v1/repositories/{fmt}/{typ}/{name}",
                body,
            )
            if code in (200, 204):
                log(f"{typ} updated {name}")
            else:
                log(f"{typ} update skipped {name} HTTP {code}: {payload}")
            continue

        code, payload = api.request(
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


def ensure_hosted(api: Api, items: list[dict[str, Any]]) -> list[str]:
    return ensure_typed_repos(api, "hosted", items, hosted_payload)


def ensure_proxies(api: Api, items: list[dict[str, Any]]) -> list[str]:
    return ensure_typed_repos(api, "proxy", items, proxy_payload)


def available_members(
    api: Api,
    fmt: str,
    members: list[str],
) -> list[str]:
    known = api.repo_names()
    out: list[str] = []
    for name in members:
        if name in known:
            out.append(name)
            continue
        log(f"group member missing (skip for now): {name}")
    return out


def ensure_groups(api: Api, items: list[dict[str, Any]]) -> list[str]:
    failed: list[str] = []
    for entry in items:
        name = entry["name"]
        fmt = entry["format"]
        wanted = list(entry["members"])
        members = available_members(api, fmt, wanted)
        if not members:
            log(f"group {name} has no available members yet")
            failed.append(name)
            continue
        if members != wanted:
            missing = [m for m in wanted if m not in members]
            log(f"group {name} partial members; missing={missing}")

        body = group_payload(entry, members)
        if api.exists_typed(fmt, "group", name):
            code, payload = api.request(
                "PUT",
                f"/service/rest/v1/repositories/{fmt}/group/{name}",
                body,
            )
            if code in (200, 204):
                log(f"group updated {name}")
            else:
                log(f"group update skipped {name} HTTP {code}: {payload}")
            continue

        code, payload = api.request(
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
    catalog_path = env("NEXSPENCE_CATALOG", "/init/catalog.json")
    with open(catalog_path, encoding="utf-8") as fh:
        raw = json.load(fh)

    blobs, hosted, proxies, groups = expand_catalog(raw)

    api = Api(
        env("NEXSPENCE_URL", "http://127.0.0.1:8081"),
        env("NEXSPENCE_ADMIN_USER", "admin"),
        env("NEXSPENCE_ADMIN_PASSWORD"),
    )

    ensure_blobstores(api, blobs)

    if any(e["format"] == "alpine" for e in (*proxies, *groups)):
        alpine_key = load_alpine_key()
        for entry in (*proxies, *groups):
            if entry["format"] == "alpine":
                entry["alpineKey"] = alpine_key

    hosted_failed = ensure_hosted(api, hosted)
    proxy_failed = ensure_proxies(api, proxies)
    group_failed = ensure_groups(api, groups)

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
