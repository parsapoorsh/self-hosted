---
title: README
page_title: README · ${domain}
---

# self-hosted · ${domain}

Docker Compose stack behind nginx: **Authelia** (SSO), **Nextcloud**, **Mattermost**, **Nexus Repository**, **Kiwix**, and a static landing page. One human admin is shared across the apps.

Public edge is **HTTPS** (`APP_SCHEME=https`). HTTP on `*.${domain}` redirects to HTTPS.

## Services

| Host | Service |
|------|---------|
| `https://${domain}` / `www` | Landing (`static/`, built from `docs/`) |
| `https://auth.${domain}` | Authelia (OIDC IdP) |
| `https://cloud.${domain}` | Nextcloud (OIDC via Authelia) |
| `https://mattermost.${domain}` | Mattermost (OIDC via Authelia) |
| `https://nexus.${domain}` | Nexus UI (OIDC) + package APIs |
| `https://kiwix.${domain}` | Kiwix (optional Anubis) |

Local aliases: `https://nexus.localhost/`, etc.

Package traffic on Nexus (`/repository/`, `/v2/`) stays on Nexus basic auth or anonymous access. The browser UI is gated by Authelia.

## Requirements

- Docker with Compose v2  
- Ports 80 / 443 free (or `HTTP_PORT` / `HTTPS_PORT`)  
- OpenSSL (cert scripts)  
- Python venv for landing pages: `venv/` + `docs/compiler/requirements.txt`  

## Quick start

```bash
cp .env.example .env
# Set DOMAIN=${domain}, APP_SCHEME=https, POSTGRES_PASSWORD, KEYCLOAK_ADMIN_PASSWORD

./scripts/self-signed.sh          # or real certs in cert/${domain}/
./scripts/build-static.sh         # docs → static/ (compose also builds if missing)
./scripts/compose.sh up -d
```

`./scripts/compose.sh` refreshes `.env.secrets`, checks domain certs, ensures `static/index.html` exists, runs compose, then `smoke-check` after `up -d`.

First boot can take a few minutes. Re-check anytime:

```bash
./scripts/smoke-check.sh
```

### Login

From `.env`:

- **Username:** `KEYCLOAK_ADMIN` (default `admin`)  
- **Password:** `KEYCLOAK_ADMIN_PASSWORD`  

Works for Authelia, Nextcloud, Mattermost (SSO), and Nexus UI / REST. (`KEYCLOAK_*` names are historical; the IdP is Authelia.)

Nexus bootstrap (every start): EULA, anonymous read, Rut Auth for SSO, `nexus/catalog.json` repos.

## Configuration

### Root `.env` (you edit)

| Variable | Purpose |
|----------|---------|
| `DOMAIN` | Apex domain (`${domain}`) |
| `APP_SCHEME` | **`https` in production** — OIDC redirect URLs (Authelia rejects non-localhost `http` callbacks) |
| `NEXUS_OAUTH2_COOKIE_SECURE` | `true` with HTTPS (default in compose) |
| `POSTGRES_PASSWORD` | Postgres superuser |
| `KEYCLOAK_ADMIN` / `_PASSWORD` | Shared app admin |

### Derived secrets

`./scripts/sync-secrets.sh` → gitignored `.env.secrets` (DB roles, Authelia HMAC, OIDC clients, oauth2 cookie).

Authelia session/OIDC state is stored in Postgres (`authelia` database), same as Nextcloud and Mattermost. The `auth.localhost` cookie domain is intentional so local TLS (`*.localhost`) and `auth.${domain}` share one IdP.

### Landing docs

| Path | Role |
|------|------|
| `docs/*.md` | Source (use `${domain}` for the apex name) |
| `scripts/build-static.sh` | Compile to `static/` with DOMAIN from `.env` |
| `static/` | Served by nginx (gitignored) |

```bash
./scripts/build-static.sh
# or: DOMAIN=other.example ./scripts/build-static.sh
```

## TLS

```bash
./scripts/self-signed.sh
# cert/${domain}/{fullchain,privkey}.pem
```

Localhost tree:

```bash
./scripts/gen-localhost-cert.sh
./scripts/trust-localhost-ca.sh
```

## Day-to-day

```bash
./scripts/compose.sh ps
./scripts/compose.sh logs -f authelia
./scripts/compose.sh restart nexus
./scripts/compose.sh down
```

### Authelia users

```bash
./scripts/authelia-users.py list
./scripts/authelia-users.py add alice --email alice@${domain}
./scripts/authelia-users.py set-password alice
./scripts/authelia-users.py sync-admin
```

Full wipe: `./scripts/reset.sh`

## How SSO is wired

1. **Authelia** — file users, OIDC clients `nextcloud` + `nexus` + `mattermost`, portal on `auth.${domain}`  
2. **Nextcloud** — `user_oidc` against Authelia  
3. **Mattermost** — GitLab SSO settings pointed at Authelia OIDC (`/signup/gitlab/complete`)  
4. **Nexus UI** — nginx `auth_request` → oauth2-proxy → Authelia → `X-Remote-User` / Rut Auth  

Redirect URI must be `https://nexus.${domain}/oauth2/callback` when the site is public HTTPS. Mattermost uses `https://mattermost.${domain}/signup/gitlab/complete`.

## Package mirrors

Client guide: **[Nexus](nexus.html)** — cargo, pip, docker, npm, go, …

Mirror priority in the catalog prefers **cdn.ir**, then **Arvancloud**, then other members.

## Layout

```
docker-compose.yml
.env / .env.example
docs/                        # markdown sources (${domain} placeholders)
static/                      # built HTML (gitignored)
authelia/ nextcloud/ mattermost/ nexus/
nginx/ postgres/ redis/
kiwix/ anubis/
scripts/                     # compose, build-static, certs, smoke
cert/                        # TLS (gitignored)
```

## Notes

- Do not commit `.env` or `.env.secrets`.  
- Changing `KEYCLOAK_ADMIN_PASSWORD` regenerates OIDC secrets on the next compose run.  
- Nexus is a large Java app; see `nexus/env` for heap caps.  
- If Cloudflare sits in front, use **Full (strict)** SSL so HTTP→HTTPS at origin does not loop.  
