# self-hosted * ${domain}

Docker Compose stack behind nginx: **Authentik** (SSO + self-signup), **Nextcloud**, **Mattermost**, **Nexspence** (package registry on `mirror.*`), **Kiwix**, and a static landing page. One human admin is shared across the apps; anyone can also create an account on the Authentik login page.

Public edge is **HTTPS**. HTTP on `*.${domain}` temporary-redirects (302) to HTTPS.

Optional edge ports via `.env`: `HTTP_PORT` / `HTTPS_PORT` (defaults 80 / 443). Non-default ports appear in public URLs and OIDC redirect URIs (open `https://chat.${domain}:8443` when `HTTPS_PORT=8443`).

## Services

| Host | Service |
|------|---------|
| `https://${domain}` / `www` | Landing (`static/`, built from `docs/`) |
| `https://auth.${domain}` | Authentik (OIDC IdP + Sign up) |
| `https://cloud.${domain}` | Nextcloud (OIDC via Authentik) |
| `https://chat.${domain}` | Mattermost (OIDC via Authentik) |
| `https://mirror.${domain}` | Nexspence UI (OIDC) + package APIs |
| `https://library.${domain}` | Kiwix (optional Anubis) |

Local aliases: `https://mirror.localhost/`, etc.

Package traffic (`/repository/`, `/v2/`) uses Nexspence basic auth or anonymous access. The browser UI uses native Authentik OIDC.

## Requirements

- Docker with Compose v2  
- Free host ports for the edge (defaults 80 / 443; override with `HTTP_PORT` / `HTTPS_PORT`)
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

Works for Authentik, Nextcloud, Mattermost (SSO), and Nexspence UI / REST. (`KEYCLOAK_*` names are historical; the IdP is Authentik.)

**Self-registration:** open `https://auth.${domain}/` and use **Sign up**.

Nexspence bootstrap (every start): anonymous read, `nexspence/catalog.json` repos (hosted / proxy / group).

## Configuration

### Root `.env` (you edit)

| Variable | Purpose |
|----------|---------|
| `DOMAIN` | Apex domain (`${domain}`) |
| `ORG_NAME` | Mattermost organization / default team name |
| `POSTGRES_PASSWORD` | Postgres superuser |
| `KEYCLOAK_ADMIN` / `_PASSWORD` | Shared app admin |
| `HTTP_PORT` / `HTTPS_PORT` | Edge publish + listen ports (default 80 / 443) |

### Derived secrets

`./scripts/sync-secrets.sh` -> gitignored `.env.secrets` (DB roles, Authentik secret/token, OIDC clients, Nexspence JWT/cookie).

Authentik state is stored in Postgres (`authentik` database), same host as Nextcloud, Mattermost, and Nexspence.

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
./scripts/compose.sh logs -f authentik
./scripts/compose.sh restart nexspence
./scripts/compose.sh down
```

### Authentik users

- **Self-signup:** `https://auth.${domain}/` → Sign up  
- **Admin UI:** `https://auth.${domain}/if/admin/` (akadmin or shared admin)  
- **API bootstrap token:** `AUTHENTIK_BOOTSTRAP_TOKEN` in `.env.secrets`

Full wipe: `./scripts/reset.sh`

## How SSO is wired

1. **Authentik** - OIDC apps `nextcloud` + `mirror` + `mattermost`, portal on `auth.${domain}`, open enrollment  
2. **Nextcloud** - `user_oidc` against Authentik (`/application/o/nextcloud/`)  
3. **Mattermost** - GitLab SSO settings pointed at Authentik OAuth2 endpoints  
4. **Nexspence UI** - native OIDC to Authentik (`/api/v1/auth/oidc/callback`); client id is `mirror`  

Redirect URI must be `https://mirror.${domain}/api/v1/auth/oidc/callback` when the site is public HTTPS (append `:${HTTPS_PORT}` when the edge is not on 443). Mattermost uses `https://chat.${domain}/signup/gitlab/complete` with the same port rule.

## Package mirrors

Client guide: **[Mirror](docs/MIRROR.md)** - cargo, pip, docker, npm, go, ... (hostname remains `mirror.${domain}`)

Mirror priority in the catalog prefers **cdn.ir**, then **Arvancloud**, then other members. Group repos merge member indexes.

Composer is not offered by Nexspence (dropped from the catalog).

## Layout

```
docker-compose.yml
.env / .env.example
docs/                        # markdown sources (${domain} placeholders)
static/                      # built HTML (gitignored)
authentik/ nextcloud/ mattermost/ nexspence/
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
- Migration from Authelia: stop the stack, `./scripts/compose.sh up -d` (new `authentik` DB). Old Authelia file users are not imported; use Sign up or the admin UI.  
