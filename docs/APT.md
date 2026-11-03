---
title: APT
page_title: APT · ${domain}
---

# APT on ${domain}

One base URL for **Ubuntu**, **Debian**, and **Kali**. The suite on the `deb` line picks the release (`jammy`, `bookworm`, `kali-rolling`, …). Indexes are merged from several Nexus apt proxies, re-signed with a local group key, and served by the **apt-group** sidecar.

Most clients should use the group. Single-mirror Nexus proxies remain available if you need one upstream only.

---

## Base URL

```bash
export NEXUS="https://nexus.${domain}"

# Local testing only:
# export NEXUS="https://nexus.localhost"
```

Group root: `${NEXUS}/repository/apt/`

Anonymous pull (no Authelia). HTTP redirects to HTTPS at the edge. Trust `cert/${domain}/` (or run `./scripts/trust-localhost-ca.sh` for localhost).

---

## Trust the group key (once)

Indexes are signed with the **group** key, not Ubuntu/Debian/Kali keys.

```bash
sudo mkdir -p /etc/apt/keyrings
curl -fsS "${NEXUS}/repository/apt/key.asc" \
  | sudo tee /etc/apt/keyrings/nexus-apt-group.asc >/dev/null
```

Key URL: `https://nexus.${domain}/repository/apt/key.asc`

---

## Configure sources

Use `signed-by=` and the **same path** for every suite.

### Ubuntu (jammy)

```bash
cat <<EOF | sudo tee /etc/apt/sources.list.d/nexus-ubuntu.list
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] ${NEXUS}/repository/apt jammy main restricted universe multiverse
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] ${NEXUS}/repository/apt jammy-updates main restricted universe multiverse
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] ${NEXUS}/repository/apt jammy-security main restricted universe multiverse
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] ${NEXUS}/repository/apt jammy-backports main restricted universe multiverse
EOF
```

For noble, replace `jammy` with `noble`. Components: `main` `restricted` `universe` `multiverse`.

### Debian (bookworm)

```bash
cat <<EOF | sudo tee /etc/apt/sources.list.d/nexus-debian.list
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] ${NEXUS}/repository/apt bookworm main contrib non-free non-free-firmware
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] ${NEXUS}/repository/apt bookworm-updates main contrib non-free non-free-firmware
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] ${NEXUS}/repository/apt bookworm-security main contrib non-free non-free-firmware
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] ${NEXUS}/repository/apt bookworm-backports main contrib non-free non-free-firmware
EOF
```

Forky / trixie / sid: change the suite name the same way. Components: `main` `contrib` `non-free` `non-free-firmware`.

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

Remove or disable old lines that point at `archive.ubuntu.com`, `deb.debian.org`, etc., so the same suite is not mixed from two archives.

---

## What you get

| | |
|--|--|
| Architectures | **amd64**, **i386** |
| Versions | **Union** across members — newest preferred; older builds stay listed while a member still has them |
| Suites | Allowlist in `nexus/catalog.json` → `aptGroup.suites` |
| Members | Family-scoped (ubuntu / debian / kali), ordered (**cdn.ir** then **Arvancloud** first), capped by `maxMembersPerSuite` |
| Signing | Group OpenPGP key in `cert/apt-group/` (created on first start) |

### Suites configured today

- **Ubuntu:** jammy, noble (+ updates / security / backports)
- **Debian:** bookworm, trixie, forky, sid (+ pockets where listed)
- **Kali:** kali-rolling, kali-last-snapshot, kali-experimental

Edit `aptGroup.suites`, then restart `apt-group`.

---

## First update can be slow

A cold suite merge downloads Packages indexes through Nexus, merges them, and signs. Expect on the order of **one to a few minutes** the first time. Later runs use cache (`metadataTtlSeconds`, default ~30 minutes).

---

## Smoke checks

```bash
curl -fsS "${NEXUS}/repository/apt/"
curl -fsS "${NEXUS}/repository/apt/key.asc" | head
curl -fsS "${NEXUS}/repository/apt/dists/jammy/InRelease" | head -20
```

Expect a clearsigned message with `Origin: nexus-apt-group` and `Architectures: amd64 i386`.

---

## Single-mirror proxies (optional)

```bash
# Prefer the group for normal use
deb ${NEXUS}/repository/ubuntu-cdnir jammy main universe
deb ${NEXUS}/repository/debian-liara bookworm main
deb ${NEXUS}/repository/kali-kargadan kali-rolling main contrib non-free non-free-firmware
```

These use **upstream** signatures. Names live under `nexus/catalog.json` → `proxies.apt`.

---

## Ops

| Piece | Role |
|-------|------|
| `apt-group` | Merge, sign, serve `/repository/apt/` |
| Nexus apt proxies | Cache upstream debs (`apt` blob store) |
| nginx | `^~ /repository/apt` → apt-group |
| `aptGroup` in catalog | Suites, member order, timeouts |

```bash
./scripts/compose.sh up -d --build apt-group
docker logs self-hosted-apt-group-1 --tail 80
```

---

## Troubleshooting

| Symptom | Try |
|---------|-----|
| `NO_PUBKEY` | Re-install `key.asc` and keep `signed-by=` on every line |
| `503` / empty suite | Check apt proxies and `apt-group` logs; cold members may be down |
| Unknown suite | Add it to `aptGroup.suites` |
| Slow first update | Normal on cold cache; pre-warm with curl on `InRelease` |
| arm64 / other arch | Group only publishes amd64 and i386 |
| OAuth / UI 403 | UI is separate; package paths stay anonymous HTTPS |

---

## Related

- Other ecosystems: [Nexus](nexus.html) · `docs/NEXUS.md`
- Stack install: [README](readme.html) · `docs/README.md`
- Catalog: `nexus/catalog.json` · code: `apt-group/`
