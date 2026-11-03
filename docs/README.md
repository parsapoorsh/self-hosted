---
title: README
page_title: README * ${domain}
---

# self-hosted * ${domain}

Docker Compose stack behind nginx: **Authelia** (SSO), **Nextcloud**, **Mattermost**, **Nexspence** (package registry on `mirror.*`), **Kiwix**, and a static landing page. One human admin is shared across the apps.

Public edge is **HTTPS**. HTTP on `*.${domain}` redirects to HTTPS.

## Services

| Host | Service |
|------|---------|
| `https://${domain}` / `www` | Landing (`static/`, built from `docs/`) |
| `https://auth.${domain}` | Authelia (OIDC IdP) |
| `https://cloud.${domain}` | Nextcloud (OIDC via Authelia) |
| `https://chat.${domain}` | Mattermost (OIDC via Authelia) |
| `https://mirror.${domain}` | Nexspence UI (OIDC) + package APIs |
| `https://library.${domain}` | Kiwix (optional Anubis) |

Local aliases: `https://mirror.localhost/`, etc.

Package traffic (`/repository/`, `/v2/`) uses Nexspence basic auth or anonymous access. The browser UI uses native Authelia OIDC ("Sign in with Authelia").

## Requirements

- Docker with Compose v2  
- Ports 80 / 443 free  
- OpenSSL (cert scripts)  
- Python venv for landing pages: `venv/` + `docs/compiler/requirements.txt`  

## Quick start

```bash
cp .env.example .env
# Set DOMAIN=${domain}, ORG_NAME, POSTGRES_PASSWORD, KEYCLOAK_ADMIN_PASSWORD

./scripts/self-signed.sh          # or real certs in cert/${domain}/
./scripts/build-static.sh         # docs -> static/ (compose also builds if missing)
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

Works for Authelia, Nextcloud, Mattermost (SSO), and Nexspence UI / REST. (`KEYCLOAK_*` names are historical; the IdP is Authelia.)

Nexspence bootstrap (every start): anonymous read, `nexspence/catalog.json` repos (hosted / proxy / group).

## Configuration

### Root `.env` (you edit)

| Variable | Purpose |
|----------|---------|
| `DOMAIN` | Apex domain (`${domain}`) |
| `ORG_NAME` | Mattermost organization / default team name |
| `POSTGRES_PASSWORD` | Postgres superuser |
| `KEYCLOAK_ADMIN` / `_PASSWORD` | Shared app admin |

### Derived secrets

`./scripts/sync-secrets.sh` -> gitignored `.env.secrets` (DB roles, Authelia HMAC, OIDC clients, Nexspence JWT/cookie).

Authelia session/OIDC state is stored in Postgres (`authelia` database), same as Nextcloud, Mattermost, and Nexspence. The `auth.localhost` cookie domain is intentional so local TLS (`*.localhost`) and `auth.${domain}` share one IdP.

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
./scripts/compose.sh restart nexspence
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

1. **Authelia** - file users, OIDC clients `nextcloud` + `mirror` + `mattermost`, portal on `auth.${domain}`  
2. **Nextcloud** - `user_oidc` against Authelia  
3. **Mattermost** - GitLab SSO settings pointed at Authelia OIDC (`/signup/gitlab/complete`)  
4. **Nexspence UI** - native OIDC to Authelia (`/api/v1/auth/oidc/callback`); OIDC client id is `mirror`  

Redirect URI must be `https://mirror.${domain}/api/v1/auth/oidc/callback` when the site is public HTTPS. Mattermost uses `https://chat.${domain}/signup/gitlab/complete`.

## Package mirrors

Client guide: **[Mirror](mirror.html)** - cargo, pip, docker, npm, go, ... (hostname remains `mirror.${domain}`)

Mirror priority in the catalog prefers **cdn.ir**, then **Arvancloud**, then other members. Group repos merge member indexes.

Composer is not offered by Nexspence (dropped from the catalog).

## Layout

```
docker-compose.yml
.env / .env.example
docs/                        # markdown sources (${domain} placeholders)
static/                      # built HTML (gitignored)
authelia/ nextcloud/ mattermost/ nexspence/
nginx/ postgres/ redis/
kiwix/ anubis/
scripts/                     # compose, build-static, certs, smoke
cert/                        # TLS (gitignored)
```

## Notes

- Do not commit `.env` or `.env.secrets`.  
- Changing `KEYCLOAK_ADMIN_PASSWORD` regenerates OIDC secrets on the next compose run.  
- Nexspence is a Go binary + shared Postgres (`nexspence` database); blobs in the `nexspence_blobs` volume.  
- If Cloudflare sits in front, use **Full (strict)** SSL so HTTP->HTTPS at origin does not loop.  
