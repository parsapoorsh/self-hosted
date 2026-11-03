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
| [https://${domain}${https_port_suffix}](https://${domain}${https_port_suffix}/) | Landing (this site) |
| [https://auth.${domain}${https_port_suffix}](https://auth.${domain}${https_port_suffix}/) | Authelia (login / OIDC) |
| [https://cloud.${domain}${https_port_suffix}](https://cloud.${domain}${https_port_suffix}/) | Nextcloud |
| [https://chat.${domain}${https_port_suffix}](https://chat.${domain}${https_port_suffix}/) | Mattermost |
| [https://mirror.${domain}${https_port_suffix}](https://mirror.${domain}${https_port_suffix}/) | Nexspence UI + package APIs |
| [https://library.${domain}${https_port_suffix}](https://library.${domain}${https_port_suffix}/) | Kiwix |

---

## Quick links

- PyPI simple: [https://mirror.${domain}${https_port_suffix}/repository/pypi/simple/](https://mirror.${domain}${https_port_suffix}/repository/pypi/simple/)
