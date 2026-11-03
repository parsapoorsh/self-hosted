---
title: ${domain}
page_title: Self-hosted * ${domain}
---

<md-center>
![Logo](logo.svg){: width=22%}

# Self-hosted on **${domain}**

Authelia SSO * Nextcloud * Mattermost * Nexspence package mirrors * Kiwix
</md-center>

---

## Guides

| Guide | What it covers |
|-------|----------------|
| **[Mirror](mirror.html)** | Cargo, pip, Docker, npm, Go, NuGet, Alpine, Hugging Face, and more |
| **[README](readme.html)** | Install the stack, TLS, SSO, day-to-day ops |

---

## Live hosts

| URL | Service |
|-----|---------|
| [https://${domain}](https://${domain}/) | Landing (this site) |
| [https://auth.${domain}](https://auth.${domain}/) | Authelia (login / OIDC) |
| [https://cloud.${domain}](https://cloud.${domain}/) | Nextcloud |
| [https://chat.${domain}](https://chat.${domain}/) | Mattermost |
| [https://mirror.${domain}](https://mirror.${domain}/) | Nexspence UI + package APIs |
| [https://library.${domain}](https://library.${domain}/) | Kiwix |

---

## Quick links

- PyPI simple: [https://mirror.${domain}/repository/pypi/simple/](https://mirror.${domain}/repository/pypi/simple/)

Local testing uses the same paths under `*.localhost` (for example `https://mirror.localhost/`).
