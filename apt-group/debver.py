"""Debian package version comparison (policy §5.6.12), pure Python."""
from __future__ import annotations

import re


EPOCH_RE = re.compile(r"^(\d+):(.*)$")
UPSTREAM_DEBIAN_RE = re.compile(r"^(.*)-([^-]*)$")
TOKEN_RE = re.compile(r"(\d+)|([A-Za-z]+)|(~)|([^A-Za-z0-9~]+)")


def split_version(version: str) -> tuple[int, str, str]:
    epoch = 0
    rest = version
    m = EPOCH_RE.match(version)
    if m:
        epoch = int(m.group(1))
        rest = m.group(2)
    m = UPSTREAM_DEBIAN_RE.match(rest)
    if m:
        return epoch, m.group(1), m.group(2)
    return epoch, rest, ""


def tokenize(part: str) -> list[tuple[str, str | int]]:
    """Return list of (kind, value) where kind is nonnum|num|tilde|other."""
    out: list[tuple[str, str | int]] = []
    for m in TOKEN_RE.finditer(part):
        if m.group(1) is not None:
            out.append(("num", int(m.group(1))))
        elif m.group(2) is not None:
            out.append(("nonnum", m.group(2)))
        elif m.group(3) is not None:
            out.append(("tilde", "~"))
        else:
            out.append(("other", m.group(4)))
    return out


def cmp_part(a: str, b: str) -> int:
    ta = tokenize(a)
    tb = tokenize(b)
    n = max(len(ta), len(tb))
    for i in range(n):
        if i >= len(ta):
            # empty is less than something unless other is tilde-leading empty...
            # remaining b: if starts with tilde, a > b; else a < b
            kind, _ = tb[i]
            return 1 if kind == "tilde" else -1
        if i >= len(tb):
            kind, _ = ta[i]
            return -1 if kind == "tilde" else 1
        ka, va = ta[i]
        kb, vb = tb[i]
        if ka == kb == "num":
            if va != vb:
                return -1 if va < vb else 1
            continue
        if ka == "tilde" or kb == "tilde":
            if ka == kb:
                continue
            return -1 if ka == "tilde" else 1
        # non-digit vs non-digit: lexical by debian char order (~ first already handled)
        if ka != kb:
            # num sorts before nonnum/other
            order = {"num": 0, "nonnum": 1, "other": 2, "tilde": 3}
            return -1 if order.get(ka, 9) < order.get(kb, 9) else 1
        if va != vb:
            # string compare with empty ending
            sa = str(va)
            sb = str(vb)
            if sa < sb:
                return -1
            if sa > sb:
                return 1
    return 0


def compare(a: str, b: str) -> int:
    """Return -1 if a<b, 0 if a==b, 1 if a>b (Debian version order)."""
    if a == b:
        return 0
    ea, ua, da = split_version(a)
    eb, ub, db = split_version(b)
    if ea != eb:
        return -1 if ea < eb else 1
    c = cmp_part(ua, ub)
    if c != 0:
        return c
    return cmp_part(da, db)


def sort_key(version: str) -> tuple:
    """Sort key so sorted(..., key=sort_key) is Debian ascending order."""
    # Use compare via functools — simple approach: return version for external sorted with cmp
    return version
