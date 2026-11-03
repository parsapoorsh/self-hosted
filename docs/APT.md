---
title: APT
page_title: APT · nexus.${domain}
---

# APT repository

Ubuntu, Debian, and Kali packages from **https://nexus.${domain}/repository/apt/**

Use the same base URL for every suite. Only the suite name on the `deb` line changes.

Architectures: **amd64**, **i386**.

---

## 1. Trust the signing key

```bash
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://nexus.${domain}/repository/apt/key.asc \
  | sudo tee /etc/apt/keyrings/nexus-apt-group.asc >/dev/null
```

---

## 2. Add the repository

### Ubuntu (jammy)

```bash
sudo tee /etc/apt/sources.list.d/nexus-ubuntu.list >/dev/null <<'EOF'
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] https://nexus.${domain}/repository/apt jammy main restricted universe multiverse
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] https://nexus.${domain}/repository/apt jammy-updates main restricted universe multiverse
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] https://nexus.${domain}/repository/apt jammy-security main restricted universe multiverse
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] https://nexus.${domain}/repository/apt jammy-backports main restricted universe multiverse
EOF
```

For **noble**, replace `jammy` with `noble` on every line.

### Debian (bookworm)

```bash
sudo tee /etc/apt/sources.list.d/nexus-debian.list >/dev/null <<'EOF'
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] https://nexus.${domain}/repository/apt bookworm main contrib non-free non-free-firmware
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] https://nexus.${domain}/repository/apt bookworm-updates main contrib non-free non-free-firmware
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] https://nexus.${domain}/repository/apt bookworm-security main contrib non-free non-free-firmware
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] https://nexus.${domain}/repository/apt bookworm-backports main contrib non-free non-free-firmware
EOF
```

For **trixie**, **forky**, or **sid**, change the suite name the same way.

### Kali (kali-rolling)

```bash
sudo tee /etc/apt/sources.list.d/nexus-kali.list >/dev/null <<'EOF'
deb [signed-by=/etc/apt/keyrings/nexus-apt-group.asc] https://nexus.${domain}/repository/apt kali-rolling main contrib non-free non-free-firmware
EOF
```

---

## 3. Update and install

```bash
sudo apt-get update
sudo apt-get install curl
```

Disable other mirror lines for the same suite (for example `archive.ubuntu.com` or `deb.debian.org`) so apt only uses this repository.

---

## Available suites

| Distro | Suites |
|--------|--------|
| Ubuntu | `jammy`, `noble` (+ `-updates`, `-security`, `-backports`) |
| Debian | `bookworm`, `trixie`, `forky`, `sid` (+ pockets where listed) |
| Kali | `kali-rolling`, `kali-last-snapshot`, `kali-experimental` |

---

## Notes

- First `apt-get update` for a suite can take a few minutes while indexes are built.
- Package index is signed by this host’s key (`key.asc` above), not the stock Ubuntu/Debian/Kali keys.
- Other package ecosystems (pip, docker, npm, …): [Nexus](nexus.html)
