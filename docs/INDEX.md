---
title: ${domain}
page_title: Self-hosted · ${domain}
---

<md-center>
![Logo](logo.svg){: width=22%}

# Self-hosted on **${domain}**

Authelia SSO · Nextcloud · Nexus package mirrors · APT group · Kiwix
</md-center>

---

## Guides

| Guide | What it covers |
|-------|----------------|
| **[APT](apt.html)** | Ubuntu, Debian, and Kali through the merged apt group (`/repository/apt/`) |
| **[Nexus](nexus.html)** | Cargo, pip, Docker, npm, Go, NuGet, Composer, Alpine, and more |
| **[README](readme.html)** | Install the stack, TLS, SSO, day-to-day ops |

---

## Live hosts

| URL | Service |
|-----|---------|
| [https://${domain}](https://${domain}/) | Landing (this site) |
| [https://auth.${domain}](https://auth.${domain}/) | Authelia (login / OIDC) |
| [https://cloud.${domain}](https://cloud.${domain}/) | Nextcloud |
| [https://nexus.${domain}](https://nexus.${domain}/) | Nexus UI + package APIs |
| [https://kiwix.${domain}](https://kiwix.${domain}/) | Kiwix |

HTTP on these names redirects to HTTPS. Package clients use **https://nexus.${domain}** (no Authelia on `/repository/` and `/v2/`).

---

## Quick links

- APT group root: [https://nexus.${domain}/repository/apt/](https://nexus.${domain}/repository/apt/)
- APT signing key: [https://nexus.${domain}/repository/apt/key.asc](https://nexus.${domain}/repository/apt/key.asc)
- PyPI simple: [https://nexus.${domain}/repository/pypi/simple/](https://nexus.${domain}/repository/pypi/simple/)

Local testing uses the same paths under `*.localhost` (for example `https://nexus.localhost/`).
