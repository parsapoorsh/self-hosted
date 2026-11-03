---
title: APT Mirror
---

# APT via Nexus (merged group)

One base URL for Ubuntu, Debian, and Kali. The **suite** on the `deb` line chooses the release (`jammy`, `bookworm`, `kali-rolling`, …). Indexes are merged from several Nexus apt proxies, re-signed with a local group key, and served by the **apt-group** sidecar.

Individual proxies still exist under `/repository/<name>/` if you need a single mirror. Most clients should use the group.

---

## Base URL

```bash
# Domain from .env
export NEXUS="https://nexus.$(grep -E '^DOMAIN=' .env | cut -d= -f2-)"

# Or localhost
export NEXUS="https://nexus.localhost"
```

Group root:

```text
${NEXUS}/repository/apt/
```

Anonymous pull (no Authelia). Self-signed TLS: run `./scripts/trust-localhost-ca.sh` or trust `cert/<DOMAIN>/`.

---

## Trust the group key (once)

Indexes are **not** signed with Ubuntu/Debian/Kali keys. Trust this key instead:

```bash
sudo mkdir -p /etc/apt/keyrings
curl -fsS "${NEXUS}/repository/apt/key.asc" \
  | sudo tee /etc/apt/keyrings/nexus-apt-group.asc >/dev/null
```

Public key URL: `${NEXUS}/repository/apt/key.asc`  
(also `/repository/apt/pubkey.gpg`)

---

## Configure sources

Use `signed-by=` and the **same path** for every suite.

### Ubuntu (example: jammy)

```bash
cat <<EOF | sudo tee /etc/apt/sources.list.d/nexus-ubuntu.list
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] ${NEXUS}/repository/apt jammy main restricted universe multiverse
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] ${NEXUS}/repository/apt jammy-updates main restricted universe multiverse
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] ${NEXUS}/repository/apt jammy-security main restricted universe multiverse
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] ${NEXUS}/repository/apt jammy-backports main restricted universe multiverse
EOF
```

Noble: replace `jammy` with `noble`.

Ubuntu components: `main` `restricted` `universe` `multiverse`.

### Debian (example: bookworm)

```bash
cat <<EOF | sudo tee /etc/apt/sources.list.d/nexus-debian.list
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] ${NEXUS}/repository/apt bookworm main contrib non-free non-free-firmware
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] ${NEXUS}/repository/apt bookworm-updates main contrib non-free non-free-firmware
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] ${NEXUS}/repository/apt bookworm-security main contrib non-free non-free-firmware
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] ${NEXUS}/repository/apt bookworm-backports main contrib non-free non-free-firmware
EOF
```

Forky / trixie / sid: change the suite name the same way.

Debian components: `main` `contrib` `non-free` `non-free-firmware`.

### Kali

```bash
cat <<EOF | sudo tee /etc/apt/sources.list.d/nexus-kali.list
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] ${NEXUS}/repository/apt kali-rolling main contrib non-free non-free-firmware
EOF
```

---

## Update and install

```bash
sudo apt-get update
sudo apt-get install curl
```

Disable or remove old `sources.list` entries that point at `archive.ubuntu.com`, `deb.debian.org`, etc., so apt does not mix two archives for the same suite.

---

## What you get

| Behavior | Detail |
|----------|--------|
| Architectures | **amd64**, **i386** only |
| Versions | **Union** across members — newest is preferred; older versions stay listed while a member still has them (pins / downgrades work) |
| Suites | Allowlisted in `nexus/catalog.json` → `aptGroup.suites` |
| Members | Family-scoped (ubuntu / debian / kali proxies only for matching suites), ordered, capped by `maxMembersPerSuite` |
| Signing | Group OpenPGP key under `cert/apt-group/` (generated on first start) |

### Suites currently configured

Ubuntu: `jammy`, `jammy-updates`, `jammy-security`, `jammy-backports`, `noble`, `noble-updates`, `noble-security`, `noble-backports`

Debian: `bookworm` (+ updates/security/backports), `trixie` (+ …), `forky` (+ …), `sid`

Kali: `kali-rolling`, `kali-last-snapshot`, `kali-experimental`

Add or remove names in `nexus/catalog.json` → `aptGroup.suites`, then restart `apt-group`.

---

## First `apt-get update` can be slow

Cold suite merge pulls Packages indexes from a few mirrors (through Nexus), merges them, and signs. That can take on the order of **one to a few minutes** per suite the first time.

Later updates hit the in-memory / disk cache (TTL ~30 minutes by default: `metadataTtlSeconds`).

---

## Smoke checks

```bash
# service
curl -fsS "${NEXUS}/repository/apt/"
curl -fsS "${NEXUS}/repository/apt/key.asc" | head

# metadata (replace jammy if needed)
curl -fsS "${NEXUS}/repository/apt/dists/jammy/InRelease" | head -20
```

Expect a PGP-signed message with `Origin: nexus-apt-group` and `Architectures: amd64 i386`.

---

## Single-mirror proxies (optional)

Without the group, point at one Nexus apt proxy:

```bash
# example only — prefer the group for normal use
deb ${NEXUS}/repository/ubuntu-cdnir jammy main universe
deb ${NEXUS}/repository/debian-liara bookworm main
deb ${NEXUS}/repository/kali-kargadan kali-rolling main contrib non-free non-free-firmware
```

Those use **upstream** signatures (Ubuntu/Debian/Kali keys), not the group key. Proxy names are in `nexus/catalog.json` → `proxies.apt`.

---

## Ops / layout

| Piece | Role |
|-------|------|
| `apt-group` container | Merge, sign, serve `/repository/apt/` |
| Nexus apt proxies | Cache upstream bytes (`blob` store `apt`) |
| nginx | `^~ /repository/apt` → apt-group (ahead of generic Nexus `/repository/`) |
| `nexus/catalog.json` → `aptGroup` | Suites, member order, `maxMembersPerSuite`, timeouts |

```bash
# rebuild / restart group only
./scripts/compose.sh up -d --build apt-group
```

---

## Troubleshooting

| Symptom | What to try |
|---------|-------------|
| `NO_PUBKEY` / signature errors | Re-fetch `key.asc` into `/etc/apt/keyrings/` and keep `signed-by=` on every line |
| `503` / empty suite | No member returned Packages for that suite yet; check Nexus apt proxies and `docker logs` on `apt-group` |
| Unknown suite | Name must be in `aptGroup.suites` |
| Very slow first update | Normal on cold cache; wait, or pre-warm with `curl` on `dists/<suite>/InRelease` |
| Wrong arch (arm64, …) | Group only publishes amd64/i386 |
| Mix Ubuntu + Debian on one host | Do not enable both suites unless you intend a mixed system |

```bash
docker logs self-hosted-apt-group-1 --tail 80
docker compose --env-file .env --env-file .env.secrets ps apt-group nexus
```

---

## Related

- Package clients for other formats: `NEXUS.md`
- Catalog and proxy list: `nexus/catalog.json`
- Service code: `apt-group/`
