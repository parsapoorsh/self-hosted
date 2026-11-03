#!/usr/bin/env python3
"""APT group: merge Nexus apt proxies into one suite-scoped archive.

Network-efficient defaults:
  - only query members matching the suite family (ubuntu/debian/kali)
  - only the components that family uses
  - cap how many members are contacted per suite
  - prefer Packages.xz only (fallback .gz once if nothing found)
  - no multi-suite prewarm
  - short connect timeouts so dead mirrors fail fast
"""
from __future__ import annotations

import asyncio
import gzip
import hashlib
import json
import logging
import lzma
import os
import re
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from aiohttp import ClientSession, ClientTimeout, TCPConnector, web

import debver

log = logging.getLogger("apt-group")

DEFAULT_ARCHES = ["amd64", "i386"]

UBUNTU_COMPONENTS = ["main", "restricted", "universe", "multiverse"]
DEBIAN_COMPONENTS = ["main", "contrib", "non-free", "non-free-firmware"]
KALI_COMPONENTS = ["main", "contrib", "non-free", "non-free-firmware"]

UBUNTU_CODENAMES = {
    "focal", "jammy", "noble", "oracular", "plucky", "questing",
    "bionic", "xenial",
}
DEBIAN_CODENAMES = {
    "bullseye", "bookworm", "trixie", "forky", "sid", "experimental",
}

DEFAULT_SUITES = [
    "jammy", "jammy-updates", "jammy-security", "jammy-backports",
    "noble", "noble-updates", "noble-security", "noble-backports",
    "bookworm", "bookworm-updates", "bookworm-security", "bookworm-backports",
    "trixie", "trixie-updates", "trixie-security", "trixie-backports",
    "forky", "forky-updates", "forky-security", "forky-backports",
    "sid",
    "kali-rolling", "kali-last-snapshot", "kali-experimental",
]


def env(name: str, default: str | None = None) -> str:
    val = os.environ.get(name, default)
    if val is None or val == "":
        raise SystemExit(f"missing env {name}")
    return val


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def md5_bytes(data: bytes) -> str:
    return hashlib.md5(data).hexdigest()  # noqa: S324 — Release file field


def decompress_packages(name: str, data: bytes) -> str:
    if name.endswith(".xz"):
        return lzma.decompress(data).decode("utf-8", errors="replace")
    if name.endswith(".gz"):
        return gzip.decompress(data).decode("utf-8", errors="replace")
    return data.decode("utf-8", errors="replace")


def parse_packages(text: str) -> list[dict[str, str]]:
    stanzas: list[dict[str, str]] = []
    cur: dict[str, str] = {}
    key: str | None = None
    for line in text.splitlines():
        if not line:
            if cur.get("Package"):
                stanzas.append(cur)
            cur = {}
            key = None
            continue
        if line[0] in (" ", "\t") and key is not None:
            cur[key] = cur[key] + "\n" + line
            continue
        if ":" not in line:
            continue
        k, _, v = line.partition(":")
        key = k.strip()
        cur[key] = v.strip()
    if cur.get("Package"):
        stanzas.append(cur)
    return stanzas


def stanza_text(fields: dict[str, str]) -> str:
    order = [
        "Package", "Version", "Architecture", "Maintainer", "Installed-Size",
        "Depends", "Pre-Depends", "Recommends", "Suggests", "Enhances",
        "Breaks", "Conflicts", "Replaces", "Provides", "Priority", "Section",
        "Filename", "Size", "MD5sum", "SHA1", "SHA256", "SHA512",
        "Description", "Description-md5", "Multi-Arch", "Homepage", "Tag",
    ]
    seen: set[str] = set()
    lines: list[str] = []
    for k in order:
        if k in fields:
            lines.append(f"{k}: {fields[k]}")
            seen.add(k)
    for k in sorted(fields):
        if k not in seen:
            lines.append(f"{k}: {fields[k]}")
    return "\n".join(lines) + "\n"


def suite_family(suite: str) -> str:
    """Map suite name to member family."""
    if suite.startswith("kali"):
        return "kali"
    base = suite.split("-", 1)[0]
    if base in UBUNTU_CODENAMES:
        return "ubuntu"
    if base in DEBIAN_CODENAMES:
        if "security" in suite:
            return "debian-security"
        if "backports" in suite:
            return "debian-backports"
        return "debian"
    return "debian"


def components_for_family(family: str) -> list[str]:
    if family == "ubuntu":
        return list(UBUNTU_COMPONENTS)
    if family == "kali":
        return list(KALI_COMPONENTS)
    return list(DEBIAN_COMPONENTS)


def member_matches_family(name: str, family: str) -> bool:
    if family == "ubuntu":
        return name.startswith("ubuntu-")
    if family == "kali":
        return name.startswith("kali-")
    if family == "debian-security":
        return name.startswith("debian-security-")
    if family == "debian-backports":
        return (
            name.startswith("debian-backports-")
            or (
                name.startswith("debian-")
                and not name.startswith("debian-security-")
            )
        )
    if family == "debian":
        return (
            name.startswith("debian-")
            and not name.startswith("debian-security-")
        )
    return False


@dataclass
class PoolSource:
    member: str
    sha256: str
    size: str


@dataclass
class SuiteArtifacts:
    suite: str
    built_at: float
    files: dict[str, bytes] = field(default_factory=dict)
    pool_map: dict[str, list[PoolSource]] = field(default_factory=dict)
    release_raw: bytes = b""
    inrelease: bytes = b""
    release_gpg: bytes = b""
    empty: bool = False


@dataclass
class Config:
    nexus_url: str
    members: list[str]
    architectures: list[str]
    suites: set[str]
    metadata_ttl: int
    empty_ttl: int
    fetch_timeout: float
    connect_timeout: float
    member_concurrency: int
    max_members: int
    keys_dir: Path
    cache_dir: Path
    origin: str
    label: str
    # optional overrides from catalog
    family_components: dict[str, list[str]] = field(default_factory=dict)
    family_members: dict[str, list[str]] = field(default_factory=dict)


class AptGroup:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self.session: ClientSession | None = None
        self.suite_cache: dict[str, SuiteArtifacts] = {}
        self.suite_locks: dict[str, asyncio.Lock] = {}
        self.gnupg_home: Path | None = None

    async def start(self) -> None:
        self.cfg.cache_dir.mkdir(parents=True, exist_ok=True)
        self.ensure_signing_key()
        timeout = ClientTimeout(
            total=self.cfg.fetch_timeout,
            connect=self.cfg.connect_timeout,
            sock_connect=self.cfg.connect_timeout,
            sock_read=self.cfg.fetch_timeout,
        )
        # Keep outbound fan-out small so Nexus/mirrors are not stampeded.
        connector = TCPConnector(
            limit=self.cfg.member_concurrency,
            limit_per_host=self.cfg.member_concurrency,
            ttl_dns_cache=300,
        )
        self.session = ClientSession(timeout=timeout, connector=connector)
        log.info(
            "started members=%d arches=%s suites=%d ttl=%ss "
            "max_members=%d concurrency=%d",
            len(self.cfg.members),
            self.cfg.architectures,
            len(self.cfg.suites),
            self.cfg.metadata_ttl,
            self.cfg.max_members,
            self.cfg.member_concurrency,
        )

    async def stop(self) -> None:
        if self.session is not None:
            await self.session.close()
            self.session = None

    def members_for_suite(self, suite: str) -> list[str]:
        """All family members in priority order (never truncated).

        max_members only caps successful fetches per component/arch slot,
        so slow/incomplete IR mirrors can still fall through to upstream.
        """
        family = suite_family(suite)
        override = self.cfg.family_members.get(family)
        if override:
            ordered = list(override)
        else:
            ordered = [
                m for m in self.cfg.members
                if member_matches_family(m, family)
            ]
            # Security/backports: try dedicated mirrors first, then main
            # debian archives (many hosts publish dists/<suite>-security).
            if family in ("debian-security", "debian-backports"):
                extra = [
                    m for m in self.cfg.members
                    if member_matches_family(m, "debian") and m not in ordered
                ]
                ordered = ordered + extra
        # Prefer *-upstream last among equals already handled by catalog order.
        return ordered

    def components_for_suite(self, suite: str) -> list[str]:
        family = suite_family(suite)
        if family in self.cfg.family_components:
            return list(self.cfg.family_components[family])
        # ubuntu-security still uses ubuntu components
        if family.startswith("debian"):
            return components_for_family("debian")
        return components_for_family(family)

    def ensure_signing_key(self) -> None:
        keys = self.cfg.keys_dir
        keys.mkdir(parents=True, exist_ok=True)
        sec = keys / "secring.gpg"
        pub = keys / "pubring.gpg"
        asc = keys / "apt-group.asc"
        home = keys / "gnupg"
        home.mkdir(mode=0o700, exist_ok=True)
        self.gnupg_home = home

        has_kbx = (home / "pubring.kbx").exists() or bool(list(home.glob("*.kbx")))
        if not has_kbx:
            if sec.exists() and pub.exists():
                self.gpg_run(["--import", str(sec)])
                self.gpg_run(["--import", str(pub)])
            else:
                log.info("generating OpenPGP signing key in %s", keys)
                batch = home / "gen.key"
                batch.write_text(
                    "Key-Type: RSA\n"
                    "Key-Length: 2048\n"
                    "Key-Usage: sign\n"
                    "Name-Real: Nexus APT Group\n"
                    "Name-Email: apt-group@localhost\n"
                    "Expire-Date: 0\n"
                    "%no-protection\n"
                    "%commit\n",
                    encoding="utf-8",
                )
                self.gpg_run(["--batch", "--generate-key", str(batch)])
                sec.write_bytes(self.gpg_out(["--export-secret-keys", "--armor"]))
                pub.write_bytes(self.gpg_out(["--export", "--armor"]))
                sec.chmod(0o644)
                pub.chmod(0o644)

        if not asc.exists():
            asc.write_bytes(self.gpg_out(["--export", "--armor"]))
            asc.chmod(0o644)

    def gpg_env(self) -> dict[str, str]:
        env_map = os.environ.copy()
        assert self.gnupg_home is not None
        env_map["GNUPGHOME"] = str(self.gnupg_home)
        return env_map

    def gpg_run(self, args: list[str]) -> None:
        cmd = ["gpg", "--batch", "--yes", "--pinentry-mode", "loopback", *args]
        subprocess.run(
            cmd,
            check=True,
            env=self.gpg_env(),
            capture_output=True,
        )

    def gpg_out(self, args: list[str]) -> bytes:
        cmd = ["gpg", "--batch", "--yes", "--pinentry-mode", "loopback", *args]
        proc = subprocess.run(
            cmd,
            check=True,
            env=self.gpg_env(),
            capture_output=True,
        )
        return proc.stdout

    def clearsign(self, data: bytes) -> bytes:
        with tempfile.NamedTemporaryFile(delete=False) as tmp:
            tmp.write(data)
            tmp_path = tmp.name
        try:
            out_path = tmp_path + ".asc"
            self.gpg_run(
                [
                    "--clearsign",
                    "--digest-algo",
                    "SHA256",
                    "-o",
                    out_path,
                    tmp_path,
                ]
            )
            return Path(out_path).read_bytes()
        finally:
            Path(tmp_path).unlink(missing_ok=True)
            Path(tmp_path + ".asc").unlink(missing_ok=True)

    def detach_sign(self, data: bytes) -> bytes:
        with tempfile.NamedTemporaryFile(delete=False) as tmp:
            tmp.write(data)
            tmp_path = tmp.name
        try:
            out_path = tmp_path + ".gpg"
            self.gpg_run(
                [
                    "--detach-sign",
                    "--armor",
                    "--digest-algo",
                    "SHA256",
                    "-o",
                    out_path,
                    tmp_path,
                ]
            )
            return Path(out_path).read_bytes()
        finally:
            Path(tmp_path).unlink(missing_ok=True)
            Path(tmp_path + ".gpg").unlink(missing_ok=True)

    def public_key_asc(self) -> bytes:
        path = self.cfg.keys_dir / "apt-group.asc"
        if path.exists():
            return path.read_bytes()
        return self.gpg_out(["--export", "--armor"])

    def member_base(self, name: str) -> str:
        return f"{self.cfg.nexus_url.rstrip('/')}/repository/{name}"

    async def fetch_bytes(self, url: str) -> tuple[int, bytes]:
        assert self.session is not None
        try:
            async with self.session.get(url) as resp:
                if resp.status != 200:
                    # drain small error bodies quickly
                    await resp.read()
                    return resp.status, b""
                body = await resp.read()
                return resp.status, body
        except Exception as exc:  # noqa: BLE001
            log.debug("fetch fail %s: %s", url, exc)
            return 0, b""

    async def fetch_packages_text(
        self,
        member: str,
        suite: str,
        component: str,
        arch: str,
        names: tuple[str, ...],
    ) -> str | None:
        base = (
            f"{self.member_base(member)}/dists/{suite}/"
            f"{component}/binary-{arch}"
        )
        for name in names:
            status, data = await self.fetch_bytes(f"{base}/{name}")
            if status == 200 and data:
                try:
                    return decompress_packages(name, data)
                except Exception as exc:  # noqa: BLE001
                    log.warning(
                        "decompress %s %s/%s/%s: %s",
                        member, suite, component, name, exc,
                    )
        return None

    def merge_stanzas(
        self,
        member: str,
        stanzas: list[dict[str, str]],
        by_key: dict[tuple[str, str, str], dict[str, str]],
        pool_map: dict[str, list[PoolSource]],
    ) -> None:
        for st in stanzas:
            pkg = st.get("Package", "")
            ver = st.get("Version", "")
            arch = st.get("Architecture", "")
            if not pkg or not ver or not arch:
                continue
            if arch not in ("all", *self.cfg.architectures):
                continue
            key = (pkg, ver, arch)
            sha = (st.get("SHA256") or "").lower()
            filename = st.get("Filename", "")
            size = st.get("Size", "")

            existing = by_key.get(key)
            if existing is None:
                by_key[key] = dict(st)
            else:
                ex_sha = (existing.get("SHA256") or "").lower()
                if sha and ex_sha and sha != ex_sha:
                    log.debug(
                        "sha mismatch %s %s %s; keep first member",
                        pkg, ver, arch,
                    )

            if filename and sha:
                sources = pool_map.setdefault(filename, [])
                if not any(s.member == member and s.sha256 == sha for s in sources):
                    sources.append(
                        PoolSource(member=member, sha256=sha, size=size)
                    )

    def order_stanzas(
        self,
        by_key: dict[tuple[str, str, str], dict[str, str]],
    ) -> list[dict[str, str]]:
        grouped: dict[tuple[str, str], list[dict[str, str]]] = {}
        for st in by_key.values():
            gkey = (st.get("Package", ""), st.get("Architecture", ""))
            grouped.setdefault(gkey, []).append(st)
        ordered: list[dict[str, str]] = []
        for gkey in sorted(grouped):
            vers = grouped[gkey]
            vers_sorted: list[dict[str, str]] = []
            for st in vers:
                inserted = False
                for i, other in enumerate(vers_sorted):
                    if debver.compare(
                        st.get("Version", ""),
                        other.get("Version", ""),
                    ) < 0:
                        vers_sorted.insert(i, st)
                        inserted = True
                        break
                if not inserted:
                    vers_sorted.append(st)
            ordered.extend(vers_sorted)
        return ordered

    async def build_suite(self, suite: str) -> SuiteArtifacts:
        members = self.members_for_suite(suite)
        components = self.components_for_suite(suite)
        family = suite_family(suite)
        log.info(
            "building suite %s family=%s members=%d components=%s",
            suite,
            family,
            len(members),
            components,
        )
        t0 = time.monotonic()
        if not members:
            log.warning("suite %s: no members for family %s", suite, family)
            return SuiteArtifacts(
                suite=suite, built_at=time.time(), empty=True,
            )

        by_comp_arch: dict[
            tuple[str, str],
            dict[tuple[str, str, str], dict[str, str]],
        ] = {}
        pool_map: dict[str, list[PoolSource]] = {}
        stats = {"ok": 0, "miss": 0}
        # One (component, arch) at a time; members in priority order.
        # Stops early once max_members successes hit for that slot.
        # Keeps RAM/network calm (universe Packages is tens of MB each).
        slot_sem = asyncio.Semaphore(max(1, min(2, self.cfg.member_concurrency)))

        async def fill_slot(component: str, arch: str) -> None:
            async with slot_sem:
                hits = 0
                # IR/primary first; after a few misses jump to *-upstream.
                primary = [m for m in members if not m.endswith("-upstream")]
                upstream = [m for m in members if m.endswith("-upstream")]
                phases = (primary, upstream) if upstream else (primary,)
                for phase in phases:
                    streak_miss = 0
                    for member in phase:
                        text = await self.fetch_packages_text(
                            member,
                            suite,
                            component,
                            arch,
                            ("Packages.xz", "Packages.gz"),
                        )
                        if not text:
                            stats["miss"] += 1
                            streak_miss += 1
                            # Don't burn every IR mirror on 404/timeout.
                            if phase is primary and streak_miss >= 3 and upstream:
                                break
                            continue
                        streak_miss = 0
                        stanzas = parse_packages(text)
                        del text
                        bucket = by_comp_arch.setdefault((component, arch), {})
                        self.merge_stanzas(member, stanzas, bucket, pool_map)
                        del stanzas
                        stats["ok"] += 1
                        hits += 1
                        if self.cfg.max_members > 0 and hits >= self.cfg.max_members:
                            break
                    if self.cfg.max_members > 0 and hits >= self.cfg.max_members:
                        break
                log.info(
                    "suite %s %s/%s hits=%d",
                    suite, component, arch, hits,
                )

        await asyncio.gather(*[
            fill_slot(c, a)
            for c in components
            for a in self.cfg.architectures
        ])

        files: dict[str, bytes] = {}
        # Always publish every configured component × arch so InRelease
        # Components: matches client sources.list (empty Packages if miss).
        for component in components:
            for arch in self.cfg.architectures:
                by_key = by_comp_arch.get((component, arch)) or {}
                ordered = self.order_stanzas(by_key) if by_key else []
                body = "\n".join(stanza_text(st) for st in ordered)
                if ordered:
                    body += "\n"
                raw = body.encode("utf-8")
                rel = f"{component}/binary-{arch}"
                files[f"{rel}/Packages"] = raw
                files[f"{rel}/Packages.gz"] = gzip.compress(raw)
                files[f"{rel}/Packages.xz"] = lzma.compress(raw)
                files[f"{rel}/Release"] = (
                    f"Archive: {suite}\n"
                    f"Component: {component}\n"
                    f"Origin: {self.cfg.origin}\n"
                    f"Label: {self.cfg.label}\n"
                    f"Architecture: {arch}\n"
                ).encode()

        # Empty suite = zero packages across all components
        total_pkgs = sum(
            1
            for (c, a), bucket in by_comp_arch.items()
            if bucket
        )
        if total_pkgs == 0:
            log.warning(
                "suite %s empty ok=%d miss=%d in %.1fs",
                suite, stats["ok"], stats["miss"], time.monotonic() - t0,
            )
            return SuiteArtifacts(
                suite=suite, built_at=time.time(), empty=True,
            )

        now = time.gmtime()
        date = time.strftime("%a, %d %b %Y %H:%M:%S UTC", now)
        arches = " ".join(self.cfg.architectures)
        # Full component list (not only ones that had packages)
        comps = list(components)
        lines = [
            f"Origin: {self.cfg.origin}",
            f"Label: {self.cfg.label}",
            f"Suite: {suite}",
            f"Codename: {suite}",
            f"Date: {date}",
            f"Architectures: {arches}",
            f"Components: {' '.join(comps)}",
            "Description: Merged Nexus apt-group archive",
            "Acquire-By-Hash: no",
        ]
        md5_lines: list[str] = []
        sha256_lines: list[str] = []
        for rel in sorted(files):
            data = files[rel]
            md5_lines.append(f" {md5_bytes(data)} {len(data):>16} {rel}")
            sha256_lines.append(f" {sha256_bytes(data)} {len(data):>16} {rel}")
        lines.append("MD5Sum:")
        lines.extend(md5_lines)
        lines.append("SHA256:")
        lines.extend(sha256_lines)
        release_raw = ("\n".join(lines) + "\n").encode("utf-8")
        files["Release"] = release_raw

        inrelease = self.clearsign(release_raw)
        release_gpg = self.detach_sign(release_raw)
        files["InRelease"] = inrelease
        files["Release.gpg"] = release_gpg

        art = SuiteArtifacts(
            suite=suite,
            built_at=time.time(),
            files=files,
            pool_map=pool_map,
            release_raw=release_raw,
            inrelease=inrelease,
            release_gpg=release_gpg,
            empty=False,
        )
        try:
            sdir = self.cfg.cache_dir / suite
            if sdir.exists():
                shutil.rmtree(sdir)
            sdir.mkdir(parents=True)
            for rel, data in files.items():
                path = sdir / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            (sdir / ".pool_map.json").write_text(
                json.dumps(
                    {
                        fn: [
                            {
                                "member": s.member,
                                "sha256": s.sha256,
                                "size": s.size,
                            }
                            for s in sources
                        ]
                        for fn, sources in pool_map.items()
                    }
                ),
                encoding="utf-8",
            )
        except OSError as exc:
            log.warning("disk cache write failed: %s", exc)

        log.info(
            "suite %s ready files=%d pool=%d ok=%d miss=%d in %.1fs",
            suite,
            len(files),
            len(pool_map),
            stats["ok"],
            stats["miss"],
            time.monotonic() - t0,
        )
        return art

    def suite_lock(self, suite: str) -> asyncio.Lock:
        lock = self.suite_locks.get(suite)
        if lock is None:
            lock = asyncio.Lock()
            self.suite_locks[suite] = lock
        return lock

    def cache_fresh(self, art: SuiteArtifacts) -> bool:
        age = time.time() - art.built_at
        if art.empty:
            return age < self.cfg.empty_ttl
        return age < self.cfg.metadata_ttl and bool(art.files)

    def load_disk_suite(self, suite: str) -> SuiteArtifacts | None:
        """Reload a still-fresh suite from disk after process restart."""
        sdir = self.cfg.cache_dir / suite
        inrelease_path = sdir / "InRelease"
        if not inrelease_path.is_file():
            return None
        built_at = inrelease_path.stat().st_mtime
        age = time.time() - built_at
        if age > self.cfg.metadata_ttl:
            return None
        files: dict[str, bytes] = {}
        try:
            for path in sdir.rglob("*"):
                if not path.is_file():
                    continue
                rel = path.relative_to(sdir).as_posix()
                if rel.startswith(".") or path.name.startswith("."):
                    continue
                files[rel] = path.read_bytes()
        except OSError as exc:
            log.warning("disk cache read %s: %s", suite, exc)
            return None
        if "InRelease" not in files or "Release" not in files:
            return None
        pool_map: dict[str, list[PoolSource]] = {}
        pool_path = sdir / ".pool_map.json"
        if pool_path.is_file():
            try:
                raw_map = json.loads(pool_path.read_text(encoding="utf-8"))
                for fn, sources in raw_map.items():
                    pool_map[fn] = [
                        PoolSource(
                            member=s["member"],
                            sha256=s.get("sha256", ""),
                            size=s.get("size", ""),
                        )
                        for s in sources
                    ]
            except (OSError, json.JSONDecodeError, KeyError, TypeError) as exc:
                log.warning("pool map load %s: %s", suite, exc)
        log.info("suite %s loaded from disk files=%d age=%.0fs", suite, len(files), age)
        return SuiteArtifacts(
            suite=suite,
            built_at=built_at,
            files=files,
            pool_map=pool_map,
            release_raw=files.get("Release", b""),
            inrelease=files.get("InRelease", b""),
            release_gpg=files.get("Release.gpg", b""),
            empty=False,
        )

    async def get_suite(self, suite: str) -> SuiteArtifacts | None:
        if suite not in self.cfg.suites:
            return None
        cached = self.suite_cache.get(suite)
        if cached and self.cache_fresh(cached):
            return cached
        async with self.suite_lock(suite):
            cached = self.suite_cache.get(suite)
            if cached and self.cache_fresh(cached):
                return cached
            disk = self.load_disk_suite(suite)
            if disk is not None and self.cache_fresh(disk):
                self.suite_cache[suite] = disk
                return disk
            art = await self.build_suite(suite)
            self.suite_cache[suite] = art
            return art

    async def proxy_pool(self, filename: str) -> web.StreamResponse | web.Response:
        sources: list[PoolSource] = []
        for art in self.suite_cache.values():
            if filename in art.pool_map:
                sources.extend(art.pool_map[filename])
        seen: set[str] = set()
        ordered: list[PoolSource] = []
        for s in sources:
            if s.member in seen:
                continue
            seen.add(s.member)
            ordered.append(s)
        # Fall back to family members of any cached suite is awkward;
        # try known sources only. Cold pool without metadata: try max_members
        # generic list is too broad — require prior index hit.
        if not ordered:
            return web.Response(
                status=404,
                text="unknown pool object (fetch dists metadata first)\n",
            )

        assert self.session is not None
        last_status = 404
        for src in ordered:
            url = f"{self.member_base(src.member)}/{filename}"
            try:
                resp = await self.session.get(url)
            except Exception as exc:  # noqa: BLE001
                log.debug("pool fetch %s: %s", url, exc)
                continue
            if resp.status != 200:
                last_status = resp.status
                resp.release()
                continue
            out = web.StreamResponse(
                status=200,
                headers={
                    "Content-Type": "application/vnd.debian.binary-package",
                    "Cache-Control": "public, max-age=3600",
                },
            )
            if src.size:
                out.headers["Content-Length"] = src.size
            elif resp.content_length is not None:
                out.headers["Content-Length"] = str(resp.content_length)
            return PoolStream(out, resp, src.sha256)

        return web.Response(
            status=last_status if last_status else 404,
            text="not found\n",
        )


class PoolStream:
    def __init__(
        self,
        out: web.StreamResponse,
        upstream: Any,
        expect_sha256: str,
    ) -> None:
        self.out = out
        self.upstream = upstream
        self.expect_sha256 = expect_sha256


def load_config() -> Config:
    catalog_path = Path(env("APT_GROUP_CATALOG", "/init/catalog.json"))
    with catalog_path.open(encoding="utf-8") as fh:
        raw = json.load(fh)

    apt_proxies = raw.get("proxies", {}).get("apt", {})
    if not isinstance(apt_proxies, dict) or not apt_proxies:
        raise SystemExit("catalog has no proxies.apt members")

    group = raw.get("aptGroup") or {}
    members = group.get("members")
    if isinstance(members, list) and members:
        member_names = [str(m) for m in members]
    else:
        member_names = list(apt_proxies.keys())

    suites = group.get("suites") or DEFAULT_SUITES
    arches = group.get("architectures") or DEFAULT_ARCHES

    family_components: dict[str, list[str]] = {}
    for fam, comps in (group.get("familyComponents") or {}).items():
        family_components[str(fam)] = [str(c) for c in comps]

    family_members: dict[str, list[str]] = {}
    for fam, mems in (group.get("familyMembers") or {}).items():
        family_members[str(fam)] = [str(m) for m in mems]

    return Config(
        nexus_url=env("APT_GROUP_NEXUS_URL", "http://nexus:8081"),
        members=member_names,
        architectures=[str(a) for a in arches],
        suites=set(str(s) for s in suites),
        metadata_ttl=int(
            group.get("metadataTtlSeconds") or env("APT_GROUP_TTL", "1800")
        ),
        empty_ttl=int(
            group.get("emptyTtlSeconds") or env("APT_GROUP_EMPTY_TTL", "120")
        ),
        fetch_timeout=float(
            group.get("memberFetchTimeoutSeconds")
            or env("APT_GROUP_FETCH_TIMEOUT", "120")
        ),
        connect_timeout=float(
            group.get("connectTimeoutSeconds")
            or env("APT_GROUP_CONNECT_TIMEOUT", "5")
        ),
        member_concurrency=int(
            group.get("memberConcurrency") or env("APT_GROUP_CONCURRENCY", "6")
        ),
        max_members=int(
            group.get("maxMembersPerSuite") or env("APT_GROUP_MAX_MEMBERS", "6")
        ),
        keys_dir=Path(env("APT_GROUP_KEYS_DIR", "/keys")),
        cache_dir=Path(env("APT_GROUP_CACHE_DIR", "/var/cache/apt-group")),
        origin=str(group.get("origin") or "nexus-apt-group"),
        label=str(group.get("label") or "Nexus APT Group"),
        family_components=family_components,
        family_members=family_members,
    )


def make_app(svc: AptGroup) -> web.Application:
    routes = web.RouteTableDef()

    @routes.get("/healthz")
    async def healthz(_: web.Request) -> web.Response:
        return web.Response(text="ok\n")

    @routes.get("/repository/apt/key.asc")
    @routes.get("/repository/apt/pubkey.gpg")
    async def pubkey(_: web.Request) -> web.Response:
        data = svc.public_key_asc()
        return web.Response(
            body=data,
            headers={
                "Content-Type": "application/pgp-keys",
                "Cache-Control": "public, max-age=3600",
            },
        )

    @routes.get("/repository/apt/{path:.+}")
    async def apt_path(request: web.Request) -> web.StreamResponse:
        path = request.match_info["path"]
        m = re.match(r"^dists/([^/]+)/(.*)$", path)
        if m:
            suite, rest = m.group(1), m.group(2)
            art = await svc.get_suite(suite)
            if art is None:
                return web.Response(status=404, text=f"unknown suite {suite}\n")
            if art.empty or not art.files:
                return web.Response(
                    status=503,
                    text=f"suite {suite} has no metadata from any member\n",
                )
            data = art.files.get(rest)
            if data is None:
                return web.Response(status=404, text="not found\n")
            ctype = "text/plain; charset=utf-8"
            if rest.endswith(".gz"):
                ctype = "application/gzip"
            elif rest.endswith(".xz"):
                ctype = "application/x-xz"
            return web.Response(
                body=data,
                headers={
                    "Content-Type": ctype,
                    "Cache-Control": (
                        f"public, max-age={max(60, svc.cfg.metadata_ttl // 2)}"
                    ),
                },
            )

        if path.startswith("pool/"):
            result = await svc.proxy_pool(path)
            if isinstance(result, PoolStream):
                await result.out.prepare(request)
                h = hashlib.sha256()
                try:
                    async for chunk in result.upstream.content.iter_chunked(1 << 16):
                        h.update(chunk)
                        await result.out.write(chunk)
                    await result.out.write_eof()
                finally:
                    result.upstream.close()
                got = h.hexdigest()
                if result.expect_sha256 and got != result.expect_sha256:
                    log.warning(
                        "pool sha mismatch path=%s expected=%s got=%s",
                        path,
                        result.expect_sha256,
                        got,
                    )
                return result.out
            return result

        return web.Response(status=404, text="not found\n")

    @routes.get("/repository/apt")
    @routes.get("/repository/apt/")
    async def apt_root(_: web.Request) -> web.Response:
        suites = ", ".join(sorted(svc.cfg.suites))
        body = (
            "Nexus APT group\n"
            f"Suites: {suites}\n"
            f"Architectures: {', '.join(svc.cfg.architectures)}\n"
            f"Max members/suite: {svc.cfg.max_members}\n"
            "Public key: /repository/apt/key.asc\n"
        )
        return web.Response(text=body)

    app = web.Application()
    app.add_routes(routes)
    return app


async def main() -> None:
    logging.basicConfig(
        level=os.environ.get("APT_GROUP_LOG", "INFO"),
        format="%(asctime)s apt-group %(levelname)s %(message)s",
    )
    cfg = load_config()
    svc = AptGroup(cfg)
    await svc.start()
    app = make_app(svc)
    listen = env("APT_GROUP_LISTEN", "0.0.0.0:8080")
    host, _, port_s = listen.rpartition(":")
    host = host or "0.0.0.0"
    port = int(port_s)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, host, port)
    await site.start()
    log.info("listening on %s:%s", host, port)
    try:
        while True:
            await asyncio.sleep(3600)
    finally:
        await svc.stop()
        await runner.cleanup()


if __name__ == "__main__":
    asyncio.run(main())
